package app.marten.client.bg

import app.marten.client.constant.Status
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.ArrayDeque
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
 * A VPN Network owned by Marten is not proof that the current process owns its
 * generation. Package replacement can kill the process (and its retained PFD)
 * while ConnectivityManager still publishes the old Network for a short time.
 * That Network must disappear before a fresh process calls Builder.establish().
 */
internal fun shouldDeferVpnStartForUntrackedOwnNetwork(
    vpnMode: Boolean,
    retainedDescriptorValid: Boolean,
    vpnOwnershipKnown: Boolean,
    ownVpnNetworkActive: Boolean,
): Boolean =
    vpnMode &&
        !retainedDescriptorValid &&
        vpnOwnershipKnown &&
        ownVpnNetworkActive

/**
 * Resolves the asymmetric Android single-VPN-slot policy after owner UIDs are
 * known. A real foreign network always wins, except for the exact user start
 * that is still transferring ownership or its short, generation-scoped
 * overlap with the pre-existing foreign Network while ConnectivityManager
 * retires the old snapshot.
 */
internal fun shouldYieldForExternalVpnOwnership(
    externalVpnActive: Boolean,
    explicitUserStartPending: Boolean,
    vpnOwnershipWasEstablished: Boolean,
    explicitTakeoverOverlapAllowed: Boolean,
): Boolean =
    externalVpnActive &&
        !(
            (explicitUserStartPending && !vpnOwnershipWasEstablished) ||
                explicitTakeoverOverlapAllowed
            )

internal fun isExplicitVpnTakeoverOverlapAllowed(
    ownVpnActive: Boolean,
    currentGeneration: Long,
    takeoverGeneration: Long,
    nowElapsedRealtimeMs: Long,
    takeoverDeadlineElapsedRealtimeMs: Long,
    externalNetworkHandles: Set<Long>,
    preexistingExternalNetworkHandles: Set<Long>,
): Boolean =
    ownVpnActive &&
        takeoverGeneration == currentGeneration &&
        nowElapsedRealtimeMs <= takeoverDeadlineElapsedRealtimeMs &&
        externalNetworkHandles.isNotEmpty() &&
        preexistingExternalNetworkHandles.containsAll(externalNetworkHandles)

/**
 * The full-route blocking replacement session is only a manual
 * Marten-disconnect aid.
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
 * Identifies the full-route blocking VPN network created solely to retire Marten's
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
    if (coreStopped) {
        releaseFrameworkService()
    }
    return coreStopped
}

internal fun isPlatformStopReleaseComplete(
    coreStopped: Boolean,
    cleanupFinished: Boolean,
    vpnReleased: Boolean,
): Boolean = coreStopped && cleanupFinished && vpnReleased

/**
 * The user-visible Disconnect operation is complete once the service has
 * sealed new TUN admission and Android no longer exposes Marten's VPN network.
 * The one exact native close may still finish on its tracked process-wide
 * owner; every later setup/start remains blocked on that same close barrier.
 */
internal fun isPlatformStopSafeForUser(
    coreStopped: Boolean,
    vpnReleased: Boolean,
): Boolean = coreStopped && vpnReleased

internal fun shouldRecoverMissingOwnVpn(
    ownershipKnown: Boolean,
    ownVpnActive: Boolean,
    serviceOwnedTransitionActive: Boolean,
    consecutiveOwnVpnMisses: Int,
    requiredMisses: Int,
): Boolean =
    ownershipKnown &&
        !ownVpnActive &&
        !serviceOwnedTransitionActive &&
        consecutiveOwnVpnMisses >= requiredMisses.coerceAtLeast(1)

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
internal data class TerminalStopEpochClaim(
    val supersededUserSessionEpoch: Long?,
    val terminalSessionEpoch: Long,
)

internal object ServiceLifecycleOwnership {
    private const val FLUTTER_RESTART_LEASE_TIMEOUT_NANOS = 60_000_000_000L
    private const val LIFECYCLE_CLEANUP_TIMEOUT_MS = 15_000L
    private const val CLEANUP_REGISTRATION_POLL_MS = 20L
    private const val EXPLICIT_USER_STOP_HISTORY_LIMIT = 8
    private val sequence = AtomicLong(0L)
    private val operationSequence = AtomicLong(0L)
    private val operationLock = Any()
    private val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var currentOwnerToken = 0L
    private var nativeRecoveryOwnerToken: Long? = null
    private var flutterRestartLeaseToken: Long? = null
    private var flutterRestartLeaseSessionEpoch = 0L
    private var flutterRestartLeaseStartedAtNanos = 0L
    private var explicitStartLeaseToken: Long? = null
    private var explicitStartLeaseSessionEpoch = 0L
    private var terminalSessionEpoch = 0L
    private var terminalStopActive = false
    private var terminalStopSupersededUserSessionEpoch: Long? = null
    private val explicitlyStoppedUserSessionEpochs = ArrayDeque<Long>()
    private var operationChanged = CompletableDeferred<Unit>()
    private var pendingCleanup: Deferred<Unit>? = null
    private var lastCleanupOwnerToken = 0L

    fun acquire(): Long = synchronized(operationLock) {
        val token = sequence.incrementAndGet()
        currentOwnerToken = token
        signalOperationChangedLocked()
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
                // Wake terminal-release continuations as soon as cleanup is
                // registered. They must observe this exact owner and wait for
                // its completion instead of racing through the short gap
                // between Status.Stopped and VpnService.onDestroy().
                signalOperationChangedLocked()
            }
        }
        operation.invokeOnCompletion {
            synchronized(operationLock) {
                signalOperationChangedLocked()
            }
        }
        operation.start()
        return true
    }

    fun hasRegisteredCleanup(ownerToken: Long): Boolean = synchronized(operationLock) {
        lastCleanupOwnerToken == ownerToken
    }

    fun hasPendingCleanup(): Boolean = synchronized(operationLock) {
        pendingCleanup?.isCompleted == false
    }

    /**
     * Direct/protected diagnostics may reopen for a stopped app only while the
     * exact terminal epoch still owns lifecycle admission. A newly issued
     * Connect or restart lease makes an older release attempt stale before it
     * can touch the native probe gates.
     */
    fun ownsTerminalNetworkingRelease(): Boolean = synchronized(operationLock) {
        terminalStopActive &&
            explicitStartLeaseToken == null &&
            flutterRestartLeaseToken == null &&
            nativeRecoveryOwnerToken == null
    }

    /**
     * Runs one terminal networking-release continuation after every exact
     * lifecycle lease and predecessor cleanup has completed. The coroutine is
     * dormant between ownership events: there is no stopped-state timer or
     * polling wakeup. A newer Connect invalidates the terminal epoch and makes
     * the continuation exit before invoking [action].
     */
    fun runWhenTerminalNetworkingReleaseOwned(action: () -> Unit) {
        cleanupScope.launch {
            while (true) {
                val change = synchronized(operationLock) {
                    expireFlutterRestartLeaseIfNeeded()
                    if (!terminalStopActive) return@launch
                    val cleanupPending = pendingCleanup?.isCompleted == false
                    if (
                        explicitStartLeaseToken == null &&
                        flutterRestartLeaseToken == null &&
                        nativeRecoveryOwnerToken == null &&
                        !cleanupPending
                    ) {
                        null
                    } else {
                        operationChanged
                    }
                }
                if (change == null) {
                    action()
                    return@launch
                }
                change.await()
            }
        }
    }

    /**
     * Waits without polling until the terminal lifecycle owns networking
     * release and, when supplied, the exact stopped service has registered and
     * completed its onDestroy cleanup. A newer Connect invalidates the wait.
     */
    suspend fun awaitTerminalNetworkingReleaseOwned(
        requiredCleanupOwnerToken: Long?,
    ): Boolean {
        while (true) {
            val change = synchronized(operationLock) {
                expireFlutterRestartLeaseIfNeeded()
                if (!terminalStopActive) return false
                val cleanupRegistered =
                    requiredCleanupOwnerToken == null ||
                        lastCleanupOwnerToken >= requiredCleanupOwnerToken
                val cleanupPending = pendingCleanup?.isCompleted == false
                if (
                    explicitStartLeaseToken == null &&
                    flutterRestartLeaseToken == null &&
                    nativeRecoveryOwnerToken == null &&
                    cleanupRegistered &&
                    !cleanupPending
                ) {
                    null
                } else {
                    operationChanged
                }
            }
            if (change == null) return true
            change.await()
        }
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

    /** Waits event-first for the exact predecessor cleanup, without a timer. */
    suspend fun awaitPendingCleanupCompletion(ownerToken: Long): Boolean {
        val operation = synchronized(operationLock) {
            if (!isCurrent(ownerToken) || terminalStopActive) return false
            pendingCleanup
        }
        if (operation != null) {
            try {
                operation.await()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                // The replacement owns a fresh exact Mobile.close after this
                // predecessor barrier. A completed predecessor failure must
                // not strand that safer owner forever; only an unfinished or
                // cancelled wait remains a barrier.
            }
        }
        return synchronized(operationLock) {
            isCurrent(ownerToken) && !terminalStopActive
        }
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
                signalOperationChangedLocked()
            }
        }
    }

    /**
     * Waits for lifecycle ownership to change, with a sparse timeout only as a
     * liveness fallback. The caller must re-run exact admission afterwards.
     * A terminal Stop or service replacement ends the old owner's retry job.
     */
    suspend fun awaitNativeRecoveryAdmissionChange(
        ownerToken: Long,
        timeoutMs: Long,
    ): Boolean {
        val change = synchronized(operationLock) {
            expireFlutterRestartLeaseIfNeeded()
            if (!isCurrent(ownerToken) || terminalStopActive) return false
            operationChanged
        }
        withTimeoutOrNull(timeoutMs.coerceAtLeast(1L)) {
            change.await()
        }
        return synchronized(operationLock) {
            isCurrent(ownerToken) && !terminalStopActive
        }
    }

    /** Waits without polling until this service's exact native recovery lease is released. */
    suspend fun awaitNativeRecoveryRelease(ownerToken: Long): Boolean {
        while (true) {
            val change = synchronized(operationLock) {
                if (!isCurrent(ownerToken) || terminalStopActive) return false
                if (nativeRecoveryOwnerToken == null) return true
                operationChanged
            }
            change.await()
        }
    }

    fun tryAcquireFlutterRestart(): Long? = synchronized(operationLock) {
        expireFlutterRestartLeaseIfNeeded()
        if (terminalStopActive || nativeRecoveryOwnerToken != null || flutterRestartLeaseToken != null) {
            return@synchronized null
        }
        val token = operationSequence.incrementAndGet()
        flutterRestartLeaseToken = token
        flutterRestartLeaseSessionEpoch = terminalSessionEpoch
        flutterRestartLeaseStartedAtNanos = System.nanoTime()
        token
    }

    suspend fun awaitFlutterRestartLease(timeoutMs: Long): Long? {
        val token = withTimeoutOrNull(timeoutMs) {
            while (true) {
                var token: Long? = null
                var terminal = false
                val change = synchronized(operationLock) {
                    expireFlutterRestartLeaseIfNeeded()
                    terminal = terminalStopActive
                    if (!terminal && nativeRecoveryOwnerToken == null && flutterRestartLeaseToken == null) {
                        token = operationSequence.incrementAndGet()
                        flutterRestartLeaseToken = token
                        flutterRestartLeaseSessionEpoch = terminalSessionEpoch
                        flutterRestartLeaseStartedAtNanos = System.nanoTime()
                    }
                    operationChanged
                }
                if (terminal) return@withTimeoutOrNull 0L
                token?.let { return@withTimeoutOrNull it }
                change.await()
            }

            @Suppress("UNREACHABLE_CODE")
            0L
        }
        return token?.takeIf { it > 0L }
    }

    fun isFlutterRestartLeaseCurrent(token: Long): Boolean = synchronized(operationLock) {
        expireFlutterRestartLeaseIfNeeded()
        !terminalStopActive &&
            flutterRestartLeaseToken == token &&
            flutterRestartLeaseSessionEpoch == terminalSessionEpoch
    }

    /**
     * Reserves a native Connect command without clearing the durable Stop
     * tombstone. The lease is created while the native handoff lock is held;
     * a later terminal Stop invalidates its session epoch before admission can
     * publish fresh user intent.
     */
    fun issueExplicitStartLease(): Long = synchronized(operationLock) {
        val token = operationSequence.incrementAndGet()
        explicitStartLeaseToken = token
        explicitStartLeaseSessionEpoch = terminalSessionEpoch
        signalOperationChangedLocked()
        token
    }

    fun isExplicitStartLeaseCurrent(token: Long): Boolean = synchronized(operationLock) {
        explicitStartLeaseToken == token &&
            explicitStartLeaseSessionEpoch == terminalSessionEpoch
    }

    fun releaseExplicitStartLease(token: Long) {
        synchronized(operationLock) {
            if (explicitStartLeaseToken == token) {
                explicitStartLeaseToken = null
                explicitStartLeaseSessionEpoch = terminalSessionEpoch
                signalOperationChangedLocked()
            }
        }
    }

    /**
     * Validates the exact native Connect lease and executes the non-suspending
     * admission transaction under the same lifecycle lock used by Stop. A
     * token-less call is reserved for a synchronous native user entry; every
     * Flutter path (including a native handoff completed by Flutter) must
     * present the exact lease captured before its first asynchronous wait.
     */
    fun runExplicitUserSession(
        explicitStartLease: Long?,
        action: () -> Unit,
    ): Boolean = admitExplicitUserSession(explicitStartLease) { action() } != null

    /**
     * Admits a new user session and returns the exact terminal epoch that every
     * later Flutter start dispatch must carry. Stop advances this epoch before
     * persisting its tombstone, so an older prompt/coroutine cannot resurrect
     * user intent even after a newer Connect has been admitted.
     */
    fun admitExplicitUserSession(
        explicitStartLease: Long?,
        action: (Long) -> Unit,
    ): Long? = synchronized(operationLock) {
        if (
            explicitStartLease != null &&
            (
                explicitStartLeaseToken != explicitStartLease ||
                    explicitStartLeaseSessionEpoch != terminalSessionEpoch
            )
        ) {
            return@synchronized null
        }
        val admittedEpoch = terminalSessionEpoch
        action(admittedEpoch)
        terminalStopActive = false
        terminalStopSupersededUserSessionEpoch = null
        if (explicitStartLease == null || explicitStartLeaseToken == explicitStartLease) {
            explicitStartLeaseToken = null
            explicitStartLeaseSessionEpoch = terminalSessionEpoch
        }
        signalOperationChangedLocked()
        admittedEpoch
    }

    fun currentUserSessionEpoch(): Long? = synchronized(operationLock) {
        terminalSessionEpoch.takeUnless { terminalStopActive }
    }

    fun isUserSessionEpochCurrent(epoch: Long): Boolean = synchronized(operationLock) {
        !terminalStopActive && terminalSessionEpoch == epoch
    }

    /**
     * Reports whether a native user entry point explicitly stopped this exact
     * admitted Connect session. The small process-local history is sufficient:
     * a Dart start continuation cannot survive process death, while retaining
     * several epochs lets multiple delayed continuations resolve without a
     * newer Connect overwriting their ownership evidence.
     */
    fun wasUserSessionExplicitlyStopped(epoch: Long): Boolean = synchronized(operationLock) {
        explicitlyStoppedUserSessionEpochs.contains(epoch)
    }

    /** Executes a final non-suspending start dispatch atomically with Stop. */
    fun runIfUserSessionEpochCurrent(epoch: Long, action: () -> Unit): Boolean =
        synchronized(operationLock) {
            if (terminalStopActive || terminalSessionEpoch != epoch) {
                return@synchronized false
            }
            action()
            true
        }

    fun invalidateFlutterRestartForTerminalStop(
        explicitUserStop: Boolean = false,
    ): TerminalStopEpochClaim = synchronized(operationLock) {
        invalidateForTerminalStopLocked(explicitUserStop = explicitUserStop)
    }

    fun invalidateForTerminalStopIfUserSessionEpochCurrent(epoch: Long): TerminalStopEpochClaim? =
        synchronized(operationLock) {
            if (terminalStopActive || terminalSessionEpoch != epoch) {
                null
            } else {
                invalidateForTerminalStopLocked(explicitUserStop = false)
            }
        }

    fun currentTerminalStopEpoch(): Long? = synchronized(operationLock) {
        terminalSessionEpoch.takeIf { terminalStopActive }
    }

    fun isTerminalStopEpochCurrent(epoch: Long): Boolean = synchronized(operationLock) {
        terminalStopActive && terminalSessionEpoch == epoch
    }

    /**
     * Claims one exact terminal continuation. A Connect that wins before this
     * call makes the old continuation stale; a Connect that wins afterwards
     * observes every mutation performed by [action] before publishing the new
     * user session.
     */
    fun runIfTerminalStopEpochCurrent(epoch: Long, action: () -> Unit): Boolean =
        synchronized(operationLock) {
            if (!terminalStopActive || terminalSessionEpoch != epoch) {
                return@synchronized false
            }
            action()
            true
        }

    fun releaseFlutterRestart(token: Long) {
        synchronized(operationLock) {
            if (flutterRestartLeaseToken == token) {
                flutterRestartLeaseToken = null
                flutterRestartLeaseSessionEpoch = terminalSessionEpoch
                flutterRestartLeaseStartedAtNanos = 0L
                signalOperationChangedLocked()
            }
        }
    }

    private fun signalOperationChangedLocked() {
        operationChanged.complete(Unit)
        operationChanged = CompletableDeferred()
    }

    private fun invalidateForTerminalStopLocked(
        explicitUserStop: Boolean,
    ): TerminalStopEpochClaim {
        val supersededUserSessionEpoch = terminalSessionEpoch.takeUnless { terminalStopActive }
        if (supersededUserSessionEpoch != null) {
            terminalStopSupersededUserSessionEpoch = supersededUserSessionEpoch
        }
        // A failed-start cleanup can win the terminal claim a few instructions
        // before the already-issued tile/shortcut Stop reaches this lock. Keep
        // the exact predecessor on the active terminal transaction so that the
        // later user command still owns its visible outcome without relabeling
        // any unrelated or newer Connect generation.
        val explicitlyStoppedEpoch = if (explicitUserStop) {
            terminalStopSupersededUserSessionEpoch
        } else {
            null
        }
        if (explicitlyStoppedEpoch != null && !explicitlyStoppedUserSessionEpochs.contains(explicitlyStoppedEpoch)) {
            explicitlyStoppedUserSessionEpochs.addLast(explicitlyStoppedEpoch)
            while (explicitlyStoppedUserSessionEpochs.size > EXPLICIT_USER_STOP_HISTORY_LIMIT) {
                explicitlyStoppedUserSessionEpochs.removeFirst()
            }
        }
        terminalStopActive = true
        terminalSessionEpoch++
        flutterRestartLeaseToken = null
        flutterRestartLeaseSessionEpoch = terminalSessionEpoch
        flutterRestartLeaseStartedAtNanos = 0L
        explicitStartLeaseToken = null
        explicitStartLeaseSessionEpoch = terminalSessionEpoch
        signalOperationChangedLocked()
        return TerminalStopEpochClaim(
            supersededUserSessionEpoch = supersededUserSessionEpoch,
            terminalSessionEpoch = terminalSessionEpoch,
        )
    }

    private fun expireFlutterRestartLeaseIfNeeded() {
        if (
            flutterRestartLeaseToken != null &&
            flutterRestartLeaseStartedAtNanos > 0L &&
            System.nanoTime() - flutterRestartLeaseStartedAtNanos >= FLUTTER_RESTART_LEASE_TIMEOUT_NANOS
        ) {
            flutterRestartLeaseToken = null
            flutterRestartLeaseSessionEpoch = terminalSessionEpoch
            flutterRestartLeaseStartedAtNanos = 0L
            signalOperationChangedLocked()
        }
    }
}
