package app.marten.client.bg

import app.marten.client.constant.Status
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicLong

internal fun shouldContinueCoreLifecycleOperation(
    operationGeneration: Long,
    currentGeneration: Long,
    userSessionActive: Boolean,
): Boolean = operationGeneration == currentGeneration && userSessionActive

internal fun shouldAcceptTunFileDescriptor(
    ownerIsCurrent: Boolean,
    userSessionActive: Boolean,
    status: Status,
): Boolean =
    ownerIsCurrent &&
        userSessionActive &&
        status != Status.Stopping &&
        status != Status.Stopped

/**
 * Android exposes a single device-wide VPN slot. A fresh Marten generation
 * must not claim that slot while another VPN may own it unless Android has
 * just mediated an explicit user transfer through VpnService.prepare(). Exact
 * ownership of an already-running Marten generation is the other exception.
 */
internal fun shouldRejectNewVpnGeneration(
    vpnMode: Boolean,
    explicitUserStart: Boolean,
    currentGenerationOwnsVpn: Boolean,
    vpnNetworkVisibilityKnown: Boolean,
    anyVpnNetworkActive: Boolean,
    externalVpnNetworkActive: Boolean,
): Boolean {
    if (!vpnMode) return false
    // VpnService.prepare() is Android's user-mediated ownership transfer.
    // Only that one explicit start may replace the currently prepared VPN.
    if (explicitUserStart) return false
    if (externalVpnNetworkActive) return true
    if (currentGenerationOwnsVpn) return false
    return !vpnNetworkVisibilityKnown || anyVpnNetworkActive
}

/**
 * The no-route replacement session is only a manual Marten-disconnect aid.
 * Re-establishing it after Android revoked Marten would compete with the VPN
 * that has just taken ownership of the system slot.
 */
internal fun shouldRetirePlatformVpnAfterCoreStop(
    coreStopped: Boolean,
    vpnService: Boolean,
    vpnOwnershipRevoked: Boolean,
    externalVpnActive: Boolean,
): Boolean =
    coreStopped &&
        vpnService &&
        !vpnOwnershipRevoked &&
        !externalVpnActive

/**
 * Identifies the no-route VPN network created solely to retire Marten's
 * previous framework session.
 *
 * The documentation-only IPv4 marker makes the replacement distinguishable
 * from the data TUN without depending on hidden `android.net.VpnTransportInfo`
 * APIs. Android 12+ must also report Marten as the owner; older releases keep
 * the conservative address-based fallback because ownerUid is unavailable.
 */
internal fun isMartenRetirementNetworkCandidate(
    vpnTransport: Boolean,
    ownerVerificationRequired: Boolean,
    ownerIsMarten: Boolean,
    hasRetirementAddress: Boolean,
): Boolean =
    vpnTransport &&
        hasRetirementAddress &&
        (!ownerVerificationRequired || ownerIsMarten)

internal suspend fun requestAuthoritativePlatformStop(
    requestCoreStop: () -> Unit,
    awaitCoreStop: suspend () -> Boolean,
    releaseFrameworkService: () -> Unit,
): Boolean {
    requestCoreStop()
    val coreStopped = awaitCoreStop()
    releaseFrameworkService()
    return coreStopped
}

internal fun isPlatformStopReleaseComplete(
    coreStopped: Boolean,
    cleanupFinished: Boolean,
    vpnReleased: Boolean,
): Boolean = coreStopped && cleanupFinished && vpnReleased

/**
 * The user-visible Disconnect operation is complete once the native runtime
 * and its owned descriptors are gone. Some Android builds keep reporting the
 * already inert VPN network agent for a short time after that point. That
 * framework lag is handled by the service and must not surface as an internal
 * Flutter error dialog.
 */
internal fun isPlatformStopSafeForUser(
    coreStopped: Boolean,
    cleanupFinished: Boolean,
): Boolean = coreStopped && cleanupFinished

internal fun shouldStopForLostVpnOwnership(
    externalVpnActive: Boolean,
    authorizationRevoked: Boolean,
    ownershipKnown: Boolean,
    ownVpnActive: Boolean,
    consecutiveOwnVpnMisses: Int,
    requiredMisses: Int,
): Boolean =
    externalVpnActive ||
        authorizationRevoked ||
        (
            ownershipKnown &&
                !ownVpnActive &&
                consecutiveOwnVpnMisses >= requiredMisses.coerceAtLeast(1)
            )

internal fun isQuiescentBoundServiceState(
    status: Status,
    coreShutdownCompleted: Boolean,
    stopOperationActive: Boolean,
): Boolean =
    status == Status.Stopped &&
        coreShutdownCompleted &&
        !stopOperationActive

internal data class PlatformStopReleaseState(
    val coreStopped: Boolean,
    val cleanupFinished: Boolean,
    val vpnReleased: Boolean,
    val quiescentBoundOwner: Boolean,
)

/**
 * Waits for every Android-side release barrier under one monotonic deadline.
 *
 * Framework service destruction owns the final native cleanup, while removal
 * of Android's VPN network can lag behind that destruction. Waiting for them
 * in this order prevents a normal framework delay from being mistaken for a
 * wedged VPN process.
 */
internal suspend fun awaitPlatformStopRelease(
    coreStopped: Boolean,
    timeoutMs: Long,
    isQuiescentBoundOwner: () -> Boolean,
    awaitCleanupAfterStop: suspend (timeoutMs: Long) -> Boolean,
    isOwnVpnActive: () -> Boolean,
    pollIntervalMs: Long,
    nowNanos: () -> Long = System::nanoTime,
    pause: suspend (delayMs: Long) -> Unit = { delay(it) },
): PlatformStopReleaseState {
    if (!coreStopped) {
        return PlatformStopReleaseState(
            coreStopped = false,
            cleanupFinished = false,
            vpnReleased = !isOwnVpnActive(),
            quiescentBoundOwner = false,
        )
    }

    val timeoutNanos = timeoutMs.coerceAtLeast(0L) * 1_000_000L
    val deadlineNanos = nowNanos() + timeoutNanos
    fun remainingMillis(): Long {
        val remainingNanos = deadlineNanos - nowNanos()
        if (remainingNanos <= 0L) return 0L
        return ((remainingNanos + 999_999L) / 1_000_000L).coerceAtLeast(1L)
    }

    val quiescentBoundOwner = isQuiescentBoundOwner()
    val cleanupFinished = if (quiescentBoundOwner) {
        true
    } else {
        val cleanupTimeoutMs = remainingMillis()
        cleanupTimeoutMs > 0L && awaitCleanupAfterStop(cleanupTimeoutMs)
    }

    var vpnReleased = !isOwnVpnActive()
    while (!vpnReleased) {
        val remainingMs = remainingMillis()
        if (remainingMs <= 0L) break
        pause(minOf(pollIntervalMs.coerceAtLeast(1L), remainingMs))
        vpnReleased = !isOwnVpnActive()
    }

    return PlatformStopReleaseState(
        coreStopped = true,
        cleanupFinished = cleanupFinished,
        vpnReleased = vpnReleased,
        quiescentBoundOwner = quiescentBoundOwner,
    )
}

/**
 * Identifies the newest Android service instance in this process.
 *
 * Android may construct a replacement service before the previous instance's
 * asynchronous onDestroy cleanup runs. Shared resources must only be changed
 * by the newest owner.
 */
internal object ServiceLifecycleOwnership {
    private const val FLUTTER_RESTART_LEASE_TIMEOUT_NANOS = 60_000_000_000L
    private const val LIFECYCLE_CLEANUP_TIMEOUT_MS = 15_000L
    private const val CLEANUP_REGISTRATION_POLL_MS = 20L
    private val sequence = AtomicLong(0L)
    private val operationSequence = AtomicLong(0L)
    private val operationLock = Any()
    private val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var currentOwnerToken = 0L
    private var nativeRecoveryOwnerToken: Long? = null
    private var flutterRestartLeaseToken: Long? = null
    private var flutterRestartLeaseStartedAtNanos = 0L
    private var pendingCleanup: Deferred<Unit>? = null
    private var lastCleanupOwnerToken = 0L

    fun acquire(): Long = synchronized(operationLock) {
        val token = sequence.incrementAndGet()
        currentOwnerToken = token
        token
    }

    fun isCurrent(ownerToken: Long): Boolean = ownerToken == currentOwnerToken

    /**
     * Runs a shared-resource mutation atomically with respect to service-owner
     * replacement. The action must stay small and must not suspend.
     */
    fun runIfCurrent(ownerToken: Long, action: () -> Unit): Boolean = synchronized(operationLock) {
        if (!isCurrent(ownerToken)) {
            return@synchronized false
        }
        action()
        true
    }

    /**
     * Registers cleanup before Android can construct the replacement service.
     *
     * Once admitted, cleanup remains authoritative even if [acquire] installs a
     * newer owner. A replacement must call [awaitPendingCleanup] before touching
     * the native core or shared network monitor.
     */
    fun beginCleanup(ownerToken: Long, cleanup: suspend () -> Unit): Boolean {
        val operation = synchronized(operationLock) {
            if (!isCurrent(ownerToken) || lastCleanupOwnerToken == ownerToken) {
                return false
            }

            val previous = pendingCleanup
            cleanupScope.async(start = CoroutineStart.LAZY) {
                previous?.let {
                    // A failed predecessor must not prevent the current owner
                    // from making its own best-effort cleanup attempt.
                    runCatching { it.await() }
                }
                cleanup()
            }.also {
                pendingCleanup = it
                lastCleanupOwnerToken = ownerToken
            }
        }
        operation.start()
        return true
    }

    suspend fun awaitPendingCleanup(
        ownerToken: Long,
        timeoutMs: Long = LIFECYCLE_CLEANUP_TIMEOUT_MS,
    ): Boolean {
        val operation = synchronized(operationLock) {
            if (!isCurrent(ownerToken)) {
                return false
            }
            pendingCleanup
        }
        if (operation != null) {
            val completedSuccessfully = try {
                withTimeoutOrNull(timeoutMs) {
                    operation.await()
                    true
                } ?: false
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                false
            }
            if (!completedSuccessfully) {
                return false
            }
        }
        return isCurrent(ownerToken)
    }

    /**
     * Waits for a stopped service to register its onDestroy cleanup and for
     * that cleanup to finish. Unlike [awaitPendingCleanup], this is owned by
     * the service being stopped, so it remains valid if Android constructs a
     * replacement owner while teardown is being delivered.
     */
    suspend fun awaitCleanupAfterStop(
        ownerToken: Long,
        timeoutMs: Long = LIFECYCLE_CLEANUP_TIMEOUT_MS,
    ): Boolean {
        if (ownerToken <= 0L) return true
        val timeoutNanos = timeoutMs.coerceAtLeast(0L) * 1_000_000L
        val deadlineNanos = System.nanoTime() + timeoutNanos

        while (true) {
            val operation = synchronized(operationLock) {
                if (lastCleanupOwnerToken >= ownerToken) pendingCleanup else null
            }
            val remainingNanos = deadlineNanos - System.nanoTime()
            if (operation != null) {
                if (remainingNanos <= 0L) return false
                val remainingMillis = ((remainingNanos + 999_999L) / 1_000_000L).coerceAtLeast(1L)
                return try {
                    withTimeoutOrNull(remainingMillis) {
                        operation.await()
                        true
                    } ?: false
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Throwable) {
                    false
                }
            }
            if (remainingNanos <= 0L) return false
            val remainingMillis = ((remainingNanos + 999_999L) / 1_000_000L).coerceAtLeast(1L)
            delay(minOf(CLEANUP_REGISTRATION_POLL_MS, remainingMillis))
        }
    }

    fun tryAcquireNativeRecovery(ownerToken: Long): Boolean = synchronized(operationLock) {
        expireFlutterRestartLeaseIfNeeded()
        if (!isCurrent(ownerToken) || nativeRecoveryOwnerToken != null || flutterRestartLeaseToken != null) {
            return@synchronized false
        }
        nativeRecoveryOwnerToken = ownerToken
        true
    }

    fun releaseNativeRecovery(ownerToken: Long) {
        synchronized(operationLock) {
            if (nativeRecoveryOwnerToken == ownerToken) {
                nativeRecoveryOwnerToken = null
            }
        }
    }

    fun tryAcquireFlutterRestart(): Long? = synchronized(operationLock) {
        expireFlutterRestartLeaseIfNeeded()
        if (nativeRecoveryOwnerToken != null || flutterRestartLeaseToken != null) {
            return@synchronized null
        }
        val token = operationSequence.incrementAndGet()
        flutterRestartLeaseToken = token
        flutterRestartLeaseStartedAtNanos = System.nanoTime()
        token
    }

    fun releaseFlutterRestart(token: Long) {
        synchronized(operationLock) {
            if (flutterRestartLeaseToken == token) {
                flutterRestartLeaseToken = null
                flutterRestartLeaseStartedAtNanos = 0L
            }
        }
    }

    private fun expireFlutterRestartLeaseIfNeeded() {
        if (
            flutterRestartLeaseToken != null &&
            flutterRestartLeaseStartedAtNanos > 0L &&
            System.nanoTime() - flutterRestartLeaseStartedAtNanos >= FLUTTER_RESTART_LEASE_TIMEOUT_NANOS
        ) {
            flutterRestartLeaseToken = null
            flutterRestartLeaseStartedAtNanos = 0L
        }
    }
}
