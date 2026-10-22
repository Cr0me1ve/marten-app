package app.marten.client.bg

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.TrafficStats
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.Observer
import app.marten.client.Application
import app.marten.client.R
import app.marten.client.Settings
import app.marten.client.constant.Action
import app.marten.client.constant.Alert
import app.marten.client.constant.Status
import app.marten.client.crashreporting.NativeCrashDiagnostics
import app.marten.native_resume.NativeResumeConfigStore
import app.marten.client.utils.GrpcClientProvider

import go.Seq
import app.marten.core.api.v2.hcommon.Empty
import app.marten.core.api.v2.hcore.CoreClient
import app.marten.core.api.v2.hcore.CoreStates
import app.marten.core.api.v2.hcore.TurncoatRouteEvidence
import app.marten.core.api.v2.hcore.UrlTestRequest
import app.marten.core.libbox.Libbox
import app.marten.client.bg.RemoteMobile as Mobile


import app.marten.core.libbox.CommandServer
import app.marten.core.libbox.CommandServerHandler
import app.marten.core.libbox.InterfaceUpdateListener
import app.marten.core.libbox.Notification
import app.marten.core.libbox.PlatformInterface
import app.marten.core.libbox.SystemProxyStatus
import app.marten.client.BuildConfig
import app.marten.client.MainActivity
import app.marten.client.NativeConnectRequestBridge
import app.marten.client.NativeConnectDispatchResult
import app.marten.client.NativeTerminalStopClaim
import app.marten.client.constant.Bugs
import app.marten.client.constant.ServiceMode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.channels.Channel
import java.io.File
import java.net.NetworkInterface
import java.util.concurrent.atomic.AtomicBoolean

private class RuntimeConfigIdentityMismatchException : IllegalStateException(
    "active VPN configuration does not belong to the current runtime generation",
)

internal fun initialPlatformStatusForStickyReplacement(
    adoptedStickyTunHandoff: Boolean,
    platformShutdownCompleted: Boolean,
): Status =
    if (adoptedStickyTunHandoff && !platformShutdownCompleted) {
        Status.Starting
    } else {
        Status.Stopped
    }

class BoxService(
        private val service: Service,
        private val platformInterface: PlatformInterface
)  {

    companion object {
        private const val TAG = "A/BoxService"
        private const val CORE_WATCHDOG_CONFIRM_MS = 250L
        private const val CORE_WATCHDOG_GRPC_TIMEOUT_MS = 2_500L
        private const val CORE_RECOVERY_BACKOFF_MS = 2_000L
        private const val CORE_NATIVE_START_GRACE_MS = 20_000L
        private const val CORE_NATIVE_STARTING_STALL_MS = 20_000L
        private const val LEGACY_PROCESS_RECOVERY_REQUEST_CODE = 4031
        // Closing the retained Android descriptor and the native duplicate is
        // asynchronous under load. Two seconds produced false-positive
        // cleanup failures and killed the foreground app during an otherwise
        // healthy Disconnect/start cancellation. Keep this bounded, but give
        // Android enough time to remove the TUN before the current generation
        // is failed closed and its framework VPN is retired.
        private const val TUN_RELEASE_TIMEOUT_MS = 5_000L
        private const val TUN_RELEASE_POLL_MS = 100L
        private const val FAIL_CLOSED_VPN_RETRY_MS = 250L
        private const val FAIL_CLOSED_VPN_INSTALL_TIMEOUT_MS = 5_000L
        private const val CORE_RECOVERY_ONLINE_TIMEOUT_MS = 45_000L
        private val platformStatus = MutableLiveData(Status.Stopped)
        private val platformStatusHandler = Handler(Looper.getMainLooper())
        private const val CORE_RECOVERY_TURNCOAT_ONLINE_TIMEOUT_MS = 120_000L
        private const val CORE_FLUTTER_START_GRACE_MS = 5_000L
        private const val CORE_FLUTTER_STARTING_STALL_MS = 45_000L
        // Flutter first verifies the selected outbound, then Android performs
        // an independent VPN-network probe. Allow both bounded checks to finish
        // before native recovery is admitted; the shorter window raced a
        // successful slow route and could close the core during acknowledgement.
        // The Android VPN-bound GET can spend up to 30s bringing up a lazy
        // TURNcoat carrier on restricted mobile networks. Native recovery must
        // not tear that verified-route acknowledgement down mid-probe.
        private const val CORE_UNVERIFIED_STARTUP_RECOVERY_GRACE_MS = 45_000L
        private const val ROUTE_WATCHDOG_GROUP = "select"
        private const val ROUTE_WATCHDOG_GRPC_TIMEOUT_MS = 8_000L
        private const val ROUTE_WATCHDOG_OPERATION_TIMEOUT_MS = 11_000L
        private const val ROUTE_RECOVERY_BACKOFF_MS = 10_000L
        private const val ROUTE_WATCHDOG_MAX_FAILURES = 3
        private const val ROUTE_WATCHDOG_TIMEOUT_DELAY = 65_535
        private const val ROUTE_WAKE_CHECK_DELAY_MS = 1_500L
        private const val NETWORK_ROUTE_RECOVERY_RETRY_MS = 2_000L
        private const val NETWORK_ROUTE_RECOVERY_MAX_ATTEMPTS = 3
        private const val ROUTE_WATCHDOG_HEALTH_LOG_EVERY = 30
        private const val STARTUP_ROUTE_VERIFY_TIMEOUT_MS = 12_000L
        private const val STARTUP_ROUTE_VERIFY_TURNCOAT_TIMEOUT_MS = 75_000L
        private const val STARTUP_ROUTE_VERIFY_RETRY_MS = 700L
        private const val CORE_START_ADMISSION_TIMEOUT_MS = 60_000L
        private const val EXTERNAL_VPN_OWNERSHIP_LOSS_CONFIRMATIONS = 2
        private const val MARK_STARTED_TUN_SETTLE_MS = 750L
        private const val MARK_STARTED_TUN_POLL_MS = 100L
        private const val VPN_START_ADMISSION_TIMEOUT_MS = 12_000L
        private const val EXPLICIT_VPN_TAKEOVER_OVERLAP_GRACE_MS = 5_000L
        private const val UNTRACKED_OWN_VPN_RELEASE_TIMEOUT_MS = 5_000L

        private data class VpnOwnershipSnapshot(
            val visibilityKnown: Boolean,
            val known: Boolean,
            val anyActive: Boolean,
            val active: Boolean,
            val externalActive: Boolean,
            val interfaceNames: Set<String>,
            val vpnNetworkHandles: Set<Long>,
            val ownNetworkHandles: Set<Long>,
            val externalNetworkHandles: Set<Long>,
        )

        @Volatile
        private var activeInstance: BoxService? = null

        internal suspend fun awaitStartupNetwork(userSessionEpoch: Long): Boolean {
            val owner = activeInstance ?: return false
            val generation = owner.currentStartGeneration()
            fun current(): Boolean = activeInstance === owner &&
                ServiceLifecycleOwnership.isUserSessionEpochCurrent(userSessionEpoch) &&
                owner.shouldContinueStart(generation)
            if (!current()) return false
            val available = DefaultNetworkMonitor.awaitUsableNetwork(owner.serviceOwnerToken)
            return available && current()
        }

        /**
         * Optional headless work may create a Flutter engine only while the
         * live service still owns a fresh proof for its exact start, Network,
         * and TUN generations. The earlier blocker-only admission is enough to
         * prevent bypass, but it is deliberately not enough to wake a second
         * engine during startup or recovery.
         */
        internal fun hasVerifiedRouteForOptionalBackgroundWork(): Boolean =
            activeInstance?.hasVerifiedRouteForOptionalBackgroundWork() == true

        /**
         * Allows optional headless work after the exact Marten VPN lifecycle
         * has released its ownership. This is intentionally stricter than
         * merely observing a false route-proof preference: a cancelled start
         * can clear that preference while its fail-closed TUN is still alive.
         */
        internal fun hasTerminalOrdinaryNetworkAdmissionForOptionalBackgroundWork(): Boolean {
            val current = activeInstance
            return !Settings.startedByUser &&
                !ServiceLifecycleOwnership.hasPendingCleanup() &&
                !hasPendingStickyTunHandoff() &&
                current?.hasRetainedVpnDescriptor() != true &&
                !isOwnVpnActive(Application.application)
        }

        /**
         * Joins a late Flutter engine to the exact already-admitted Android VPN
         * generation without creating a new transition. This is deliberately
         * read-only: if any native probe gate, route proof, TUN or lifecycle
         * owner is no longer current, Flutter must take the normal seal +
         * resume-admission path instead.
         */
        internal fun tryJoinVerifiedVpnAdmission(): Long? {
            val current = activeInstance ?: return null
            val sessionEpoch = ServiceLifecycleOwnership.currentUserSessionEpoch() ?: return null
            var routeStillAdmitted = false
            val sessionStillCurrent = ServiceLifecycleOwnership.runIfUserSessionEpochCurrent(sessionEpoch) {
                routeStillAdmitted =
                    LocalProbeAdmission.isAllowed() &&
                        current.hasVerifiedRouteForOptionalBackgroundWork()
            }
            return sessionEpoch.takeIf { sessionStillCurrent && routeStillAdmitted }
        }

        /**
         * Reopens protected local diagnostics only for the exact native seal
         * that is still current and only after either a fresh VPN route proof
         * or a fully released terminal VPN/TUN owner. The admission predicate
         * runs under LocalProbeAdmission's ordering lock, so a newer seal wins.
         */
        internal fun tryAllowLocalProbesForCurrentState(blockEpoch: Long): Boolean =
            LocalProbeAdmission.allowIfCurrent(
                blockEpoch,
                ::canReleaseLocalProbesForCurrentState,
            )

        /**
         * The Flutter terminal frame can arrive after the VPN/TUN barrier but
         * before Android delivers VpnService.onDestroy(). Join that exact
         * service cleanup event before retrying the current probe epoch. This
         * is transition-only and event-driven: no stopped-state polling loop,
         * recurring timer, wake lock or radio work is introduced.
         */
        internal suspend fun awaitLocalProbesForCurrentState(blockEpoch: Long): Boolean {
            if (tryAllowLocalProbesForCurrentState(blockEpoch)) return true
            val requiredCleanupOwnerToken = activeInstance
                ?.takeUnless { it.platformShutdownCompleted }
                ?.serviceOwnerToken
            if (
                !ServiceLifecycleOwnership.awaitTerminalNetworkingReleaseOwned(
                    requiredCleanupOwnerToken,
                )
            ) {
                return false
            }
            return tryAllowLocalProbesForCurrentState(blockEpoch)
        }

        private fun canReleaseLocalProbesForCurrentState(): Boolean {
            val current = activeInstance
            if (current?.hasVerifiedRouteForOptionalBackgroundWork() == true) {
                return true
            }
            // The exact retirement Network's onLost callback and TUN barrier
            // are authoritative. ConnectivityManager's global VPN snapshot can
            // retain that already-retired owner for a short OEM-dependent
            // interval; requiring the stale snapshot as well strands the
            // current terminal epoch even though no descriptor can carry data.
            val platformNetworkingReleased =
                current?.platformShutdownCompleted == true ||
                    !isOwnVpnActive(Application.application)
            val terminalOwner = ServiceLifecycleOwnership.ownsTerminalNetworkingRelease()
            val stoppedByUser = !Settings.startedByUser
            val nativeAdmissionClosed = !NativeCrashDiagnostics.isNetworkAdmissionAllowed()
            val cleanupComplete = !ServiceLifecycleOwnership.hasPendingCleanup()
            val stickyTunReleased = !hasPendingStickyTunHandoff()
            val currentTunReleased = current?.hasRetainedVpnDescriptor() != true
            val terminalPlatformReleaseOwned = terminalOwner &&
                stoppedByUser &&
                nativeAdmissionClosed &&
                cleanupComplete &&
                stickyTunReleased &&
                currentTunReleased &&
                platformNetworkingReleased
            val released = terminalPlatformReleaseOwned
            if (!released) {
                Log.i(
                    TAG,
                    "terminal probe release deferred " +
                        "terminal_owner=$terminalOwner stopped=$stoppedByUser " +
                        "native_closed=$nativeAdmissionClosed cleanup_complete=$cleanupComplete " +
                        "sticky_tun_released=$stickyTunReleased current_tun_released=$currentTunReleased " +
                        "platform_released=$platformNetworkingReleased " +
                        "platform_barrier=${current?.platformShutdownCompleted == true}",
                )
            }
            return released
        }

        private fun releaseLocalProbesWhenTerminalOwnerIsReady(
            blockEpoch: Long,
            reason: String,
        ) {
            ServiceLifecycleOwnership.runWhenTerminalNetworkingReleaseOwned {
                val released = tryAllowLocalProbesForCurrentState(blockEpoch)
                Log.i(
                    TAG,
                    "event-driven terminal probe release reason=$reason released=$released",
                )
            }
        }

        private val vpnStartAdmissionLock = Any()
        private data class VpnStartAdmission(
            val userSessionEpoch: Long,
            val completion: CompletableDeferred<Result<Unit>>,
        )

        private var vpnStartAdmission: VpnStartAdmission? = null

        /**
         * First Android transaction for a user Connect (or a cold persisted
         * session): establish a physical full-route packet sink before Flutter
         * persists intent, initializes
         * network SDKs, prepares configuration, or starts the native core.
         */
        suspend fun beginVpnStartAdmission(
            resumeSession: Boolean,
            explicitStartLease: Long? = null,
            nativeHandoffClaim: Boolean = false,
        ): Long {
            require(!resumeSession || explicitStartLease == null) {
                "automatic VPN resume cannot consume an explicit Connect lease"
            }
            require(!resumeSession || !nativeHandoffClaim) {
                "automatic VPN resume cannot complete a native Connect handoff"
            }
            require(!nativeHandoffClaim || explicitStartLease != null) {
                "native Connect handoff completion requires its exact start lease"
            }
            require(resumeSession || explicitStartLease != null) {
                "manual Flutter VPN admission requires an exact pre-Stop start lease"
            }
            if (resumeSession && !Settings.startedByUser) {
                NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)
                Settings.startCoreAfterStartingService = false
                error("automatic VPN resume rejected without durable native user intent")
            }
            val sessionEpoch = if (!resumeSession) {
                val admittedEpoch = ServiceLifecycleOwnership.admitExplicitUserSession(
                    explicitStartLease,
                ) {
                    // Validate and durably publish this exact lease before it
                    // is allowed to observe or complete any shared admission.
                    Settings.startedByUser = true
                    Settings.startCoreAfterStartingService = false
                    check(Settings.startedByUser) {
                        "explicit VPN start could not replace durable terminal stop"
                    }
                }
                if (admittedEpoch == null) {
                    explicitStartLease?.let(NativeConnectRequestBridge::completeFlutterConnectClaim)
                    error("native Connect lease was superseded by terminal stop")
                }
                if (
                    nativeHandoffClaim &&
                    !NativeConnectRequestBridge.completeFlutterConnectClaim(checkNotNull(explicitStartLease))
                ) {
                    error("terminal stop invalidated native Connect during admission")
                }
                admittedEpoch
            } else {
                ServiceLifecycleOwnership.currentUserSessionEpoch()?.takeIf {
                    Settings.startedByUser
                } ?: error("automatic VPN resume superseded by terminal stop")
            }

            // A Flutter engine can attach after an Always-on/package-replace
            // restore has already crossed strict Android admission. Likewise,
            // a duplicate exact user lease can safely join that admitted
            // process. Joining must happen before sealing the process-wide
            // gate: sealing first makes hasProcessNetworkAdmission() false,
            // sends a redundant command that the active service ignores, and
            // eventually terminally aborts a healthy VPN on timeout.
            val current = activeInstance
            val currentAdmissionReady = current?.hasProcessNetworkAdmission() == true
            if (currentAdmissionReady) {
                check(
                    ServiceLifecycleOwnership.isUserSessionEpochCurrent(sessionEpoch) &&
                        Settings.startedByUser,
                ) { "terminal stop superseded active VPN admission join" }
                return sessionEpoch
            }
            LocalProbeAdmission.blockAndCancel()
            NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)
            Settings.strictVpnRouteVerified = false

            val (admission, shouldStart) = synchronized(vpnStartAdmissionLock) {
                val pending = vpnStartAdmission?.takeIf {
                    it.userSessionEpoch == sessionEpoch && it.completion.isActive
                }
                if (pending != null) {
                    pending.completion to false
                } else {
                    vpnStartAdmission
                        ?.takeIf {
                            it.userSessionEpoch != sessionEpoch && it.completion.isActive
                        }
                        ?.completion
                        ?.complete(
                            Result.failure(
                                IllegalStateException("VPN admission superseded by a newer exact user session"),
                            ),
                        )
                    val created = VpnStartAdmission(
                        userSessionEpoch = sessionEpoch,
                        completion = CompletableDeferred(),
                    )
                    vpnStartAdmission = created
                    created.completion to true
                }
            }

            if (shouldStart) {
                val dispatched = ServiceLifecycleOwnership.runIfUserSessionEpochCurrent(sessionEpoch) {
                    check(Settings.startedByUser) {
                        "terminal stop superseded VPN admission dispatch"
                    }
                    val intent = Intent(Application.application, Settings.serviceClass())
                        .setAction(
                            if (resumeSession) {
                                Action.SERVICE_RECOVER
                            } else {
                                Action.SERVICE_PREPARE_VPN
                            },
                        )
                        .putExtra(Action.EXTRA_USER_INITIATED, !resumeSession)
                    if (!resumeSession) {
                        intent.putExtra(Action.EXTRA_USER_SESSION_EPOCH, sessionEpoch)
                    }
                    ContextCompat.startForegroundService(Application.application, intent)
                }
                if (!dispatched) {
                    completeVpnStartAdmissionFailure(
                        sessionEpoch,
                        "terminal stop superseded VPN admission dispatch",
                    )
                    error("terminal stop superseded VPN admission dispatch")
                }
            }

            val outcome = withTimeoutOrNull(VPN_START_ADMISSION_TIMEOUT_MS) {
                checkNotNull(admission).await()
            }
            if (outcome == null) {
                if (
                    activeInstance?.hasProcessNetworkAdmission() == true &&
                    ServiceLifecycleOwnership.isUserSessionEpochCurrent(sessionEpoch) &&
                    Settings.startedByUser
                ) {
                    return sessionEpoch
                }
                abortVpnStartAdmission(sessionEpoch, "Android VPN admission timed out")
                error("Android VPN admission timed out")
            }
            outcome.exceptionOrNull()?.let { failure ->
                abortVpnStartAdmission(
                    sessionEpoch,
                    failure.message ?: "Android VPN admission failed",
                )
                throw failure
            }
            check(
                ServiceLifecycleOwnership.isUserSessionEpochCurrent(sessionEpoch) &&
                    Settings.startedByUser,
            ) { "terminal stop superseded completed VPN admission" }
            return sessionEpoch
        }

        fun abortVpnStartAdmission(userSessionEpoch: Long, reason: String) {
            Log.w(TAG, "aborting strict VPN start admission: $reason")
            val probeBlock = LocalProbeAdmission.ensureBlockedAndCancel()
            val terminalClaim =
                NativeConnectRequestBridge.cancelPendingFlutterConnectIfUserSessionEpochCurrent(
                    userSessionEpoch,
                )
            if (terminalClaim == null) {
                completeVpnStartAdmissionFailure(userSessionEpoch, reason)
                tryAllowLocalProbesForCurrentState(probeBlock.epoch)
                Log.i(TAG, "stale VPN admission abort ignored for epoch=$userSessionEpoch")
                return
            }
            val terminalIntent = persistTerminalStopIntent(
                reason = reason,
                preclaimedTerminalStop = terminalClaim,
                preblockedProbeEpoch = probeBlock.epoch,
            )
            dispatchTerminalStopIntent(terminalIntent)
        }

        private fun completeVpnStartAdmissionSuccess(userSessionEpoch: Long?) {
            if (userSessionEpoch == null) return
            synchronized(vpnStartAdmissionLock) {
                vpnStartAdmission
                    ?.takeIf {
                        it.userSessionEpoch == userSessionEpoch &&
                            it.completion.isActive
                    }
                    ?.completion
                    ?.complete(Result.success(Unit))
            }
        }

        private fun completeVpnStartAdmissionFailure(
            userSessionEpoch: Long?,
            message: String,
        ) {
            if (userSessionEpoch == null) return
            synchronized(vpnStartAdmissionLock) {
                vpnStartAdmission
                    ?.takeIf {
                        it.userSessionEpoch == userSessionEpoch &&
                            it.completion.isActive
                    }
                    ?.completion
                    ?.complete(Result.failure(IllegalStateException(message)))
            }
        }

        private data class StickyTunHandoff(
            val descriptor: ParcelFileDescriptor,
            val ownerToken: Long,
            val failClosedVpnGeneration: FailClosedVpnGeneration?,
        )

        private data class TerminalStickyTunCloseResult(
            val ownerToken: Long?,
            val released: Boolean,
        )

        private data class TerminalStopIntentResult(
            val persisted: Boolean,
            val probeBlockEpoch: Long,
            val terminalSessionEpoch: Long,
            val supersededUserSessionEpoch: Long?,
        )

        /** Serializes predecessor cleanup registration, TUN handoff and owner acquisition. */
        private val serviceReplacementLock = Any()
        private var stickyTunHandoff: StickyTunHandoff? = null

        /**
         * Transfers the framework-owned full-route descriptor between two
         * VpnService objects in the same process. Android lockdown deliberately
         * exempts the VPN app UID, so releasing this descriptor during a sticky
         * service replacement would let unrelated Marten sockets use the
         * physical default route.
         */
        private fun publishStickyTunHandoff(
            descriptor: ParcelFileDescriptor,
            ownerToken: Long,
            failClosedVpnGeneration: FailClosedVpnGeneration?,
        ): Boolean =
            synchronized(serviceReplacementLock) {
                val previous = stickyTunHandoff
                if (previous?.descriptor?.fileDescriptor?.valid() == true) {
                    return@synchronized false
                }
                if (previous != null) {
                    runCatching { previous.descriptor.close() }
                }
                stickyTunHandoff = StickyTunHandoff(
                    descriptor,
                    ownerToken,
                    failClosedVpnGeneration,
                )
                true
            }

        private fun claimStickyTunHandoff(): StickyTunHandoff? =
            synchronized(serviceReplacementLock) {
                val handoff = stickyTunHandoff
                stickyTunHandoff = null
                val descriptor = handoff?.descriptor
                handoff?.takeIf { descriptor?.fileDescriptor?.valid() == true }?.also {
                    Log.i(TAG, "adopted process-retained full-route TUN after sticky service replacement")
                } ?: run {
                    if (descriptor != null) {
                        runCatching { descriptor.close() }
                    }
                    null
                }
            }

        private fun closePendingStickyTunForTerminalStop(): TerminalStickyTunCloseResult =
            synchronized(serviceReplacementLock) {
                val handoff = stickyTunHandoff
                    ?: return@synchronized TerminalStickyTunCloseResult(
                        ownerToken = null,
                        released = true,
                    )
                stickyTunHandoff = null
                val failure = runCatching { handoff.descriptor.close() }.exceptionOrNull()
                val released = !handoff.descriptor.fileDescriptor.valid()
                if (!released) {
                    // Keep exact ownership visible if close failed. A later
                    // explicit Stop can retry; local physical probes stay
                    // blocked until the descriptor is actually retired.
                    stickyTunHandoff = handoff
                }
                failure?.let {
                    Log.e(TAG, "failed to close pending sticky TUN for terminal stop", it)
                }
                TerminalStickyTunCloseResult(
                    ownerToken = handoff.ownerToken,
                    released = released,
                )
            }

        /**
         * Persist and seal terminal intent before posting or starting any
         * asynchronous cleanup. This is bounded transition-only I/O: no poll,
         * timer, watchdog or wake lock remains active in the stopped state.
         */
        private fun persistTerminalStopIntent(
            reason: String,
            preclaimedTerminalStop: NativeTerminalStopClaim? = null,
            preblockedProbeEpoch: Long? = null,
            explicitUserStop: Boolean = false,
        ): TerminalStopIntentResult {
            check(!explicitUserStop || preclaimedTerminalStop == null) {
                "explicit user Stop ownership must be recorded during the atomic terminal claim"
            }
            val probeBlockEpoch =
                preblockedProbeEpoch ?: LocalProbeAdmission.ensureBlockedAndCancel().epoch
            val terminalClaim =
                preclaimedTerminalStop ?: NativeConnectRequestBridge.cancelPendingFlutterConnect(
                    explicitUserStop = explicitUserStop,
                )
            if (terminalClaim.cancelledHandoffId != null) {
                Log.i(
                    TAG,
                    "terminal stop cancelled native Connect handoff=${terminalClaim.cancelledHandoffId}",
                )
            }
            var persisted = false
            val terminalIntentStillCurrent =
                ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(
                    terminalClaim.terminalSessionEpoch,
                ) {
                    NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)
                    persisted = Settings.persistStoppedState()
                    if (!persisted) {
                        // commit() already makes the in-process preference
                        // values false. If both disk mechanisms fail,
                        // current-process recovery is still rejected and the
                        // retained Android VPN stays non-bypassable.
                        Settings.startedByUser = false
                        Settings.startCoreAfterStartingService = false
                        Log.e(
                            TAG,
                            "terminal stop storage unavailable; remaining fail-closed: $reason",
                        )
                    }
                }
            terminalClaim.supersededUserSessionEpoch?.let { supersededEpoch ->
                completeVpnStartAdmissionFailure(
                    supersededEpoch,
                    "terminal stop superseded VPN start admission",
                )
            }
            if (!terminalIntentStillCurrent) {
                Log.i(
                    TAG,
                    "terminal stop persistence skipped because a newer Connect won " +
                        "epoch=${terminalClaim.terminalSessionEpoch}",
                )
            }
            return TerminalStopIntentResult(
                persisted = terminalIntentStillCurrent && persisted,
                probeBlockEpoch = probeBlockEpoch,
                terminalSessionEpoch = terminalClaim.terminalSessionEpoch,
                supersededUserSessionEpoch = terminalClaim.supersededUserSessionEpoch,
            )
        }

        private fun hasPendingStickyTunHandoff(): Boolean =
            synchronized(serviceReplacementLock) {
                stickyTunHandoff?.descriptor?.fileDescriptor?.valid() == true
            }

        private var initializeOnce = false
        private lateinit var workingDir: File
        private fun initialize() {
            if (BuildConfig.DEBUG) {
                System.setProperty("GODEBUG", "stacktraceback=2")
            }
            if (initializeOnce) return
            val baseDir = Application.application.filesDir

            baseDir.mkdirs()
            workingDir = Application.application.getExternalFilesDir(null) ?: return
            workingDir.mkdirs()
            val tempDir = Application.application.cacheDir
            tempDir.mkdirs()
            NativeResumeConfigStore.cleanupPlaintextLeases(Application.application)
            Log.d(TAG, "base dir: ${baseDir.path}")
            Log.d(TAG, "working dir: ${workingDir.path}")
            Log.d(TAG, "temp dir: ${tempDir.path}")

//
            //Mobile.setup(baseDir.path, workingDir.path, tempDir.path,  2L ,"127.0.0.1:{Setting}","",false,this)
//            Libbox.setup(baseDir.path, workingDir.path, tempDir.path, false)

//            Libbox.setup(SetupOptions().also {
//                it.basePath = baseDir.path
//                it.workingPath = workingDir.path
//                it.tempPath = tempDir.path
//                it.fixAndroidStack = Bugs.fixAndroidStack
//
//            })
            Libbox.redirectStderr("/dev/null")
            initializeOnce = true
            return
        }

        fun start() {
            val intent = Intent(Application.application, Settings.serviceClass())
            ContextCompat.startForegroundService(Application.application, intent)
        }

        fun connect(
            userInitiated: Boolean = false,
            quickSettingsRequestId: Long = 0L,
            entrySource: String = "native_service",
            explicitStartLease: Long? = null,
        ) {
            val nativeConnect = {
                LocalProbeAdmission.blockAndCancel()
                NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)
                runCatching {
                    val sessionEpoch = ServiceLifecycleOwnership.admitExplicitUserSession(
                        explicitStartLease = explicitStartLease,
                    ) { epoch ->
                        Settings.startedByUser = true
                        check(Settings.startedByUser) {
                            "native Connect rejected because durable terminal stop could not be replaced"
                        }
                        Settings.startCoreAfterStartingService = true
                        val intent = Intent(Application.application, Settings.serviceClass())
                            .setAction(Action.SERVICE_CONNECT)
                            .putExtra(Action.EXTRA_USER_INITIATED, userInitiated)
                            .putExtra(Action.EXTRA_USER_SESSION_EPOCH, epoch)
                            .putExtra(Action.EXTRA_REQUEST_ID, maxOf(0L, quickSettingsRequestId))
                        ContextCompat.startForegroundService(Application.application, intent)
                    }
                    check(sessionEpoch != null) { "native Connect was superseded by terminal stop" }
                    true
                }.getOrElse {
                    Log.e(TAG, "native Connect admission failed", it)
                    dispatchTerminalStopIntent(
                        persistTerminalStopIntent("native Connect admission failed"),
                    )
                    false
                }
            }

            if (explicitStartLease != null) {
                when (
                    NativeConnectRequestBridge.dispatchExplicitConnect(
                        source = entrySource,
                        requestId = quickSettingsRequestId,
                        explicitStartLease = explicitStartLease,
                        nativeConnect = nativeConnect,
                    )
                ) {
                    NativeConnectDispatchResult.FLUTTER_HANDOFF -> Log.i(
                        TAG,
                        "permission-owned connect handed to live Flutter strict-egress gate source=${entrySource.ifBlank { "native" }}",
                    )

                    NativeConnectDispatchResult.NATIVE_STARTED -> Unit
                    NativeConnectDispatchResult.NO_ENGINE -> error(
                        "native Connect dispatch returned without an engine or native owner",
                    )
                    NativeConnectDispatchResult.REJECTED -> Log.i(
                        TAG,
                        "stale permission-owned connect rejected source=${entrySource.ifBlank { "native" }}",
                    )
                }
                return
            }

            if (NativeConnectRequestBridge.requestFlutterConnect(entrySource, quickSettingsRequestId)) {
                Log.i(
                    TAG,
                    "native connect handed to live Flutter strict-egress gate source=${entrySource.ifBlank { "native" }}",
                )
                return
            }
            nativeConnect()
        }

        fun stop(quickSettingsRequestId: Long = 0L) {
            val terminalIntent = persistTerminalStopIntent(
                reason = "explicit native user stop",
                explicitUserStop = true,
            )
            dispatchTerminalStopIntent(terminalIntent, quickSettingsRequestId)
        }

        /**
         * Flutter invokes this for both a user disconnect and failed-start
         * cleanup. Dart already owns its user-intent generation, so this route
         * deliberately does not manufacture native explicit-Stop evidence.
         */
        fun stopFromFlutter() {
            val terminalIntent = persistTerminalStopIntent("Flutter lifecycle stop")
            dispatchTerminalStopIntent(terminalIntent)
        }

        private fun dispatchTerminalStopIntent(
            terminalIntent: TerminalStopIntentResult,
            quickSettingsRequestId: Long = 0L,
        ) {
            if (
                !ServiceLifecycleOwnership.isTerminalStopEpochCurrent(
                    terminalIntent.terminalSessionEpoch,
                )
            ) {
                Log.i(
                    TAG,
                    "stale terminal Stop dispatch ignored epoch=${terminalIntent.terminalSessionEpoch}",
                )
                return
            }

            val instance = activeInstance
            if (instance == null) {
                var stickyTunClose = TerminalStickyTunCloseResult(
                    ownerToken = null,
                    released = false,
                )
                var probesReleased = false
                var durableStateUnavailable = false
                var terminalCleanupClaimed = false
                probesReleased =
                    LocalProbeAdmission.allowIfCurrent(
                        terminalIntent.probeBlockEpoch,
                    ) allow@{
                        if (
                            !ServiceLifecycleOwnership.isTerminalStopEpochCurrent(
                                terminalIntent.terminalSessionEpoch,
                            )
                        ) {
                            return@allow false
                        }
                        // Every production Connect/Stop seals LocalProbeAdmission
                        // before changing its lifecycle epoch. Its lock therefore
                        // keeps this exact terminal owner stable while the pending
                        // descriptor is closed, without nesting lifecycle and
                        // service-replacement locks in the opposite order.
                        terminalCleanupClaimed = true
                        if (!terminalIntent.persisted) {
                            durableStateUnavailable = true
                            return@allow false
                        }
                        stickyTunClose = closePendingStickyTunForTerminalStop()
                        if (!stickyTunClose.released) {
                            return@allow false
                        }
                        canReleaseLocalProbesForCurrentState()
                    }
                if (!terminalCleanupClaimed) {
                    Log.i(
                        TAG,
                        "terminal Stop without owner was superseded before cleanup " +
                            "epoch=${terminalIntent.terminalSessionEpoch}",
                    )
                    return
                }
                if (durableStateUnavailable) {
                    Log.e(
                        TAG,
                        "terminal Stop marker is not durable; retaining any process-owned full-route VPN handoff",
                    )
                    return
                }
                if (!probesReleased) {
                    releaseLocalProbesWhenTerminalOwnerIsReady(
                        terminalIntent.probeBlockEpoch,
                        "stop without active service owner",
                    )
                }
                if (!stickyTunClose.released) {
                    Log.e(
                        TAG,
                        "terminal Stop retained the pending full-route Android TUN after close failure",
                    )
                    return
                }
                Log.i(
                    TAG,
                    if (stickyTunClose.ownerToken != null) {
                        "terminal stop closed pending sticky Android TUN " +
                            "owner=${stickyTunClose.ownerToken} probes_released=$probesReleased"
                    } else {
                        "stop requested without an active Android service owner " +
                            "probes_released=$probesReleased"
                    },
                )
                if (quickSettingsRequestId > 0L) {
                    QuickSettingsDiagnostics.record(
                        Application.application,
                        component = "service",
                        event = "stop",
                        requestId = quickSettingsRequestId,
                        outcome = if (stickyTunClose.ownerToken != null) "closed_handoff" else "no_owner",
                        status = Status.Stopped,
                    )
                }
                return
            }

            // TileService, ShortcutActivity and MethodHandler share this
            // process. Admit their user stop directly into the service owner
            // so the caller can wait for the exact cleanup Job; a broadcast
            // leaves an avoidable registration window in which unbinding the
            // last client can destroy the service before it accepts Stop.
            if (Looper.myLooper() == Looper.getMainLooper()) {
                instance.stopService(
                    quickSettingsRequestId = quickSettingsRequestId,
                    terminalStopAlreadyClaimed = true,
                    terminalStateAlreadyPersisted = terminalIntent.persisted,
                    terminalProbeBlockEpoch = terminalIntent.probeBlockEpoch,
                    terminalSessionEpoch = terminalIntent.terminalSessionEpoch,
                )
            } else {
                instance.mainHandler.post {
                    val currentInstance = activeInstance
                    if (currentInstance == null) {
                        dispatchTerminalStopIntent(terminalIntent, quickSettingsRequestId)
                    } else {
                        currentInstance.stopService(
                            quickSettingsRequestId = quickSettingsRequestId,
                            terminalStopAlreadyClaimed = true,
                            terminalStateAlreadyPersisted = terminalIntent.persisted,
                            terminalProbeBlockEpoch = terminalIntent.probeBlockEpoch,
                            terminalSessionEpoch = terminalIntent.terminalSessionEpoch,
                        )
                    }
                }
            }
        }

        suspend fun acknowledgeVerifiedRoute(): Boolean {
            val instance = activeInstance
            if (instance == null) {
                Log.w(TAG, "refusing verified-route acknowledgement: Android service instance is absent")
                return false
            }
            return instance.acknowledgeVerifiedRouteFromFlutter()
        }

        fun currentPlatformStatus(): Status =
            activeInstance?.status?.value
                ?: if (hasPendingStickyTunHandoff()) Status.Starting else Status.Stopped

        /**
         * Observes the process-owned Android service lifecycle without relying
         * on a visible Activity binding. A retained Flutter engine remains a
         * lifecycle consumer after MainActivity stops, so its EventChannel
         * must still receive revoke, external-takeover and terminal cleanup
         * transitions from the authoritative service owner.
         */
        internal fun observePlatformStatus(observer: Observer<Status>) {
            fun observeOnMain() {
                platformStatus.value = currentPlatformStatus()
                platformStatus.observeForever(observer)
            }
            if (Looper.myLooper() == Looper.getMainLooper()) {
                observeOnMain()
            } else {
                platformStatusHandler.post(::observeOnMain)
            }
        }

        internal fun removePlatformStatusObserver(observer: Observer<Status>) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                platformStatus.removeObserver(observer)
            } else {
                platformStatusHandler.post { platformStatus.removeObserver(observer) }
            }
        }

        private fun publishPlatformStatus(owner: BoxService, nextStatus: Status) {
            fun publishOnMain() {
                if (activeInstance === owner) {
                    platformStatus.value = nextStatus
                }
            }
            if (Looper.myLooper() == Looper.getMainLooper()) {
                publishOnMain()
            } else {
                platformStatusHandler.post(::publishOnMain)
            }
        }

        private fun publishCurrentPlatformStatus() {
            fun publishOnMain() {
                platformStatus.value = currentPlatformStatus()
            }
            if (Looper.myLooper() == Looper.getMainLooper()) {
                publishOnMain()
            } else {
                platformStatusHandler.post(::publishOnMain)
            }
        }

        fun currentRuntimeConfigMatches(fingerprint: String): Boolean {
            val instance = activeInstance ?: return false
            if (!ServiceLifecycleOwnership.isCurrent(instance.serviceOwnerToken)) return false
            return instance.runtimeConfigOwnership.matchesActive(
                status = instance.status.value ?: Status.Stopped,
                currentGeneration = instance.currentStartGeneration(),
                expectedFingerprint = fingerprint,
            )
        }

        /**
         * Returns the owner that can actually receive the stop request.
         *
         * The lifecycle registry's newest allocated token can briefly point
         * past [activeInstance] during rapid Android service replacement, so
         * it is not a safe stop-wait snapshot.
         */
        fun currentActiveOwnerToken(): Long? =
            activeInstance?.serviceOwnerToken
                ?: synchronized(serviceReplacementLock) { stickyTunHandoff?.ownerToken }

        fun isExternalVpnActive(context: Context, reason: String): Boolean {
            val ownership = readVpnOwnership(context)
            // Seeing Marten's old Network at the same time does not make a
            // foreign owner safe to ignore: that is exactly the overlap seen
            // while another VPN takes Android's single slot. The one opposite
            // direction (an explicit Marten takeover) is handled by the exact
            // generation-scoped allowance in the active service instance.
            val externalVpnActive = ownership.externalActive
            if (externalVpnActive) {
                Log.w(TAG, "another app owns an active VPN network during $reason")
            }
            return externalVpnActive
        }

        fun isOwnVpnActive(context: Context): Boolean {
            return readVpnOwnership(context).active
        }

        fun shouldRejectNewVpnStart(
            context: Context,
            reason: String,
            explicitUserStart: Boolean = false,
        ): Boolean {
            val ownership = readVpnOwnership(context)
            val instance = activeInstance
            val retainedDescriptorValid = instance?.let {
                synchronized(it.fileDescriptorLock) {
                    it.fileDescriptor?.fileDescriptor?.valid() == true
                }
            } == true
            val currentGenerationOwnsVpn =
                retainedDescriptorValid &&
                    (instance?.adoptedStickyTunHandoff == true ||
                        (instance?.status?.value != Status.Stopping &&
                            instance?.status?.value != Status.Stopped)) &&
                    (!ownership.known || ownership.active)
            val deferForUntrackedOwnVpn = shouldDeferVpnStartForUntrackedOwnNetwork(
                vpnMode = Settings.serviceMode == ServiceMode.VPN,
                retainedDescriptorValid = retainedDescriptorValid,
                vpnOwnershipKnown = ownership.known,
                ownVpnNetworkActive = ownership.active,
            )
            val explicitTakeoverOverlapAllowed =
                instance?.isExplicitTakeoverOverlapAllowed(ownership) == true
            val externalVpnActive = ownership.externalActive
            val rejected =
                !deferForUntrackedOwnVpn &&
                    shouldRejectNewVpnGeneration(
                        vpnMode = Settings.serviceMode == ServiceMode.VPN,
                        explicitUserStart = explicitUserStart || explicitTakeoverOverlapAllowed,
                        currentGenerationOwnsVpn = currentGenerationOwnsVpn,
                        vpnNetworkVisibilityKnown = ownership.visibilityKnown,
                        anyVpnNetworkActive = ownership.anyActive,
                        externalVpnNetworkActive = externalVpnActive,
                    )
            if (deferForUntrackedOwnVpn) {
                instance?.requireUntrackedOwnVpnRelease(ownership.ownNetworkHandles)
                Log.w(
                    TAG,
                    "deferring new Marten VPN generation during $reason until the " +
                        "untracked self-owned VPN Network is released",
                )
            }
            if (rejected) {
                Log.w(
                    TAG,
                    "rejecting new Marten VPN generation during $reason; " +
                        "visibility_known=${ownership.visibilityKnown} " +
                        "any_vpn=${ownership.anyActive} external_vpn_active=$externalVpnActive " +
                        "current_generation_owns_vpn=$currentGenerationOwnsVpn " +
                        "explicit_user_start=$explicitUserStart",
                )
            }
            return rejected
        }

        private fun readVpnOwnership(context: Context): VpnOwnershipSnapshot {
            val connectivity = context.getSystemService(ConnectivityManager::class.java)
                ?: return VpnOwnershipSnapshot(
                    visibilityKnown = false,
                    known = false,
                    anyActive = false,
                    active = false,
                    externalActive = false,
                    interfaceNames = emptySet(),
                    vpnNetworkHandles = emptySet(),
                    ownNetworkHandles = emptySet(),
                    externalNetworkHandles = emptySet(),
                )
            val vpnNetworks = runCatching {
                connectivity.allNetworks.filter { network ->
                    connectivity.getNetworkCapabilities(network)
                        ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
                }
            }.onFailure {
                Log.w(TAG, "failed to inspect active Android VPN networks", it)
            }.getOrElse {
                return VpnOwnershipSnapshot(
                    visibilityKnown = false,
                    known = false,
                    anyActive = false,
                    active = false,
                    externalActive = false,
                    interfaceNames = emptySet(),
                    vpnNetworkHandles = emptySet(),
                    ownNetworkHandles = emptySet(),
                    externalNetworkHandles = emptySet(),
                )
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                return VpnOwnershipSnapshot(
                    visibilityKnown = true,
                    known = false,
                    anyActive = vpnNetworks.isNotEmpty(),
                    active = false,
                    externalActive = false,
                    interfaceNames = emptySet(),
                    vpnNetworkHandles = vpnNetworks.mapTo(mutableSetOf()) { network ->
                        network.networkHandle
                    },
                    ownNetworkHandles = emptySet(),
                    externalNetworkHandles = emptySet(),
                )
            }
            val ownUid = context.applicationInfo.uid
            val ownerUids = vpnNetworks.associateWith { network ->
                connectivity.getNetworkCapabilities(network)?.ownerUid ?: -1
            }
            // Android can redact ownerUid even on API levels that expose the
            // property. Treat that as unknown ownership so runtime health uses
            // its conservative retained-descriptor/interface fallback. New
            // generation admission still sees anyActive and remains blocked.
            val ownershipKnown = ownerUids.values.none { it == -1 }
            val ownNetworks = if (ownershipKnown) {
                ownerUids.filterValues { it == ownUid }.keys
            } else {
                emptySet()
            }
            val externalActive = ownershipKnown && ownerUids.values.any { it != ownUid }
            val externalNetworks = if (ownershipKnown) {
                ownerUids.filterValues { it != ownUid }.keys
            } else {
                emptySet()
            }
            return VpnOwnershipSnapshot(
                visibilityKnown = true,
                known = ownershipKnown,
                anyActive = vpnNetworks.isNotEmpty(),
                active = ownNetworks.isNotEmpty(),
                externalActive = externalActive,
                interfaceNames = ownNetworks.mapNotNull { network ->
                    connectivity.getLinkProperties(network)?.interfaceName
                }.toSet(),
                vpnNetworkHandles = vpnNetworks.mapTo(mutableSetOf()) { network ->
                    network.networkHandle
                },
                ownNetworkHandles = ownNetworks.mapTo(mutableSetOf()) { network ->
                    network.networkHandle
                },
                externalNetworkHandles = externalNetworks.mapTo(mutableSetOf()) { network ->
                    network.networkHandle
                },
            )
        }

        suspend fun awaitAuthoritativeStop(ownerToken: Long, timeoutMs: Long): Boolean {
            val stoppedInstance = activeInstance
            if (stoppedInstance == null) {
                return !hasPendingStickyTunHandoff()
            }
            if (stoppedInstance.serviceOwnerToken != ownerToken) return false

            return withTimeoutOrNull(timeoutMs.coerceAtLeast(0L)) {
                var completed: Boolean? = null
                while (completed == null) {
                    val stopJob = stoppedInstance.serviceStopJob
                    if (stopJob == null) {
                        if (
                            stoppedInstance.status.value == Status.Stopped &&
                            stoppedInstance.platformShutdownCompleted
                        ) {
                            completed = true
                            continue
                        }
                        // A non-main-thread request can be posted to the owner.
                        // Do not mistake that short admission window for a
                        // stopped core or race teardown against native close.
                        delay(10L)
                        continue
                    }

                    stopJob.join()
                    completed =
                        stoppedInstance.status.value == Status.Stopped &&
                            stoppedInstance.platformShutdownCompleted
                }
                completed == true
            } ?: false
        }

        fun isQuiescentBoundOwner(ownerToken: Long): Boolean {
            val instance = activeInstance ?: return false
            if (instance.serviceOwnerToken != ownerToken) return false
            return isQuiescentBoundServiceState(
                status = instance.status.value ?: Status.Stopped,
                coreShutdownCompleted = instance.coreShutdownCompleted,
                // The completed Job is retained so late waiters can join it.
                // It is not an outstanding cleanup barrier and must not make a
                // stopped, bound service wait for an onDestroy that may never
                // arrive while MainActivity intentionally keeps the binding.
                stopOperationActive = instance.serviceStopJob?.isActive == true,
            )
        }


    }

    private enum class TunDescriptorMode {
        NONE,
        FAIL_CLOSED,
        DATA_PLANE,
    }

    private data class ServiceStartRequest(
        val generation: Long,
        val allowStoredIdentityMigration: Boolean,
        val userSessionEpoch: Long,
    )

    private data class DeferredConnectAfterStop(
        val intent: Intent,
        val flags: Int,
        val userSessionEpoch: Long,
    )

    private data class DeferredTerminalStopAfterCleanup(
        val predecessorJob: Job,
        val terminalIntent: TerminalStopIntentResult,
        val keepNotification: Boolean,
        val vpnRevoked: Boolean,
        val quickSettingsRequestId: Long,
    )

    private data class FailClosedSessionHold(
        val generation: Long,
        val userSessionEpoch: Long,
        var resumeRequested: Boolean,
        var cleanupReady: Boolean = false,
    )

    private val fileDescriptorLock = Any()
    private var fileDescriptor: ParcelFileDescriptor? = null
    private var tunDescriptorMode = TunDescriptorMode.NONE
    private var failClosedVpnGeneration: FailClosedVpnGeneration? = null
    private var adoptedStickyTunHandoff = false
    // Every service instance starts fail closed. Admission is opened only after
    // pending service cleanup and the exact process-wide Mobile.close operation
    // have both completed for the accepted start generation.
    private var tunDescriptorAdmissionClosed = true
    @Volatile
    private var tunGeneration = 0L
    private var serviceOwnerToken = 0L
    private val serviceJob = SupervisorJob()
    private val serviceScope = CoroutineScope(serviceJob + Dispatchers.IO)

    private val status = MutableLiveData(Status.Stopped)
    private val processStatusObserver = Observer<Status> { nextStatus ->
        publishPlatformStatus(this, nextStatus)
    }
    private val binder = ServiceBinder(status)
    private val notification = ServiceNotification(status, service)
//    private var boxService: BoxService? = null
    private var commandServer: CommandServer? = null
    private val lifecycleLock = Any()
    private val runtimeConfigOwnership = RuntimeConfigOwnership()
    private var receiverRegistered = false
    @Volatile
    private var startGeneration = 0L
    @Volatile
    private var keepStoppedNotificationOnDestroy = false
    @Volatile
    private var closedByStopService = false
    @Volatile
    // A service created only by bindService() has never admitted a core/TUN
    // start, so it begins quiescent. startService() flips this to false before
    // it touches service-owned native state.
    private var coreShutdownCompleted = true
    @Volatile
    // Manual Disconnect is safe for the user once the full-route VPN has been
    // released. The single exact native close may still be finishing in its
    // tracked process-wide coordinator and remains a hard gate for the next
    // Connect, but it must not pin the UI in DISCONNECTING.
    private var platformShutdownCompleted = true
    @Volatile
    private var destroyCleanupRegistered = false
    @Volatile
    private var stickyTunPreparedForReplacement = false
    @Volatile
    private var serviceStopJob: Job? = null
    @Volatile
    private var undurableTerminalStopHoldJob: Job? = null
    @Volatile
    private var terminalStopIntentForCleanup: TerminalStopIntentResult? = null
    @Volatile
    private var coreRuntimeMonitorJob: Job? = null
    @Volatile
    private var coreWatchdogJob: Job? = null
    @Volatile
    private var coreRecoveryJob: Job? = null
    @Volatile
    private var coreRecoveryAdmissionRetryJob: Job? = null
    @Volatile
    private var routeWatchdogJob: Job? = null
    @Volatile
    private var coreRecoveryInProgress = false
    @Volatile
    private var coreRecoveryTransitionGeneration: Long? = null
    @Volatile
    private var lastCoreRecoveryAttemptAt = 0L
    @Volatile
    private var coreRecoveryOnlineStartedAtElapsed = 0L
    @Volatile
    private var terminalCoreCleanupFailurePublished = false
    @Volatile
    private var routeWatchdogFailures = 0
    @Volatile
    private var lastRouteRecoveryAttemptAt = 0L
    @Volatile
    private var routeHealthMonitor: RouteHealthMonitor? = null
    @Volatile
    private var lastProxyRouteProofAtElapsedMs = 0L
    @Volatile
    private var routeWatchdogCheckInProgress = false
    @Volatile
    private var externalVpnWatchdogJob: Job? = null
    @Volatile
    private var vpnOwnershipRevoked = false
    @Volatile
    private var vpnOwnershipWasEstablished = false
    private val untrackedOwnVpnReleaseLock = Any()
    @Volatile
    private var untrackedOwnVpnReleaseRequired = false
    private var untrackedOwnVpnNetworkHandles: Set<Long> = emptySet()
    @Volatile
    private var explicitUserVpnStartPending = false
    @Volatile
    private var explicitVpnTakeoverOverlapGeneration = 0L
    @Volatile
    private var explicitVpnTakeoverOverlapDeadlineElapsedRealtimeMs = 0L
    @Volatile
    private var preexistingExternalVpnNetworkHandles: Set<Long> = emptySet()
    @Volatile
    private var earlyVpnStartAdmissionReady = false
    @Volatile
    private var activeVpnStartAdmissionEpoch: Long? = null
    @Volatile
    private var serviceStartPipelineActive = false
    private var serviceStartPipelineGeneration = 0L
    private var serviceStartPipelineUserSessionEpoch = Long.MIN_VALUE
    private var pendingServiceStartRequest: ServiceStartRequest? = null
    private var deferredConnectAfterStop: DeferredConnectAfterStop? = null
    private var deferredTerminalStopAfterCleanup: DeferredTerminalStopAfterCleanup? = null
    private var failClosedSessionHold: FailClosedSessionHold? = null
    @Volatile
    private var failClosedSessionHoldJob: Job? = null
    @Volatile
    private var routeWatchdogHealthyChecks = 0
    @Volatile
    private var routeWatchdogDegraded = false
    @Volatile
    private var lastVpnDataPlaneProof: VpnDataPlaneProof? = null
    @Volatile
    private var lastTunTrafficSnapshot: TunTrafficSnapshot? = null
    @Volatile
    private var lastSelectedOutboundType = ""
    @Volatile
    private var networkGeneration = 0L
    @Volatile
    private var observedUnderlyingNetwork: android.net.Network? = null
    @Volatile
    private var underlyingNetworkInitialized = false
    @Volatile
    private var networkRecoveryJob: Job? = null
    @Volatile
    private var activeQuickSettingsRequestId = 0L
    @Volatile
    private var activeQuickSettingsGeneration = 0L
    @Volatile
    private var quickSettingsConnectedPublished = false
    private val routeWatchdogCheckLock = Any()
    private val vpnDataPlaneProofLock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val vpnDataPlaneProbe = VpnDataPlaneProbe(service)
    private val serviceCaptchaControlPlane = ServiceOwnedCaptchaControlPlane(
        context = service,
        scope = serviceScope,
        isGenerationActive = ::shouldContinueStart,
        onLifecycle = ::onServiceCaptchaLifecycle,
    )

    init {
        synchronized(serviceReplacementLock) {
            // The predecessor must publish its descriptor and register exact
            // cleanup while its token is still current. Only then may this
            // instance replace the owner and cross that cleanup barrier.
            activeInstance?.prepareForStickyServiceReplacement()
            serviceOwnerToken = ServiceLifecycleOwnership.acquire()
            val adopted = adoptStickyTunHandoffIfAvailable()
            if (
                adopted &&
                !Settings.startedByUser &&
                !Settings.startCoreAfterStartingService
            ) {
                Log.i(TAG, "terminal replacement closed inherited full-route TUN")
                closeTunFileDescriptor()
                platformShutdownCompleted = true
            }
            // Seed before this instance becomes authoritative and before the
            // process observer replays its current value. A live retained TUN
            // is a non-quiescent replacement owner, never a terminal Stopped
            // frame, even though its new core has not reached Started yet.
            status.value = initialPlatformStatusForStickyReplacement(
                adoptedStickyTunHandoff = adopted,
                platformShutdownCompleted = platformShutdownCompleted,
            )
            activeInstance = this
        }
        Mobile.beforeForcedDeath = {
            kotlinx.coroutines.runBlocking(Dispatchers.IO) {
                service !is VPNService || !Settings.startedByUser || vpnOwnershipRevoked ||
                    ensurePhysicalFailClosedVpn("core operation deadline")
            }
        }
        Mobile.onUnexpectedDeath = {
            val generation = currentStartGeneration()
            if (shouldContinueStart(generation)) invalidateVpnDataPlaneProof("core process death")
            serviceScope.launch {
                if (!shouldContinueStart(generation)) return@launch
                status.postValue(Status.Starting)
                requestCoreRecovery("core process death", generation)
            }
        }
        status.observeForever(processStatusObserver)
    }

    private fun adoptStickyTunHandoffIfAvailable(): Boolean {
        val alreadyRetained = synchronized(fileDescriptorLock) {
            fileDescriptor?.fileDescriptor?.valid() == true
        }
        if (alreadyRetained) return adoptedStickyTunHandoff

        val retainedHandoff = claimStickyTunHandoff() ?: return false
        val retainedDescriptor = retainedHandoff.descriptor
        val adopted = synchronized(fileDescriptorLock) {
            if (fileDescriptor != null) {
                false
            } else {
                fileDescriptor = retainedDescriptor
                // The previous exact Mobile.close remains the cleanup barrier.
                // Once it completes, this unread full-route descriptor is a
                // physical packet sink until the new data TUN replaces it.
                tunDescriptorMode = TunDescriptorMode.FAIL_CLOSED
                failClosedVpnGeneration = retainedHandoff.failClosedVpnGeneration
                tunGeneration += 1
                adoptedStickyTunHandoff = true
                vpnOwnershipWasEstablished = true
                coreShutdownCompleted = false
                platformShutdownCompleted = false
                true
            }
        }
        if (!adopted) {
            runCatching { retainedDescriptor.close() }
        }
        return adopted
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Action.SERVICE_CLOSE -> {
                    stopService(intent.getBooleanExtra(Action.EXTRA_KEEP_NOTIFICATION, false))
                }

                Action.SERVICE_MARK_STARTED -> {
                    serviceScope.launch(Dispatchers.IO) {
                        verifyAndMarkCoreRuntimeStarted("platform started signal")
                    }
                }

                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        serviceUpdateIdleMode()
                        if (!Application.powerManager.isDeviceIdleMode) {
                            routeHealthMonitor?.rearm()
                        }
                    }
                }

                Intent.ACTION_SCREEN_ON -> {
                    routeHealthMonitor?.rearm()
                }

                Intent.ACTION_SCREEN_OFF -> {
                    routeHealthMonitor?.rearm()
                }

                Intent.ACTION_USER_PRESENT -> {
                    routeHealthMonitor?.rearm()
                }
            }
        }
    }

    private fun registerServiceReceiverIfNeeded() {
        if (receiverRegistered) return
        ContextCompat.registerReceiver(service, receiver, IntentFilter().apply {
            addAction(Action.SERVICE_CLOSE)
            addAction(Action.SERVICE_MARK_STARTED)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            }
        }, ContextCompat.RECEIVER_NOT_EXPORTED)
        receiverRegistered = true
    }
    


    private var activeProfileName = ""

    private fun nextStartGeneration(): Long {
        return synchronized(lifecycleLock) {
            startGeneration += 1
            startGeneration
        }
    }

    private fun cancelPendingStarts(): Long {
        return synchronized(lifecycleLock) {
            startGeneration += 1
            startGeneration
        }
    }

    private fun currentStartGeneration(): Long = synchronized(lifecycleLock) { startGeneration }

    private fun queueConnectBehindStop(
        intent: Intent,
        flags: Int,
        userSessionEpoch: Long,
    ) {
        synchronized(lifecycleLock) {
            deferredConnectAfterStop = DeferredConnectAfterStop(
                intent = Intent(intent),
                flags = flags,
                userSessionEpoch = userSessionEpoch,
            )
        }
    }

    private fun consumeDeferredConnectAfterStop(): DeferredConnectAfterStop? =
        synchronized(lifecycleLock) {
            val queued = deferredConnectAfterStop
            deferredConnectAfterStop = null
            queued?.takeIf {
                Settings.startedByUser &&
                    ServiceLifecycleOwnership.isUserSessionEpochCurrent(it.userSessionEpoch)
            } ?: if (
                Settings.startedByUser &&
                Settings.startCoreAfterStartingService
            ) {
                ServiceLifecycleOwnership.currentUserSessionEpoch()?.let { epoch ->
                    DeferredConnectAfterStop(
                        intent = Intent(service, Settings.serviceClass())
                            .setAction(Action.SERVICE_CONNECT)
                            .putExtra(Action.EXTRA_USER_INITIATED, true)
                            .putExtra(Action.EXTRA_USER_SESSION_EPOCH, epoch),
                        flags = 0,
                        userSessionEpoch = epoch,
                    )
                }
            } else {
                null
            }
        }

    /**
     * A terminal Stop accepted while an older stop cleanup is still unwinding
     * must not be folded into that older operation. The predecessor may already
     * have handed its superseding Connect to a passive fail-closed continuation,
     * so returning as a "duplicate" would leave the newer terminal epoch with no
     * cleanup owner. Retain only the newest exact Stop and replay it from the
     * predecessor Job's completion event.
     */
    private fun deferTerminalStopUntilCleanupCompletes(
        predecessorJob: Job,
        terminalIntent: TerminalStopIntentResult,
        keepNotification: Boolean,
        vpnRevoked: Boolean,
        quickSettingsRequestId: Long,
    ) {
        synchronized(lifecycleLock) {
            deferredTerminalStopAfterCleanup = DeferredTerminalStopAfterCleanup(
                predecessorJob = predecessorJob,
                terminalIntent = terminalIntent,
                keepNotification = keepNotification,
                vpnRevoked = vpnRevoked,
                quickSettingsRequestId = quickSettingsRequestId,
            )
        }
        Log.i(
            TAG,
            "queued terminal service Stop behind the older Android VPN/TUN cleanup " +
                "epoch=${terminalIntent.terminalSessionEpoch}",
        )
    }

    private fun onServiceStopCleanupCompleted(completedJob: Job) {
        mainHandler.post {
            val deferredStop = synchronized(lifecycleLock) {
                if (serviceStopJob === completedJob) {
                    serviceStopJob = null
                }
                deferredTerminalStopAfterCleanup
                    ?.takeIf { it.predecessorJob === completedJob }
                    ?.also { deferredTerminalStopAfterCleanup = null }
            } ?: return@post

            if (
                !ServiceLifecycleOwnership.isTerminalStopEpochCurrent(
                    deferredStop.terminalIntent.terminalSessionEpoch,
                )
            ) {
                Log.i(
                    TAG,
                    "discarding deferred terminal Stop superseded by a newer lifecycle command " +
                        "epoch=${deferredStop.terminalIntent.terminalSessionEpoch}",
                )
                return@post
            }

            Log.i(
                TAG,
                "older Android VPN/TUN cleanup completed; resuming the newest exact terminal Stop " +
                    "epoch=${deferredStop.terminalIntent.terminalSessionEpoch}",
            )
            val target = activeInstance
            if (target == null) {
                dispatchTerminalStopIntent(
                    deferredStop.terminalIntent,
                    deferredStop.quickSettingsRequestId,
                )
                return@post
            }
            target.stopService(
                keepNotification = deferredStop.keepNotification,
                vpnRevoked = deferredStop.vpnRevoked,
                quickSettingsRequestId = deferredStop.quickSettingsRequestId,
                terminalStopAlreadyClaimed = true,
                terminalStateAlreadyPersisted = deferredStop.terminalIntent.persisted,
                terminalProbeBlockEpoch = deferredStop.terminalIntent.probeBlockEpoch,
                terminalSessionEpoch = deferredStop.terminalIntent.terminalSessionEpoch,
            )
        }
    }

    private fun admitQuickSettingsRequest(requestId: Long, generation: Long) {
        activeQuickSettingsRequestId = requestId.takeIf { it > 0L } ?: 0L
        activeQuickSettingsGeneration = if (requestId > 0L) generation else 0L
        quickSettingsConnectedPublished = false
        if (requestId > 0L) {
            recordQuickSettingsLifecycle(
                event = "service_command",
                outcome = "admitted",
                requestId = requestId,
                generation = generation,
            )
        }
    }

    private fun onServiceCaptchaLifecycle(
        event: String,
        outcome: String,
        generation: Long,
        revision: Long,
    ) {
        if (
            activeQuickSettingsRequestId <= 0L ||
            activeQuickSettingsGeneration != generation
        ) {
            return
        }
        recordQuickSettingsLifecycle(
            event = "captcha_$event",
            outcome = outcome,
            generation = generation,
            revision = revision,
        )
    }

    private fun recordQuickSettingsLifecycle(
        event: String,
        outcome: String,
        requestId: Long = activeQuickSettingsRequestId,
        generation: Long = activeQuickSettingsGeneration,
        revision: Long = 0L,
    ) {
        if (requestId <= 0L) return
        QuickSettingsDiagnostics.record(
            service,
            component = "service",
            event = event,
            requestId = requestId,
            outcome = outcome,
            status = status.value ?: Status.Stopped,
            generation = generation,
            revision = revision,
        )
    }

    private fun clearQuickSettingsRequest() {
        activeQuickSettingsRequestId = 0L
        activeQuickSettingsGeneration = 0L
        quickSettingsConnectedPublished = false
    }

    private fun ensureRuntimeConfigOwnership(
        generation: Long,
        allowStoredIdentityMigration: Boolean,
    ): Boolean {
        if (runtimeConfigOwnership.ownsGeneration(generation)) return true
        if (!allowStoredIdentityMigration) return false

        val persistedFingerprint = normalizeConfigFingerprint(Settings.activeConfigFingerprint)
        val fingerprint = persistedFingerprint ?: runCatching {
            NativeResumeConfigStore.fingerprintStoredConfig(service)
        }.onFailure {
            Log.e(TAG, "failed to recover native config identity", it)
        }.getOrNull()
        if (fingerprint == null) return false
        if (persistedFingerprint == null) {
            Settings.activeConfigFingerprint = fingerprint
        }
        return runtimeConfigOwnership.admit(
            generation = generation,
            fingerprint = fingerprint,
            usesTurncoat = Settings.activeConfigUsesTurncoat,
        )
    }

    private fun currentRuntimeUsesTurncoat(): Boolean =
        runtimeConfigOwnership.usesTurncoat(currentStartGeneration()) ?: false

    private fun isCurrentLifecycleGeneration(generation: Long): Boolean =
        generation == currentStartGeneration()

    private fun hasProcessNetworkAdmission(): Boolean =
        service is VPNService &&
            hasRetainedVpnDescriptor() &&
            NativeCrashDiagnostics.isNetworkAdmissionAllowed()

    private fun hasVerifiedRouteForOptionalBackgroundWork(): Boolean {
        val generation = currentStartGeneration()
        return ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) &&
            status.value == Status.Started &&
            Settings.startedByUser &&
            Settings.strictVpnRouteVerified &&
            hasProcessNetworkAdmission() &&
            hasReusableVpnDataPlaneProof(generation)
    }

    private fun shouldContinueStart(generation: Long): Boolean {
        return ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) &&
            shouldContinueCoreLifecycleOperation(
            operationGeneration = generation,
            currentGeneration = currentStartGeneration(),
            userSessionActive = Settings.startedByUser,
        ) &&
            status.value != Status.Stopping &&
            status.value != Status.Stopped
    }

    private suspend fun finishCancelledStart(generation: Long, reason: String) {
        if (shouldContinueStart(generation)) return
        if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
            Log.i(TAG, "stale service start owner discarded after $reason")
            return
        }
        if (!isCurrentLifecycleGeneration(generation)) {
            Log.i(TAG, "stale service start generation=$generation discarded after $reason")
            return
        }
        if (Settings.startedByUser && status.value != Status.Stopping && status.value != Status.Stopped) {
            Log.i(TAG, "service start cancelled by a newer start ($reason)")
            return
        }
        Log.w(TAG, "service start cancelled after $reason; closing mobile core")
        clearExplicitVpnTakeoverAllowance()
        stopCoreRuntimeMonitor()
        stopCoreWatchdog()
        stopRouteWatchdog()
        stopExternalVpnWatchdog()
        serviceCaptchaControlPlane.stop()
        recordQuickSettingsLifecycle(
            event = "service_start",
            outcome = "cancelled",
            generation = generation,
        )
        resetUnderlyingNetworkGeneration()
        if (!isCurrentLifecycleGeneration(generation)) return
        NativeResumeConfigStore.cleanupPlaintextLeases(service)
        DefaultNetworkMonitor.stop(serviceOwnerToken)
        val cleanupResult = closeMobileCoreAndAwaitTunQuiescence(
            "cancelled service start: $reason",
            serviceStopping = true,
        )
        coreShutdownCompleted = cleanupResult.completed
        if (coreShutdownCompleted) {
            runtimeConfigOwnership.clearThrough(generation)
        }
        if (requiresCoreCleanupEscalation(
                cleanupResult.closeCompleted,
                cleanupResult.tunQuiescent,
            )
        ) {
            if (!isCurrentLifecycleGeneration(generation)) {
                Log.i(TAG, "discarding stale cancelled-start cleanup failure generation=$generation")
                return
            }
            finishCoreCleanupFailure(
                "cancelled service start did not release the native core and TUN",
                expectedGeneration = generation,
            )
            return
        }
        withContext(Dispatchers.Main) {
            if (
                isCurrentLifecycleGeneration(generation) &&
                (!Settings.startedByUser || status.value == Status.Stopping || status.value == Status.Stopped)
            ) {
                status.value = Status.Stopped
                notification.close()
                service.stopSelf()
            }
        }
    }

    /**
     * Waits for the framework Network left by an older Marten process to be
     * removed. Register before the first re-check so an onLost edge cannot be
     * missed between discovery and suspension. No replacement VPN is created
     * anywhere in this wait.
     */
    private suspend fun awaitUntrackedOwnVpnRelease(
        generation: Long,
        userSessionEpoch: Long,
    ): Boolean {
        if (!hasUntrackedOwnVpnNetwork()) return true

        LocalProbeAdmission.ensureBlockedAndCancel()
        platformShutdownCompleted = false
        val connectivity = service.getSystemService(ConnectivityManager::class.java)
            ?: return false
        val networkChanged = Channel<Unit>(Channel.CONFLATED)
        val callback = object : ConnectivityManager.NetworkCallback() {
            private fun signalChange() {
                networkChanged.trySend(Unit)
            }

            override fun onAvailable(network: Network) = signalChange()

            override fun onLost(network: Network) = signalChange()

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) = signalChange()
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
            .build()
        val registered = runCatching {
            connectivity.registerNetworkCallback(request, callback)
        }.onFailure {
            Log.e(TAG, "failed to observe untracked Marten VPN release", it)
        }.isSuccess
        if (!registered) {
            networkChanged.close()
            return false
        }

        val startedAtElapsedRealtimeMs = SystemClock.elapsedRealtime()
        ConnectionDiagnostics.record(
            service,
            component = "service",
            event = "untracked_vpn_release",
            outcome = "waiting",
            generation = generation,
        )
        val released = try {
            withTimeoutOrNull(UNTRACKED_OWN_VPN_RELEASE_TIMEOUT_MS) {
                while (
                    shouldContinueStart(generation) &&
                    ServiceLifecycleOwnership.isUserSessionEpochCurrent(userSessionEpoch)
                ) {
                    // Once this wait has observed an untracked self-owned
                    // Network, require every captured old Network handle to
                    // vanish. A temporarily redacted ownerUid is not release
                    // evidence, while a different foreign handle does not
                    // keep Marten's already-retired generation alive.
                    if (!hasUntrackedOwnVpnNetwork()) {
                        return@withTimeoutOrNull true
                    }
                    networkChanged.receive()
                }
                false
            } == true
        } finally {
            runCatching { connectivity.unregisterNetworkCallback(callback) }
            networkChanged.close()
        }
        ConnectionDiagnostics.record(
            service,
            component = "service",
            event = "untracked_vpn_release",
            outcome = if (released) {
                "released"
            } else if (shouldContinueStart(generation)) {
                "timeout"
            } else {
                "cancelled"
            },
            generation = generation,
            durationMs = SystemClock.elapsedRealtime() - startedAtElapsedRealtimeMs,
        )
        return released
    }

    /**
     * An OEM that does not retire the previous process's VPN inside the bounded
     * window gets a terminal Disconnect. Stopping this descriptor-less service
     * lets Android finish removing the old Network without ever stacking a new
     * startup or retirement Builder generation over it.
     */
    private suspend fun stopAfterUntrackedOwnVpnReleaseTimeout(
        generation: Long,
        userSessionEpoch: Long,
    ) {
        if (
            !ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) ||
            !isCurrentLifecycleGeneration(generation) ||
            !ServiceLifecycleOwnership.isUserSessionEpochCurrent(userSessionEpoch)
        ) {
            return
        }
        val terminalIntent = persistTerminalStopIntent(
            "untracked previous-process VPN release timed out",
        )
        if (!terminalIntent.persisted) {
            Log.e(
                TAG,
                "untracked previous-process VPN remains fail-closed because terminal state was not durable",
            )
            return
        }
        val terminalStopAdmitted =
            ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(
                terminalIntent.terminalSessionEpoch,
            ) {
                // Publish the transition in the same transaction that admits
                // a newer Connect. A winner after this point therefore queues
                // behind this descriptor-less terminal handoff instead of
                // being cancelled by its stale continuation.
                status.value = Status.Stopping
            }
        if (!terminalStopAdmitted) {
            Log.i(
                TAG,
                "untracked previous-process VPN timeout was superseded by a newer Connect",
            )
            return
        }

        terminalStopIntentForCleanup = terminalIntent
        closedByStopService = true
        coreShutdownCompleted = true
        platformShutdownCompleted = false
        clearExplicitVpnTakeoverAllowance()
        cancelPendingStarts()
        if (receiverRegistered) {
            runCatching {
                service.unregisterReceiver(receiver)
            }.onFailure {
                Log.w(TAG, "error unregistering service receiver", it)
            }
            receiverRegistered = false
        }
        stopCoreRuntimeMonitor()
        stopCoreWatchdog()
        stopRouteWatchdog()
        stopExternalVpnWatchdog()
        serviceCaptchaControlPlane.stop()
        resetUnderlyingNetworkGeneration()
        DefaultNetworkMonitor.clearListener(serviceOwnerToken)
        NativeResumeConfigStore.cleanupPlaintextLeases(service)
        DefaultNetworkMonitor.stop(serviceOwnerToken)
        runtimeConfigOwnership.clearThrough(generation)
        invalidateVpnDataPlaneProof("untracked previous-process VPN release timeout")
        releaseLocalProbesWhenTerminalOwnerIsReady(
            terminalIntent.probeBlockEpoch,
            "untracked previous-process VPN release timeout",
        )
        releaseLocalProbesAfterUntrackedVpnNetworkLoss(
            blockEpoch = terminalIntent.probeBlockEpoch,
            terminalStopEpoch = terminalIntent.terminalSessionEpoch,
        )
        ConnectionDiagnostics.record(
            service,
            component = "service",
            event = "untracked_vpn_release",
            outcome = "terminal_stop",
            generation = generation,
        )
        withContext(Dispatchers.Main) {
            if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) return@withContext
            val terminalStopStillCurrent =
                ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(
                    terminalIntent.terminalSessionEpoch,
                ) {
                    status.value = Status.Stopped
                    notification.stopDynamicUpdates()
                    notification.close()
                    service.stopSelf()
                }
            if (terminalStopStillCurrent) return@withContext

            val deferredConnect = consumeDeferredConnectAfterStop()
            if (deferredConnect != null) {
                closedByStopService = false
                terminalStopIntentForCleanup = null
                status.value = Status.Stopped
                onStartCommand(deferredConnect.intent, deferredConnect.flags)
            } else if (
                Settings.startedByUser &&
                ServiceLifecycleOwnership.currentUserSessionEpoch() != null
            ) {
                // Admission can win before Android delivers its command. Keep
                // this owner alive; that exact command will restart the normal
                // wait/admission pipeline when it arrives.
                closedByStopService = false
                terminalStopIntentForCleanup = null
                status.value = Status.Starting
                notification.show(activeProfileName, R.string.status_starting)
            }
        }
    }

    /**
     * Terminal cleanup and Android's Network onLost can arrive in either order.
     * The lifecycle callback above handles cleanup-last; this callback handles
     * Network-loss-last and removes itself after the exact terminal epoch is
     * either releasable or superseded.
     */
    private fun releaseLocalProbesAfterUntrackedVpnNetworkLoss(
        blockEpoch: Long,
        terminalStopEpoch: Long,
    ) {
        val connectivity = service.getSystemService(ConnectivityManager::class.java) ?: return
        val finished = AtomicBoolean(false)
        lateinit var callback: ConnectivityManager.NetworkCallback

        fun finishObservation() {
            if (finished.compareAndSet(false, true)) {
                runCatching { connectivity.unregisterNetworkCallback(callback) }
            }
        }

        fun onNetworkStateChanged() {
            if (!ServiceLifecycleOwnership.isTerminalStopEpochCurrent(terminalStopEpoch)) {
                finishObservation()
                return
            }
            // Keep the discovery latch authoritative even if Android redacts
            // ownerUid after the timeout. Only disappearance of every captured
            // old handle proves that Marten's previous generation is gone.
            if (hasUntrackedOwnVpnNetwork()) return

            val terminalReleaseStillCurrent =
                ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(terminalStopEpoch) {
                    platformShutdownCompleted = true
                }
            if (!terminalReleaseStillCurrent) {
                finishObservation()
                return
            }
            val released = tryAllowLocalProbesForCurrentState(blockEpoch)
            Log.i(
                TAG,
                "untracked previous-process VPN Network released; local_probes_released=$released",
            )
            finishObservation()
        }

        callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = onNetworkStateChanged()

            override fun onLost(network: Network) = onNetworkStateChanged()

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) = onNetworkStateChanged()
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
            .build()
        val registered = runCatching {
            connectivity.registerNetworkCallback(request, callback)
        }.onFailure {
            Log.e(TAG, "failed to observe terminal untracked VPN release", it)
        }.isSuccess
        if (registered) {
            onNetworkStateChanged()
        }
    }

    private suspend fun startService(
        generation: Long,
        allowStoredIdentityMigration: Boolean = true,
        userSessionEpoch: Long,
    ) {
        if (
            !ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) ||
            !ServiceLifecycleOwnership.isUserSessionEpochCurrent(userSessionEpoch) ||
            !shouldContinueCoreLifecycleOperation(
                operationGeneration = generation,
                currentGeneration = currentStartGeneration(),
                userSessionActive = Settings.startedByUser,
            )
        ) {
            Log.i(TAG, "stale service start generation=$generation ignored")
            return
        }
        if (service is VPNService && hasUntrackedOwnVpnNetwork()) {
            withContext(Dispatchers.Main) {
                status.value = Status.Starting
                notification.show(activeProfileName, R.string.status_starting)
            }
            val previousProcessVpnReleased = awaitUntrackedOwnVpnRelease(
                generation = generation,
                userSessionEpoch = userSessionEpoch,
            )
            if (!previousProcessVpnReleased) {
                if (shouldContinueStart(generation)) {
                    stopAfterUntrackedOwnVpnReleaseTimeout(
                        generation = generation,
                        userSessionEpoch = userSessionEpoch,
                    )
                }
                return
            }
            if (shouldRejectNewVpnStart(
                    service,
                    "service start after previous-process VPN release",
                    explicitUserStart = explicitUserVpnStartPending,
                )
            ) {
                completeVpnStartAdmissionFailure(
                    userSessionEpoch,
                    "another Android VPN owner appeared after the previous Marten Network was released",
                )
                stopForExternalVpnOnMain("previous-process VPN release handoff")
                return
            }
        }
        val startupStartedAt = SystemClock.elapsedRealtime()
        var startupStage = "blocker"
        try {
            keepStoppedNotificationOnDestroy = false
            routeWatchdogDegraded = false
            invalidateVpnDataPlaneProof("service start")
            lastSelectedOutboundType = ""
            closedByStopService = false
            coreShutdownCompleted = false
            platformShutdownCompleted = false
            vpnOwnershipRevoked = false
            if (!hasRetainedVpnDescriptor()) {
                vpnOwnershipWasEstablished = false
            }
            Log.d(TAG, "starting service")
            withContext(Dispatchers.Main) {
                status.value = Status.Starting
                notification.show(activeProfileName, R.string.status_starting)
            }
            // Establish the service-owned packet sink before waiting for any
            // predecessor cleanup or exact native close. Those waits are safe
            // behind a real non-bypassable full-route TUN and do not
            // require Android's optional Always-on/lockdown bridge.
            if (service is VPNService) {
                val blockerAdmitted = ensurePhysicalFailClosedVpn(
                    "service start admission",
                )
                if (!blockerAdmitted) {
                    if (hasUntrackedOwnVpnNetwork()) {
                        stopAfterUntrackedOwnVpnReleaseTimeout(
                            generation = generation,
                            userSessionEpoch = userSessionEpoch,
                        )
                        return
                    }
                    completeVpnStartAdmissionFailure(
                        userSessionEpoch,
                        "failed to establish fail-closed Android VPN",
                    )
                    stopAndAlert(
                        Alert.CreateService,
                        "failed to establish fail-closed Android VPN",
                        expectedUserSessionEpoch = userSessionEpoch,
                        expectedGeneration = generation,
                    )
                    return
                }
                service.logSystemLockdownStatus()
                NativeCrashDiagnostics.setNetworkAdmissionAllowed(true)
                completeVpnStartAdmissionSuccess(userSessionEpoch)
            }
            startupStage = "config_identity"
            if (!ensureRuntimeConfigOwnership(generation, allowStoredIdentityMigration)) {
                stopAndAlert(
                    Alert.StartService,
                    "active VPN configuration identity is unavailable",
                    expectedUserSessionEpoch = userSessionEpoch,
                    expectedGeneration = generation,
                )
                return
            }

            val selectedConfigPath = Settings.activeConfigPath
            if (selectedConfigPath.isBlank()) {
                stopAndAlert(
                    Alert.EmptyConfiguration,
                    expectedUserSessionEpoch = userSessionEpoch,
                    expectedGeneration = generation,
                )
                return
            }

            activeProfileName = Settings.activeProfileName

            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, R.string.status_starting)
                binder.broadcast {
                    it.onServiceResetLogs(listOf())
                }
            }

            startupStage = "cleanup_barrier"
            val admissionStartedAt = SystemClock.elapsedRealtime()
            ConnectionDiagnostics.record(
                service,
                component = "service",
                event = "start_barrier",
                outcome = "waiting",
                generation = generation,
            )
            if (!ServiceLifecycleOwnership.awaitPendingCleanup(
                    serviceOwnerToken,
                    timeoutMs = CORE_START_ADMISSION_TIMEOUT_MS,
                )
            ) {
                ConnectionDiagnostics.record(
                    service,
                    component = "service",
                    event = "cleanup_barrier",
                    outcome = "timeout",
                    generation = generation,
                    durationMs = SystemClock.elapsedRealtime() - admissionStartedAt,
                )
                if (ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
                    // The previous service already owns its registered cleanup.
                    // Do not start another full close wait from this rejected
                    // Connect; publish the same bounded fail-closed result used
                    // for an in-flight process-wide Mobile.close operation.
                    finishCoreCleanupFailure(
                        "previous service cleanup did not finish before service start",
                        service.getString(R.string.error_connection_still_stopping),
                        expectedUserSessionEpoch = userSessionEpoch,
                        expectedGeneration = generation,
                    )
                }
                return
            }
            if (!shouldContinueStart(generation)) {
                finishCancelledStart(generation, "waiting for previous service cleanup")
                return
            }
            val closeWaitStartedAt = SystemClock.elapsedRealtime()
            if (!MobileCoreCloser.waitForCloseToFinish(
                    reason = "service start generation=$generation",
                    timeoutMs = CORE_START_ADMISSION_TIMEOUT_MS,
                )
            ) {
                ConnectionDiagnostics.record(
                    service,
                    component = "service",
                    event = "close_barrier",
                    outcome = "timeout",
                    generation = generation,
                    durationMs = SystemClock.elapsedRealtime() - closeWaitStartedAt,
                )
                // The exact close is already owned by MobileCoreCloser. Do not
                // spend a second bounded interval joining it from the rejected
                // start path; keep admission sealed and publish one clear,
                // fail-closed result for this Connect attempt.
                finishCoreCleanupFailure(
                    "previous core is still stopping before service start",
                    service.getString(R.string.error_connection_still_stopping),
                    expectedUserSessionEpoch = userSessionEpoch,
                    expectedGeneration = generation,
                )
                return
            }
            ConnectionDiagnostics.record(
                service,
                component = "service",
                event = "start_barrier",
                outcome = "ready",
                generation = generation,
                durationMs = SystemClock.elapsedRealtime() - admissionStartedAt,
            )
            if (!shouldContinueStart(generation)) {
                finishCancelledStart(generation, "waiting for previous core close")
                return
            }
            val tunAdmissionOpened = synchronized(fileDescriptorLock) {
                if (shouldContinueStart(generation)) {
                    tunDescriptorAdmissionClosed = false
                    true
                } else {
                    false
                }
            }
            if (!tunAdmissionOpened) {
                finishCancelledStart(generation, "opening TUN admission after previous core close")
                return
            }
            if (Settings.serviceMode == ServiceMode.VPN) {
                // Ownership can be lost after Builder.establish() but before
                // route verification publishes Started. Observe the entire
                // admitted generation instead of relying on onRevoke() or on
                // the post-Started watchdog alone.
                startExternalVpnWatchdog()
            }
            startupStage = "network_monitor"
            resetUnderlyingNetworkGeneration()
            if (!DefaultNetworkMonitor.start(serviceOwnerToken, ::onUnderlyingNetworkObserved)) {
                finishCancelledStart(generation, "default network monitor ownership")
                return
            }
            ConnectionDiagnostics.record(
                service,
                component = "service",
                event = "network_monitor",
                outcome = if (DefaultNetworkMonitor.defaultNetwork != null) "ready" else "waiting",
                generation = generation,
            )
            if (!shouldContinueStart(generation)) {
                finishCancelledStart(generation, "default network monitor start")
                return
            }
            if (shouldYieldToExternalVpn("service start before mobile setup")) {
                stopForExternalVpnOnMain("service start before mobile setup")
                return
            }
            startupStage = "core_setup"
            // Memory policy is applied inside the replaceable core process.
            val setupCompleted = try {
                MobileCoreLifecycle.run {
                    if (!shouldContinueStart(generation)) return@run false
                    Log.d(
                        TAG,
                        "core setup request mode=background debug=${Settings.debugMode} " +
                            "service_mode=${Settings.serviceMode} platform_interface=true",
                    )
                    Mobile.setup(
                        Settings.baseDir,
                        Settings.workingDir,
                        Settings.tempDir,
                        4L,
                        "127.0.0.1:${Settings.grpcServiceModePort}",
                        "",
                        Settings.debugMode,
                        platformInterface,
                    )
                    Log.d(
                        TAG,
                        "core setup complete mode=background platform_interface=true ${Mobile.runtimeState()}",
                    )
                    true
                }
//                Libbox.newService(content,platformInterface)

            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                ConnectionDiagnostics.record(
                    service,
                    component = "service",
                    event = "start_failure",
                    outcome = "failed",
                    generation = generation,
                    durationMs = SystemClock.elapsedRealtime() - startupStartedAt,
                    stage = startupStage,
                    category = nativeStartFailureCategory(e),
                )
                stopAndAlert(
                    Alert.CreateService,
                    e.message,
                    expectedUserSessionEpoch = userSessionEpoch,
                    expectedGeneration = generation,
                )
                return
            }
            if (!setupCompleted) {
                finishCancelledStart(generation, "mobile setup admission")
                return
            }
            ConnectionDiagnostics.record(
                service,
                component = "service",
                event = "core_setup",
                outcome = "ready",
                generation = generation,
            )
            if (!shouldContinueStart(generation)) {
                finishCancelledStart(generation, "mobile setup")
                return
            }
            serviceCaptchaControlPlane.start(
                generation = generation,
                enabled = runtimeConfigOwnership.usesTurncoat(generation) == true,
            )
            // Claim the coalesced native-start request under the same lock used
            // by redelivered service commands. A command that arrives after
            // this claim remains pending for the pipeline drain; one that
            // arrived before it is consumed exactly once here.
            val startCoreInService = synchronized(lifecycleLock) {
                if (
                    Settings.startCoreAfterStartingService &&
                    shouldContinueStart(generation)
                ) {
                    Settings.startCoreAfterStartingService = false
                    true
                } else {
                    false
                }
            }
            if (startCoreInService) {
                if (!shouldContinueStart(generation)) {
                    finishCancelledStart(generation, "before mobile start")
                    return
                }
                if (shouldYieldToExternalVpn("service start before mobile start")) {
                    stopForExternalVpnOnMain("service start before mobile start")
                    return
                }
                startCoreRuntimeMonitor(nativeStartup = true)
                startupStage = "native_start"
                val routeVerified = startMobileCoreFromNativePath(
                    Settings.activeConfigPath,
                    "service start",
                    generation = generation,
                    userSessionEpoch = userSessionEpoch,
                )
                if (!routeVerified) {
                    Log.w(TAG, "native service startup retained for selected-route recovery")
                    recordQuickSettingsLifecycle(
                        event = "route",
                        outcome = "recovery_pending",
                        generation = generation,
                    )
                    return
                }
            }
            if (!shouldContinueStart(generation)) {
                finishCancelledStart(generation, "mobile start")
                return
            }
            if (startCoreInService) {
                markCoreRuntimeStarted(routeVerified = true, generation = generation)
            } else {
                startCoreRuntimeMonitor()
            }
//            if (delayStart) {
//                delay(1000L)
//            }

//            newService.start()
//            boxService = newService
//            commandServer?.setService(boxService)


        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            ConnectionDiagnostics.record(
                service,
                component = "service",
                event = "start_failure",
                outcome = "failed",
                generation = generation,
                durationMs = SystemClock.elapsedRealtime() - startupStartedAt,
                stage = startupStage,
                category = nativeStartFailureCategory(e),
            )
            stopAndAlert(
                Alert.StartService,
                e.message,
                expectedUserSessionEpoch = userSessionEpoch,
                expectedGeneration = generation,
            )
            return
        }
    }

    /**
     * Owns service setup and any native-core request that arrives while setup
     * is still crossing the blocker, cleanup, and Mobile.setup barriers.
     *
     * Samsung can redeliver the always-on VpnService intent while the first
     * command is still installing its blocker. Starting the stored core from
     * that second command races openTun against the sealed generation and can
     * terminally cancel the very blocker that is being established. Keep one
     * pipeline owner and let it consume every coalesced native start request.
     */
    private fun launchServiceStart(
        generation: Long,
        allowStoredIdentityMigration: Boolean,
        userSessionEpoch: Long = checkNotNull(ServiceLifecycleOwnership.currentUserSessionEpoch()),
    ) {
        if (!ServiceLifecycleOwnership.isUserSessionEpochCurrent(userSessionEpoch)) {
            Log.i(TAG, "stale service pipeline launch ignored for user epoch=$userSessionEpoch")
            return
        }
        val request = ServiceStartRequest(
            generation = generation,
            allowStoredIdentityMigration = allowStoredIdentityMigration,
            userSessionEpoch = userSessionEpoch,
        )
        var queuedGeneration = 0L
        var queuedBehindGeneration = 0L
        val admitted = synchronized(lifecycleLock) {
            if (serviceStartPipelineActive) {
                queuedBehindGeneration = serviceStartPipelineGeneration
                val pending = pendingServiceStartRequest
                val newerThanActive =
                    userSessionEpoch > serviceStartPipelineUserSessionEpoch ||
                        (
                            userSessionEpoch == serviceStartPipelineUserSessionEpoch &&
                                generation > serviceStartPipelineGeneration
                        )
                val newerThanPending = pending == null ||
                    userSessionEpoch > pending.userSessionEpoch ||
                    (
                        userSessionEpoch == pending.userSessionEpoch &&
                            generation > pending.generation
                    )
                when {
                    newerThanActive && newerThanPending -> {
                        pendingServiceStartRequest = request
                        queuedGeneration = generation
                    }

                    pending != null &&
                        generation == pending.generation &&
                        userSessionEpoch == pending.userSessionEpoch -> {
                        // An explicit configuration identity is stricter than
                        // migration from persisted identity. Preserve that
                        // stricter request when duplicate commands coalesce.
                        pendingServiceStartRequest = pending.copy(
                            allowStoredIdentityMigration =
                                pending.allowStoredIdentityMigration && allowStoredIdentityMigration,
                        )
                        queuedGeneration = generation
                    }
                }
                false
            } else {
                serviceStartPipelineActive = true
                serviceStartPipelineGeneration = generation
                serviceStartPipelineUserSessionEpoch = userSessionEpoch
                true
            }
        }
        if (!admitted) {
            if (queuedGeneration > 0L) {
                Log.i(
                    TAG,
                    "service start generation=$queuedGeneration queued behind active setup generation=" +
                        queuedBehindGeneration,
                )
            } else {
                Log.i(TAG, "duplicate service start coalesced into the active setup pipeline")
            }
            return
        }
        serviceScope.launch(Dispatchers.IO) {
            runServiceStartPipeline(request)
        }
    }

    private suspend fun runServiceStartPipeline(initialRequest: ServiceStartRequest) {
        var request = initialRequest
        var released = false
        try {
            pipeline@ while (true) {
                try {
                    initialize()
                    startService(
                        generation = request.generation,
                        allowStoredIdentityMigration = request.allowStoredIdentityMigration,
                        userSessionEpoch = request.userSessionEpoch,
                    )
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.e(
                        TAG,
                        "unexpected service start pipeline failure generation=${request.generation}",
                        e,
                    )
                    if (shouldContinueStart(request.generation)) {
                        stopAndAlert(
                            Alert.StartService,
                            e.message,
                            expectedUserSessionEpoch = request.userSessionEpoch,
                            expectedGeneration = request.generation,
                        )
                    }
                }

                while (true) {
                    var nextRequest: ServiceStartRequest? = null
                    val startPendingCore = synchronized(lifecycleLock) {
                        val pending = pendingServiceStartRequest
                        if (pending != null) {
                            pendingServiceStartRequest = null
                            serviceStartPipelineGeneration = pending.generation
                            serviceStartPipelineUserSessionEpoch = pending.userSessionEpoch
                            nextRequest = pending
                            false
                        } else if (
                            Settings.startCoreAfterStartingService &&
                            shouldContinueStart(request.generation) &&
                            ServiceLifecycleOwnership.isUserSessionEpochCurrent(
                                request.userSessionEpoch,
                            )
                        ) {
                            Settings.startCoreAfterStartingService = false
                            true
                        } else {
                            serviceStartPipelineActive = false
                            serviceStartPipelineGeneration = 0L
                            serviceStartPipelineUserSessionEpoch = Long.MIN_VALUE
                            released = true
                            false
                        }
                    }
                    nextRequest?.let { queued ->
                        Log.i(
                            TAG,
                            "service start pipeline handing off generation=${request.generation} " +
                                "to generation=${queued.generation}",
                        )
                        request = queued
                        continue@pipeline
                    }
                    if (!startPendingCore) return
                    Log.i(
                        TAG,
                        "running native core start coalesced behind service setup " +
                            "generation=${request.generation}",
                    )
                    startStoredCoreFromNativeEntryPoint(
                        generation = request.generation,
                        userSessionEpoch = request.userSessionEpoch,
                    )
                }
            }
        } finally {
            if (!released) {
                synchronized(lifecycleLock) {
                    // The only cancellation source is this service instance's
                    // SupervisorJob during onDestroy. No request can safely be
                    // handed off within a destroyed owner, so release all
                    // instance-local pipeline state atomically.
                    serviceStartPipelineActive = false
                    serviceStartPipelineGeneration = 0L
                    serviceStartPipelineUserSessionEpoch = Long.MIN_VALUE
                    pendingServiceStartRequest = null
                }
            }
        }
    }

    private fun deferNativeCoreStartToServicePipeline(): Boolean = synchronized(lifecycleLock) {
        if (!serviceStartPipelineActive) {
            false
        } else {
            Settings.startCoreAfterStartingService = true
            true
        }
    }

    fun serviceReload() {
        runBlocking {
            serviceReload0()
        }
    }

    suspend fun serviceReload0() {
        if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
            Log.i(TAG, "stale service reload ignored")
            return
        }
        val userSessionEpoch =
            ServiceLifecycleOwnership.currentUserSessionEpoch() ?: return
        val generation = nextStartGeneration()
        notification.close()
        stopCoreRuntimeMonitor()
        stopCoreWatchdog()
        stopRouteWatchdog()
        stopExternalVpnWatchdog()
        serviceCaptchaControlPlane.stop()
        status.postValue(Status.Starting)

        val cleanupResult = if (!shouldContinueCoreLifecycleOperation(
                operationGeneration = generation,
                currentGeneration = currentStartGeneration(),
                userSessionActive = Settings.startedByUser,
            )
        ) {
            null
        } else {
            DefaultNetworkMonitor.clearListener(serviceOwnerToken)
            closeMobileCoreAndAwaitTunQuiescence("service reload")
        }
        coreShutdownCompleted = cleanupResult?.completed == true

//        boxService?.apply {
//            runCatching {
//                close()
//            }.onFailure {
//                writeLog("service: error when closing: $it")
//            }
//            Seq.destroyRef(refnum)
//        }
//        boxService = null
        if (cleanupResult == null) return
        if (requiresCoreCleanupEscalation(
                cleanupResult.closeCompleted,
                cleanupResult.tunQuiescent,
            )
        ) {
            finishCoreCleanupFailure(
                "service reload did not release the native core and TUN",
                expectedUserSessionEpoch = userSessionEpoch,
                expectedGeneration = generation,
            )
            return
        }
        if (
            shouldContinueStart(generation) &&
            ServiceLifecycleOwnership.isUserSessionEpochCurrent(userSessionEpoch)
        ) {
            startService(
                generation = generation,
                userSessionEpoch = userSessionEpoch,
            )
        }
    }

    fun getSystemProxyStatus(): SystemProxyStatus {
        val status = SystemProxyStatus()
        if (service is VPNService) {
            status.available = service.systemProxyAvailable
            status.enabled = service.systemProxyEnabled
        }
        return status
    }

    fun setSystemProxyEnabled(isEnabled: Boolean) {
        serviceReload()
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun serviceUpdateIdleMode() {
        if (Application.powerManager.isDeviceIdleMode) {
//            boxService?.pause()
            //Mobile.pause()
        } else {
            // The current mobile ABI no longer exposes Mobile.wake().
//            boxService?.wake()
        }
    }

    private fun stopService(
        keepNotification: Boolean = false,
        vpnRevoked: Boolean = false,
        quickSettingsRequestId: Long = 0L,
        terminalStopAlreadyClaimed: Boolean = false,
        terminalStateAlreadyPersisted: Boolean = false,
        terminalProbeBlockEpoch: Long? = null,
        terminalSessionEpoch: Long? = null,
    ) {
        if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
            Log.i(TAG, "stale service stop ignored")
            if (quickSettingsRequestId > 0L) {
                recordQuickSettingsLifecycle(
                    event = "stop",
                    outcome = "stale_owner",
                    requestId = quickSettingsRequestId,
                    generation = currentStartGeneration(),
                )
            }
            return
        }
        val terminalIntent = if (terminalStopAlreadyClaimed) {
            TerminalStopIntentResult(
                persisted = terminalStateAlreadyPersisted,
                probeBlockEpoch = checkNotNull(terminalProbeBlockEpoch) {
                    "pre-persisted terminal Stop requires its exact probe-block epoch"
                },
                terminalSessionEpoch = checkNotNull(terminalSessionEpoch) {
                    "pre-persisted terminal Stop requires its exact lifecycle epoch"
                },
                supersededUserSessionEpoch = null,
            )
        } else {
            persistTerminalStopIntent(
                if (vpnRevoked) "Android VPN ownership revoked" else "service stop",
            )
        }
        val terminalStopAdmitted =
            ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(
                terminalIntent.terminalSessionEpoch,
            ) {
                // Publish Stopping under the same exact lifecycle transaction
                // that arbitrates Connect. A newer Connect therefore either
                // wins first and makes this continuation stale, or observes
                // Stopping and queues behind this cleanup barrier.
                status.value = Status.Stopping
            }
        if (!terminalStopAdmitted) {
            Log.i(
                TAG,
                "terminal service Stop superseded by newer Connect " +
                    "epoch=${terminalIntent.terminalSessionEpoch}",
            )
            return
        }
        val terminalStateDurable = terminalIntent.persisted
        terminalStopIntentForCleanup = terminalIntent
        val predecessorStopJob = serviceStopJob
        if (
            predecessorStopJob?.isActive == true &&
            predecessorStopJob !== undurableTerminalStopHoldJob
        ) {
            if (quickSettingsRequestId > 0L) {
                recordQuickSettingsLifecycle(
                    event = "stop",
                    outcome = "admitted",
                    requestId = quickSettingsRequestId,
                    generation = currentStartGeneration(),
                )
            }
            recordQuickSettingsLifecycle(event = "session_stop", outcome = "admitted")
            clearExplicitVpnTakeoverAllowance()
            cancelFailClosedSessionHoldForTerminalStop()
            cancelLegacyProcessRecoveryAlarm()
            if (vpnRevoked) {
                vpnOwnershipRevoked = true
                Log.w(TAG, "VPN permission revoked by Android; stopping without session restore")
                keepStoppedNotificationOnDestroy = false
                binder.broadcast { callback ->
                    callback.onServiceAlert(Alert.VpnRevoked.ordinal, null)
                }
            }
            synchronized(fileDescriptorLock) {
                tunDescriptorAdmissionClosed = true
            }
            invalidateVpnDataPlaneProof("terminal Stop queued behind older service cleanup")
            platformShutdownCompleted = false
            val deferredStopGeneration = cancelPendingStarts()
            closedByStopService = true
            keepStoppedNotificationOnDestroy = keepNotification && !vpnRevoked
            notification.stopDynamicUpdates()
            notification.show(activeProfileName, R.string.status_stopping)
            stopCoreRuntimeMonitor()
            stopCoreWatchdog()
            stopRouteWatchdog()
            stopExternalVpnWatchdog()
            serviceCaptchaControlPlane.stop()
            resetUnderlyingNetworkGeneration()
            recordQuickSettingsLifecycle(
                event = "session_stop",
                outcome = "queued_after_active_cleanup",
                generation = deferredStopGeneration,
            )
            deferTerminalStopUntilCleanupCompletes(
                predecessorJob = predecessorStopJob,
                terminalIntent = terminalIntent,
                keepNotification = keepNotification,
                vpnRevoked = vpnRevoked,
                quickSettingsRequestId = quickSettingsRequestId,
            )
            return
        }
        if (!terminalStateDurable && !vpnRevoked) {
            holdFailClosedAfterUndurableTerminalStop(quickSettingsRequestId)
            return
        }
        if (quickSettingsRequestId > 0L) {
            recordQuickSettingsLifecycle(
                event = "stop",
                outcome = "admitted",
                requestId = quickSettingsRequestId,
                generation = currentStartGeneration(),
            )
        }
        recordQuickSettingsLifecycle(event = "session_stop", outcome = "admitted")
        // A user-mediated takeover authorizes exactly one TUN creation attempt.
        // No stop, revoke, or later recovery may inherit that authorization.
        clearExplicitVpnTakeoverAllowance()
        cancelFailClosedSessionHoldForTerminalStop()
        cancelLegacyProcessRecoveryAlarm()
        if (vpnRevoked) {
            vpnOwnershipRevoked = true
            Log.w(TAG, "VPN permission revoked by Android; stopping without session restore")
            keepStoppedNotificationOnDestroy = false
            closedByStopService = true
            binder.broadcast { callback ->
                callback.onServiceAlert(Alert.VpnRevoked.ordinal, null)
            }
        }
        synchronized(fileDescriptorLock) {
            // Seal descriptor admission atomically with the visible stop
            // transition. Otherwise openTun could pass its pre-stop checks,
            // lose the race to closeTunFileDescriptor(), and install a new
            // framework-owned descriptor after cleanup had already run.
            tunDescriptorAdmissionClosed = true
        }
        // The cleanup Job atomically replaces the data-plane VPN with a real
        // framework-owned blocker before asking the native core to close. Keep
        // the current full-route data plane alive until that replacement is
        // established; releasing it here would expose Wi-Fi/cellular.
        invalidateVpnDataPlaneProof("manual service stop admitted")
        platformShutdownCompleted = false
        val activeStopJob = serviceStopJob
        if (activeStopJob?.isActive == true) {
            Log.i(TAG, "durable terminal Stop superseded the passive storage-failure hold")
        }
        val stopGeneration = cancelPendingStarts()
        closedByStopService = true
        keepStoppedNotificationOnDestroy = keepNotification && !vpnRevoked
        if (receiverRegistered) {
            runCatching {
                service.unregisterReceiver(receiver)
            }.onFailure {
                Log.w(TAG, "error unregistering service receiver", it)
            }
            receiverRegistered = false
        }
        notification.stopDynamicUpdates()
        if (!keepStoppedNotificationOnDestroy) {
            notification.close()
        } else {
            notification.show(activeProfileName, R.string.status_stopping)
        }
        stopCoreRuntimeMonitor()
        stopCoreWatchdog()
        stopRouteWatchdog()
        stopExternalVpnWatchdog()
        serviceCaptchaControlPlane.stop()
        resetUnderlyingNetworkGeneration()
        val newStopJob = serviceScope.launch(
            Dispatchers.IO,
            start = CoroutineStart.LAZY,
        ) {
            if (
                !isCurrentLifecycleGeneration(stopGeneration) ||
                !ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)
            ) {
                Log.i(TAG, "discarding stale service stop generation=$stopGeneration")
                return@launch
            }
            DefaultNetworkMonitor.clearListener(serviceOwnerToken)
            NativeResumeConfigStore.cleanupPlaintextLeases(service)
            DefaultNetworkMonitor.stop(serviceOwnerToken)
            val coreClosed = closeMobileCoreAndAwaitTunQuiescence(
                "service stop",
                serviceStopping = true,
            )
            coreShutdownCompleted = coreClosed.completed
            val vpnAndTunReleased =
                coreClosed.platformVpnRetired && coreClosed.tunQuiescent
            platformShutdownCompleted = vpnAndTunReleased
            if (coreShutdownCompleted) {
                runtimeConfigOwnership.clearThrough(stopGeneration)
            }
            if (!platformShutdownCompleted) {
                val cleanupJob = currentCoroutineContext()[Job]
                val deferredTerminalStop = synchronized(lifecycleLock) {
                    deferredTerminalStopAfterCleanup
                        ?.takeIf { it.predecessorJob === cleanupJob }
                }
                if (
                    deferredTerminalStop != null &&
                    ServiceLifecycleOwnership.isTerminalStopEpochCurrent(
                        deferredTerminalStop.terminalIntent.terminalSessionEpoch,
                    )
                ) {
                    Log.i(
                        TAG,
                        "older Android VPN/TUN cleanup yielded its failed release to the queued " +
                            "terminal Stop epoch=${deferredTerminalStop.terminalIntent.terminalSessionEpoch}",
                    )
                    return@launch
                }
                val latestTerminalIntent = terminalStopIntentForCleanup ?: terminalIntent
                finishCoreCleanupFailure(
                    "manual service stop did not release the Android VPN/TUN barrier",
                    terminalProbeBlockEpoch = latestTerminalIntent.probeBlockEpoch,
                )
                return@launch
            }
            // A terminal release has no admitted VPN Network left. Close the
            // native gate before the terminal epoch may reopen physical
            // subscription/ping probes; a superseding Connect reopens it only
            // after verifying its retained exact blocker generation.
            NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)
            if (!coreShutdownCompleted) {
                Log.w(
                    TAG,
                    "manual service stop handed the unfinished exact native close to its process-wide owner",
                )
            }
            withContext(Dispatchers.Main) {
                if (
                    !isCurrentLifecycleGeneration(stopGeneration) ||
                    !ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)
                ) {
                    return@withContext
                }
                status.value = Status.Stopped
                val deferredConnect = consumeDeferredConnectAfterStop()
                if (deferredConnect != null) {
                    keepStoppedNotificationOnDestroy = false
                    closedByStopService = false
                    recordQuickSettingsLifecycle(
                        event = "session_stop",
                        outcome = "superseded_by_connect",
                        generation = stopGeneration,
                    )
                    terminalStopIntentForCleanup = null
                    Log.i(
                        TAG,
                        "replaying newest exact Connect after Android VPN/TUN stop barrier",
                    )
                    onStartCommand(deferredConnect.intent, deferredConnect.flags)
                    return@withContext
                }
                if (
                    Settings.startedByUser &&
                    ServiceLifecycleOwnership.currentUserSessionEpoch() != null
                ) {
                    // Admission clears the durable Stop before Android delivers
                    // the corresponding service command. If platform cleanup
                    // wins that tiny delivery race, keep this exact owner and
                    // blocker alive; the accepted command (or process restore)
                    // remains the only event that resumes setup.
                    status.value = Status.Starting
                    keepStoppedNotificationOnDestroy = false
                    closedByStopService = false
                    terminalStopIntentForCleanup = null
                    notification.show(activeProfileName, R.string.status_starting)
                    recordQuickSettingsLifecycle(
                        event = "session_stop",
                        outcome = "superseded_awaiting_connect_command",
                        generation = stopGeneration,
                    )
                    Log.i(TAG, "terminal Stop release was superseded by an accepted Connect awaiting delivery")
                    return@withContext
                }
                // Explicit Stop is now durable and the exact Android VPN/TUN
                // release barrier has completed. Only this point may reopen
                // process-wide physical diagnostics for the disconnected app.
                val latestTerminalIntent = terminalStopIntentForCleanup ?: terminalIntent
                val probesReleased =
                    tryAllowLocalProbesForCurrentState(latestTerminalIntent.probeBlockEpoch)
                if (!probesReleased) {
                    Log.i(
                        TAG,
                        "terminal VPN/TUN release completed, but a newer native probe seal remains authoritative",
                    )
                    releaseLocalProbesWhenTerminalOwnerIsReady(
                        latestTerminalIntent.probeBlockEpoch,
                        "completed service stop",
                    )
                }
                if (keepStoppedNotificationOnDestroy) {
                    notification.showStopped(activeProfileName)
                } else {
                    notification.close()
                }
                recordQuickSettingsLifecycle(
                    event = "session_stop",
                    outcome = "completed",
                    generation = stopGeneration,
                )
                clearQuickSettingsRequest()
                terminalStopIntentForCleanup = null
                service.stopSelf()
            }
//            commandServer?.setService(null)
//            boxService?.apply {
//                runCatching {
//                    close()
//                }.onFailure {
//                    writeLog("service: error when closing: $it")
//                }
//                //Seq.destroyRef(refnum)
//            }

//            boxService = null
//            Libbox.registerLocalDNSTransport(null)

//            commandServer?.apply {
//                close()
//                Seq.destroyRef(refnum)
//            }
//            commandServer = null
        }
        newStopJob.invokeOnCompletion {
            onServiceStopCleanupCompleted(newStopJob)
        }
        synchronized(lifecycleLock) {
            // A directly admitted newer Stop supersedes any not-yet-delivered
            // continuation left by a completed predecessor.
            deferredTerminalStopAfterCleanup = null
            serviceStopJob = newStopJob
        }
        newStopJob.start()
    }

    /**
     * A terminal Stop may release Android's VPN owner only after its native
     * tombstone is durable. On storage failure, retire the readable core into
     * the existing full-route packet sink and keep this foreground owner alive
     * without leaving the user-visible lifecycle in Stopping. There is
     * deliberately no retry timer, watchdog, wake lock or polling loop; a
     * later explicit action may retry persistence while the packet/probe seals
     * remain authoritative.
     */
    private fun holdFailClosedAfterUndurableTerminalStop(quickSettingsRequestId: Long) {
        clearExplicitVpnTakeoverAllowance()
        NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)
        synchronized(fileDescriptorLock) {
            tunDescriptorAdmissionClosed = true
            status.value = Status.Stopping
        }
        cancelPendingStarts()
        stopCoreRuntimeMonitor()
        stopCoreWatchdog()
        stopRouteWatchdog()
        stopExternalVpnWatchdog()
        serviceCaptchaControlPlane.stop()
        notification.stopDynamicUpdates()
        notification.show(activeProfileName, R.string.status_stopping)
        if (quickSettingsRequestId > 0L) {
            recordQuickSettingsLifecycle(
                event = "stop",
                outcome = "storage_fail_closed",
                requestId = quickSettingsRequestId,
                generation = currentStartGeneration(),
            )
        }
        if (serviceStopJob?.isActive == true) return
        lateinit var holdJob: Job
        holdJob = serviceScope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
            val blockerReady = ensurePhysicalFailClosedVpn(
                "terminal Stop marker persistence failure",
            )
            val coreClosed = if (blockerReady) {
                MobileCoreCloser.closeBlocking(
                    "terminal Stop marker persistence failure",
                )
            } else {
                false
            }
            // A later durable Stop may replace serviceStopJob while this exact
            // native close continues. Never let the superseded hold overwrite
            // that authoritative release continuation's terminal state.
            val holdStillAuthoritative = serviceStopJob === holdJob
            if (holdStillAuthoritative) {
                coreShutdownCompleted = coreClosed
                platformShutdownCompleted = false
            }
            Log.e(
                TAG,
                "terminal Stop held fail-closed because its durable marker is unavailable " +
                    "blocker_ready=$blockerReady core_closed=$coreClosed",
            )
            withContext(Dispatchers.Main) {
                if (
                    serviceStopJob !== holdJob ||
                    !ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)
                ) {
                    return@withContext
                }
                // Stopped describes the terminal user command, not permission
                // to bypass the still-retained packet sink. Local probes and
                // ordinary sockets remain sealed until a later exact release.
                status.value = Status.Stopped
                notification.showStopped(activeProfileName)
                recordQuickSettingsLifecycle(
                    event = "stop",
                    outcome = "storage_fail_closed_terminal",
                    requestId = quickSettingsRequestId,
                    generation = currentStartGeneration(),
                )
            }
        }
        undurableTerminalStopHoldJob = holdJob
        serviceStopJob = holdJob
        holdJob.start()
    }

    fun replaceTunFileDescriptor(pfd: ParcelFileDescriptor): Boolean =
        replaceTunFileDescriptor(pfd, TunDescriptorMode.DATA_PLANE)

    internal fun installFailClosedTunFileDescriptor(
        pfd: ParcelFileDescriptor,
        @Suppress("UNUSED_PARAMETER") replacingRetainedDescriptor: Boolean,
        generation: FailClosedVpnGeneration,
    ): Boolean = replaceTunFileDescriptor(
        pfd,
        TunDescriptorMode.FAIL_CLOSED,
        allowSealedFailClosedReplacement = true,
        installedFailClosedVpnGeneration = generation,
    )

    internal fun hasRetainedVpnDescriptor(): Boolean = synchronized(fileDescriptorLock) {
        fileDescriptor?.fileDescriptor?.valid() == true &&
            tunDescriptorMode != TunDescriptorMode.NONE
    }

    internal fun hasFailClosedVpnDescriptor(): Boolean = synchronized(fileDescriptorLock) {
        fileDescriptor?.fileDescriptor?.valid() == true &&
            tunDescriptorMode == TunDescriptorMode.FAIL_CLOSED &&
            failClosedVpnGeneration != null
    }

    internal fun hasPendingExplicitVpnStart(): Boolean = explicitUserVpnStartPending

    private fun replaceTunFileDescriptor(
        pfd: ParcelFileDescriptor,
        mode: TunDescriptorMode,
        allowSealedFailClosedReplacement: Boolean = false,
        installedFailClosedVpnGeneration: FailClosedVpnGeneration? = null,
    ): Boolean {
        check((mode == TunDescriptorMode.FAIL_CLOSED) == (installedFailClosedVpnGeneration != null)) {
            "fail-closed Android TUN descriptor requires its exact framework generation"
        }
        var accepted = false
        var acceptedTunGeneration = 0L
        val previous = synchronized(fileDescriptorLock) {
            val ordinaryDataPlaneAdmission =
                !tunDescriptorAdmissionClosed &&
                    shouldAcceptTunFileDescriptor(
                        ownerIsCurrent = ServiceLifecycleOwnership.isCurrent(serviceOwnerToken),
                        userSessionActive = Settings.startedByUser,
                        status = status.value ?: Status.Stopped,
                    )
            val sealedFailClosedReplacement =
                allowSealedFailClosedReplacement &&
                    mode == TunDescriptorMode.FAIL_CLOSED &&
                    tunDescriptorAdmissionClosed &&
                    ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) &&
                    !vpnOwnershipRevoked &&
                    (
                        fileDescriptor?.fileDescriptor?.valid() == true ||
                            (Settings.startedByUser && status.value == Status.Starting)
                    )
            if (ordinaryDataPlaneAdmission || sealedFailClosedReplacement) {
                accepted = true
                val previous = fileDescriptor
                fileDescriptor = pfd
                tunDescriptorMode = mode
                failClosedVpnGeneration = installedFailClosedVpnGeneration
                adoptedStickyTunHandoff = false
                tunGeneration += 1
                acceptedTunGeneration = tunGeneration
                previous
            } else {
                null
            }
        }
        if (!accepted) {
            Log.w(TAG, "closing tun file descriptor created after service stop")
            runCatching { pfd.close() }.onFailure {
                Log.w(TAG, "error closing late tun file descriptor", it)
            }
            MobileCoreCloser.closeAsync("late tun after service stop")
            return false
        }
        if (Settings.serviceMode == ServiceMode.VPN) {
            vpnOwnershipWasEstablished = true
            explicitUserVpnStartPending = false
            invalidateVpnDataPlaneProof(
                "Android TUN generation=$acceptedTunGeneration mode=${mode.name.lowercase()}",
            )
        }
        if (previous != null && previous !== pfd) {
            runCatching { previous.close() }.onFailure {
                Log.w(TAG, "error closing previous tun file descriptor", it)
            }
        }
        return true
    }

    fun onTunCreationFailed() {
        // Builder.establish() is the single attempt authorized by the user's
        // prepare flow. A retry must pass fresh ownership admission and must
        // never take a VPN that the user selected after this attempt began.
        clearExplicitVpnTakeoverAllowance()
    }

    /**
     * Called under [serviceReplacementLock] before a successor acquires the
     * process owner token. Publishing the full-route descriptor and registering
     * predecessor cleanup in this order makes the successor's pending-cleanup
     * wait a real exact barrier rather than a best-effort onDestroy race.
     */
    private fun prepareForStickyServiceReplacement(): Boolean {
        if (destroyCleanupRegistered) return stickyTunPreparedForReplacement
        synchronized(fileDescriptorLock) {
            tunDescriptorAdmissionClosed = true
        }
        cancelPendingStarts()
        val transferableTun =
            !vpnOwnershipRevoked &&
                !isExternalVpnActive("service replacement preparation") &&
                hasRetainedVpnDescriptor()
        val handedOff = transferableTun && handoffTunFileDescriptorForStickyRecovery()
        // A successor owns all subsequent framework-VPN mutations even when
        // the predecessor has no transferable descriptor. Its early blocker
        // may be established while this exact native close runs, so predecessor
        // cleanup must never retire that newer platform generation.
        val cleanupRegistered = registerDestroyCleanup(preserveStickyTun = true)
        check(cleanupRegistered) {
            "predecessor cleanup was not registered before service replacement"
        }
        stickyTunPreparedForReplacement = handedOff
        return handedOff
    }

    private fun registerDestroyCleanup(preserveStickyTun: Boolean): Boolean {
        if (
            destroyCleanupRegistered ||
            ServiceLifecycleOwnership.hasRegisteredCleanup(serviceOwnerToken)
        ) {
            destroyCleanupRegistered = true
            return true
        }
        val accepted = ServiceLifecycleOwnership.beginCleanup(serviceOwnerToken) {
            performDestroyCleanup(preserveStickyTun)
        }
        if (accepted) {
            destroyCleanupRegistered = true
        }
        return accepted || ServiceLifecycleOwnership.hasRegisteredCleanup(serviceOwnerToken)
    }

    private suspend fun performDestroyCleanup(preserveStickyTun: Boolean) {
        DefaultNetworkMonitor.stop(serviceOwnerToken)
        NativeResumeConfigStore.cleanupPlaintextLeases(service)
        if (preserveStickyTun) {
            if (!coreShutdownCompleted) {
                coreShutdownCompleted = MobileCoreCloser.closeBlocking(
                    "service destroy with sticky full-route TUN handoff",
                )
                if (!coreShutdownCompleted) {
                    Log.w(TAG, "exact native close remains pending after sticky TUN handoff")
                }
            }
            // The successor (or process-static terminal-stop path) owns the
            // still-open descriptor. This old object must never retire it.
            platformShutdownCompleted = true
        } else if (!coreShutdownCompleted) {
            val cleanupResult = closeMobileCoreAndAwaitTunQuiescence(
                "service destroy",
                serviceStopping = true,
            )
            coreShutdownCompleted = cleanupResult.completed
            platformShutdownCompleted =
                cleanupResult.platformVpnRetired && cleanupResult.tunQuiescent
            if (requiresCoreCleanupEscalation(
                    cleanupResult.closeCompleted,
                    cleanupResult.tunQuiescent,
                )
            ) {
                Log.w(TAG, "mobile core cleanup remains pending after service destroy")
            }
        }
    }

    private fun handoffTunFileDescriptorForStickyRecovery(): Boolean {
        var handedOffTunGeneration = 0L
        var handedOffMode = TunDescriptorMode.NONE
        var handedOffFailClosedVpnGeneration: FailClosedVpnGeneration? = null
        val descriptor = synchronized(fileDescriptorLock) {
            val retained = fileDescriptor?.takeIf {
                it.fileDescriptor.valid() && tunDescriptorMode != TunDescriptorMode.NONE
            } ?: return@synchronized null
            handedOffMode = tunDescriptorMode
            handedOffFailClosedVpnGeneration = failClosedVpnGeneration
            fileDescriptor = null
            tunDescriptorMode = TunDescriptorMode.NONE
            failClosedVpnGeneration = null
            adoptedStickyTunHandoff = false
            tunGeneration += 1
            handedOffTunGeneration = tunGeneration
            retained
        } ?: return false

        if (!publishStickyTunHandoff(
                descriptor,
                serviceOwnerToken,
                handedOffFailClosedVpnGeneration,
            )
        ) {
            val restored = synchronized(fileDescriptorLock) {
                if (fileDescriptor == null) {
                    fileDescriptor = descriptor
                    tunDescriptorMode = handedOffMode
                    failClosedVpnGeneration = handedOffFailClosedVpnGeneration
                    tunGeneration += 1
                    true
                } else {
                    false
                }
            }
            if (!restored) {
                runCatching { descriptor.close() }
            }
            Log.e(TAG, "refused duplicate sticky TUN handoff")
            return false
        }

        invalidateVpnDataPlaneProof(
            "handed off Android TUN generation=$handedOffTunGeneration for sticky recovery",
        )
        return true
    }

    private fun closeTunFileDescriptor() {
        var closedTunGeneration = 0L
        val pfd = synchronized(fileDescriptorLock) {
            val pfd = fileDescriptor
            fileDescriptor = null
            tunDescriptorMode = TunDescriptorMode.NONE
            failClosedVpnGeneration = null
            adoptedStickyTunHandoff = false
            if (pfd != null) {
                tunGeneration += 1
                closedTunGeneration = tunGeneration
            }
            pfd
        }
        if (pfd != null) {
            invalidateVpnDataPlaneProof("closed Android TUN generation=$closedTunGeneration")
            runCatching { pfd.close() }.onFailure {
                Log.w(TAG, "error closing tun file descriptor", it)
            }
        }
    }

    /**
     * A self-owned framework Network without this process's exact descriptor
     * belongs to an older process incarnation. In particular, package
     * replacement can leave that Network visible briefly after the old PFD is
     * gone. It must never authorize a fresh Builder.establish().
     */
    private fun requireUntrackedOwnVpnRelease(networkHandles: Set<Long>) {
        synchronized(untrackedOwnVpnReleaseLock) {
            untrackedOwnVpnReleaseRequired = true
            untrackedOwnVpnNetworkHandles =
                untrackedOwnVpnNetworkHandles + networkHandles
        }
    }

    internal fun hasUntrackedOwnVpnNetwork(): Boolean {
        val retainedDescriptorValid = hasRetainedVpnDescriptor()
        val ownership = readVpnOwnership(service)
        val latchedReleaseStillPending = synchronized(untrackedOwnVpnReleaseLock) {
            if (!untrackedOwnVpnReleaseRequired) {
                null
            } else if (!ownership.visibilityKnown) {
                true
            } else {
                val trackedHandles = untrackedOwnVpnNetworkHandles
                val remainingHandles =
                    trackedHandles.intersect(ownership.vpnNetworkHandles)
                untrackedOwnVpnNetworkHandles = remainingHandles
                val pending = if (remainingHandles.isNotEmpty()) {
                    true
                } else if (trackedHandles.isEmpty() && ownership.anyActive) {
                    // The exact handles should always be captured on Android
                    // 12+, but keep the legacy empty-handle fallback
                    // conservative rather than treating redacted ownership as
                    // release evidence.
                    true
                } else {
                    false
                }
                if (!pending) {
                    untrackedOwnVpnReleaseRequired = false
                }
                pending
            }
        }
        if (latchedReleaseStillPending != null) return latchedReleaseStillPending
        val shouldDefer = shouldDeferVpnStartForUntrackedOwnNetwork(
            vpnMode = Settings.serviceMode == ServiceMode.VPN,
            retainedDescriptorValid = retainedDescriptorValid,
            vpnOwnershipKnown = ownership.known,
            ownVpnNetworkActive = ownership.active,
        )
        if (shouldDefer) {
            requireUntrackedOwnVpnRelease(ownership.ownNetworkHandles)
        }
        return shouldDefer
    }

    /** Closes only the exact tracked framework VPN descriptor supplied by its owner. */
    internal fun closeTunFileDescriptorIfCurrent(expected: ParcelFileDescriptor): Boolean {
        var closedTunGeneration = 0L
        var owned = false
        val descriptor = synchronized(fileDescriptorLock) {
            if (fileDescriptor !== expected) {
                null
            } else {
                owned = true
                fileDescriptor = null
                tunDescriptorMode = TunDescriptorMode.NONE
                failClosedVpnGeneration = null
                adoptedStickyTunHandoff = false
                tunGeneration += 1
                closedTunGeneration = tunGeneration
                expected
            }
        }
        if (!owned) return !expected.fileDescriptor.valid()
        invalidateVpnDataPlaneProof(
            "closed exact Android TUN generation=$closedTunGeneration",
        )
        val failure = runCatching { descriptor?.close() }.exceptionOrNull()
        failure?.let { Log.w(TAG, "error closing exact tun file descriptor", it) }
        return !expected.fileDescriptor.valid()
    }

    private fun startCoreRuntimeMonitor(nativeStartup: Boolean = false) {
        if (coreRuntimeMonitorJob?.isActive == true) return
        val generation = currentStartGeneration()
        val neverStartedGraceMs =
            if (nativeStartup) CORE_NATIVE_START_GRACE_MS else CORE_FLUTTER_START_GRACE_MS
        val startingStallMs =
            if (nativeStartup) CORE_NATIVE_STARTING_STALL_MS else CORE_FLUTTER_STARTING_STALL_MS
        val unverifiedTimeoutMs =
            if (nativeStartup) nativeUnverifiedStartupRecoveryTimeoutMs() else unverifiedStartupRecoveryTimeoutMs()
        val startupOwner = if (nativeStartup) "native service" else "Flutter"
        if (nativeStartup) {
            Log.w(
                TAG,
                "native startup recovery monitors armed " +
                    "grace_ms=$neverStartedGraceMs starting_stall_ms=$startingStallMs " +
                    "unverified_ms=$unverifiedTimeoutMs",
            )
        }

        coreRuntimeMonitorJob = serviceScope.launch(Dispatchers.IO) {
            val coreClient = GrpcClientProvider.coreClient(CORE_WATCHDOG_GRPC_TIMEOUT_MS)
            var sawStartedCore = false
            var startedAtElapsed = 0L
            var monitorStartedAtElapsed = SystemClock.elapsedRealtime()
            while (isActive) {
                try {
                    val serviceStatus = status.value
                    if (serviceStatus == Status.Stopped || serviceStatus == Status.Stopping) return@launch
                    if (serviceStatus == Status.Started) return@launch
                    if (underlyingNetworkInitialized && observedUnderlyingNetwork == null) {
                        // No route can become healthy without a physical network.
                        // Suspend on the owner-scoped Android callback instead of
                        // consuming a recovery deadline or waking on a short poll.
                        Log.i(TAG, "startup monitor parked until an underlying-network callback")
                        DefaultNetworkMonitor.require()
                        if (!shouldWatchCore(generation)) return@launch
                        val resumedAt = SystemClock.elapsedRealtime()
                        monitorStartedAtElapsed = resumedAt
                        if (sawStartedCore) startedAtElapsed = resumedAt
                        Log.i(TAG, "startup monitor resumed after an underlying-network callback")
                        continue
                    }
                    val coreState = readCoreState(coreClient)
                    if (coreState == CoreStates.STARTED) {
                        if (!sawStartedCore) {
                            Log.i(TAG, "core runtime started; waiting for verified selected-route signal")
                            sawStartedCore = true
                            startedAtElapsed = SystemClock.elapsedRealtime()
                        }
                        val elapsedMs = SystemClock.elapsedRealtime() - startedAtElapsed
                        if (
                            shouldRecoverUnverifiedRunningCore(
                                sawStartedCore = sawStartedCore,
                                coreState = coreState,
                                userSessionActive = shouldWatchCore(generation),
                                elapsedMs = elapsedMs,
                                timeoutMs = unverifiedTimeoutMs,
                            )
                        ) {
                            if (requestCoreRecovery("selected-route verification timed out", generation)) {
                                Log.w(
                                    TAG,
                                    "selected-route verification did not complete within ${elapsedMs}ms; " +
                                        "entering native retry recovery",
                                )
                                return@launch
                            }
                        }
                    } else if (
                        shouldRecoverUnverifiedStartedCore(
                            sawStartedCore = sawStartedCore,
                            coreState = coreState,
                            userSessionActive = shouldWatchCore(generation),
                        )
                    ) {
                        if (
                            requestCoreRecovery(
                                "selected server unavailable during $startupOwner startup",
                                generation,
                            )
                        ) {
                            Log.w(TAG, "unverified startup core stopped; entering native retry recovery")
                            return@launch
                        }
                    } else if (
                        shouldRecoverNeverStartedCore(
                            sawStartedCore = sawStartedCore,
                            coreState = coreState,
                            userSessionActive = shouldWatchCore(generation),
                            elapsedMs = SystemClock.elapsedRealtime() - monitorStartedAtElapsed,
                            timeoutMs = neverStartedGraceMs,
                        )
                    ) {
                        if (requestCoreRecovery("core did not start within bounded grace period", generation)) {
                            Log.w(
                                TAG,
                                "core did not start within ${neverStartedGraceMs}ms; " +
                                    "entering native retry recovery",
                            )
                            return@launch
                        }
                    } else if (
                        shouldRecoverStalledStartingCore(
                            sawStartedCore = sawStartedCore,
                            coreState = coreState,
                            userSessionActive = shouldWatchCore(generation),
                            elapsedMs = SystemClock.elapsedRealtime() - monitorStartedAtElapsed,
                            timeoutMs = startingStallMs,
                        )
                    ) {
                        if (requestCoreRecovery("core remained STARTING beyond bounded startup window", generation)) {
                            Log.w(
                                TAG,
                                "core remained STARTING for ${startingStallMs}ms; " +
                                    "entering native retry recovery",
                            )
                            return@launch
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    if (status.value == Status.Started) return@launch
                    Log.d(TAG, "core runtime monitor waiting for started core", e)
                }
                delay(
                    coreWatchdogPollDelayMs(
                        recoveryInProgress = true,
                        deviceInteractive = Application.powerManager.isInteractive,
                    ),
                )
            }
        }
    }

    private fun unverifiedStartupRecoveryTimeoutMs(): Long {
        val verificationTimeout = if (currentRuntimeUsesTurncoat()) {
            STARTUP_ROUTE_VERIFY_TURNCOAT_TIMEOUT_MS
        } else {
            STARTUP_ROUTE_VERIFY_TIMEOUT_MS
        }
        return verificationTimeout + CORE_UNVERIFIED_STARTUP_RECOVERY_GRACE_MS
    }

    private fun nativeUnverifiedStartupRecoveryTimeoutMs(): Long =
        unverifiedStartupRecoveryTimeoutMs() + ROUTE_WATCHDOG_GRPC_TIMEOUT_MS

    private fun stopCoreRuntimeMonitor() {
        coreRuntimeMonitorJob?.cancel()
        coreRuntimeMonitorJob = null
    }

    private fun startExternalVpnWatchdog() {
        val generation = currentStartGeneration()
        synchronized(routeWatchdogCheckLock) {
            if (externalVpnWatchdogJob?.isActive == true || service !is VPNService) return
            externalVpnWatchdogJob = serviceScope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                val changes = Channel<Unit>(Channel.CONFLATED)
                val connectivity = Application.connectivity
                val callback = object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) { changes.trySend(Unit) }
                    override fun onLost(network: Network) { changes.trySend(Unit) }
                    override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                        changes.trySend(Unit)
                    }
                }
                val request = NetworkRequest.Builder()
                    .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
                    .build()
                val registered = runCatching {
                    connectivity.registerNetworkCallback(request, callback)
                }.onFailure {
                    // onRevoke remains authoritative; the rare route monitor
                    // also arbitrates ownership if this platform observer fails.
                    Log.w(TAG, "VPN ownership observer unavailable", it)
                }.isSuccess
                try {
                    changes.trySend(Unit) // Register before the first snapshot.
                    do {
                        changes.receive()
                        if (!shouldWatchCore(generation)) return@launch
                        var misses = 0
                        for (confirmation in 1..EXTERNAL_VPN_OWNERSHIP_LOSS_CONFIRMATIONS) {
                            if (!shouldWatchCore(generation)) return@launch
                            if (shouldYieldToExternalVpn("VPN ownership event")) {
                                stopForExternalVpnOnMain("VPN ownership event")
                                return@launch
                            }
                            val ownership = readVpnOwnership(service)
                            if (ownership.active) {
                                vpnOwnershipWasEstablished = true
                                break
                            }
                            if (!ownership.known || !vpnOwnershipWasEstablished) break
                            val transitionOwned = coreRecoveryOwnsVpnTransition(generation) ||
                                (status.value == Status.Starting && serviceStartPipelineActive)
                            if (transitionOwned) break
                            misses += 1
                            if (shouldRecoverMissingOwnVpn(
                                ownershipKnown = ownership.known,
                                ownVpnActive = ownership.active,
                                serviceOwnedTransitionActive = transitionOwned,
                                consecutiveOwnVpnMisses = misses,
                                requiredMisses = EXTERNAL_VPN_OWNERSHIP_LOSS_CONFIRMATIONS,
                            )) {
                                val reason = "VPN ownership event confirmed missing own network"
                                markRouteDegraded(reason)
                                requestCoreRecovery(reason, generation)
                                break
                            }
                            // Only a suspected ownership loss gets a bounded
                            // confirmation; stable ownership has no timer/RPC loop.
                            delay(CORE_WATCHDOG_CONFIRM_MS)
                        }
                    } while (registered && isActive)
                } finally {
                    if (registered) runCatching { connectivity.unregisterNetworkCallback(callback) }
                    changes.close()
                }
            }
            externalVpnWatchdogJob?.start()
        }
    }

    private fun stopExternalVpnWatchdog() {
        externalVpnWatchdogJob?.cancel()
        externalVpnWatchdogJob = null
    }

    private suspend fun verifyAndMarkCoreRuntimeStarted(reason: String) {
        val generation = currentStartGeneration()
        if (!shouldContinueStart(generation)) return
        if (nativeRouteRecoveryOwnsGeneration(generation)) {
            Log.i(TAG, "delegating platform started signal to active native route recovery")
            return
        }
        val routeVerified = verifyNativeStartupRoute(
            usesTurncoat = currentRuntimeUsesTurncoat(),
            reason = reason,
            generation = generation,
        )
        if (routeVerified) {
            markCoreRuntimeStarted(routeVerified = true, generation = generation)
        }
    }

    private suspend fun acknowledgeVerifiedRouteFromFlutter(): Boolean {
        val generation = currentStartGeneration()
        if (!shouldContinueStart(generation)) return false
        if (nativeRouteRecoveryOwnsGeneration(generation)) {
            Log.i(TAG, "delegating Flutter started acknowledgement to active native route recovery")
            return false
        }
        val usesTurncoat = currentRuntimeUsesTurncoat()
        val deadline = SystemClock.elapsedRealtime() + if (usesTurncoat) {
            STARTUP_ROUTE_VERIFY_TURNCOAT_TIMEOUT_MS
        } else {
            STARTUP_ROUTE_VERIFY_TIMEOUT_MS
        }
        return awaitStartupRoutePublication(
            deadlineElapsedMs = deadline,
            now = { SystemClock.elapsedRealtime() },
            isCurrent = { shouldContinueStart(generation) },
            recoveryActive = { nativeRouteRecoveryOwnsGeneration(generation) },
            hasCurrentProof = { hasReusableVpnDataPlaneProof(generation) },
            verify = {
                verifyNativeStartupRoute(
                    usesTurncoat = usesTurncoat,
                    reason = "Flutter started acknowledgement",
                    generation = generation,
                    operationDeadlineElapsedMs = deadline,
                )
            },
            publish = {
                var proofChanged = false
                val started = markCoreRuntimeStarted(
                    routeVerified = true,
                    generation = generation,
                    recoverOnProofChange = false,
                    onProofChanged = { proofChanged = true },
                )
                when {
                    started -> StartupRoutePublicationResult.STARTED
                    proofChanged -> StartupRoutePublicationResult.PROOF_CHANGED
                    else -> StartupRoutePublicationResult.FAILED
                }
            },
        )
    }

    private fun nativeRouteRecoveryOwnsGeneration(generation: Long): Boolean =
        shouldDelegateRouteVerificationToNativeRecovery(
            nativeRecoveryActive =
                coreRecoveryInProgress ||
                    routeWatchdogDegraded ||
                    networkRecoveryJob?.isActive == true,
            userSessionActive = Settings.startedByUser,
            startStillCurrent = shouldContinueStart(generation),
        )

    private fun coreRecoveryOwnsVpnTransition(generation: Long): Boolean =
        synchronized(lifecycleLock) {
            coreRecoveryInProgress &&
                coreRecoveryTransitionGeneration == generation &&
                coreRecoveryJob?.isActive == true &&
                shouldWatchCore(generation)
        }

    private fun hasReusableVpnDataPlaneProof(generation: Long): Boolean {
        if (Settings.serviceMode != ServiceMode.VPN) return true
        val proof = currentVpnDataPlaneProof(generation) ?: return false
        val proofAgeMs = SystemClock.elapsedRealtime() - proof.completedAtElapsedRealtimeMs
        return proofAgeMs in 0..VPN_DATA_PLANE_PROOF_REUSE_MS
    }

    private fun currentVpnDataPlaneProof(generation: Long): VpnDataPlaneProof? {
        // A volatile fast-path avoids a ConnectivityManager Binder lookup in
        // the common not-yet-proven case. A concurrent new proof may be used
        // by the next check; returning null here is deliberately conservative.
        if (lastVpnDataPlaneProof == null) return null
        val currentVpnNetworkHandle = vpnDataPlaneProbe.currentVpnNetworkHandle()
        return synchronized(vpnDataPlaneProofLock) {
            val proof = lastVpnDataPlaneProof ?: return@synchronized null
            proof.takeIf {
                it.startGeneration == generation &&
                    it.networkGeneration == networkGeneration &&
                    it.tunGeneration == tunGeneration &&
                    it.vpnNetworkHandle == currentVpnNetworkHandle
            }
        }
    }

    private fun recordVpnDataPlaneProof(
        proofStartGeneration: Long,
        proofNetworkGeneration: Long,
        proofTunGeneration: Long,
        proofVpnNetworkHandle: Long,
    ): Boolean {
        // Keep the exact Android VPN Network revalidation, but do not hold the
        // proof lock while ConnectivityManager performs its Binder-backed
        // lookup. Full TUN/interface inspection is intentionally deferred to
        // the existing route watchdog and Started health gate.
        val currentVpnNetworkHandle = vpnDataPlaneProbe.currentVpnNetworkHandle()
        return synchronized(vpnDataPlaneProofLock) {
            if (
                proofStartGeneration != startGeneration ||
                proofNetworkGeneration != networkGeneration ||
                proofTunGeneration != tunGeneration ||
                proofVpnNetworkHandle != currentVpnNetworkHandle
            ) {
                return@synchronized false
            }
            lastVpnDataPlaneProof = VpnDataPlaneProof(
                startGeneration = proofStartGeneration,
                networkGeneration = proofNetworkGeneration,
                tunGeneration = proofTunGeneration,
                vpnNetworkHandle = proofVpnNetworkHandle,
                completedAtElapsedRealtimeMs = SystemClock.elapsedRealtime(),
            )
            // The first normal watchdog pass seeds this baseline outside the
            // startup publication path. Subsequent passes retain the same
            // activity-aware proof scheduling policy.
            lastTunTrafficSnapshot = null
            true
        }
    }

    private fun invalidateVpnDataPlaneProof(reason: String) {
        if (Settings.serviceMode == ServiceMode.VPN) {
            Settings.strictVpnRouteVerified = false
        }
        val invalidated = synchronized(vpnDataPlaneProofLock) {
            val hadProof = lastVpnDataPlaneProof != null
            lastVpnDataPlaneProof = null
            lastTunTrafficSnapshot = null
            hadProof
        }
        if (invalidated) {
            Mobile.updateCrashReporting()
            Log.i(TAG, "invalidating VPN data-plane proof: $reason")
        }
    }

    private suspend fun markCoreRuntimeStarted(
        routeVerified: Boolean = false,
        generation: Long = currentStartGeneration(),
        recoverOnProofChange: Boolean = true,
        onProofChanged: () -> Unit = {},
    ): Boolean {
        if (!shouldContinueStart(generation)) {
            Log.i(TAG, "discarding stale core-start signal generation=$generation")
            return false
        }
        if (coreRecoveryInProgress && !routeVerified) {
            Log.w(TAG, "ignoring unverified core started signal while route recovery is in progress")
            return false
        }
        if (!hasReusableVpnDataPlaneProof(generation)) {
            onProofChanged()
            Log.w(TAG, "refusing Started without a fresh current-generation VPN data-plane proof")
            withContext(Dispatchers.Main) {
                if (shouldContinueStart(generation)) {
                    status.value = Status.Starting
                    notification.show(activeProfileName, R.string.status_starting)
                }
            }
            return false
        }
        val tunHealth = awaitTunRuntimeHealthForStarted()
        if (!tunHealth.healthy) {
            Log.w(TAG, "refusing Started without a healthy Android TUN: ${tunHealth.summary}")
            withContext(Dispatchers.Main) {
                if (shouldContinueStart(generation)) {
                    status.value = Status.Starting
                    notification.show(activeProfileName, R.string.status_starting)
                }
            }
            if (!coreRecoveryInProgress) {
                requestCoreRecovery("verified route did not produce a healthy Android TUN", generation)
            }
            return false
        }
        if (activeProfileName.isBlank()) {
            activeProfileName = Settings.activeProfileName
        }
        val currentJob = currentCoroutineContext()[Job]
        coreRuntimeMonitorJob?.takeIf { it != currentJob }?.cancel()
        coreRuntimeMonitorJob = null
        cancelCoreRecoveryAdmissionRetry()
        val marked = withContext(Dispatchers.Main) {
            if (!shouldContinueStart(generation)) {
                return@withContext false
            }
            // TUN or Android Network ownership can change after the first
            // proof check while TUN health settles. Revalidate at the exact
            // publication point so a proof from the replaced generation can
            // never promote the new generation to Started.
            if (!hasReusableVpnDataPlaneProof(generation)) {
                onProofChanged()
                Log.w(TAG, "refusing Started because VPN data-plane proof changed before publication")
                status.value = Status.Starting
                notification.show(activeProfileName, R.string.status_starting)
                return@withContext false
            }
            status.value = Status.Started
            Settings.strictVpnRouteVerified = true
            Mobile.updateCrashReporting()
            notification.show(activeProfileName, R.string.status_started)
            true
        }
        if (!marked) {
            if (recoverOnProofChange && shouldContinueStart(generation)) {
                routeWatchdogDegraded = true
                requestRouteWatchdogCheck("VPN data-plane proof changed before Started", delayMs = 0L)
            }
            return false
        }
        routeWatchdogFailures = 0
        routeWatchdogDegraded = false
        if (Settings.serviceMode == ServiceMode.VPN) {
            vpnOwnershipWasEstablished = true
        }
        notification.start()
        startExternalVpnWatchdog()
        stopCoreRecoverySupervision()
        startRouteWatchdog()
        routeHealthMonitor?.rearm()
        Log.d(TAG, "accepted Started after platform readiness: ${tunHealth.summary}")
        if (
            activeQuickSettingsGeneration == generation &&
            activeQuickSettingsRequestId > 0L &&
            !quickSettingsConnectedPublished
        ) {
            quickSettingsConnectedPublished = true
            recordQuickSettingsLifecycle(
                event = "route",
                outcome = "connected",
                generation = generation,
            )
        }
        return true
    }

    private suspend fun awaitTunRuntimeHealthForStarted(): TunRuntimeHealth {
        var health = readTunRuntimeHealth()
        if (health.healthy) return health
        val deadline = SystemClock.elapsedRealtime() + MARK_STARTED_TUN_SETTLE_MS
        while (SystemClock.elapsedRealtime() < deadline) {
            delay(MARK_STARTED_TUN_POLL_MS)
            health = readTunRuntimeHealth()
            if (health.healthy) return health
        }
        return health
    }

    private fun startCoreWatchdog() {
        if (coreWatchdogJob?.isActive == true) return
        val generation = currentStartGeneration()
        // Stable runtime health is checked by the rare route monitor; Binder
        // death is immediate. This job exists only inside bounded core recovery.
        coreWatchdogJob = serviceScope.launch(Dispatchers.IO) {
            val coreClient = GrpcClientProvider.coreClient(CORE_WATCHDOG_GRPC_TIMEOUT_MS)
            while (isActive && shouldWatchCore(generation) && coreRecoveryInProgress) {
                if (underlyingNetworkInitialized && observedUnderlyingNetwork == null) {
                    DefaultNetworkMonitor.require()
                    continue
                }
                delay(coreWatchdogPollDelayMs(
                    recoveryInProgress = true,
                    deviceInteractive = Application.powerManager.isInteractive,
                ))
                if (!shouldWatchCore(generation) || !coreRecoveryInProgress) return@launch
                val recoveryStartedAt = coreRecoveryOnlineStartedAtElapsed
                val elapsedMs = if (recoveryStartedAt > 0L) {
                    SystemClock.elapsedRealtime() - recoveryStartedAt
                } else 0L
                if (shouldTerminateExpiredCoreRecovery(
                    recoveryInProgress = true,
                    userSessionActive = shouldWatchCore(generation),
                    underlyingNetworkAvailable =
                        !underlyingNetworkInitialized || observedUnderlyingNetwork != null,
                    elapsedMs = elapsedMs,
                    timeoutMs = coreRecoveryOnlineTimeoutMs(),
                )) {
                    terminateExpiredCoreRecovery(generation, readCoreStateSnapshot(coreClient), elapsedMs)
                }
            }
        }
    }

    private fun stopCoreRecoverySupervision() {
        coreWatchdogJob?.cancel()
        coreWatchdogJob = null
    }

    private fun stopCoreWatchdog() {
        stopCoreRecoverySupervision()
        cancelCoreRecoveryAdmissionRetry()
        val recoveryJob = synchronized(lifecycleLock) {
            val active = coreRecoveryJob
            coreRecoveryJob = null
            coreRecoveryInProgress = false
            coreRecoveryTransitionGeneration = null
            lastCoreRecoveryAttemptAt = 0L
            coreRecoveryOnlineStartedAtElapsed = 0L
            active
        }
        recoveryJob?.cancel()
    }

    private fun cancelCoreRecoveryAdmissionRetry() {
        val retryJob = synchronized(lifecycleLock) {
            val active = coreRecoveryAdmissionRetryJob
            coreRecoveryAdmissionRetryJob = null
            active
        }
        retryJob?.cancel()
    }

    private fun startRouteWatchdog() {
        val generation = currentStartGeneration()
        synchronized(routeWatchdogCheckLock) {
            if (routeWatchdogJob?.isActive == true) return
            val healthClient = GrpcClientProvider.coreClient(CORE_WATCHDOG_GRPC_TIMEOUT_MS)
            val routeClient = GrpcClientProvider.coreClient(ROUTE_WATCHDOG_GRPC_TIMEOUT_MS)
            val monitor = RouteHealthMonitor(
                nowMs = SystemClock::elapsedRealtime,
                nextDelayMs = {
                    if (shouldWatchCore(generation)) routeWatchdogPollDelayMs() else Long.MAX_VALUE
                },
                check = { reason ->
                    if (shouldWatchCore(generation)) {
                        runRouteWatchdogCheck(reason, healthClient, routeClient, generation)
                    }
                },
            )
            routeHealthMonitor = monitor
            routeWatchdogJob = serviceScope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                monitor.run()
            }
            routeWatchdogJob?.start()
        }
    }

    private fun stopRouteWatchdog() {
        routeWatchdogJob?.cancel()
        routeWatchdogJob = null
        routeHealthMonitor = null
        lastProxyRouteProofAtElapsedMs = 0L
        routeWatchdogFailures = 0
        routeWatchdogHealthyChecks = 0
        lastRouteRecoveryAttemptAt = 0L
        Log.i(TAG, "route watchdog stopped")
    }

    private fun resetUnderlyingNetworkGeneration() {
        networkRecoveryJob?.cancel()
        networkRecoveryJob = null
        invalidateVpnDataPlaneProof("underlying network monitor reset")
        networkGeneration = 0L
        observedUnderlyingNetwork = null
        underlyingNetworkInitialized = false
    }

    private fun onUnderlyingNetworkObserved(network: android.net.Network?) {
        if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
            Log.i(TAG, "ignoring underlying network callback for stale service owner")
            return
        }
        val previous = observedUnderlyingNetwork
        observedUnderlyingNetwork = network
        updateCoreRecoveryOnlineWindow(network)

        // The blocker is deliberately established before the physical-network
        // monitor starts. Its first usable callback must therefore update the
        // framework VPN as well; treating that callback as initialization-only
        // leaves UnderlyingNetworks empty for the whole generation and can
        // capture Marten's own pre-TUN transport sockets.
        if (service is VPNService) {
            service.updateUnderlyingNetwork(network)
        }

        if (!underlyingNetworkInitialized) {
            underlyingNetworkInitialized = true
            Log.i(TAG, "underlying network generation=0 initialized available=${network != null}")
            return
        }
        if (previous == network) return

        val generation = ++networkGeneration
        invalidateVpnDataPlaneProof("underlying network generation=$generation")
        Log.w(TAG, "underlying network changed generation=$generation available=${network != null}")
        val wasConnected = status.value == Status.Started
        val wasRecovering = networkRecoveryJob?.isActive == true
        if ((!wasConnected && !wasRecovering && !routeWatchdogDegraded) || !shouldWatchCore()) return
        routeWatchdogDegraded = true

        launchNetworkRouteRecovery(
            generation = generation,
            reason = "underlying network generation=$generation",
            // onAvailable already identifies a usable non-VPN Network. When
            // connectivity returns from a complete outage, begin the single
            // owner-scoped recovery immediately instead of adding a timer.
            settleDelayMs = if (previous == null && network != null) 0L else ROUTE_WAKE_CHECK_DELAY_MS,
            replaceActive = true,
        )
    }

    private fun updateCoreRecoveryOnlineWindow(network: android.net.Network?) {
        synchronized(lifecycleLock) {
            if (!coreRecoveryInProgress) return
            coreRecoveryOnlineStartedAtElapsed = if (network == null) {
                0L
            } else if (coreRecoveryOnlineStartedAtElapsed <= 0L) {
                SystemClock.elapsedRealtime()
            } else {
                coreRecoveryOnlineStartedAtElapsed
            }
        }
    }

    private fun launchNetworkRouteRecovery(
        generation: Long,
        reason: String,
        settleDelayMs: Long,
        replaceActive: Boolean,
        forceTurncoatCarrierRetirement: Boolean = false,
    ) {
        if (!shouldWatchCore() || status.value == Status.Stopped || status.value == Status.Stopping) return
        val activeJob = networkRecoveryJob
        if (!replaceActive && activeJob?.isActive == true) {
            Log.i(TAG, "network route recovery already active; keeping current owner ($reason)")
            return
        }
        activeJob?.cancel()

        mainHandler.post {
            if (
                generation == networkGeneration &&
                shouldWatchCore() &&
                status.value != Status.Stopped &&
                status.value != Status.Stopping
            ) {
                if (activeProfileName.isBlank()) {
                    activeProfileName = Settings.activeProfileName
                }
                status.value = Status.Starting
                notification.show(activeProfileName, R.string.status_recovering)
            }
        }

        networkRecoveryJob = serviceScope.launch(Dispatchers.IO) {
            val currentJob = currentCoroutineContext()[Job]
            try {
                if (settleDelayMs > 0L) delay(settleDelayMs)
                recoverNetworkRoute(
                    generation = generation,
                    reason = reason,
                    forceTurncoatCarrierRetirement = forceTurncoatCarrierRetirement,
                )
            } finally {
                synchronized(lifecycleLock) {
                    if (networkRecoveryJob === currentJob) {
                        networkRecoveryJob = null
                    }
                }
                if (generation == networkGeneration && shouldWatchCore()) {
                    routeHealthMonitor?.rearm()
                }
            }
        }
    }

    private suspend fun recoverNetworkRoute(
        generation: Long,
        reason: String,
        forceTurncoatCarrierRetirement: Boolean,
    ) {
        val healthClient = GrpcClientProvider.coreClient(CORE_WATCHDOG_GRPC_TIMEOUT_MS)
        val routeClient = GrpcClientProvider.coreClient(ROUTE_WATCHDOG_GRPC_TIMEOUT_MS)
        var routeAttempt = 0
        var forcedTurncoatRetirementAttempted = false

        while (currentCoroutineContext().isActive) {
            if (generation != networkGeneration || !shouldWatchCore()) {
                Log.i(TAG, "discarding stale network route recovery ($reason)")
                return
            }
            if (underlyingNetworkInitialized && observedUnderlyingNetwork == null) {
                Log.i(TAG, "route recovery parked until an underlying-network callback generation=$generation")
                try {
                    DefaultNetworkMonitor.require()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    Log.i(TAG, "underlying-network wait ended before recovery generation=$generation")
                }
                return
            }
            if (shouldYieldToExternalVpn("network route recovery")) {
                stopForExternalVpnOnMain("network route recovery")
                return
            }
            if (coreRecoveryInProgress) {
                Log.i(TAG, "network route recovery handed to active core recovery ($reason)")
                return
            }

            val coreState = readCoreStateSnapshot(healthClient)
            if (!isCoreRuntimeHealthy(coreState)) {
                Log.w(TAG, "local core became unhealthy during network route recovery: state=$coreState")
                requestCoreRecovery("network route recovery found an unhealthy core: state=$coreState")
                return
            }

            val forceTurncoatCarrier = forceTurncoatCarrierRetirement && !forcedTurncoatRetirementAttempted
            if (forceTurncoatCarrier) {
                // Consume the stronger reset before crossing the native boundary:
                // a partial failure must not repeatedly retire a freshly rebuilding
                // carrier on every retry.
                forcedTurncoatRetirementAttempted = true
            }
            val networkObservationRevision = DefaultNetworkMonitor.observationRevision(serviceOwnerToken)
            val resetResult = runCatching {
                // Network reset is bound to the current native Box snapshot,
                // but is deliberately not a lifecycle-exclusive operation.
                // Stop/Close must remain able to detach that Box and break a
                // transport reset that has stopped making progress.
                if (forceTurncoatCarrier) {
                    Mobile.resetNetworkForRouteRecovery()
                } else {
                    Mobile.resetNetwork()
                }
            }
            if (resetResult.isFailure) {
                val resetKind = if (forceTurncoatCarrier) "forced TURNcoat carrier reset" else "network reset"
                Log.w(TAG, "native $resetKind failed ($reason); rebuilding core and TUN", resetResult.exceptionOrNull())
                requestCoreRecovery("native $resetKind failed during $reason")
                return
            }
            val resetKind = if (forceTurncoatCarrier) "forced TURNcoat carrier reset" else "network reset"
            Log.i(TAG, "native $resetKind completed ($reason); awaiting fresh VPN data-plane proof")

            if (!beginRouteWatchdogCheck()) {
                Log.i(TAG, "network route recovery deferred to the active route check ($reason)")
                return
            }
            val result = try {
                runCatching {
                    checkSelectedRoute(
                        routeClient,
                        requireVpnDataPlane = true,
                        redundantDataPlaneEndpoints = true,
                    )
                }.getOrElse {
                    if (it is CancellationException) throw it
                    RouteHealth(false, "network route check error: ${it.message ?: it.javaClass.simpleName}")
                }
            } finally {
                endRouteWatchdogCheck()
            }
            if (generation != networkGeneration || !shouldWatchCore()) {
                Log.i(TAG, "discarding stale VPN data-plane result ($reason)")
                return
            }
            if (result.outboundType.isNotBlank()) {
                lastSelectedOutboundType = result.outboundType
            }

            if (!result.healthy && result.networkReadinessPending) {
                Log.i(
                    TAG,
                    "physical network is published but its resolver is not ready; " +
                        "parking VPN route recovery on the next network observation ($reason)",
                )
                ConnectionDiagnostics.record(
                    service,
                    component = "network",
                    event = "resolver_readiness",
                    outcome = "waiting",
                    generation = currentStartGeneration(),
                    networkGeneration = generation,
                    tunGeneration = tunGeneration,
                )
                if (networkObservationRevision != null) {
                    DefaultNetworkMonitor.awaitObservationAfter(
                        ownerToken = serviceOwnerToken,
                        revision = networkObservationRevision,
                        fallbackTimeoutMs = NETWORK_ROUTE_RECOVERY_RETRY_MS,
                    )
                } else {
                    delay(NETWORK_ROUTE_RECOVERY_RETRY_MS)
                }
                continue
            }

            routeAttempt += 1
            if (
                isCurrentNetworkRouteProof(
                    proofGeneration = generation,
                    currentGeneration = networkGeneration,
                    routeHealthy = result.healthy,
                    userSessionActive = shouldWatchCore(),
                )
            ) {
                routeWatchdogFailures = 0
                routeWatchdogDegraded = false
                Log.i(TAG, "network route recovered ($reason, attempt $routeAttempt): ${result.summary}")
                markCoreRuntimeStarted(routeVerified = true)
                return
            }

            Log.w(TAG, "network route still unavailable ($reason, attempt $routeAttempt): ${result.summary}")
            if (
                (result.requiresCoreRecovery && routeAttempt >= 2) ||
                routeAttempt >= NETWORK_ROUTE_RECOVERY_MAX_ATTEMPTS
            ) {
                Log.w(TAG, "VPN data plane remained unavailable after network reset; rebuilding core and TUN")
                requestCoreRecovery(
                    "network route recovery could not restore the VPN data plane: ${result.summary}",
                )
                return
            }
            delay(NETWORK_ROUTE_RECOVERY_RETRY_MS)
        }
    }

    private fun requestRouteWatchdogCheck(reason: String, delayMs: Long = ROUTE_WAKE_CHECK_DELAY_MS) {
        if (status.value == Status.Stopped || status.value == Status.Stopping) return
        startRouteWatchdog()
        routeHealthMonitor?.request(reason, delayMs)
    }

    private suspend fun runRouteWatchdogCheck(
        reason: String,
        healthClient: CoreClient,
        routeClient: CoreClient,
        generation: Long,
        logHealthy: Boolean = false,
        logSkips: Boolean = false,
    ) {
        if (!beginRouteWatchdogCheck()) {
            if (logSkips) Log.d(TAG, "route watchdog skipped ($reason): another check is running")
            return
        }

        val checkNetworkGeneration = networkGeneration
        val checkTunGeneration = tunGeneration
        fun isCurrentObservation(): Boolean = shouldWatchCore(generation) &&
            networkGeneration == checkNetworkGeneration && tunGeneration == checkTunGeneration
        try {
            currentCoroutineContext().ensureActive()
            if (!isCurrentObservation()) return
            if (shouldYieldToExternalVpn("route watchdog check")) {
                routeWatchdogFailures = 0
                stopForExternalVpnOnMain("route watchdog check")
                return
            }
            if (!shouldWatchCore()) {
                routeWatchdogFailures = 0
                if (logSkips) Log.i(TAG, "route watchdog skipped ($reason): no user-started core")
                return
            }
            if (coreRecoveryInProgress) {
                if (logSkips) Log.i(TAG, "route watchdog skipped ($reason): recovery already in progress")
                return
            }
            if (coreRecoveryAdmissionRetryJob?.isActive == true) {
                if (logSkips) Log.i(TAG, "route watchdog parked ($reason): recovery admission pending")
                return
            }
            if (networkRecoveryJob?.isActive == true) {
                if (logSkips) Log.i(TAG, "route watchdog skipped ($reason): network recovery already owns validation")
                return
            }
            val coreState = readCoreStateSnapshot(healthClient)
            currentCoroutineContext().ensureActive()
            if (!isCurrentObservation()) return
            if (!isCoreRuntimeHealthy(coreState)) {
                routeWatchdogFailures = 0
                Log.w(TAG, "route watchdog found an unhealthy local core ($reason): state=$coreState")
                requestCoreRecovery("route watchdog found an unhealthy core: state=$coreState")
                return
            }

            val tunHealth = readTunRuntimeHealth()
            val currentTunTrafficSnapshot = readTunTrafficSnapshot(tunHealth)
            val previousTunTrafficSnapshot = lastTunTrafficSnapshot
            val tunTrafficAdvanced = hasTunTrafficAdvanced(
                previous = previousTunTrafficSnapshot,
                current = currentTunTrafficSnapshot,
            )
            val nowElapsedRealtimeMs = SystemClock.elapsedRealtime()
            val currentProof = currentVpnDataPlaneProof(currentStartGeneration())
            if (
                previousTunTrafficSnapshot == null &&
                currentTunTrafficSnapshot != null &&
                currentProof != null
            ) {
                synchronized(vpnDataPlaneProofLock) {
                    if (
                        lastTunTrafficSnapshot == null &&
                        lastVpnDataPlaneProof === currentProof
                    ) {
                        lastTunTrafficSnapshot = currentTunTrafficSnapshot
                    }
                }
            }
            val requireVpnDataPlane = Settings.serviceMode == ServiceMode.VPN &&
                shouldRunVpnDataPlaneProbe(
                    forced = status.value == Status.Starting,
                    degraded = routeWatchdogDegraded,
                    deviceInteractive = Application.powerManager.isInteractive,
                    lastProofElapsedRealtimeMs = currentProof?.completedAtElapsedRealtimeMs ?: 0L,
                    nowElapsedRealtimeMs = nowElapsedRealtimeMs,
                )
            val preserveVerifiedRouteOnProbeFailure =
                shouldPreserveVerifiedRouteAfterTransientProbeFailure(
                    platformStarted = status.value == Status.Started,
                    routeAlreadyDegraded = routeWatchdogDegraded,
                    priorFailedChecks = routeWatchdogFailures,
                    currentProofAvailable = currentProof != null,
                    tunHealthy = tunHealth.healthy,
                    tunTrafficAdvanced = tunTrafficAdvanced,
                )
            val result = if (!tunHealth.healthy) {
                RouteHealth(
                    healthy = false,
                    summary = tunHealth.summary,
                    outboundType = lastSelectedOutboundType,
                    requiresCoreRecovery = true,
                )
            } else if (requireVpnDataPlane) {
                runCatching {
                    checkSelectedRoute(
                        routeClient,
                        requireVpnDataPlane = true,
                        preserveVpnDataPlaneProofOnFailure = preserveVerifiedRouteOnProbeFailure,
                    )
                }.getOrElse {
                    if (it is CancellationException) throw it
                    RouteHealth(
                        false,
                        "VPN data-plane watchdog error: ${it.javaClass.simpleName}",
                        lastSelectedOutboundType,
                        requiresCoreRecovery = true,
                    )
                }
            } else if (Settings.serviceMode == ServiceMode.VPN && currentProof != null) {
                // A not-due VPN proof is retained for every protocol. Never
                // replace this passive decision with an outbound HTTPS probe.
                RouteHealth(true, "current VPN data-plane proof retained")
            } else {
                runCatching {
                    checkSelectedRoute(routeClient)
                }.getOrElse {
                    if (it is CancellationException) throw it
                    RouteHealth(false, "route watchdog check error: ${it.message ?: it.javaClass.simpleName}")
                }
            }
            currentCoroutineContext().ensureActive()
            if (!isCurrentObservation()) {
                Log.i(TAG, "discarding stale route monitor result ($reason)")
                return
            }
            if (!result.healthy && result.networkReadinessPending) {
                routeWatchdogFailures = 0
                routeWatchdogDegraded = true
                markRouteDegraded(result.summary)
                Log.i(TAG, "route watchdog handed physical resolver readiness to network recovery")
                launchNetworkRouteRecovery(
                    generation = networkGeneration,
                    reason = "physical resolver readiness",
                    settleDelayMs = 0L,
                    replaceActive = false,
                )
            } else if (result.healthy) {
                if (result.outboundType.isNotBlank()) {
                    lastSelectedOutboundType = result.outboundType
                }
                if (Settings.serviceMode != ServiceMode.VPN) {
                    lastProxyRouteProofAtElapsedMs = SystemClock.elapsedRealtime()
                }
                routeWatchdogHealthyChecks += 1
                val recoveredFromDegradedRoute = routeWatchdogDegraded && status.value == Status.Starting
                if (routeWatchdogFailures > 0) {
                    Log.i(
                        TAG,
                        "route watchdog recovered after $routeWatchdogFailures failed check(s): ${result.summary}",
                    )
                } else if (logHealthy || routeWatchdogHealthyChecks % ROUTE_WATCHDOG_HEALTH_LOG_EVERY == 0) {
                    Log.i(TAG, "route watchdog healthy ($reason): ${result.summary}")
                }
                routeWatchdogFailures = 0
                routeWatchdogDegraded = false
                if (recoveredFromDegradedRoute && !coreRecoveryInProgress) {
                    markCoreRuntimeStarted(routeVerified = true)
                }
            } else {
                if (result.outboundType.isNotBlank()) {
                    lastSelectedOutboundType = result.outboundType
                }
                routeWatchdogFailures += 1
                val recoveryThreshold = if (result.requiresCoreRecovery) 2 else ROUTE_WATCHDOG_MAX_FAILURES
                val currentProofStillAvailable = currentVpnDataPlaneProof(currentStartGeneration()) != null
                val hardFailure = !tunHealth.healthy || !currentProofStillAvailable
                val publishRecovery = shouldPublishRouteRecoveryStatus(
                    failedChecks = routeWatchdogFailures,
                    recoveryThreshold = recoveryThreshold,
                    hardFailure = hardFailure,
                )
                routeWatchdogDegraded = true
                if (publishRecovery) {
                    markRouteDegraded(result.summary)
                } else {
                    Log.w(
                        TAG,
                        "route watchdog observed one transient failure while the verified TUN remained active",
                    )
                }
                Log.w(
                    TAG,
                    "route watchdog failed ($reason, $routeWatchdogFailures/$ROUTE_WATCHDOG_MAX_FAILURES): ${result.summary}",
                )
                val isICMPRoute = lastSelectedOutboundType.equals("icmp", ignoreCase = true)
                if (shouldEscalateRouteRecovery(routeWatchdogFailures, recoveryThreshold)) {
                    recoverRoute("selected route unavailable: ${result.summary}")
                    routeWatchdogFailures = 0
                } else if (isICMPRoute && !result.requiresCoreRecovery) {
                    Log.i(TAG, "ICMP route recovery remains in-place before bounded core restart; Android TUN is retained")
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            currentCoroutineContext().ensureActive()
            if (!isCurrentObservation()) return
            routeWatchdogFailures += 1
            routeWatchdogDegraded = true
            markRouteDegraded(e.message ?: e.javaClass.simpleName)
            Log.w(
                TAG,
                "route watchdog iteration failed ($reason, $routeWatchdogFailures/$ROUTE_WATCHDOG_MAX_FAILURES)",
                e,
            )
            if (routeWatchdogFailures >= ROUTE_WATCHDOG_MAX_FAILURES) {
                recoverRoute("selected route watchdog error: ${e.message ?: e.javaClass.simpleName}")
                routeWatchdogFailures = 0
            }
        } finally {
            endRouteWatchdogCheck()
        }
    }

    private fun beginRouteWatchdogCheck(): Boolean {
        return synchronized(routeWatchdogCheckLock) {
            if (routeWatchdogCheckInProgress) {
                false
            } else {
                routeWatchdogCheckInProgress = true
                true
            }
        }
    }

    private fun endRouteWatchdogCheck() {
        synchronized(routeWatchdogCheckLock) {
            routeWatchdogCheckInProgress = false
        }
    }

    private fun routeWatchdogPollDelayMs(): Long {
        if (
            !shouldWatchCore() || coreRecoveryInProgress ||
            coreRecoveryAdmissionRetryJob?.isActive == true || networkRecoveryJob?.isActive == true
        ) {
            return Long.MAX_VALUE // Completion/network events re-arm this owner.
        }
        val interactive = Application.powerManager.isInteractive
        if (status.value != Status.Started || routeWatchdogDegraded) {
            return selectedRouteWatchdogPollDelayMs(degraded = true, deviceInteractive = interactive)
        }
        val proofAt = if (Settings.serviceMode == ServiceMode.VPN) {
            currentVpnDataPlaneProof(currentStartGeneration())?.completedAtElapsedRealtimeMs ?: 0L
        } else {
            lastProxyRouteProofAtElapsedMs
        }
        return vpnDataPlaneProbeDelayMs(interactive, proofAt, SystemClock.elapsedRealtime())
    }

    private fun configUsesTurncoat(configPath: String): Boolean {
        if (configPath.isBlank()) return false
        if (configPath == Settings.activeConfigPath) return currentRuntimeUsesTurncoat()
        return runCatching {
            File(configPath).takeIf { it.exists() }?.readText()?.contains("\"turncoat\"", ignoreCase = true) == true
        }.getOrDefault(false)
    }

    private suspend fun checkSelectedRoute(
        coreClient: CoreClient,
        requireVpnDataPlane: Boolean = false,
        dataPlaneAttemptTimeoutMs: Long? = null,
        redundantDataPlaneEndpoints: Boolean = false,
        preserveVpnDataPlaneProofOnFailure: Boolean = false,
    ): RouteHealth {
        if (requireVpnDataPlane && Settings.serviceMode == ServiceMode.VPN) {
            val timeoutMs = dataPlaneAttemptTimeoutMs ?: vpnDataPlaneAttemptTimeoutMs(
                turncoatRoute = currentRuntimeUsesTurncoat(),
            )
            return checkVpnDataPlaneRoute(
                timeoutMs,
                redundantEndpoints = redundantDataPlaneEndpoints,
                preserveProofOnFailure = preserveVpnDataPlaneProofOnFailure,
            )
        }
        val result = withTimeoutOrNull(ROUTE_WATCHDOG_OPERATION_TIMEOUT_MS) {
            val selected = coreClient.ProbeSelectedRoute().executeBlocking(
                UrlTestRequest(group_tag = ROUTE_WATCHDOG_GROUP),
            )
            val delay = selected.url_test_delay
            val outboundType = selected.type.trim().lowercase()
            if (selected.tag.isBlank() || selected.url_test_time == null) {
                RouteHealth(
                    false,
                    "selected route probe returned an incomplete result type=${outboundType.ifBlank { "unknown" }}",
                    outboundType,
                )
            } else if (!isUsableRouteDelay(delay)) {
                RouteHealth(
                    false,
                    "selected route failed [${selected.tag}]: type=${outboundType.ifBlank { "unknown" }} delay=$delay",
                    outboundType,
                )
            } else {
                RouteHealth(
                    true,
                    "selected route verified [${selected.tag}]: type=${outboundType.ifBlank { "unknown" }} ${delay}ms",
                    outboundType,
                )
            }
        }
        return result ?: RouteHealth(
            false,
            "route watchdog timed out waiting for selected route probe",
            lastSelectedOutboundType,
        )
    }

    private suspend fun checkVpnDataPlaneRoute(
        attemptTimeoutMs: Long,
        redundantEndpoints: Boolean = false,
        preserveProofOnFailure: Boolean = false,
    ): RouteHealth {
        if (Settings.serviceMode != ServiceMode.VPN) {
            return RouteHealth(true, "proxy service mode does not use Android TUN", lastSelectedOutboundType)
        }
        val proofStartGeneration = currentStartGeneration()
        val proofNetworkGeneration = networkGeneration
        val proofTunGeneration = tunGeneration
        val diagnosticId = ConnectionDiagnostics.nextAttemptId()
        val diagnosticStartedAt = SystemClock.elapsedRealtime()
        fun recordProbeDiagnostic(
            outcome: String,
            stage: String,
            category: String,
            durationMs: Long,
        ) {
            ConnectionDiagnostics.record(
                service,
                component = "service",
                event = "vpn_data_plane",
                outcome = outcome,
                requestId = diagnosticId,
                generation = proofStartGeneration,
                durationMs = durationMs,
                stage = stage,
                category = category,
                networkGeneration = proofNetworkGeneration,
                tunGeneration = proofTunGeneration,
            )
        }
        recordProbeDiagnostic(
            outcome = "started",
            stage = VpnDataPlaneProbeStage.VPN_NETWORK.token,
            category = "none",
            durationMs = 0L,
        )
        val result = try {
            vpnDataPlaneProbe.run(
                DefaultNetworkMonitor.defaultNetwork,
                timeoutMs = attemptTimeoutMs,
                redundantEndpoints = redundantEndpoints,
            )
        } catch (error: CancellationException) {
            recordProbeDiagnostic(
                outcome = "cancelled",
                stage = "lifecycle",
                category = "coroutine_cancelled",
                durationMs = (SystemClock.elapsedRealtime() - diagnosticStartedAt).coerceAtLeast(0L),
            )
            throw error
        }
        if (
            proofStartGeneration != currentStartGeneration() ||
            proofNetworkGeneration != networkGeneration ||
            proofTunGeneration != tunGeneration ||
            !shouldWatchCore(proofStartGeneration)
        ) {
            invalidateVpnDataPlaneProof("stale probe generation")
            recordProbeDiagnostic(
                outcome = "stale",
                stage = "publication",
                category = "stale_generation",
                durationMs = (SystemClock.elapsedRealtime() - diagnosticStartedAt).coerceAtLeast(0L),
            )
            return RouteHealth(
                false,
                "VPN data-plane proof became stale during network/session transition",
                lastSelectedOutboundType,
                requiresCoreRecovery = true,
            )
        }
        if (!result.healthy) {
            if (preserveProofOnFailure && !result.networkReadinessPending) {
                Log.w(
                    TAG,
                    "retaining the current VPN proof until a transient watchdog failure is confirmed",
                )
            } else {
                invalidateVpnDataPlaneProof(result.summary)
            }
            recordProbeDiagnostic(
                outcome = "failed",
                stage = result.stage.token,
                category = result.failure ?: "unknown",
                durationMs = (SystemClock.elapsedRealtime() - diagnosticStartedAt).coerceAtLeast(0L),
            )
            return RouteHealth(
                false,
                result.summary,
                lastSelectedOutboundType,
                requiresCoreRecovery = !result.networkReadinessPending,
                networkReadinessPending = result.networkReadinessPending,
            )
        }
        val publicationStartedAt = SystemClock.elapsedRealtime()
        val proofVpnNetworkHandle = result.vpnNetworkHandle
            ?: run {
                recordProbeDiagnostic(
                    outcome = "failed",
                    stage = "publication",
                    category = "missing_vpn_network",
                    durationMs = (SystemClock.elapsedRealtime() - diagnosticStartedAt).coerceAtLeast(0L),
                )
                return RouteHealth(
                    false,
                    "VPN data-plane proof did not identify its Android Network",
                    lastSelectedOutboundType,
                    requiresCoreRecovery = true,
                )
            }
        if (
            !recordVpnDataPlaneProof(
                proofStartGeneration,
                proofNetworkGeneration,
                proofTunGeneration,
                proofVpnNetworkHandle,
            )
        ) {
            recordProbeDiagnostic(
                outcome = "stale",
                stage = "publication",
                category = "stale_publication",
                durationMs = (SystemClock.elapsedRealtime() - diagnosticStartedAt).coerceAtLeast(0L),
            )
            return RouteHealth(
                false,
                "VPN data-plane proof became stale before publication",
                lastSelectedOutboundType,
                requiresCoreRecovery = true,
            )
        }
        ConnectionDiagnostics.record(
            service,
            component = "service",
            event = "vpn_data_plane_publication",
            outcome = "verified",
            requestId = diagnosticId,
            generation = proofStartGeneration,
            durationMs = (SystemClock.elapsedRealtime() - publicationStartedAt).coerceAtLeast(0L),
            stage = "publication",
            category = "none",
            networkGeneration = proofNetworkGeneration,
            tunGeneration = proofTunGeneration,
        )
        recordProbeDiagnostic(
            outcome = "verified",
            stage = result.stage.token,
            category = "none",
            durationMs = (SystemClock.elapsedRealtime() - diagnosticStartedAt).coerceAtLeast(0L),
        )
        return RouteHealth(true, result.summary, lastSelectedOutboundType)
    }

    private fun readTunTrafficSnapshot(health: TunRuntimeHealth): TunTrafficSnapshot? {
        val interfaceName = health.interfaceName ?: return null
        val (rxBytes, txBytes) = runCatching {
            TrafficStats.getRxBytes(interfaceName) to TrafficStats.getTxBytes(interfaceName)
        }.getOrNull() ?: return null
        if (rxBytes == TrafficStats.UNSUPPORTED.toLong() || txBytes == TrafficStats.UNSUPPORTED.toLong()) {
            return null
        }
        return TunTrafficSnapshot(interfaceName, rxBytes, txBytes)
    }

    private fun isUsableRouteDelay(delay: Int): Boolean {
        return delay > 0 && delay < ROUTE_WATCHDOG_TIMEOUT_DELAY
    }

    private suspend fun recoverRoute(reason: String) {
        val now = System.currentTimeMillis()
        if (now - lastRouteRecoveryAttemptAt < ROUTE_RECOVERY_BACKOFF_MS) return
        lastRouteRecoveryAttemptAt = now
        // A failed route proof does not establish that the native core is
        // unhealthy. First give every route type the bounded in-place network
        // reset + redundant VPN proof path; rebuilding core/TUN immediately
        // can strand Mobile.close behind live transport work and turn a short
        // TLS/DNS wobble into a terminal disconnect. The in-place recovery
        // still escalates a failed reset or repeated fresh-proof failures to
        // the single service-owned core recovery path below it.
        launchNetworkRouteRecovery(
            generation = networkGeneration,
            reason = "route watchdog recovery: $reason",
            settleDelayMs = 0L,
            replaceActive = false,
            forceTurncoatCarrierRetirement = currentRuntimeUsesTurncoat(),
        )
    }

    private data class RouteHealth(
        val healthy: Boolean,
        val summary: String,
        val outboundType: String = "",
        val requiresCoreRecovery: Boolean = false,
        val networkReadinessPending: Boolean = false,
    )

    private data class VpnDataPlaneProof(
        val startGeneration: Long,
        val networkGeneration: Long,
        val tunGeneration: Long,
        val vpnNetworkHandle: Long,
        val completedAtElapsedRealtimeMs: Long,
    )

    private data class TunRuntimeHealth(
        val healthy: Boolean,
        val descriptorValid: Boolean,
        val ownVpnActive: Boolean,
        val ownershipKnown: Boolean,
        val ownedCandidateCount: Int,
        val globalCandidateCount: Int,
        val interfaceName: String?,
        val summary: String,
    )

    private data class CoreCleanupResult(
        val nativeCloseCompleted: Boolean,
        val platformVpnRetired: Boolean,
        val tunQuiescent: Boolean,
    ) {
        val closeCompleted: Boolean
            get() = nativeCloseCompleted && platformVpnRetired

        val completed: Boolean
            get() = closeCompleted && tunQuiescent
    }

    private fun readTunRuntimeHealth(): TunRuntimeHealth {
        if (Settings.serviceMode != ServiceMode.VPN) {
            return TunRuntimeHealth(
                healthy = true,
                descriptorValid = false,
                ownVpnActive = false,
                ownershipKnown = true,
                ownedCandidateCount = 0,
                globalCandidateCount = 0,
                interfaceName = null,
                summary = "proxy service mode",
            )
        }
        val descriptorValid = synchronized(fileDescriptorLock) {
            fileDescriptor?.fileDescriptor?.valid() == true
        }
        val ownership = readVpnOwnership(service)
        val tunnelsResult = runCatching {
            NetworkInterface.getNetworkInterfaces()
                ?.toList()
                .orEmpty()
                .filter { it.name.startsWith("tun") }
                .map { tunnel ->
                    TunInterfaceState(
                        name = tunnel.name,
                        index = tunnel.index,
                        up = runCatching { tunnel.isUp }.getOrDefault(false),
                        mtu = runCatching { tunnel.mtu }.getOrDefault(0),
                        addressCount = runCatching { tunnel.inetAddresses.toList().size }.getOrDefault(0),
                    )
                }
        }
        val tunnels = tunnelsResult.getOrDefault(emptyList())
        // Unknown must never be interpreted as permission-safe zero.
        val globalCandidateCount = if (tunnelsResult.isSuccess) tunnels.size else -1
        val ownedTunnels = if (ownership.known) {
            tunnels.filter { ownership.interfaceNames.contains(it.name) }
        } else {
            tunnels
        }
        val ownedCandidateCount = if (tunnelsResult.isSuccess) ownedTunnels.size else -1
        val tunnel = selectTunRuntimeInterface(ownedTunnels)
        val interfaceUp = tunnel?.up == true
        val healthy = isOwnedTunRuntimeHealthy(
            descriptorValid = descriptorValid,
            ownVpnActive = ownership.active,
            ownershipKnown = ownership.known,
            interfaceUp = interfaceUp,
            ownedCandidateCount = ownedCandidateCount,
            globalCandidateCount = globalCandidateCount,
        )
        return TunRuntimeHealth(
            healthy,
            descriptorValid,
            ownership.active,
            ownership.known,
            ownedCandidateCount,
            globalCandidateCount,
            tunnel?.name,
            "Android TUN health: fd_valid=$descriptorValid interface=${tunnel?.name ?: "missing"} " +
                "up=$interfaceUp mtu=${tunnel?.mtu ?: 0} addresses=${tunnel?.addressCount ?: 0} " +
                "own_vpn=${ownership.active} owner_known=${ownership.known} " +
                "owned_candidates=$ownedCandidateCount global_candidates=$globalCandidateCount " +
                "inspection_ok=${tunnelsResult.isSuccess}",
        )
    }

    internal fun isFailClosedTunBarrierActive(): Boolean {
        val retainedBarrier = synchronized(fileDescriptorLock) {
            failClosedVpnGeneration?.let { generation ->
                fileDescriptor?.takeIf { descriptor ->
                    tunDescriptorMode == TunDescriptorMode.FAIL_CLOSED &&
                        descriptor.fileDescriptor.valid()
                }?.let { descriptor -> generation to descriptor }
            }
        } ?: return false
        val publishedMarkerAddresses =
            (service as? VPNService)?.publishedFailClosedVpnMarkerAddresses().orEmpty()
        val barrierReady = isFailClosedVpnBarrierReady(
            retainedGeneration = retainedBarrier.first,
            publishedMarkerAddresses = publishedMarkerAddresses,
            tunRuntimeHealthy = readTunRuntimeHealth().healthy,
        )
        if (!barrierReady) return false

        // Android network inspection and the in-process descriptor snapshot
        // cannot share one lock. Revalidate the exact descriptor/generation
        // after the potentially slow framework reads so a concurrently
        // installed data TUN cannot satisfy the old blocker's marker proof.
        return synchronized(fileDescriptorLock) {
            failClosedVpnGeneration == retainedBarrier.first &&
                tunDescriptorMode == TunDescriptorMode.FAIL_CLOSED &&
                fileDescriptor === retainedBarrier.second &&
                retainedBarrier.second.fileDescriptor.valid()
        }
    }

    internal fun requireTunCreationPrecondition() {
        val retainedDescriptorReplacement = synchronized(fileDescriptorLock) {
            !tunDescriptorAdmissionClosed &&
                fileDescriptor?.fileDescriptor?.valid() == true &&
                tunDescriptorMode != TunDescriptorMode.NONE &&
                shouldAcceptTunFileDescriptor(
                    ownerIsCurrent = ServiceLifecycleOwnership.isCurrent(serviceOwnerToken),
                    userSessionActive = Settings.startedByUser,
                    status = status.value ?: Status.Stopped,
                )
        }
        val allowPlatformVpnReplacement =
            explicitUserVpnStartPending || retainedDescriptorReplacement
        if (
            shouldRejectNewVpnStart(
                service,
                "TUN creation",
                explicitUserStart = explicitUserVpnStartPending,
            )
        ) {
            vpnOwnershipRevoked = true
            mainHandler.post {
                if (ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
                    stopForExternalVpn("TUN creation ownership conflict")
                }
            }
            error("android: another VPN is already active")
        }
        val health = readTunRuntimeHealth()
        if (
            retainedDescriptorReplacement &&
            health.descriptorValid &&
            (health.ownVpnActive || !health.ownershipKnown)
        ) {
            Log.i(TAG, "admitting atomic replacement of retained fail-closed Android VPN")
            return
        }
        if (
            isOwnedTunRuntimeQuiescent(
                descriptorValid = health.descriptorValid,
                ownVpnActive = health.ownVpnActive,
                ownershipKnown = health.ownershipKnown,
                globalCandidateCount = health.globalCandidateCount,
                allowPlatformVpnReplacement = allowPlatformVpnReplacement,
            )
        ) {
            return
        }

        Log.e(TAG, "rejecting openTun while a previous generation is still active; ${health.summary}")
        error("android: previous TUN generation is still active")
    }

    /**
     * Authorizes the service-owned full-route blocker while ordinary data-TUN
     * admission remains sealed. A fresh Connect may create the first blocker;
     * stop/recovery may atomically replace any descriptor retained by this
     * exact owner. Neither path can survive revocation or take another app's
     * VPN slot.
     */
    internal fun requireFailClosedTunInstallationPrecondition() {
        val acceptedSessionWhileStopping =
            status.value == Status.Stopping &&
                ServiceLifecycleOwnership.currentUserSessionEpoch() != null
        val installationAllowed = synchronized(fileDescriptorLock) {
            val retainedDescriptor = fileDescriptor?.fileDescriptor?.valid() == true &&
                tunDescriptorMode != TunDescriptorMode.NONE
            val freshStrictStart =
                !retainedDescriptor &&
                    Settings.startedByUser &&
                    (
                        status.value == Status.Starting ||
                            acceptedSessionWhileStopping
                    )
            tunDescriptorAdmissionClosed &&
                ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) &&
                !vpnOwnershipRevoked &&
                (retainedDescriptor || freshStrictStart)
        }
        if (!installationAllowed) {
            error("android: fail-closed TUN installation is not owned by the current generation")
        }
        if (shouldYieldToExternalVpn("fail-closed TUN installation")) {
            error("android: another VPN owns the platform slot")
        }
    }

    private suspend fun ensurePhysicalFailClosedVpn(reason: String): Boolean {
        val vpnService = service as? VPNService ?: return true
        var attempt = 0
        val deadlineElapsedRealtimeMs =
            SystemClock.elapsedRealtime() + FAIL_CLOSED_VPN_INSTALL_TIMEOUT_MS
        while (
            ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) &&
            SystemClock.elapsedRealtime() < deadlineElapsedRealtimeMs
        ) {
            if (vpnOwnershipRevoked) {
                Log.i(TAG, "skipping fail-closed VPN replacement after ownership revoke: $reason")
                return false
            }
            if (shouldYieldToExternalVpn("fail-closed VPN replacement: $reason")) {
                Log.i(TAG, "skipping fail-closed VPN replacement after external takeover: $reason")
                return false
            }
            if (
                !hasRetainedVpnDescriptor() &&
                !isOwnVpnActive(service) &&
                !Settings.startedByUser
            ) {
                // A start cancelled before Builder.establish() has no Android
                // VPN generation to replace and therefore no clear-route gap.
                return true
            }
            val installed = runCatching {
                vpnService.ensureFailClosedVpn()
            }.onFailure {
                Log.e(TAG, "failed to install physical fail-closed VPN during $reason", it)
            }.getOrDefault(false)
            invalidateVpnDataPlaneProof("fail-closed VPN replacement: $reason")
            if (installed) {
                while (
                    ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) &&
                    !vpnOwnershipRevoked &&
                    SystemClock.elapsedRealtime() < deadlineElapsedRealtimeMs
                ) {
                    if (shouldYieldToExternalVpn("fail-closed VPN publication: $reason")) {
                        Log.i(
                            TAG,
                            "stopped waiting for fail-closed VPN after external takeover: $reason",
                        )
                        return false
                    }
                    if (isFailClosedTunBarrierActive()) {
                        if (Settings.startedByUser) {
                            NativeCrashDiagnostics.setNetworkAdmissionAllowed(true)
                        }
                        return true
                    }
                    val remainingMs =
                        deadlineElapsedRealtimeMs - SystemClock.elapsedRealtime()
                    if (remainingMs > 0L) {
                        delay(minOf(TUN_RELEASE_POLL_MS, remainingMs))
                    }
                }
                Log.e(
                    TAG,
                    "fail-closed Android VPN was installed but its exact network barrier " +
                        "was not active before deadline during $reason",
                )
                return false
            }

            // A native close is forbidden until Builder.establish() has
            // physically replaced the readable data-plane TUN. Retrying may
            // keep a stop/recovery pending, but it cannot expose clear traffic
            // or let the old core outlive an untracked transition.
            attempt += 1
            if (attempt == 1 || attempt % 20 == 0) {
                Log.e(
                    TAG,
                    "waiting for physical fail-closed VPN before $reason; attempt=$attempt",
                )
            }
            delay(FAIL_CLOSED_VPN_RETRY_MS)
        }
        Log.e(
            TAG,
            "physical fail-closed VPN replacement unavailable during $reason; " +
                "leaving the existing VPN generation in place",
        )
        return false
    }

    private suspend fun awaitTunRuntimeQuiescence(
        reason: String,
        serviceStopping: Boolean,
        releaseDeadlineElapsedRealtimeMs: Long =
            SystemClock.elapsedRealtime() + TUN_RELEASE_TIMEOUT_MS,
    ): Boolean {
        if (Settings.serviceMode != ServiceMode.VPN) return true

        var health = readTunRuntimeHealth()
        while (
            !isOwnedTunReleaseCompleteForCleanup(
                descriptorValid = health.descriptorValid,
                ownVpnActive = health.ownVpnActive,
                ownershipKnown = health.ownershipKnown,
                globalCandidateCount = health.globalCandidateCount,
                serviceStopping = serviceStopping,
            ) &&
            SystemClock.elapsedRealtime() < releaseDeadlineElapsedRealtimeMs
        ) {
            delay(TUN_RELEASE_POLL_MS)
            health = readTunRuntimeHealth()
        }
        val quiescent = isOwnedTunReleaseCompleteForCleanup(
            descriptorValid = health.descriptorValid,
            ownVpnActive = health.ownVpnActive,
            ownershipKnown = health.ownershipKnown,
            globalCandidateCount = health.globalCandidateCount,
            serviceStopping = serviceStopping,
        )
        if (quiescent) {
            if (serviceStopping && health.ownVpnActive) {
                Log.i(
                    TAG,
                    "Android TUN descriptor release confirmed after $reason; " +
                        "VpnService stop will remove the remaining interface",
                )
            } else {
                Log.i(TAG, "Android TUN release confirmed after $reason")
            }
        } else {
            Log.e(TAG, "Android TUN release did not finish after $reason; ${health.summary}")
        }
        return quiescent
    }

    private suspend fun closeMobileCoreAndAwaitTunQuiescence(
        reason: String,
        serviceStopping: Boolean = false,
    ): CoreCleanupResult {
        fun retainVpnForActiveSession(): Boolean =
            service is VPNService &&
                Settings.startedByUser &&
                ServiceLifecycleOwnership.currentUserSessionEpoch() != null &&
                !vpnOwnershipRevoked
        synchronized(fileDescriptorLock) {
            tunDescriptorAdmissionClosed = true
        }
        val failClosedBarrierRequired =
            service is VPNService &&
                (hasRetainedVpnDescriptor() || isOwnVpnActive(service)) &&
                !vpnOwnershipRevoked &&
                !isExternalVpnActive("fail-closed barrier requirement: $reason")
        val failClosedVpnInstalled = ensurePhysicalFailClosedVpn(reason)
        if (failClosedBarrierRequired && !failClosedVpnInstalled) {
            Log.e(
                TAG,
                "refusing native close/platform retirement without a verified full-route blocker during $reason",
            )
            return CoreCleanupResult(
                nativeCloseCompleted = false,
                platformVpnRetired = false,
                tunQuiescent = false,
            )
        }
        val closeCompleted = MobileCoreCloser.closeBlocking(reason)
        if (!closeCompleted) {
            Log.w(TAG, "Mobile.close did not fully finish during $reason")
        }

        // Automatic recovery never tears down Android's full-route owner. The
        // data-plane descriptor was already replaced by a framework-owned
        // packet sink above; Builder.establish() atomically replaces that sink
        // only after the next data-plane TUN is ready.
        val terminalStopEpoch = ServiceLifecycleOwnership.currentTerminalStopEpoch()
        val retirementOutcome = when {
            retainVpnForActiveSession() -> PlatformVpnRetirementOutcome.RETAINED
            service !is VPNService -> PlatformVpnRetirementOutcome.RELEASED
            vpnOwnershipRevoked || isExternalVpnActive("platform VPN release") ->
                PlatformVpnRetirementOutcome.RELEASED
            else -> {
                val releaseDeadlineElapsedRealtimeMs =
                    SystemClock.elapsedRealtime() + TUN_RELEASE_TIMEOUT_MS
                service.retirePlatformVpnSessionAfterCoreStop(
                    releaseDeadlineElapsedRealtimeMs,
                    terminalStopEpoch = terminalStopEpoch,
                    retainForActiveSession = ::retainVpnForActiveSession,
                ) {
                    !vpnOwnershipRevoked &&
                        !isExternalVpnActive("platform VPN release final gate")
                }
            }
        }
        val platformVpnRetained = retirementOutcome == PlatformVpnRetirementOutcome.RETAINED
        val platformVpnRetired = when (retirementOutcome) {
            PlatformVpnRetirementOutcome.RELEASED -> true
            PlatformVpnRetirementOutcome.RETAINED ->
                failClosedVpnInstalled && isFailClosedTunBarrierActive()
            PlatformVpnRetirementOutcome.FAILED -> false
        }
        if (!platformVpnRetired) {
            Log.w(TAG, "Android fail-closed VPN barrier did not complete during $reason")
        }
        val tunQuiescent = if (platformVpnRetained) {
            failClosedVpnInstalled && isFailClosedTunBarrierActive()
        } else {
            closeTunFileDescriptor()
            awaitTunRuntimeQuiescence(
                reason,
                serviceStopping,
                SystemClock.elapsedRealtime() + TUN_RELEASE_TIMEOUT_MS,
            )
        }
        return CoreCleanupResult(closeCompleted, platformVpnRetired, tunQuiescent)
    }

    /**
     * Keeps one automatic recovery owner alive while its exact native close or
     * Android VPN retirement is still pending. Descriptor admission stays
     * sealed throughout; no replacement TUN is allowed until every release
     * barrier for the previous generation has completed.
     */
    private suspend fun awaitRecoverableCoreCleanup(
        reason: String,
        generation: Long,
        initialResult: CoreCleanupResult,
    ): CoreCleanupResult? {
        if (!shouldWatchCore(generation)) return null
        if (shouldYieldToExternalVpn("automatic recovery cleanup")) {
            stopForExternalVpnOnMain("automatic recovery cleanup")
            return null
        }
        synchronized(fileDescriptorLock) {
            tunDescriptorAdmissionClosed = true
        }
        val failClosedVpnInstalled = ensurePhysicalFailClosedVpn(
            "automatic recovery cleanup generation=$generation",
        )
        invalidateVpnDataPlaneProof(
            "automatic recovery cleanup pending generation=$generation",
        )
        withContext(Dispatchers.Main) {
            if (shouldWatchCore(generation)) {
                status.value = Status.Starting
                notification.show(activeProfileName, R.string.status_recovering)
            }
        }
        Log.w(
            TAG,
            "automatic recovery cleanup awaiting exact completion generation=$generation " +
                "native_close=${initialResult.nativeCloseCompleted} " +
                "platform_vpn_retired=${initialResult.platformVpnRetired} " +
                "tun_quiescent=${initialResult.tunQuiescent}: $reason",
        )
        if (!failClosedVpnInstalled) {
            return CoreCleanupResult(
                nativeCloseCompleted = false,
                platformVpnRetired = false,
                tunQuiescent = false,
            )
        }
        if (!initialResult.nativeCloseCompleted) {
            MobileCoreCloser.closeAsync(
                "automatic recovery cleanup generation=$generation",
            )
        }
        val nativeCloseCompleted =
            initialResult.nativeCloseCompleted ||
                MobileCoreCloser.awaitCloseToFinish(
                    "automatic recovery cleanup generation=$generation",
                )
        if (!shouldWatchCore(generation)) return null
        val blockerReady =
            failClosedVpnInstalled ||
                ensurePhysicalFailClosedVpn(
                    "automatic recovery cleanup completion generation=$generation",
                )
        val result = CoreCleanupResult(
            nativeCloseCompleted = nativeCloseCompleted,
            platformVpnRetired =
                initialResult.platformVpnRetired ||
                    (blockerReady && isFailClosedTunBarrierActive()),
            tunQuiescent = blockerReady && isFailClosedTunBarrierActive(),
        )
        Log.i(
            TAG,
            "automatic recovery cleanup event completed generation=$generation: $reason",
        )
        return result
    }

    private suspend fun markRouteDegraded(reason: String) {
        val changed = withContext(Dispatchers.Main) {
            if (!shouldWatchCore() || status.value != Status.Started) {
                return@withContext false
            }
            status.value = Status.Starting
            notification.show(activeProfileName, R.string.status_recovering)
            true
        }
        if (changed) {
            Log.w(TAG, "route degraded; keeping VPN fail-closed while recovering: $reason")
        }
    }

    private fun shouldWatchCore(generation: Long? = null): Boolean {
        val sessionActive =
            ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) &&
                Settings.startedByUser &&
                Settings.activeConfigPath.isNotBlank()
        return if (generation == null) {
            sessionActive
        } else {
            shouldContinueCoreLifecycleOperation(
                operationGeneration = generation,
                currentGeneration = currentStartGeneration(),
                userSessionActive = sessionActive,
            )
        }
    }

    private fun isExternalVpnActive(reason: String): Boolean {
        return isExternalVpnActive(service, reason)
    }

    private fun markExplicitVpnTakeoverAllowance() {
        val ownership = readVpnOwnership(service)
        explicitUserVpnStartPending = true
        explicitVpnTakeoverOverlapGeneration = currentStartGeneration()
        explicitVpnTakeoverOverlapDeadlineElapsedRealtimeMs =
            SystemClock.elapsedRealtime() + EXPLICIT_VPN_TAKEOVER_OVERLAP_GRACE_MS
        preexistingExternalVpnNetworkHandles = ownership.externalNetworkHandles
    }

    private fun clearExplicitVpnTakeoverAllowance() {
        explicitUserVpnStartPending = false
        explicitVpnTakeoverOverlapGeneration = 0L
        explicitVpnTakeoverOverlapDeadlineElapsedRealtimeMs = 0L
        preexistingExternalVpnNetworkHandles = emptySet()
    }

    private fun isExplicitTakeoverOverlapAllowed(ownership: VpnOwnershipSnapshot): Boolean {
        val allowed = isExplicitVpnTakeoverOverlapAllowed(
            ownVpnActive = ownership.active,
            currentGeneration = currentStartGeneration(),
            takeoverGeneration = explicitVpnTakeoverOverlapGeneration,
            nowElapsedRealtimeMs = SystemClock.elapsedRealtime(),
            takeoverDeadlineElapsedRealtimeMs =
                explicitVpnTakeoverOverlapDeadlineElapsedRealtimeMs,
            externalNetworkHandles = ownership.externalNetworkHandles,
            preexistingExternalNetworkHandles = preexistingExternalVpnNetworkHandles,
        )
        if (
            !ownership.externalActive &&
            ownership.active &&
            explicitVpnTakeoverOverlapGeneration == currentStartGeneration()
        ) {
            explicitVpnTakeoverOverlapGeneration = 0L
            explicitVpnTakeoverOverlapDeadlineElapsedRealtimeMs = 0L
            preexistingExternalVpnNetworkHandles = emptySet()
        }
        return allowed
    }

    private fun shouldYieldToExternalVpn(reason: String): Boolean {
        val ownership = readVpnOwnership(service)
        val explicitTakeoverOverlapAllowed = isExplicitTakeoverOverlapAllowed(ownership)
        val shouldYield = shouldYieldForExternalVpnOwnership(
            externalVpnActive = ownership.externalActive,
            explicitUserStartPending = explicitUserVpnStartPending,
            vpnOwnershipWasEstablished = vpnOwnershipWasEstablished,
            explicitTakeoverOverlapAllowed = explicitTakeoverOverlapAllowed,
        )
        if (ownership.externalActive && !shouldYield) {
            ConnectionDiagnostics.record(
                service,
                component = "service",
                event = "vpn_ownership",
                outcome = if (explicitTakeoverOverlapAllowed) {
                    "explicit_overlap"
                } else {
                    "explicit_transfer"
                },
                generation = currentStartGeneration(),
            )
            Log.i(
                TAG,
                "allowing exact explicit user VPN ownership transfer during $reason " +
                    "overlap=$explicitTakeoverOverlapAllowed",
            )
        } else if (shouldYield) {
            ConnectionDiagnostics.record(
                service,
                component = "service",
                event = "vpn_ownership",
                outcome = "external_yield",
                generation = currentStartGeneration(),
            )
            Log.w(TAG, "another app owns an active VPN network during $reason")
        }
        return shouldYield
    }

    private fun stopForExternalVpn(reason: String) {
        Log.w(TAG, "stopping Marten because Android VPN ownership was lost: $reason")
        stopService(vpnRevoked = true)
    }

    private suspend fun stopForExternalVpnOnMain(reason: String) {
        withContext(Dispatchers.Main) {
            stopForExternalVpn(reason)
        }
    }

    private suspend fun readCoreStateSnapshot(coreClient: CoreClient): CoreStates? {
        return withTimeoutOrNull(CORE_WATCHDOG_GRPC_TIMEOUT_MS + 500L) {
            runCatching {
                readCoreState(coreClient)
            }.getOrElse {
                if (it is CancellationException) throw it
                null
            }
        }
    }

    private fun coreRecoveryOnlineTimeoutMs(): Long =
        if (currentRuntimeUsesTurncoat()) {
            CORE_RECOVERY_TURNCOAT_ONLINE_TIMEOUT_MS
        } else {
            CORE_RECOVERY_ONLINE_TIMEOUT_MS
        }

    private suspend fun terminateExpiredCoreRecovery(
        generation: Long,
        coreState: CoreStates?,
        elapsedMs: Long,
    ) {
        if (!coreRecoveryOwnsVpnTransition(generation)) return
        val userSessionEpoch = ServiceLifecycleOwnership.currentUserSessionEpoch() ?: return
        ConnectionDiagnostics.record(
            service,
            component = "service",
            event = "core_recovery",
            outcome = "online_deadline_expired",
            generation = generation,
            durationMs = elapsedMs,
        )
        Log.e(
            TAG,
            "core recovery exhausted its online deadline after ${elapsedMs}ms " +
                "in state=${coreState ?: "unavailable"}; terminating generation=$generation",
        )
        stopAndAlert(
            type = Alert.StartService,
            message = service.getString(R.string.error_connection_recovery_failed),
            terminalFailure = true,
            expectedUserSessionEpoch = userSessionEpoch,
            expectedGeneration = generation,
        )
    }

    private fun ownsActiveFailClosedVpnSession(): Boolean =
        service is VPNService &&
            ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) &&
            ServiceLifecycleOwnership.currentUserSessionEpoch() != null &&
            Settings.startedByUser &&
            !vpnOwnershipRevoked

    /**
     * Converts a non-terminal setup/recovery failure into a passive packet
     * sink. User intent remains durable, the framework VPN is retained, and
     * the only continuation sleeps on predecessor/native completion events.
     */
    private suspend fun holdActiveSessionFailClosed(
        reason: String,
        alert: Alert,
        userMessage: String?,
        resumeWhenCleanupReady: Boolean,
        expectedUserSessionEpoch: Long? = null,
        expectedGeneration: Long? = null,
    ): Boolean {
        if (!ownsActiveFailClosedVpnSession()) return false
        return runNonCancellableServiceCleanup cleanup@{
            if (!ownsActiveFailClosedVpnSession()) return@cleanup false
            val sessionEpoch =
                ServiceLifecycleOwnership.currentUserSessionEpoch() ?: return@cleanup false
            if (expectedUserSessionEpoch != null && sessionEpoch != expectedUserSessionEpoch) {
                return@cleanup false
            }
            val hold = synchronized(lifecycleLock) {
                if (expectedGeneration != null && startGeneration != expectedGeneration) {
                    null
                } else {
                    val existing = failClosedSessionHold?.takeIf {
                        it.generation == startGeneration &&
                            it.userSessionEpoch == sessionEpoch
                    }
                    if (existing != null) {
                        existing.resumeRequested =
                            existing.resumeRequested || resumeWhenCleanupReady
                        existing
                    } else {
                        startGeneration += 1
                        pendingServiceStartRequest = null
                        FailClosedSessionHold(
                            generation = startGeneration,
                            userSessionEpoch = sessionEpoch,
                            resumeRequested = resumeWhenCleanupReady,
                        ).also {
                            failClosedSessionHold = it
                        }
                    }
                }
            } ?: return@cleanup false
            LocalProbeAdmission.ensureBlockedAndCancel()
            val failureStillOwnsSession =
                ServiceLifecycleOwnership.runIfUserSessionEpochCurrent(sessionEpoch) {
                    NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)
                    Settings.strictVpnRouteVerified = false
                }
            if (!failureStillOwnsSession) {
                synchronized(lifecycleLock) {
                    if (failClosedSessionHold === hold) {
                        failClosedSessionHold = null
                    }
                }
                return@cleanup false
            }
            invalidateVpnDataPlaneProof("passive fail-closed session hold: $reason")
            Settings.startCoreAfterStartingService = hold.resumeRequested
            clearExplicitVpnTakeoverAllowance()
            coreShutdownCompleted = false
            platformShutdownCompleted = false
            stopCoreRuntimeMonitor()
            stopCoreWatchdog()
            stopRouteWatchdog()
            stopExternalVpnWatchdog()
            serviceCaptchaControlPlane.stop()
            resetUnderlyingNetworkGeneration()
            synchronized(fileDescriptorLock) {
                tunDescriptorAdmissionClosed = true
            }
            recordQuickSettingsLifecycle(
                event = "service_failure",
                outcome = "held_fail_closed",
                generation = hold.generation,
            )

            val blockerReady = ensurePhysicalFailClosedVpn("passive session hold: $reason")
            MobileCoreCloser.closeAsync("passive session hold: $reason")
            withContext(Dispatchers.Main) {
                if (
                    !ownsActiveFailClosedVpnSession() ||
                    !ServiceLifecycleOwnership.isUserSessionEpochCurrent(sessionEpoch)
                ) {
                    return@withContext
                }
                status.value = Status.Starting
                notification.stopDynamicUpdates()
                notification.show(activeProfileName, R.string.status_recovering)
                binder.broadcast { callback ->
                    callback.onServiceAlert(alert.ordinal, userMessage)
                }
            }
            Log.e(
                TAG,
                "non-terminal failure retained full-route blocker generation=${hold.generation} " +
                    "blocker_ready=$blockerReady: $reason",
            )
            scheduleFailClosedSessionHoldContinuation(hold)
            true
        }
    }

    private fun scheduleFailClosedSessionHoldContinuation(expected: FailClosedSessionHold) {
        lateinit var continuation: Job
        val admitted = synchronized(lifecycleLock) {
            if (failClosedSessionHold !== expected || failClosedSessionHoldJob?.isActive == true) {
                false
            } else {
                continuation = serviceScope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                    val predecessorReady =
                        ServiceLifecycleOwnership.awaitPendingCleanupCompletion(serviceOwnerToken)
                    val closeReady = predecessorReady &&
                        MobileCoreCloser.awaitCloseToFinish(
                            "resuming passive fail-closed generation=${expected.generation}",
                        )
                    val recoveryOwnerReleased = closeReady &&
                        ServiceLifecycleOwnership.awaitNativeRecoveryRelease(serviceOwnerToken)
                    val shouldResume = synchronized(lifecycleLock) {
                        val current = failClosedSessionHold
                        if (current !== expected) {
                            false
                        } else {
                            current.cleanupReady =
                                predecessorReady && closeReady && recoveryOwnerReleased
                            current.cleanupReady && current.resumeRequested
                        }
                    }
                    if (shouldResume) {
                        resumeFailClosedSession(expected)
                    } else if (!recoveryOwnerReleased && ownsActiveFailClosedVpnSession()) {
                        Log.e(
                            TAG,
                            "passive fail-closed cleanup remains unavailable generation=${expected.generation}; " +
                                "waiting for an explicit Connect or Stop without polling",
                        )
                    }
                }
                failClosedSessionHoldJob = continuation
                true
            }
        }
        if (!admitted) return
        continuation.invokeOnCompletion {
            synchronized(lifecycleLock) {
                if (failClosedSessionHoldJob === continuation) {
                    failClosedSessionHoldJob = null
                }
            }
        }
        continuation.start()
    }

    private fun resumeFailClosedSession(expected: FailClosedSessionHold) {
        val request = synchronized(lifecycleLock) {
            if (
                failClosedSessionHold !== expected ||
                !expected.cleanupReady ||
                !expected.resumeRequested ||
                expected.generation != startGeneration ||
                !Settings.startedByUser ||
                !ServiceLifecycleOwnership.isUserSessionEpochCurrent(expected.userSessionEpoch)
            ) {
                null
            } else {
                startGeneration += 1
                val generation = startGeneration
                failClosedSessionHold = null
                deferredConnectAfterStop = null
                terminalCoreCleanupFailurePublished = false
                Settings.startCoreAfterStartingService = true
                ServiceStartRequest(
                    generation = generation,
                    allowStoredIdentityMigration = true,
                    userSessionEpoch = expected.userSessionEpoch,
                )
            }
        } ?: return
        coreShutdownCompleted = true
        synchronized(fileDescriptorLock) {
            tunDescriptorAdmissionClosed = true
            status.postValue(Status.Starting)
        }
        Log.i(
            TAG,
            "passive fail-closed barriers released; resuming generation=${request.generation}",
        )
        launchServiceStart(
            generation = request.generation,
            allowStoredIdentityMigration = request.allowStoredIdentityMigration,
            userSessionEpoch = request.userSessionEpoch,
        )
    }

    private fun requestFailClosedSessionResume(): Boolean {
        val hold = synchronized(lifecycleLock) {
            failClosedSessionHold?.also { it.resumeRequested = true }
        } ?: return false
        Settings.startCoreAfterStartingService = true
        if (hold.cleanupReady) {
            resumeFailClosedSession(hold)
            return true
        }
        val hasContinuation = failClosedSessionHoldJob?.isActive == true
        if (!hasContinuation) {
            MobileCoreCloser.closeAsync(
                "explicit Connect retry for passive fail-closed generation=${hold.generation}",
            )
            scheduleFailClosedSessionHoldContinuation(hold)
        }
        return true
    }

    private fun cancelFailClosedSessionHoldForTerminalStop() {
        val continuation = synchronized(lifecycleLock) {
            failClosedSessionHold = null
            deferredConnectAfterStop = null
            failClosedSessionHoldJob.also { failClosedSessionHoldJob = null }
        }
        continuation?.cancel()
    }

    /**
     * Non-terminal cleanup failures retain the exact VPN owner above. Only an
     * already durable Stop/revoke may enter the terminal framework-release
     * branch below.
     */
    private suspend fun finishCoreCleanupFailure(
        reason: String,
        userMessage: String = service.getString(R.string.error_connection_recovery_failed),
        terminalProbeBlockEpoch: Long? = null,
        expectedUserSessionEpoch: Long? = null,
        expectedGeneration: Long? = null,
    ) {
        if (
            holdActiveSessionFailClosed(
                reason = reason,
                alert = Alert.StartService,
                userMessage = userMessage,
                resumeWhenCleanupReady = true,
                expectedUserSessionEpoch = expectedUserSessionEpoch,
                expectedGeneration = expectedGeneration,
            )
        ) {
            return
        }
        if (
            expectedUserSessionEpoch != null &&
            !ServiceLifecycleOwnership.isUserSessionEpochCurrent(expectedUserSessionEpoch)
        ) {
            Log.i(
                TAG,
                "stale core cleanup failure ignored for user epoch=$expectedUserSessionEpoch: $reason",
            )
            return
        }
        if (expectedGeneration != null && !isCurrentLifecycleGeneration(expectedGeneration)) {
            Log.i(
                TAG,
                "stale core cleanup failure ignored for generation=$expectedGeneration: $reason",
            )
            return
        }
        cancelFailClosedSessionHoldForTerminalStop()
        runNonCancellableServiceCleanup {
            val admitted = synchronized(lifecycleLock) {
                if (terminalCoreCleanupFailurePublished) {
                    false
                } else {
                    terminalCoreCleanupFailurePublished = true
                    true
                }
            }
            if (!admitted) return@runNonCancellableServiceCleanup
            val failedGeneration = cancelPendingStarts()
            clearExplicitVpnTakeoverAllowance()
            closedByStopService = true
            keepStoppedNotificationOnDestroy = true
            Settings.startedByUser = false
            Settings.startCoreAfterStartingService = false
            cancelLegacyProcessRecoveryAlarm()
            stopCoreRuntimeMonitor()
            stopCoreWatchdog()
            stopRouteWatchdog()
            stopExternalVpnWatchdog()
            serviceCaptchaControlPlane.stop()
            recordQuickSettingsLifecycle(
                event = "service_failure",
                outcome = "cleanup_failed",
                generation = failedGeneration,
            )
            resetUnderlyingNetworkGeneration()
            synchronized(fileDescriptorLock) {
                tunDescriptorAdmissionClosed = true
            }
            val failClosedBarrierReady =
                ensurePhysicalFailClosedVpn("terminal core cleanup failure")
            val retainedCurrentVpnOwner =
                service is VPNService &&
                    !vpnOwnershipRevoked &&
                    !isExternalVpnActive("terminal cleanup fail-closed retention") &&
                    (hasRetainedVpnDescriptor() || isOwnVpnActive(service))
            if (!failClosedBarrierReady && retainedCurrentVpnOwner) {
                Log.e(
                    TAG,
                    "terminal cleanup remains fail-closed on the retained data plane; " +
                        "native close and platform release were not admitted",
                )
                withContext(Dispatchers.Main) {
                    if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) return@withContext
                    // This is a terminal failed Stop, not an in-progress
                    // disconnect. Keep the exact TUN/probe seals and service
                    // owner, but never strand UI or Quick Settings in Stopping.
                    status.value = Status.Stopped
                    notification.stopDynamicUpdates()
                    notification.showStopped(activeProfileName)
                    binder.broadcast { callback ->
                        callback.onServiceAlert(Alert.StartService.ordinal, userMessage)
                    }
                }
                return@runNonCancellableServiceCleanup
            }
            DefaultNetworkMonitor.clearListener(serviceOwnerToken)
            DefaultNetworkMonitor.stop(serviceOwnerToken)
            NativeResumeConfigStore.cleanupPlaintextLeases(service)
            MobileCoreCloser.closeAsync("terminal core cleanup failure")

            withContext(Dispatchers.Main) {
                if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) return@withContext
                status.value = Status.Stopping
                notification.stopDynamicUpdates()
                notification.show(activeProfileName, R.string.status_stopping)
            }

            val retirementOutcome = if (service is VPNService) {
                service.retirePlatformVpnSessionAfterFailedCoreCleanup(
                    terminalStopEpoch = ServiceLifecycleOwnership.currentTerminalStopEpoch(),
                    retainForActiveSession = {
                        Settings.startedByUser &&
                            ServiceLifecycleOwnership.currentUserSessionEpoch() != null &&
                            !vpnOwnershipRevoked
                    },
                ) {
                    ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) &&
                        !vpnOwnershipRevoked &&
                        !isExternalVpnActive("terminal core cleanup failure")
                }
            } else {
                PlatformVpnRetirementOutcome.RELEASED
            }
            if (retirementOutcome == PlatformVpnRetirementOutcome.RETAINED) {
                Log.i(TAG, "terminal cleanup yielded its exact VPN barrier to a newer lifecycle owner")
                return@runNonCancellableServiceCleanup
            }
            closeTunFileDescriptor()
            val tunReleased = awaitTunRuntimeQuiescence(
                "terminal core cleanup failure",
                serviceStopping = true,
            )
            val platformReleased = retirementOutcome == PlatformVpnRetirementOutcome.RELEASED
            val vpnAndTunReleased = platformReleased && tunReleased
            platformShutdownCompleted = vpnAndTunReleased
            if (platformShutdownCompleted) {
                NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)
            }
            Log.e(
                TAG,
                "native core cleanup reached terminal failure: $reason; " +
                    "platform_released=$platformReleased; ${readTunRuntimeHealth().summary}",
            )
            runtimeConfigOwnership.clearThrough(failedGeneration)

            withContext(Dispatchers.Main) {
                if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) return@withContext
                // The bounded terminal attempt has finished. If Android still
                // retains an exact Marten owner, packet/probe admission remains
                // sealed and this service stays alive, but the lifecycle must
                // not masquerade as an endlessly progressing disconnect.
                status.value = Status.Stopped
                notification.showStopped(activeProfileName)
                if (platformShutdownCompleted) {
                    terminalProbeBlockEpoch?.let { blockEpoch ->
                        if (!tryAllowLocalProbesForCurrentState(blockEpoch)) {
                            releaseLocalProbesWhenTerminalOwnerIsReady(
                                blockEpoch,
                                "terminal cleanup failure release",
                            )
                        }
                    }
                } else {
                    Log.e(
                        TAG,
                        "terminal cleanup published Stopped while exact fail-closed ownership remains retained",
                    )
                }
                binder.broadcast { callback ->
                    callback.onServiceAlert(Alert.StartService.ordinal, userMessage)
                }
                if (platformShutdownCompleted) {
                    service.stopSelf()
                }
            }
        }
    }

    private fun cancelLegacyProcessRecoveryAlarm() {
        val pendingIntent = processRecoveryPendingIntent(
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        ) ?: return
        service.getSystemService(android.app.AlarmManager::class.java)?.cancel(pendingIntent)
        pendingIntent.cancel()
        Log.i(TAG, "cancelled legacy VPN service recovery alarm")
    }

    private fun processRecoveryPendingIntent(flags: Int): PendingIntent? {
        val recoveryIntent = Intent(service, Settings.serviceClass())
            .setAction(Action.SERVICE_RECOVER)
            .setPackage(service.packageName)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(
                service,
                LEGACY_PROCESS_RECOVERY_REQUEST_CODE,
                recoveryIntent,
                flags,
            )
        } else {
            PendingIntent.getService(
                service,
                LEGACY_PROCESS_RECOVERY_REQUEST_CODE,
                recoveryIntent,
                flags,
            )
        }
    }

    private fun readTurncoatRouteEvidence(coreClient: CoreClient): TurncoatRouteEvidence {
        return coreClient.GetTurncoatRouteEvidence().executeBlocking(Empty())
    }

    private fun readCoreState(coreClient: CoreClient): CoreStates? {
        val (sink, source) = coreClient.CoreInfoListener().executeBlocking()
        return try {
            sink.write(Empty())
            sink.close()
            source.read()?.core_state
        } finally {
            runCatching { sink.close() }
            runCatching { source.close() }
        }
    }

    private fun launchCoreRecovery(
        reason: String,
        generation: Long = currentStartGeneration(),
    ): Boolean {
        val now = System.currentTimeMillis()
        return synchronized(lifecycleLock) {
            if (
                !shouldContinueCoreLifecycleOperation(
                    operationGeneration = generation,
                    currentGeneration = startGeneration,
                    userSessionActive = Settings.startedByUser,
                )
            ) {
                return@synchronized false
            }
            if (coreRecoveryJob?.isActive == true) {
                return@synchronized true
            }
            if (now - lastCoreRecoveryAttemptAt < CORE_RECOVERY_BACKOFF_MS) {
                return@synchronized false
            }
            if (!ServiceLifecycleOwnership.tryAcquireNativeRecovery(serviceOwnerToken)) {
                Log.i(TAG, "deferring native recovery while another lifecycle owner is active")
                return@synchronized false
            }

            lateinit var launched: Job
            launched = serviceScope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                recoverMobileCore(reason, generation)
            }
            coreRecoveryJob = launched
            coreRecoveryInProgress = true
            coreRecoveryTransitionGeneration = generation
            lastCoreRecoveryAttemptAt = now
            coreRecoveryOnlineStartedAtElapsed =
                if (underlyingNetworkInitialized && observedUnderlyingNetwork == null) {
                    0L
                } else {
                    SystemClock.elapsedRealtime()
                }
            launched.invokeOnCompletion {
                synchronized(lifecycleLock) {
                    if (coreRecoveryJob === launched) {
                        stopCoreRecoverySupervision()
                        coreRecoveryJob = null
                        coreRecoveryInProgress = false
                        coreRecoveryTransitionGeneration = null
                        coreRecoveryOnlineStartedAtElapsed = 0L
                    }
                }
                ServiceLifecycleOwnership.releaseNativeRecovery(serviceOwnerToken)
                if (shouldWatchCore(generation)) {
                    routeHealthMonitor?.rearm()
                }
            }
            startCoreWatchdog()
            launched.start()
            true
        }
    }

    private fun requestCoreRecovery(
        reason: String,
        generation: Long = currentStartGeneration(),
    ): Boolean {
        if (launchCoreRecovery(reason, generation)) return true

        return synchronized(lifecycleLock) {
            if (
                !shouldContinueCoreLifecycleOperation(
                    operationGeneration = generation,
                    currentGeneration = startGeneration,
                    userSessionActive = Settings.startedByUser,
                )
            ) {
                return@synchronized false
            }
            if (coreRecoveryAdmissionRetryJob?.isActive == true) {
                return@synchronized true
            }

            lateinit var scheduled: Job
            scheduled = serviceScope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                var rejectedAttempts = 0
                while (currentCoroutineContext().isActive && shouldWatchCore(generation)) {
                    val retryDelayMs = coreRecoveryAdmissionRetryDelayMs(
                        rejectedAttempts = rejectedAttempts,
                        deviceInteractive = Application.powerManager.isInteractive,
                    )
                    if (
                        !ServiceLifecycleOwnership.awaitNativeRecoveryAdmissionChange(
                            ownerToken = serviceOwnerToken,
                            timeoutMs = retryDelayMs,
                        )
                    ) {
                        return@launch
                    }
                    if (launchCoreRecovery(reason, generation)) {
                        Log.w(
                            TAG,
                            "core recovery admitted after ${rejectedAttempts + 1} deferred attempt(s): $reason",
                        )
                        return@launch
                    }
                    rejectedAttempts += 1
                    if (rejectedAttempts == 1 || (rejectedAttempts and (rejectedAttempts - 1)) == 0) {
                        Log.w(
                            TAG,
                            "core recovery admission remains pending attempt=$rejectedAttempts " +
                                "nextFallbackMs=${coreRecoveryAdmissionRetryDelayMs(
                                    rejectedAttempts = rejectedAttempts,
                                    deviceInteractive = Application.powerManager.isInteractive,
                                )}: $reason",
                        )
                    }
                }
            }
            coreRecoveryAdmissionRetryJob = scheduled
            scheduled.invokeOnCompletion {
                synchronized(lifecycleLock) {
                    if (coreRecoveryAdmissionRetryJob === scheduled) {
                        coreRecoveryAdmissionRetryJob = null
                    }
                }
                if (shouldWatchCore(generation)) {
                    routeHealthMonitor?.rearm()
                }
            }
            Log.w(
                TAG,
                "core recovery admission waiting for lifecycle release with sparse fallback: $reason",
            )
            scheduled.start()
            true
        }
    }

    private suspend fun recoverMobileCore(reason: String, generation: Long) {
        val recoveryUserSessionEpoch =
            ServiceLifecycleOwnership.currentUserSessionEpoch() ?: return
        val recoveryStartedAtElapsed = SystemClock.elapsedRealtime()
        val recoveryReasonCategory = coreRecoveryReasonCategory(reason)
        ConnectionDiagnostics.record(
            service,
            component = "service",
            event = "core_recovery",
            outcome = "started",
            generation = generation,
            category = recoveryReasonCategory,
        )

        try {
            var failedAttempts = 0

            while (currentCoroutineContext().isActive && shouldWatchCore(generation)) {
                if (underlyingNetworkInitialized && observedUnderlyingNetwork == null) {
                    Log.i(TAG, "core recovery parked until an underlying-network callback")
                    try {
                        DefaultNetworkMonitor.require()
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Throwable) {
                        if (!shouldWatchCore(generation)) return
                        val userSessionEpoch =
                            ServiceLifecycleOwnership.currentUserSessionEpoch() ?: return
                        Log.e(TAG, "underlying-network callback wait failed during core recovery")
                        stopAndAlert(
                            type = Alert.StartService,
                            message = service.getString(R.string.error_connection_recovery_failed),
                            terminalFailure = true,
                            expectedUserSessionEpoch = userSessionEpoch,
                            expectedGeneration = generation,
                        )
                        return
                    }
                    if (!shouldWatchCore(generation)) return
                    synchronized(lifecycleLock) {
                        if (
                            coreRecoveryInProgress &&
                            coreRecoveryTransitionGeneration == generation &&
                            coreRecoveryOnlineStartedAtElapsed <= 0L
                        ) {
                            coreRecoveryOnlineStartedAtElapsed = SystemClock.elapsedRealtime()
                        }
                    }
                    Log.i(TAG, "core recovery resumed after an underlying-network callback")
                    continue
                }

                val onlineStartedAt = coreRecoveryOnlineStartedAtElapsed
                val onlineElapsedMs = if (onlineStartedAt > 0L) {
                    SystemClock.elapsedRealtime() - onlineStartedAt
                } else {
                    0L
                }
                if (
                    shouldTerminateExpiredCoreRecovery(
                        recoveryInProgress = coreRecoveryInProgress,
                        userSessionActive = shouldWatchCore(generation),
                        underlyingNetworkAvailable = true,
                        elapsedMs = onlineElapsedMs,
                        timeoutMs = coreRecoveryOnlineTimeoutMs(),
                    )
                ) {
                    terminateExpiredCoreRecovery(generation, coreState = null, elapsedMs = onlineElapsedMs)
                    return
                }

                val attempt = failedAttempts + 1
                val configPath = Settings.activeConfigPath
                if (configPath.isBlank()) return
                if (shouldYieldToExternalVpn("core watchdog recovery")) {
                    stopForExternalVpnOnMain("core watchdog recovery")
                    return
                }

                Log.w(TAG, "core watchdog recovery attempt $attempt: $reason")
                withContext(Dispatchers.Main) {
                    if (!shouldWatchCore(generation)) return@withContext
                    status.value = Status.Starting
                    notification.show(activeProfileName, R.string.status_recovering)
                }

                val prepared = try {
                    if (!shouldWatchCore(generation)) {
                        false
                    } else {
                        DefaultNetworkMonitor.clearListener(serviceOwnerToken)
                        val initialCleanupResult = closeMobileCoreAndAwaitTunQuiescence(
                            "core watchdog recovery attempt $attempt",
                        )
                        val cleanupResult = if (
                            requiresCoreCleanupEscalation(
                                initialCleanupResult.closeCompleted,
                                initialCleanupResult.tunQuiescent,
                            )
                        ) {
                            awaitRecoverableCoreCleanup(
                                reason = "preparing core watchdog recovery attempt $attempt",
                                generation = generation,
                                initialResult = initialCleanupResult,
                            )
                        } else {
                            initialCleanupResult
                        }
                        if (!shouldWatchCore(generation)) {
                            false
                        } else if (cleanupResult?.completed != true) {
                            false
                        } else if (shouldYieldToExternalVpn("core watchdog recovery before mobile setup")) {
                            false
                        } else {
                            val tunAdmissionOpened = synchronized(fileDescriptorLock) {
                                if (shouldWatchCore(generation)) {
                                    tunDescriptorAdmissionClosed = false
                                    true
                                } else {
                                    false
                                }
                            }
                            if (!tunAdmissionOpened) {
                                false
                            } else {
                                MobileCoreLifecycle.run {
                                    if (!shouldWatchCore(generation)) return@run false
                                    if (shouldYieldToExternalVpn("core watchdog recovery before mobile setup")) {
                                        return@run false
                                    }
                                    Mobile.setup(
                                        Settings.baseDir,
                                        Settings.workingDir,
                                        Settings.tempDir,
                                        4L,
                                        "127.0.0.1:${Settings.grpcServiceModePort}",
                                        "",
                                        Settings.debugMode,
                                        platformInterface,
                                    )
                                    true
                                }
                            }
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    Log.e(TAG, "core watchdog recovery preparation $attempt failed", e)
                    false
                }

                if (!prepared) {
                    if (!shouldWatchCore(generation)) return
                    if (shouldYieldToExternalVpn("core watchdog recovery preparation")) {
                        stopForExternalVpnOnMain("core watchdog recovery preparation")
                        return
                    }
                }

                if (prepared && shouldWatchCore(generation)) {
                    serviceCaptchaControlPlane.start(
                        generation = generation,
                        enabled = runtimeConfigOwnership.usesTurncoat(generation) == true,
                    )
                }

                val started = if (prepared && shouldWatchCore(generation)) {
                    try {
                        if (shouldYieldToExternalVpn("core watchdog recovery before mobile start")) {
                            stopForExternalVpnOnMain("core watchdog recovery before mobile start")
                            return
                        }
                        startMobileCoreFromNativePath(
                            configPath,
                            "core watchdog recovery attempt $attempt",
                            generation = generation,
                            userSessionEpoch = recoveryUserSessionEpoch,
                        )
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Throwable) {
                        Log.e(TAG, "core watchdog recovery attempt $attempt failed", e)
                        false
                    }
                } else {
                    false
                }

                if (started) {
                    if (!shouldWatchCore(generation)) return
                    if (markCoreRuntimeStarted(routeVerified = true, generation = generation)) {
                        ConnectionDiagnostics.record(
                            service,
                            component = "service",
                            event = "core_recovery",
                            outcome = "recovered",
                            generation = generation,
                            attempt = attempt.toLong(),
                            durationMs = (
                                SystemClock.elapsedRealtime() - recoveryStartedAtElapsed
                            ).coerceAtLeast(0L),
                            category = recoveryReasonCategory,
                        )
                        Log.i(TAG, "core watchdog recovery started mobile core after $attempt attempt(s)")
                        return
                    }
                    Log.w(TAG, "core watchdog recovery did not produce a current healthy Android VPN generation")
                }

                failedAttempts = attempt
                // A retry is admitted only after both native close and
                // permission-safe zero-TUN quiescence have completed.
                val cleanupReady = closeFailedRecoveryRuntime("failed core recovery attempt $attempt", generation)
                if (!shouldWatchCore(generation)) return
                val retryDelayMs = coreRecoveryRetryDelayMs(failedAttempts)
                if (!cleanupReady) {
                    // An incomplete predecessor close is not a terminal route
                    // outcome. Keep the existing user session fail-closed and
                    // retry within the one online recovery deadline.
                    ConnectionDiagnostics.record(
                        service,
                        component = "service",
                        event = "core_recovery",
                        outcome = "cleanup_pending",
                        generation = generation,
                        attempt = attempt.toLong(),
                        durationMs = (
                            SystemClock.elapsedRealtime() - recoveryStartedAtElapsed
                        ).coerceAtLeast(0L),
                        category = recoveryReasonCategory,
                    )
                    Log.w(TAG, "core watchdog recovery cleanup is still pending; retaining fail-closed session")
                }
                Log.w(TAG, "core watchdog recovery retry scheduled in ${retryDelayMs}ms")
                delay(retryDelayMs)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            Log.e(TAG, "core watchdog recovery loop failed", e)
            if (shouldWatchCore(generation)) {
                ConnectionDiagnostics.record(
                    service,
                    component = "service",
                    event = "core_recovery",
                    outcome = "loop_failed",
                    generation = generation,
                    durationMs = (
                        SystemClock.elapsedRealtime() - recoveryStartedAtElapsed
                    ).coerceAtLeast(0L),
                    category = recoveryReasonCategory,
                )
                stopAndAlert(
                    Alert.StartService,
                    "core watchdog recovery loop failed",
                    terminalFailure = true,
                    expectedUserSessionEpoch = recoveryUserSessionEpoch,
                    expectedGeneration = generation,
                )
            }
        } finally {
            val recoveryEndedWithoutOutcome =
                shouldWatchCore(generation) &&
                    status.value != Status.Started &&
                    status.value != Status.Stopping &&
                    status.value != Status.Stopped
            if (recoveryEndedWithoutOutcome) {
                // Every admitted recovery owns exactly one terminal outcome.
                // Normal early returns (for example an unreleasable predecessor
                // TUN) must not silently clear coreRecoveryInProgress and leave
                // the service in ownerless Starting forever.
                Log.e(
                    TAG,
                    "core recovery ended without route admission; terminating generation=$generation",
                )
                ConnectionDiagnostics.record(
                    service,
                    component = "service",
                    event = "core_recovery",
                    outcome = "unexpected_exit",
                    generation = generation,
                    durationMs = (
                        SystemClock.elapsedRealtime() - recoveryStartedAtElapsed
                    ).coerceAtLeast(0L),
                    category = recoveryReasonCategory,
                )
                runNonCancellableServiceCleanup {
                    if (shouldWatchCore(generation)) {
                        stopAndAlert(
                            type = Alert.StartService,
                            message = service.getString(R.string.error_connection_recovery_failed),
                            terminalFailure = true,
                            expectedUserSessionEpoch = recoveryUserSessionEpoch,
                            expectedGeneration = generation,
                        )
                    }
                }
            }
        }
    }

    private suspend fun closeFailedRecoveryRuntime(reason: String, generation: Long): Boolean {
        if (!shouldWatchCore(generation)) return false
        DefaultNetworkMonitor.clearListener(serviceOwnerToken)
        val initialCleanupResult = closeMobileCoreAndAwaitTunQuiescence(reason)
        if (!shouldWatchCore(generation)) return false
        val cleanupResult = if (
            requiresCoreCleanupEscalation(
                initialCleanupResult.closeCompleted,
                initialCleanupResult.tunQuiescent,
            )
        ) {
            awaitRecoverableCoreCleanup(reason, generation, initialCleanupResult)
        } else {
            initialCleanupResult
        }
        return cleanupResult?.completed == true && shouldWatchCore(generation)
    }

    private suspend fun stopAndAlert(
        type: Alert,
        message: String? = null,
        resumeWhenCleanupReady: Boolean = false,
        terminalFailure: Boolean = false,
        expectedUserSessionEpoch: Long? = null,
        expectedGeneration: Long? = null,
    ) {
        if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
            Log.i(TAG, "stale service alert ignored: $type")
            return
        }
        if (expectedGeneration != null && !isCurrentLifecycleGeneration(expectedGeneration)) {
            Log.i(TAG, "stale service alert ignored for generation=$expectedGeneration: $type")
            return
        }
        if (
            expectedUserSessionEpoch != null &&
            !ServiceLifecycleOwnership.runIfUserSessionEpochCurrent(
                expectedUserSessionEpoch,
            ) { }
        ) {
            Log.i(
                TAG,
                "stale service alert ignored for user epoch=$expectedUserSessionEpoch: $type",
            )
            return
        }
        if (
            !terminalFailure &&
            holdActiveSessionFailClosed(
                reason = "service alert type=$type",
                alert = type,
                userMessage = message,
                resumeWhenCleanupReady = resumeWhenCleanupReady,
                expectedUserSessionEpoch = expectedUserSessionEpoch,
                expectedGeneration = expectedGeneration,
            )
        ) {
            return
        }
        if (
            expectedUserSessionEpoch != null &&
            !ServiceLifecycleOwnership.isUserSessionEpochCurrent(expectedUserSessionEpoch)
        ) {
            Log.i(
                TAG,
                "service alert lost its exact session while entering cleanup " +
                    "epoch=$expectedUserSessionEpoch",
            )
            return
        }
        if (expectedGeneration != null && !isCurrentLifecycleGeneration(expectedGeneration)) {
            Log.i(
                TAG,
                "service alert lost its exact generation while entering cleanup " +
                    "generation=$expectedGeneration",
            )
            return
        }
        cancelFailClosedSessionHoldForTerminalStop()
        // Automatic terminal failures must own the same durable terminal
        // epoch as an explicit Stop before Flutter can observe Stopped. Without
        // that claim the Dart gate correctly refuses to reopen local probes,
        // leaving disconnected Ping All/refresh silently sealed until process
        // restart even after Android has released the VPN.
        val terminalIntent = persistTerminalStopIntent(
            reason = "service alert type=$type",
        )
        clearExplicitVpnTakeoverAllowance()
        // This path can run inside a watchdog that it cancels below. Cleanup must still reach
        // Mobile.close() and stopSelf(), otherwise Android keeps a dead VPN network active.
        runNonCancellableServiceCleanup {
            val stopGeneration = cancelPendingStarts()
            Settings.startedByUser = false
            Settings.startCoreAfterStartingService = false
            closedByStopService = true
            stopCoreRuntimeMonitor()
            stopCoreWatchdog()
            stopRouteWatchdog()
            stopExternalVpnWatchdog()
            serviceCaptchaControlPlane.stop()
            recordQuickSettingsLifecycle(
                event = "service_failure",
                outcome = "alerted",
                generation = stopGeneration,
            )
            resetUnderlyingNetworkGeneration()
            if (
                !isCurrentLifecycleGeneration(stopGeneration) ||
                !ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)
            ) {
                return@runNonCancellableServiceCleanup
            }
            DefaultNetworkMonitor.clearListener(serviceOwnerToken)
            NativeResumeConfigStore.cleanupPlaintextLeases(service)
            DefaultNetworkMonitor.stop(serviceOwnerToken)
            val coreClosed = closeMobileCoreAndAwaitTunQuiescence(
                "service alert",
                serviceStopping = true,
            )
            coreShutdownCompleted = coreClosed.completed
            platformShutdownCompleted = coreClosed.completed
            if (coreShutdownCompleted) {
                runtimeConfigOwnership.clearThrough(stopGeneration)
            }
            if (requiresCoreCleanupEscalation(
                    coreClosed.closeCompleted,
                    coreClosed.tunQuiescent,
                )
            ) {
                finishCoreCleanupFailure(
                    "service alert did not release the native core and TUN",
                    terminalProbeBlockEpoch = terminalIntent.probeBlockEpoch,
                    expectedGeneration = stopGeneration,
                )
                return@runNonCancellableServiceCleanup
            }
            withContext(Dispatchers.Main) {
                if (
                    !isCurrentLifecycleGeneration(stopGeneration) ||
                    !ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)
                ) {
                    return@withContext
                }
                if (receiverRegistered) {
                    runCatching {
                        service.unregisterReceiver(receiver)
                    }.onFailure {
                        Log.w(TAG, "error unregistering service receiver", it)
                    }
                    receiverRegistered = false
                }
                notification.stopDynamicUpdates()
                notification.close()
                // stopAndAlert may run inside the recovery coroutine itself.
                // Release that lifecycle lease after exact core/platform
                // cleanup, otherwise the terminal-probe predicate cannot
                // become true until after Stopped has already reached Flutter.
                ServiceLifecycleOwnership.releaseNativeRecovery(serviceOwnerToken)
                val localProbesReleased = terminalIntent.persisted &&
                    tryAllowLocalProbesForCurrentState(terminalIntent.probeBlockEpoch)
                if (terminalIntent.persisted && !localProbesReleased) {
                    releaseLocalProbesWhenTerminalOwnerIsReady(
                        terminalIntent.probeBlockEpoch,
                        "service alert terminal release",
                    )
                }
                // No terminal UI callback may outrun the exact probe release:
                // Flutter can offer Ping All as soon as it handles this alert.
                binder.broadcast { callback ->
                    callback.onServiceAlert(type.ordinal, message)
                }
                status.value = Status.Stopped
                service.stopSelf()
            }
        }
    }

    private fun prepareVpnStartAdmission(userSessionEpoch: Long): Int {
        LocalProbeAdmission.blockAndCancel()
        if (service !is VPNService) {
            completeVpnStartAdmissionFailure(
                userSessionEpoch,
                "strict VPN admission requires Android VPN mode",
            )
            Settings.startedByUser = false
            service.stopSelf()
            return Service.START_NOT_STICKY
        }
        if (!Settings.startedByUser) {
            completeVpnStartAdmissionFailure(
                userSessionEpoch,
                "terminal stop superseded delayed VPN admission service command",
            )
            Settings.startCoreAfterStartingService = false
            service.stopSelf()
            return Service.START_NOT_STICKY
        }
        if (hasProcessNetworkAdmission()) {
            earlyVpnStartAdmissionReady = true
            completeVpnStartAdmissionSuccess(userSessionEpoch)
            return Service.START_STICKY
        }

        if (status.value == Status.Stopped) {
            nextStartGeneration()
            synchronized(lifecycleLock) {
                terminalCoreCleanupFailurePublished = false
            }
            synchronized(fileDescriptorLock) {
                tunDescriptorAdmissionClosed = true
                status.value = Status.Starting
            }
        }
        NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)
        Settings.strictVpnRouteVerified = false
        Settings.startCoreAfterStartingService = false
        markExplicitVpnTakeoverAllowance()
        earlyVpnStartAdmissionReady = false
        closedByStopService = false
        platformShutdownCompleted = false
        vpnOwnershipRevoked = false
        keepStoppedNotificationOnDestroy = false
        registerServiceReceiverIfNeeded()
        notification.show(activeProfileName, R.string.status_starting)

        val admissionGeneration = currentStartGeneration()
        serviceScope.launch(Dispatchers.IO) {
            if (hasUntrackedOwnVpnNetwork()) {
                val previousProcessVpnReleased = awaitUntrackedOwnVpnRelease(
                    generation = admissionGeneration,
                    userSessionEpoch = userSessionEpoch,
                )
                if (!previousProcessVpnReleased) {
                    completeVpnStartAdmissionFailure(
                        userSessionEpoch,
                        "previous Android VPN generation was not released",
                    )
                    if (shouldContinueStart(admissionGeneration)) {
                        stopAfterUntrackedOwnVpnReleaseTimeout(
                            generation = admissionGeneration,
                            userSessionEpoch = userSessionEpoch,
                        )
                    }
                    return@launch
                }
                if (shouldRejectNewVpnStart(
                        service,
                        "VPN admission after previous-process VPN release",
                        explicitUserStart = explicitUserVpnStartPending,
                    )
                ) {
                    completeVpnStartAdmissionFailure(
                        userSessionEpoch,
                        "another Android VPN owner appeared after the previous Marten Network was released",
                    )
                    stopForExternalVpnOnMain("previous-process VPN admission handoff")
                    return@launch
                }
            }
            val admitted = runCatching {
                // Establish the no-reader full-route packet sink before any
                // core or ordinary Marten networking. Android Always-on and
                // lockdown are optional; this service-owned blocker is the
                // authoritative boundary for managed lifecycle transitions.
                ensurePhysicalFailClosedVpn("early VPN start admission")
            }.onFailure {
                Log.e(TAG, "early fail-closed VPN admission failed", it)
            }.getOrDefault(false)
            if (!admitted) {
                completeVpnStartAdmissionFailure(
                    userSessionEpoch,
                    "failed to establish fail-closed Android VPN",
                )
                if (hasUntrackedOwnVpnNetwork()) {
                    stopAfterUntrackedOwnVpnReleaseTimeout(
                        generation = admissionGeneration,
                        userSessionEpoch = userSessionEpoch,
                    )
                    return@launch
                }
                if (!ServiceLifecycleOwnership.isUserSessionEpochCurrent(userSessionEpoch)) {
                    Log.i(TAG, "discarding stale fail-closed admission failure epoch=$userSessionEpoch")
                    return@launch
                }
                Log.e(
                    TAG,
                    "strict VPN admission failed for current epoch=$userSessionEpoch; " +
                        "the exact waiting admission owner will arbitrate terminal cleanup",
                )
                return@launch
            }
            if (!ServiceLifecycleOwnership.isUserSessionEpochCurrent(userSessionEpoch)) {
                Log.i(TAG, "discarding stale successful VPN preparation epoch=$userSessionEpoch")
                return@launch
            }
            NativeCrashDiagnostics.setNetworkAdmissionAllowed(true)
            service.logSystemLockdownStatus()
            earlyVpnStartAdmissionReady = true
            completeVpnStartAdmissionSuccess(userSessionEpoch)
            Log.i(TAG, "strict VPN start admission ready before Flutter core setup")
        }
        return Service.START_STICKY
    }

    @Suppress("SameReturnValue")
    internal fun onStartCommand(intent: Intent?, flags: Int): Int {
        // Android normally serializes old onDestroy -> new onCreate, but claim
        // again here so an OEM replacement that allocated this object early
        // still observes the predecessor's full-route descriptor before VPN
        // ownership admission.
        adoptStickyTunHandoffIfAvailable()
        val userSessionEpochRequired =
            intent?.action == Action.SERVICE_PREPARE_VPN ||
                intent?.action == Action.SERVICE_CONNECT ||
                intent?.getBooleanExtra(Action.EXTRA_USER_INITIATED, false) == true
        val suppliedUserSessionEpoch = if (
            intent?.hasExtra(Action.EXTRA_USER_SESSION_EPOCH) == true
        ) {
            intent.getLongExtra(Action.EXTRA_USER_SESSION_EPOCH, Long.MIN_VALUE)
        } else {
            null
        }
        if (
            userSessionEpochRequired &&
            (
                suppliedUserSessionEpoch == null ||
                    !ServiceLifecycleOwnership.isUserSessionEpochCurrent(suppliedUserSessionEpoch) ||
                    !Settings.startedByUser
            )
        ) {
            Log.w(
                TAG,
                "rejecting explicit service command superseded by terminal Stop action=${intent?.action}",
            )
            if (!Settings.startedByUser && status.value == Status.Stopped) {
                notification.close()
                service.stopSelf()
            }
            return Service.START_NOT_STICKY
        }
        suppliedUserSessionEpoch?.let { activeVpnStartAdmissionEpoch = it }
        if (intent?.action == Action.SERVICE_PREPARE_VPN) {
            if (status.value == Status.Stopping) {
                queueConnectBehindStop(
                    intent = intent,
                    flags = flags,
                    userSessionEpoch = checkNotNull(suppliedUserSessionEpoch),
                )
                Log.i(TAG, "queued exact VPN preparation behind the active Stop barrier")
                return Service.START_STICKY
            }
            return prepareVpnStartAdmission(checkNotNull(suppliedUserSessionEpoch))
        }
        val connectFromNotification = intent?.action == Action.SERVICE_CONNECT
        val quickSettingsRequestId = if (connectFromNotification) {
            intent?.getLongExtra(Action.EXTRA_REQUEST_ID, 0L)?.takeIf { it > 0L } ?: 0L
        } else {
            0L
        }
        if (quickSettingsRequestId > 0L) {
            QuickSettingsDiagnostics.record(
                service,
                component = "service",
                event = "service_command",
                requestId = quickSettingsRequestId,
                outcome = "received",
                status = status.value ?: Status.Stopped,
                generation = currentStartGeneration(),
            )
        }
        val processRecoveryRequested = intent?.action == Action.SERVICE_RECOVER
        if (processRecoveryRequested) {
            // Builds before 0.7.11 could leave one AlarmManager PendingIntent.
            // Consume it once, but never use alarms to replace an active,
            // system-bound VpnService again.
            cancelLegacyProcessRecoveryAlarm()
        }
        // Samsung delivers Always-on startup as a non-null framework intent
        // with action android.net.VpnService and flags=0. Treat it as a system
        // restart: it may restore an explicitly persisted user session, but it
        // must never manufacture new user intent after authoritative Disconnect.
        val restartedBySystem = intent == null ||
            intent.action == VpnService.SERVICE_INTERFACE ||
            (flags and Service.START_FLAG_REDELIVERY) != 0 ||
            (flags and Service.START_FLAG_RETRY) != 0
        val explicitUserStartRequested =
            !restartedBySystem &&
                !processRecoveryRequested &&
                (
                    connectFromNotification ||
                        intent?.getBooleanExtra(Action.EXTRA_USER_INITIATED, false) == true
                )
        val shouldRestoreUserSession = shouldRestoreUserSessionFromServiceCommand(
            restartedBySystem = restartedBySystem,
            processRecoveryRequested = processRecoveryRequested,
            connectFromNotification = connectFromNotification,
            userSessionActive = Settings.startedByUser,
            activeConfigAvailable = Settings.activeConfigPath.isNotBlank(),
        )
        if (shouldRestoreUserSession && activeVpnStartAdmissionEpoch == null) {
            activeVpnStartAdmissionEpoch = ServiceLifecycleOwnership.currentUserSessionEpoch()
        }

        if (
            shouldRejectNewVpnStart(
                service,
                "service start",
                explicitUserStart = explicitUserStartRequested,
            )
        ) {
            if (quickSettingsRequestId > 0L) {
                QuickSettingsDiagnostics.record(
                    service,
                    component = "service",
                    event = "service_command",
                    requestId = quickSettingsRequestId,
                    outcome = "rejected_vpn_owner",
                    status = status.value ?: Status.Stopped,
                    generation = currentStartGeneration(),
                )
            }
            Settings.startedByUser = false
            Settings.startCoreAfterStartingService = false
            if (status.value != Status.Stopped) {
                stopForExternalVpn("service start")
            } else {
                binder.broadcast { callback ->
                    callback.onServiceAlert(Alert.VpnRevoked.ordinal, null)
                }
                notification.close()
                service.stopSelf()
            }
            return Service.START_NOT_STICKY
        }

        if (shouldRestoreUserSession && !NativeResumeConfigStore.hasStoredConfig(service)) {
            if (quickSettingsRequestId > 0L) {
                QuickSettingsDiagnostics.record(
                    service,
                    component = "service",
                    event = "service_command",
                    requestId = quickSettingsRequestId,
                    outcome = "rejected_no_config",
                    status = status.value ?: Status.Stopped,
                    generation = currentStartGeneration(),
                )
            }
            Log.w(TAG, "discarding stale user-session restore without encrypted recovery config")
            Settings.startedByUser = false
            Settings.startCoreAfterStartingService = false
            notification.close()
            service.stopSelf()
            return Service.START_NOT_STICKY
        }

        if (status.value != Status.Stopped) {
            if (
                (connectFromNotification || explicitUserStartRequested) &&
                requestFailClosedSessionResume()
            ) {
                Log.i(TAG, "explicit Connect requested resume from passive fail-closed hold")
                if (quickSettingsRequestId > 0L) {
                    QuickSettingsDiagnostics.record(
                        service,
                        component = "service",
                        event = "service_command",
                        requestId = quickSettingsRequestId,
                        outcome = "queued_fail_closed",
                        status = status.value ?: Status.Starting,
                        generation = currentStartGeneration(),
                    )
                }
                return Service.START_STICKY
            }
            if (
                status.value == Status.Stopping &&
                (connectFromNotification || explicitUserStartRequested)
            ) {
                val exactEpoch = checkNotNull(suppliedUserSessionEpoch) {
                    "accepted Connect while stopping requires its exact user-session epoch"
                }
                Settings.startCoreAfterStartingService = true
                queueConnectBehindStop(
                    intent = checkNotNull(intent),
                    flags = flags,
                    userSessionEpoch = exactEpoch,
                )
                Log.i(TAG, "queued newest exact Connect behind the active native Stop barrier")
                if (quickSettingsRequestId > 0L) {
                    QuickSettingsDiagnostics.record(
                        service,
                        component = "service",
                        event = "service_command",
                        requestId = quickSettingsRequestId,
                        outcome = "queued_stopping",
                        status = Status.Stopping,
                        generation = currentStartGeneration(),
                    )
                }
                return Service.START_STICKY
            }
            if (earlyVpnStartAdmissionReady && explicitUserStartRequested) {
                val explicitConfigIdentity = intent?.hasExtra(Action.EXTRA_CONFIG_FINGERPRINT) == true
                val requestedConfigFingerprint = if (explicitConfigIdentity) {
                    intent?.getStringExtra(Action.EXTRA_CONFIG_FINGERPRINT)
                } else {
                    Settings.activeConfigFingerprint
                }
                val requestedConfigUsesTurncoat = if (
                    explicitConfigIdentity && intent?.hasExtra(Action.EXTRA_CONFIG_USES_TURNCOAT) == true
                ) {
                    intent.getBooleanExtra(Action.EXTRA_CONFIG_USES_TURNCOAT, false)
                } else {
                    Settings.activeConfigUsesTurncoat
                }
                val generation = currentStartGeneration()
                if (!runtimeConfigOwnership.admit(
                        generation = generation,
                        fingerprint = requestedConfigFingerprint,
                        usesTurncoat = requestedConfigUsesTurncoat,
                    )
                ) {
                    val exactUserSessionEpoch = checkNotNull(suppliedUserSessionEpoch)
                    completeVpnStartAdmissionFailure(
                        exactUserSessionEpoch,
                        "active VPN configuration identity is unavailable",
                    )
                    serviceScope.launch(Dispatchers.IO) {
                        stopAndAlert(
                            Alert.StartService,
                            "active VPN configuration identity is unavailable",
                            expectedUserSessionEpoch = exactUserSessionEpoch,
                            expectedGeneration = generation,
                        )
                    }
                    return Service.START_NOT_STICKY
                }
                earlyVpnStartAdmissionReady = false
                launchServiceStart(
                    generation = generation,
                    allowStoredIdentityMigration = !explicitConfigIdentity,
                    userSessionEpoch = checkNotNull(suppliedUserSessionEpoch),
                )
                return Service.START_STICKY
            }
            if ((restartedBySystem || processRecoveryRequested) && !connectFromNotification) {
                Log.i(TAG, "ignoring system service restart while service is already active")
                return Service.START_STICKY
            }
            if (connectFromNotification && status.value == Status.Started) {
                Settings.startCoreAfterStartingService = false
                Log.i(TAG, "ignoring notification connect while core is already started")
                if (quickSettingsRequestId > 0L) {
                    QuickSettingsDiagnostics.record(
                        service,
                        component = "service",
                        event = "service_command",
                        requestId = quickSettingsRequestId,
                        outcome = "ignored_started",
                        status = Status.Started,
                        generation = currentStartGeneration(),
                    )
                }
                return Service.START_STICKY
            }
            if ((connectFromNotification || Settings.startCoreAfterStartingService) && status.value != Status.Stopping) {
                if (quickSettingsRequestId > 0L) {
                    admitQuickSettingsRequest(quickSettingsRequestId, currentStartGeneration())
                }
                if (deferNativeCoreStartToServicePipeline()) {
                    Log.i(TAG, "native core start deferred until service setup is ready")
                    return Service.START_STICKY
                }
                Settings.startCoreAfterStartingService = false
                val nativeStartGeneration = currentStartGeneration()
                val nativeStartUserSessionEpoch =
                    checkNotNull(ServiceLifecycleOwnership.currentUserSessionEpoch())
                serviceScope.launch(Dispatchers.IO) {
                    startStoredCoreFromNativeEntryPoint(
                        generation = nativeStartGeneration,
                        userSessionEpoch = nativeStartUserSessionEpoch,
                    )
                }
            }
            return Service.START_STICKY
        }
        val explicitConfigIdentity = intent?.hasExtra(Action.EXTRA_CONFIG_FINGERPRINT) == true
        val requestedConfigFingerprint = if (explicitConfigIdentity) {
            intent?.getStringExtra(Action.EXTRA_CONFIG_FINGERPRINT)
        } else {
            Settings.activeConfigFingerprint
        }
        val requestedConfigUsesTurncoat = if (
            explicitConfigIdentity && intent?.hasExtra(Action.EXTRA_CONFIG_USES_TURNCOAT) == true
        ) {
            intent.getBooleanExtra(Action.EXTRA_CONFIG_USES_TURNCOAT, false)
        } else {
            Settings.activeConfigUsesTurncoat
        }
        earlyVpnStartAdmissionReady = false
        val generation = nextStartGeneration()
        admitQuickSettingsRequest(quickSettingsRequestId, generation)
        runtimeConfigOwnership.admit(
            generation = generation,
            fingerprint = requestedConfigFingerprint,
            usesTurncoat = requestedConfigUsesTurncoat,
        )
        if (explicitUserStartRequested && Settings.serviceMode == ServiceMode.VPN) {
            markExplicitVpnTakeoverAllowance()
        } else {
            clearExplicitVpnTakeoverAllowance()
        }
        synchronized(lifecycleLock) {
            terminalCoreCleanupFailurePublished = false
        }
        synchronized(fileDescriptorLock) {
            // Keep descriptor admission closed until startService has crossed
            // both the prior service-cleanup and exact native-close barriers.
            status.value = Status.Starting
        }

        if (shouldRestoreUserSession) {
            Log.w(TAG, "restoring user-started VPN after system service restart")
            Settings.startCoreAfterStartingService = true
        } else if ((restartedBySystem || processRecoveryRequested) && !connectFromNotification) {
            Log.i(TAG, "ignoring system service restart without explicit connect")
            Settings.startedByUser = false
            Settings.startCoreAfterStartingService = false
            service.stopSelf()
            return Service.START_NOT_STICKY
        }

        if (
            Settings.activeConfigPath.isNotBlank() &&
            connectFromNotification
        ) {
            Settings.startCoreAfterStartingService = true
        }

        registerServiceReceiverIfNeeded()

        if (!Settings.startedByUser) {
            Log.w(TAG, "terminal Stop superseded service start before pipeline launch")
            Settings.startCoreAfterStartingService = false
            service.stopSelf()
            return Service.START_NOT_STICKY
        }
        val launchUserSessionEpoch =
            suppliedUserSessionEpoch
                ?: checkNotNull(ServiceLifecycleOwnership.currentUserSessionEpoch())
        launchServiceStart(
            generation = generation,
            allowStoredIdentityMigration = !explicitConfigIdentity,
            userSessionEpoch = launchUserSessionEpoch,
        )
        return Service.START_STICKY
    }

    private suspend fun startStoredCoreFromNativeEntryPoint(
        generation: Long,
        userSessionEpoch: Long,
    ) {
        if (
            !shouldContinueStart(generation) ||
            !ServiceLifecycleOwnership.isUserSessionEpochCurrent(userSessionEpoch)
        ) {
            Log.i(TAG, "discarding stale native core start generation=$generation")
            return
        }
        if (shouldYieldToExternalVpn("native core start")) {
            stopForExternalVpnOnMain("native core start")
            return
        }
        if (status.value == Status.Started) {
            Log.i(TAG, "ignoring native core start while core is already started")
            return
        }
        val configPath = Settings.activeConfigPath
        if (configPath.isBlank()) {
            if (shouldContinueStart(generation)) {
                stopAndAlert(
                    Alert.EmptyConfiguration,
                    expectedUserSessionEpoch = userSessionEpoch,
                    expectedGeneration = generation,
                )
            }
            return
        }
        if (!NativeResumeConfigStore.hasStoredConfig(service)) {
            if (shouldContinueStart(generation)) {
                stopAndAlert(
                    Alert.EmptyConfiguration,
                    expectedUserSessionEpoch = userSessionEpoch,
                    expectedGeneration = generation,
                )
            }
            return
        }
        try {
            if (!shouldContinueStart(generation)) return
            startCoreRuntimeMonitor(nativeStartup = true)
            val routeVerified = startMobileCoreFromNativePath(
                configPath,
                "native core start",
                generation = generation,
                userSessionEpoch = userSessionEpoch,
            )
            if (routeVerified) {
                markCoreRuntimeStarted(routeVerified = true, generation = generation)
                return
            }
            if (!shouldContinueStart(generation)) return
            Log.w(TAG, "native entry-point startup retained for selected-route recovery")
            recordQuickSettingsLifecycle(
                event = "route",
                outcome = "recovery_pending",
                generation = generation,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            if (shouldContinueStart(generation)) {
                stopAndAlert(
                    Alert.StartService,
                    error.message,
                    expectedUserSessionEpoch = userSessionEpoch,
                    expectedGeneration = generation,
                )
            } else {
                Log.i(TAG, "discarding stale native core start failure generation=$generation")
            }
        }
    }

    private suspend fun startMobileCoreFromNativePath(
        configPath: String,
        reason: String,
        generation: Long? = null,
        userSessionEpoch: Long? = null,
    ): Boolean {
        val usesTurncoat = if (generation != null) {
            runtimeConfigOwnership.usesTurncoat(generation) ?: false
        } else {
            configUsesTurncoat(configPath)
        }
        val started = try {
            MobileCoreLifecycle.run {
                if (generation != null && !shouldContinueStart(generation)) {
                    return@run false
                }
                val lease = if (configPath == Settings.activeConfigPath) {
                    NativeResumeConfigStore.createPlaintextLease(service, generation ?: currentStartGeneration())
                } else {
                    null
                }
                val actualPath = lease?.absolutePath ?: configPath
                try {
                    if (
                        generation != null &&
                        !runtimeConfigOwnership.matches(
                            generation,
                            NativeResumeConfigStore.fingerprintPlaintextFile(File(actualPath)),
                        )
                    ) {
                        throw RuntimeConfigIdentityMismatchException()
                    }
                    Mobile.start(actualPath, "")
                } finally {
                    NativeResumeConfigStore.deleteLease(lease)
                }
                true
            }
        } catch (error: RuntimeConfigIdentityMismatchException) {
            Log.e(TAG, "refusing native start for a superseded runtime configuration")
            if (generation == null || shouldContinueStart(generation)) {
                stopAndAlert(
                    Alert.StartService,
                    error.message,
                    expectedUserSessionEpoch = userSessionEpoch,
                    expectedGeneration = generation,
                )
            } else {
                Log.i(TAG, "discarding stale runtime identity failure generation=$generation")
            }
            return false
        }
        if (!started) return false
        if (generation != null && !shouldContinueStart(generation)) return false
        return verifyNativeStartupRoute(usesTurncoat, reason, generation)
    }

    private suspend fun verifyNativeStartupRoute(
        usesTurncoat: Boolean,
        reason: String,
        generation: Long? = null,
        operationDeadlineElapsedMs: Long? = null,
    ): Boolean {
        val timeoutMs = if (usesTurncoat) {
            STARTUP_ROUTE_VERIFY_TURNCOAT_TIMEOUT_MS
        } else {
            STARTUP_ROUTE_VERIFY_TIMEOUT_MS
        }
        val deadline = minOf(
            SystemClock.elapsedRealtime() + timeoutMs,
            operationDeadlineElapsedMs ?: Long.MAX_VALUE,
        )
        val routeClient = GrpcClientProvider.coreClient(ROUTE_WATCHDOG_GRPC_TIMEOUT_MS)
        var attempt = 0
        var lastSummary = "not checked"
        if (usesTurncoat) {
            lastSelectedOutboundType = "turncoat"
        }

        while (SystemClock.elapsedRealtime() < deadline) {
            if (generation != null && !shouldContinueStart(generation)) {
                finishCancelledStart(generation, "startup route verification")
                return false
            }
            if (shouldYieldToExternalVpn("startup route verification")) {
                stopForExternalVpnOnMain("startup route verification")
                return false
            }
            if (underlyingNetworkInitialized && observedUnderlyingNetwork == null) {
                lastSummary = "waiting for an underlying network"
                val remainingMs = deadline - SystemClock.elapsedRealtime()
                if (remainingMs <= 0L) break
                val availableNetwork = withTimeoutOrNull(remainingMs) {
                    DefaultNetworkMonitor.require()
                }
                if (availableNetwork == null) break
                continue
            }

            attempt += 1
            val probeNetworkGeneration = networkGeneration
            val probeNetworkObservationRevision = DefaultNetworkMonitor.observationRevision(serviceOwnerToken)
            val remainingBudgetMs = deadline - SystemClock.elapsedRealtime()
            val attemptTimeoutMs = vpnDataPlaneAttemptTimeoutMs(
                turncoatRoute = usesTurncoat,
                remainingBudgetMs = remainingBudgetMs,
            )
            val result = runCatching {
                // Carrier telemetry and direct outbound urltest remain useful
                // diagnostics, but neither proves that Android application
                // traffic crossed the current TUN. Startup is admitted only
                // by the real VPN Network GET below.
                checkSelectedRoute(
                    routeClient,
                    requireVpnDataPlane = true,
                    dataPlaneAttemptTimeoutMs = attemptTimeoutMs,
                    redundantDataPlaneEndpoints = true,
                )
            }.getOrElse {
                if (it is CancellationException) throw it
                RouteHealth(false, "startup route check error: ${it.message ?: it.javaClass.simpleName}")
            }
            if (probeNetworkGeneration != networkGeneration) {
                lastSummary =
                    "discarded stale VPN data-plane proof from network generation=$probeNetworkGeneration"
                Log.w(TAG, "native startup route changed during probe ($reason): $lastSummary")
                val remainingMs = deadline - SystemClock.elapsedRealtime()
                if (remainingMs <= 0L) break
                delay(minOf(STARTUP_ROUTE_VERIFY_RETRY_MS, remainingMs))
                continue
            }
            lastSummary = result.summary
            if (result.outboundType.isNotBlank()) {
                lastSelectedOutboundType = result.outboundType
            }
            if (result.healthy) {
                if (generation != null && !shouldContinueStart(generation)) {
                    finishCancelledStart(generation, "selected route verification")
                    return false
                }
                Log.i(TAG, "native startup route verified ($reason): ${result.summary}")
                ConnectionDiagnostics.record(
                    service,
                    component = "service",
                    event = "startup_route",
                    outcome = "verified",
                    generation = generation ?: currentStartGeneration(),
                    attempt = attempt.toLong(),
                    durationMs = timeoutMs - maxOf(0L, deadline - SystemClock.elapsedRealtime()),
                )
                return true
            }
            if (result.networkReadinessPending) {
                Log.i(TAG, "native startup is waiting for physical resolver readiness ($reason)")
                val remainingMs = deadline - SystemClock.elapsedRealtime()
                if (remainingMs <= 0L) break
                val fallbackTimeoutMs = minOf(STARTUP_ROUTE_VERIFY_RETRY_MS, remainingMs)
                if (probeNetworkObservationRevision != null) {
                    DefaultNetworkMonitor.awaitObservationAfter(
                        ownerToken = serviceOwnerToken,
                        revision = probeNetworkObservationRevision,
                        fallbackTimeoutMs = fallbackTimeoutMs,
                    )
                } else {
                    delay(fallbackTimeoutMs)
                }
                continue
            }
            Log.w(TAG, "native startup route not ready ($reason, attempt $attempt): ${result.summary}")
            val remainingMs = deadline - SystemClock.elapsedRealtime()
            if (remainingMs <= 0L) break
            delay(minOf(STARTUP_ROUTE_VERIFY_RETRY_MS, remainingMs))
        }

        val recoveryGeneration = generation ?: currentStartGeneration()
        if (
            underlyingNetworkInitialized &&
            observedUnderlyingNetwork == null &&
            shouldContinueStart(recoveryGeneration)
        ) {
            routeWatchdogDegraded = true
            withContext(Dispatchers.Main) {
                if (shouldContinueStart(recoveryGeneration)) {
                    status.value = Status.Starting
                    notification.show(activeProfileName, R.string.status_starting)
                }
            }
            ConnectionDiagnostics.record(
                service,
                component = "service",
                event = "startup_route",
                outcome = "waiting_network",
                generation = recoveryGeneration,
                attempt = attempt.toLong(),
                durationMs = timeoutMs,
            )
            Log.i(
                TAG,
                "native startup route parked until an underlying-network callback ($reason)",
            )
            return false
        }

        Log.w(TAG, "native startup route failed ($reason): $lastSummary")
        ConnectionDiagnostics.record(
            service,
            component = "service",
            event = "startup_route",
            outcome = "recovery_pending",
            generation = recoveryGeneration,
            attempt = attempt.toLong(),
            durationMs = timeoutMs,
        )
        val retryFailedStart = shouldRetryFailedNativeStartup(
            routeVerified = false,
            userSessionActive = Settings.startedByUser,
            startStillCurrent = shouldContinueStart(recoveryGeneration),
        )
        if (retryFailedStart) {
            val recoveryAlreadyOwned = nativeRouteRecoveryOwnsGeneration(recoveryGeneration)
            routeWatchdogDegraded = true
            withContext(Dispatchers.Main) {
                if (shouldContinueStart(recoveryGeneration)) {
                    status.value = Status.Starting
                    notification.show(activeProfileName, R.string.status_recovering)
                }
            }
            if (recoveryAlreadyOwned) {
                Log.w(TAG, "native startup route remains owned by active recovery ($reason)")
            } else {
                requestCoreRecovery(
                    "native startup route unavailable during $reason: $lastSummary",
                    recoveryGeneration,
                )
                Log.w(TAG, "native startup route handed to retry recovery ($reason)")
            }
        } else {
            Log.i(TAG, "discarding failed native startup route for stale or inactive generation ($reason)")
        }
        return false
    }

    fun onBind(intent: Intent): IBinder {
        return binder
    }

    fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(serviceOwnerToken, listener)
    }

    fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.clearListener(serviceOwnerToken, listener)
    }

    fun onDestroy() {
        status.removeObserver(processStatusObserver)
        clearExplicitVpnTakeoverAllowance()
        synchronized(fileDescriptorLock) {
            tunDescriptorAdmissionClosed = true
        }
        cancelPendingStarts()
        val stopWasRequested = closedByStopService
        val externalVpnActive = BoxService.isExternalVpnActive(service, "service destroy")
        val ownership = readVpnOwnership(service)
        val establishedVpnOwnershipLost =
            Settings.serviceMode == ServiceMode.VPN &&
                vpnOwnershipWasEstablished &&
                ownership.known &&
                !ownership.active
        val shouldPreserveUserSession =
            !stopWasRequested &&
                !externalVpnActive &&
                !vpnOwnershipRevoked &&
                Settings.startedByUser &&
                Settings.activeConfigPath.isNotBlank()
        if (vpnOwnershipRevoked) {
            Log.w(
                TAG,
                "service destroy observed revoked Marten VPN ownership; sticky restore disabled",
            )
        } else if (establishedVpnOwnershipLost && shouldPreserveUserSession) {
            Log.w(
                TAG,
                "service destroy observed missing Marten VPN network without revoke or external owner; " +
                    "preserving user intent for sticky recovery",
            )
        }
        stopCoreRuntimeMonitor()
        stopCoreWatchdog()
        stopRouteWatchdog()
        stopExternalVpnWatchdog()
        serviceCaptchaControlPlane.stop()
        recordQuickSettingsLifecycle(
            event = "service_destroy",
            outcome = if (stopWasRequested) "requested" else "unexpected",
            generation = currentStartGeneration(),
        )
        resetUnderlyingNetworkGeneration()
        serviceJob.cancel()
        invalidateVpnDataPlaneProof("service destroy")

        val (stickyTunHandedOff, cleanupAccepted) = synchronized(serviceReplacementLock) {
            // Re-check mutable terminal intent inside the same transaction as
            // descriptor publication. A manual Stop racing onDestroy either
            // wins before publication, or sees and closes the pending handoff.
            val preserveAtHandoff =
                shouldPreserveUserSession &&
                    !closedByStopService &&
                    Settings.startedByUser
            val handedOff =
                stickyTunPreparedForReplacement ||
                    (preserveAtHandoff && handoffTunFileDescriptorForStickyRecovery())
            val cleanupRegistered = registerDestroyCleanup(
                preserveStickyTun = handedOff,
            )
            if (activeInstance === this) {
                activeInstance = null
            }
            handedOff to cleanupRegistered
        }

        if (cleanupAccepted && ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
            val preservePublishedSession = shouldPreserveUserSession && stickyTunHandedOff
            if (preservePublishedSession) {
                Log.w(
                    TAG,
                    "service destroyed unexpectedly; preserving user-started VPN session for sticky restart " +
                        "tun_handoff=$stickyTunHandedOff",
                )
                status.value = Status.Starting
            }
            if (!preservePublishedSession) {
                Settings.startedByUser = false
                status.value = Status.Stopped
            }
            Settings.startCoreAfterStartingService = preservePublishedSession
            notification.close(
                removeNotification =
                    !preservePublishedSession && !keepStoppedNotificationOnDestroy,
            )
            keepStoppedNotificationOnDestroy = false
        } else if (cleanupAccepted) {
            Log.i(TAG, "service destroy cleanup already belongs to the replacement owner barrier")
        } else {
            Log.i(TAG, "stale service destroy skipped shared network/core cleanup")
        }
        binder.close()
        publishCurrentPlatformStatus()
    }

    fun onRevoke() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            stopService(vpnRevoked = true)
        } else {
            mainHandler.post {
                stopService(vpnRevoked = true)
            }
        }
    }

    internal fun sendNotification(notification: Notification) {
        return
        val builder =
            NotificationCompat.Builder(service, notification.identifier).setShowWhen(false)
                .setContentTitle(notification.title).setContentText(notification.body)
                .setOnlyAlertOnce(true).setSmallIcon(R.drawable.ic_stat_logo_sharp)
                .setCategory(NotificationCompat.CATEGORY_EVENT)
                .setPriority(NotificationCompat.PRIORITY_HIGH).setAutoCancel(true)
        if (!notification.subtitle.isNullOrBlank()) {
            builder.setContentInfo(notification.subtitle)
        }
        if (!notification.openURL.isNullOrBlank()) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    service,
                    0,
                    Intent(
                        service,
                        MainActivity::class.java,
                    ).apply {
                        setAction(Action.SERVICE).setData(Uri.parse(notification.openURL))
                        setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    },
                    ServiceNotification.flags,
                ),
            )
        }
        serviceScope.launch(Dispatchers.Main) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Application.notification.createNotificationChannel(
                    NotificationChannel(
                        notification.identifier,
                        notification.typeName,
                        NotificationManager.IMPORTANCE_HIGH,
                    ),
                )
            }
            Application.notification.notify(notification.typeID, builder.build())
        }
    }

     fun writeDebugMessage(message: String?) {
        if (message.isNullOrBlank()) return
        Log.d("BoxService", message)
        binder.broadcast {
            it.onServiceWriteLog(message)
        }
    }

}
