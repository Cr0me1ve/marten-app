package app.marten.client

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.provider.Settings as AndroidSettings
import android.util.Log
import app.marten.client.bg.BoxService
import app.marten.client.bg.ConnectionDiagnostics
//import app.marten.client.bg.BoxService.Companion.workingDir
import app.marten.client.bg.MobileCoreCloser
import app.marten.client.bg.MobileCoreLifecycle
import app.marten.client.bg.MobileForegroundSetupCoordinator
import app.marten.client.bg.MobileForegroundSetupKey
import app.marten.client.bg.LocalProbeAdmission
import app.marten.client.bg.PhysicalTlsProbe
import app.marten.client.bg.ServiceLifecycleOwnership
import app.marten.client.bg.awaitPlatformStopRelease
import app.marten.client.bg.isPlatformStopReleaseComplete
import app.marten.client.bg.isPlatformStopSafeForUser
import app.marten.client.bg.requestAuthoritativePlatformStop
import app.marten.client.constant.Action
import app.marten.client.constant.Status
import app.marten.native_resume.NativeResumeConfigPublisher
import app.marten.native_resume.NativeResumeConfigStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

import app.marten.core.libbox.Libbox
import app.marten.client.bg.RemoteMobile as Mobile
import app.marten.client.bg.Bugs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Completes every MethodChannel call exactly once on synchronous or suspending
 * platform failure. Kotlin's generic receiver.runCatching silently stores an
 * exception in an ignored Result; using it with MethodChannel.Result leaves
 * Dart awaiting forever and can strand the UI in Connecting/Disconnecting.
 */
internal inline fun MethodChannel.Result.respondCatching(
    block: MethodChannel.Result.() -> Unit,
) {
    try {
        block()
    } catch (failure: Throwable) {
        Log.e(
            MethodHandler.TAG,
            "method channel operation failed error_type=${failure.javaClass.simpleName}",
        )
        try {
            error(
                "marten_platform_error",
                failure.message ?: "Android platform operation failed",
                failure.javaClass.simpleName,
            )
        } catch (replyFailure: Throwable) {
            Log.w(
                MethodHandler.TAG,
                "method channel failure reply was rejected error_type=${replyFailure.javaClass.simpleName}",
            )
        }
    }
}

class MethodHandler(private val scope: CoroutineScope) : FlutterPlugin,
    MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private lateinit var appContext: Context

    companion object {
        const val TAG = "A/MethodHandler"
        const val channelName = "app.marten.client/method"
        private const val AUTHORITATIVE_CORE_STOP_TIMEOUT_MS = 20_000L
        private const val PLATFORM_RELEASE_TIMEOUT_MS = 5_000L
        private const val OWN_VPN_RELEASE_POLL_MS = 50L
        private const val FOREGROUND_SETUP_CLOSE_WAIT_TIMEOUT_MS = 60_000L
        private const val FLUTTER_RESTART_WAIT_TIMEOUT_MS = 60_000L
        private const val TERMINAL_PROBE_RELEASE_TIMEOUT_MS = 15_000L
        // A timed-out method call can outlive the Flutter engine that issued it.
        // Keep admission process-wide so a replacement engine joins the same
        // native setup instead of creating another operation behind the gate.
        private val foregroundSetupCoordinator = MobileForegroundSetupCoordinator()

        enum class Trigger(val method: String) {
            Setup("setup"),
            ClaimVpnStartLease("claim_vpn_start_lease"),
            CancelVpnStartLease("cancel_vpn_start_lease"),
            TryJoinVerifiedVpnAdmission("try_join_verified_vpn_admission"),
            BeginVpnStartAdmission("begin_vpn_start_admission"),
            Start("start"),
            Stop("stop"),
            Restart("restart"),
            MarkStarted("markStarted"),
            GetStartedByUser("get_started_by_user"),
            GetServiceStatus("get_service_status"),
            MatchesActiveConfigGeneration("matches_active_config_generation"),
            ValidateVpnUserSession("validate_vpn_user_session"),
            WasVpnUserSessionExplicitlyStopped("was_vpn_user_session_explicitly_stopped"),
            TryBeginFlutterRestart("try_begin_flutter_restart"),
            ValidateFlutterRestart("validate_flutter_restart"),
            EndFlutterRestart("end_flutter_restart"),
            AddGrpcClientPublicKey("add_grpc_client_public_key"),
            GetGrpcServerPublicKey("get_grpc_server_public_key"),
            GetStableDeviceID("get_stable_device_id"),
            GetSubscriptionClientMetadata("get_subscription_client_metadata"),
            ICMPPing("icmp_ping"),
            TLSPing("tls_ping"),
            CancelLocalProbes("cancel_local_probes"),
            AllowLocalProbes("allow_local_probes"),

        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        appContext = flutterPluginBinding.applicationContext
        channel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            channelName,
        )
        channel!!.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            Trigger.ClaimVpnStartLease.method -> {
                // This handler is deliberately synchronous. Platform-channel
                // delivery orders the accepted Connect lease before a later
                // Stop can invalidate it, without adding a timer or worker.
                result.success(ServiceLifecycleOwnership.issueExplicitStartLease())
            }

            Trigger.CancelVpnStartLease.method -> {
                val token = (call.arguments as? Number)?.toLong()
                if (token != null) {
                    ServiceLifecycleOwnership.releaseExplicitStartLease(token)
                }
                result.success(token != null)
            }

            Trigger.TryJoinVerifiedVpnAdmission.method -> {
                // A late engine must inspect the exact retained admission
                // before its Dart gate seals native probes. No permission UI,
                // service dispatch or lifecycle mutation belongs on this path.
                result.success(BoxService.tryJoinVerifiedVpnAdmission())
            }

            Trigger.BeginVpnStartAdmission.method -> {
                scope.launch(Dispatchers.IO) {
                    result.respondCatching {
                        val resumeSession =
                            (call.arguments as? Map<*, *>)?.get("resumeSession") as? Boolean ?: false
                        val explicitStartLease =
                            ((call.arguments as? Map<*, *>)?.get("explicitStartLease") as? Number)?.toLong()
                        val nativeHandoffClaim =
                            (call.arguments as? Map<*, *>)?.get("nativeHandoffClaim") as? Boolean ?: false
                        val vpnPermissionGranted =
                            VpnPermissionActivity.awaitStrictVpnPermission(allowPrompt = !resumeSession)
                                ?: MainActivity.instance.awaitStrictVpnPermission(allowPrompt = !resumeSession)
                        if (!vpnPermissionGranted) {
                            explicitStartLease?.let(ServiceLifecycleOwnership::releaseExplicitStartLease)
                            error("Android VPN permission was not granted")
                        }
                        success(
                            BoxService.beginVpnStartAdmission(
                                resumeSession = resumeSession,
                                explicitStartLease = explicitStartLease,
                                nativeHandoffClaim = nativeHandoffClaim,
                            ),
                        )
                    }
                }
            }

            Trigger.ICMPPing.method -> {
                launchLocalProbe(result) {
                    val args = call.arguments as? Map<*, *> ?: error("missing ICMP ping arguments")
                    val host = args["host"] as? String ?: error("missing ICMP ping host")
                    val timeoutMs = (args["timeoutMs"] as? Number)?.toLong() ?: 4_000L
                    Libbox.icmpPing(host, timeoutMs)
                }
            }

            Trigger.TLSPing.method -> {
                launchLocalProbe(result) {
                    val args = call.arguments as? Map<*, *> ?: error("missing TLS ping arguments")
                    val host = args["host"] as? String ?: error("missing TLS ping host")
                    val port = (args["port"] as? Number)?.toInt() ?: error("missing TLS ping port")
                    val serverName = args["serverName"] as? String
                    val allowUntrusted = args["allowUntrusted"] as? Boolean ?: false
                    val timeoutMs = (args["timeoutMs"] as? Number)?.toLong() ?: 4_000L
                    PhysicalTlsProbe.measure(host, port, serverName, allowUntrusted, timeoutMs)
                }
            }

            Trigger.CancelLocalProbes.method -> {
                scope.launch(Dispatchers.IO) {
                    result.respondCatching {
                        val keepBlocked =
                            (call.arguments as? Map<*, *>)?.get("keepBlocked") as? Boolean ?: false
                        success(cancelLocalProbes(keepBlocked))
                    }
                }
            }

            Trigger.AllowLocalProbes.method -> {
                scope.launch(Dispatchers.IO) {
                    result.respondCatching {
                        val blockEpoch =
                            ((call.arguments as? Map<*, *>)?.get("blockEpoch") as? Number)?.toLong()
                        val released = blockEpoch != null &&
                            withTimeoutOrNull(TERMINAL_PROBE_RELEASE_TIMEOUT_MS) {
                                allowLocalProbes(blockEpoch)
                            } == true
                        success(released)
                    }
                }
            }

            Trigger.GetStableDeviceID.method -> {
                result.success(stableDeviceId())
            }

            Trigger.GetSubscriptionClientMetadata.method -> {
                result.success(subscriptionClientMetadata())
            }

            Trigger.AddGrpcClientPublicKey.method -> {
                GlobalScope.launch {
                    result.respondCatching {
                        val args = call.arguments as Map<*, *>
                        val clientPub = args["clientPublicKey"] as ByteArray
//                        Mobile.addGrpcClientPublicKey(clientPub)
                        Settings.grpcFlutterPublicKey = clientPub
                        success("")

                    }
                }
            }

            Trigger.GetGrpcServerPublicKey.method -> {
                GlobalScope.launch {
                    result.respondCatching {
                        result.success(Mobile.getServerPublicKey())
                    }
                }
            }

            Trigger.Setup.method -> {
                scope.launch(Dispatchers.IO) {
                    result.respondCatching {
                        val args = call.arguments as Map<*, *>
                        Settings.baseDir = args["baseDir"] as String
                        Settings.workingDir = args["workingDir"] as String
                        Settings.tempDir = args["tempDir"] as String
                        Settings.debugMode = args["debug"] as Boolean? ?: true
                        val mode = args["mode"] as Int
                        val grpcPort = args["grpcPort"] as Int
                        val suppliedRequestId = (args["requestId"] as? Number)?.toLong() ?: 0L
                        val requestId = suppliedRequestId.takeIf { it > 0L }
                            ?: ConnectionDiagnostics.nextAttemptId()
                        val requestStartedAt = SystemClock.elapsedRealtime()
                        val key = MobileForegroundSetupKey(
                            baseDir = Settings.baseDir,
                            workingDir = Settings.workingDir,
                            tempDir = Settings.tempDir,
                            mode = mode,
                            grpcPort = grpcPort,
                            debug = Settings.debugMode,
                        )
                        Log.d("debugmode","${Settings.debugMode}")
                        Log.i(TAG, "foreground setup request=$requestId phase=admitted mode=$mode")
                        ConnectionDiagnostics.record(
                            appContext,
                            component = "foreground",
                            event = "setup",
                            outcome = "admitted",
                            requestId = requestId,
                        )
                        try {
                            val admission = foregroundSetupCoordinator.run(key) {
                                val closeWaitStartedAt = SystemClock.elapsedRealtime()
                                val closeReady = MobileCoreCloser.waitForCloseToFinish(
                                    reason = "foreground setup request=$requestId",
                                    timeoutMs = FOREGROUND_SETUP_CLOSE_WAIT_TIMEOUT_MS,
                                )
                                val closeWaitMs = SystemClock.elapsedRealtime() - closeWaitStartedAt
                                ConnectionDiagnostics.record(
                                    appContext,
                                    component = "foreground",
                                    event = "close_barrier",
                                    outcome = if (closeReady) "ready" else "timeout",
                                    requestId = requestId,
                                    durationMs = closeWaitMs,
                                )
                                check(closeReady) { "previous native core close is still running" }
                                Log.d(
                                    TAG,
                                    "core setup request=$requestId mode=foreground debug=${key.debug} " +
                                        "service_mode=${Settings.serviceMode} platform_interface=false",
                                )
                                MobileCoreLifecycle.run {
                                    Mobile.setup(
                                        key.baseDir,
                                        key.workingDir,
                                        key.tempDir,
                                        key.mode.toLong(),
                                        "127.0.0.1:${key.grpcPort}",
                                        "",
                                        key.debug,
                                        null,
                                    )
                                    Log.d(
                                        TAG,
                                        "core setup complete request=$requestId mode=foreground " +
                                            "platform_interface=false ${Mobile.runtimeState()}",
                                    )

//                                    Libbox.setup(Settings.baseDir, Settings.workingDir, Settings.tempDir, false)
                                    Libbox.redirectStderr("/dev/null")
                                }
                            }
                            val durationMs = SystemClock.elapsedRealtime() - requestStartedAt
                            val outcome = when {
                                admission.coalesced -> "coalesced_ready"
                                admission.waitedForOtherSetup -> "serialized_ready"
                                else -> "ready"
                            }
                            Log.i(
                                TAG,
                                "foreground setup request=$requestId phase=complete outcome=$outcome " +
                                    "duration_ms=$durationMs",
                            )
                            ConnectionDiagnostics.record(
                                appContext,
                                component = "foreground",
                                event = "setup",
                                outcome = outcome,
                                requestId = requestId,
                                durationMs = durationMs,
                            )
                            success("")
                        } catch (error: Throwable) {
                            val durationMs = SystemClock.elapsedRealtime() - requestStartedAt
                            Log.e(
                                TAG,
                                "foreground setup request=$requestId phase=complete outcome=failed " +
                                    "error_type=${error.javaClass.simpleName} duration_ms=$durationMs",
                            )
                            ConnectionDiagnostics.record(
                                appContext,
                                component = "foreground",
                                event = "setup",
                                outcome = "failed",
                                requestId = requestId,
                                durationMs = durationMs,
                            )
                            error(error)
                        }
                    }
                }
            }


            Trigger.Start.method -> {
                scope.launch {
                    result.respondCatching {
                        val args = call.arguments as Map<*, *>
                        val userSessionEpoch = (args["userSessionEpoch"] as? Number)?.toLong()
                            ?: error("missing Android VPN user-session epoch")
                        if (
                            !ServiceLifecycleOwnership.isUserSessionEpochCurrent(userSessionEpoch) ||
                            !Settings.startedByUser
                        ) {
                            // Stop winning this hand-off race is an expected
                            // lifecycle outcome, not a platform-channel error.
                            // Returning normally lets Dart join the exact
                            // terminal cleanup without publishing a failure.
                            Log.i(TAG, "discarding Android background start superseded by terminal Stop")
                            success(false)
                            return@respondCatching
                        }
                        val preparedPath = args["path"] as String? ?: ""
                        val storedConfig = storeNativeResumeConfig(preparedPath, args["name"] as String? ?: "")
                        Settings.debugMode = args["debug"] as Boolean? ?: true
                        Settings.grpcServiceModePort = args["grpcPort"] as Int
                        // The foreground/background gRPC services are long-lived.
                        // Refresh native diagnostic mode before Flutter or the
                        // service-owned recovery path constructs the next core.
                        withContext(Dispatchers.IO) { Mobile.setDebug(Settings.debugMode) }

                        val mainActivity = MainActivity.instance
//                        val started = mainActivity.serviceStatus.value == Status.Started
//                        if (started) {
//                            Log.w(TAG, "service is already running")
//                            return@launch success(true)
//                        }
                        Settings.startCoreAfterStartingService = false

                        mainActivity.startService(
                            configFingerprint = storedConfig.fingerprint,
                            configUsesTurncoat = storedConfig.usesTurncoat,
                            userSessionEpoch = userSessionEpoch,
                        )
                        success(true)
                    }
                }
            }

            "await_start_network" -> {
                scope.launch {
                    result.respondCatching {
                        val epoch = (call.arguments as? Number)?.toLong()
                            ?: error("missing Android VPN user-session epoch")
                        success(BoxService.awaitStartupNetwork(epoch))
                    }
                }
            }

            Trigger.Stop.method -> {
                scope.launch {
                    result.respondCatching {
                        Settings.startedByUser = false
                        Settings.startCoreAfterStartingService = false
                        NativeResumeConfigStore.cleanupPlaintextLeases(appContext)
                        val mainActivity = MainActivity.instance
                        val stoppedOwnerToken = BoxService.currentActiveOwnerToken() ?: 0L
                        BoxService.stopFromFlutter()
                        val initialStatus = mainActivity.serviceStatus.value
                        val initialBoundStatus = mainActivity.boundServiceStatus
                        if (initialStatus == Status.Stopped && initialBoundStatus == Status.Stopped) {
                            // Stopped is authoritative either after completed
                            // service cleanup or for a service created only by
                            // bindService() that never admitted a core/TUN start.
                            // Do not issue a duplicate native close; the release
                            // barrier below distinguishes those two cases.
                            Log.i(TAG, "service is already authoritatively stopped; skipping duplicate native close")
                            releaseStoppedPlatformService(mainActivity)
                            success(
                                awaitStoppedPlatformServiceRelease(
                                    ownerToken = stoppedOwnerToken,
                                    coreStopped = true,
                                ),
                            )
                            return@respondCatching
                        }
                        // Core/TUN shutdown is authoritative and coalesced inside
                        // BoxService. Keep the Activity binding until the exact
                        // service owner acknowledges that shutdown; otherwise a
                        // Quick Settings-started service can be destroyed while
                        // its asynchronous stop command is still being admitted.
                        val coreStopped = requestAuthoritativePlatformStop(
                            requestCoreStop = {},
                            awaitCoreStop = {
                                BoxService.awaitAuthoritativeStop(
                                    ownerToken = stoppedOwnerToken,
                                    timeoutMs = AUTHORITATIVE_CORE_STOP_TIMEOUT_MS,
                                )
                            },
                            releaseFrameworkService = { releaseStoppedPlatformService(mainActivity) },
                        )
                        val platformReleased = awaitStoppedPlatformServiceRelease(
                            ownerToken = stoppedOwnerToken,
                            coreStopped = coreStopped,
                        )
                        success(platformReleased)
                    }
                }
            }

            Trigger.MarkStarted.method -> {
                scope.launch {
                    result.respondCatching {
                        val accepted = BoxService.acknowledgeVerifiedRoute()
                        Log.d(TAG, "verified-route acknowledgement accepted=$accepted ${Mobile.runtimeState()}")
                        success(accepted)
                    }
                }
            }

            Trigger.GetStartedByUser.method -> {
                // Flutter and the foreground service share the same backing
                // preferences, but Dart keeps an independent cached snapshot.
                // After a cold app launch that snapshot may be stale even
                // though the native VPN session is still intentionally
                // running, so expose the service-owned value as the authority
                // for cold-attach reconciliation.
                result.success(Settings.startedByUser)
            }

            Trigger.GetServiceStatus.method -> {
                // The service owner is the lifecycle authority. Activity and
                // binder callbacks are presentation caches and can retain a
                // final Started event after a stopped service is destroyed.
                result.success(BoxService.currentPlatformStatus().name)
            }

            Trigger.MatchesActiveConfigGeneration.method -> {
                scope.launch(Dispatchers.IO) {
                    result.respondCatching {
                        val args = call.arguments as? Map<*, *>
                            ?: error("missing config identity arguments")
                        val preparedPath = args["path"] as? String
                            ?: error("missing prepared config path")
                        val fingerprint = NativeResumeConfigStore.fingerprintPlaintextFile(File(preparedPath))
                        success(BoxService.currentRuntimeConfigMatches(fingerprint))
                    }
                }
            }

            Trigger.TryBeginFlutterRestart.method -> {
                scope.launch(Dispatchers.IO) {
                    result.respondCatching {
                        if (!Settings.startedByUser) {
                            success(null)
                            return@respondCatching
                        }
                        val activity = MainActivity.instance
                        val initialStatus = activity.boundServiceStatus ?: activity.serviceStatus.value ?: Status.Stopped
                        if (initialStatus == Status.Stopped || initialStatus == Status.Stopping) {
                            success(null)
                            return@respondCatching
                        }
                        val token = ServiceLifecycleOwnership.awaitFlutterRestartLease(
                            FLUTTER_RESTART_WAIT_TIMEOUT_MS,
                        )
                        val admittedStatus = activity.boundServiceStatus ?: activity.serviceStatus.value ?: Status.Stopped
                        val admitted = token != null &&
                            admittedStatus == Status.Started &&
                            Settings.startedByUser &&
                            ServiceLifecycleOwnership.isFlutterRestartLeaseCurrent(token)
                        if (token != null && !admitted) {
                            ServiceLifecycleOwnership.releaseFlutterRestart(token)
                        }
                        success(token?.takeIf { admitted })
                    }
                }
            }

            Trigger.ValidateFlutterRestart.method -> {
                val token = (call.arguments as? Number)?.toLong()
                val activity = MainActivity.instance
                val status = activity.boundServiceStatus ?: activity.serviceStatus.value ?: Status.Stopped
                result.success(
                    token != null &&
                        status == Status.Started &&
                        Settings.startedByUser &&
                        ServiceLifecycleOwnership.isFlutterRestartLeaseCurrent(token),
                )
            }

            Trigger.ValidateVpnUserSession.method -> {
                val epoch = (call.arguments as? Number)?.toLong()
                result.success(
                    epoch != null &&
                        Settings.startedByUser &&
                        ServiceLifecycleOwnership.isUserSessionEpochCurrent(epoch),
                )
            }

            Trigger.WasVpnUserSessionExplicitlyStopped.method -> {
                val epoch = (call.arguments as? Number)?.toLong()
                result.success(
                    epoch != null &&
                        ServiceLifecycleOwnership.wasUserSessionExplicitlyStopped(epoch),
                )
            }

            Trigger.EndFlutterRestart.method -> {
                val token = (call.arguments as? Number)?.toLong()
                if (token != null) {
                    ServiceLifecycleOwnership.releaseFlutterRestart(token)
                }
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun launchLocalProbe(
        result: MethodChannel.Result,
        operation: suspend () -> Any?,
    ) {
        val replyStarted = AtomicBoolean(false)
        fun replyOnce(block: MethodChannel.Result.() -> Unit) {
            if (replyStarted.compareAndSet(false, true)) {
                result.respondCatching(block)
            }
        }

        lateinit var job: Job
        job = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
            try {
                currentCoroutineContext().ensureActive()
                val value = operation()
                currentCoroutineContext().ensureActive()
                replyOnce { success(value) }
            } catch (cancelled: CancellationException) {
                replyOnce {
                    error(
                        "local_probe_blocked",
                        "local probes are blocked during strict VPN transition",
                        null,
                    )
                }
                throw cancelled
            } catch (failure: Throwable) {
                Log.e(
                    TAG,
                    "local probe failed error_type=${failure.javaClass.simpleName}",
                )
                replyOnce {
                    error(
                        "marten_platform_error",
                        failure.message ?: "Android platform operation failed",
                        failure.javaClass.simpleName,
                    )
                }
            }
        }
        job.invokeOnCompletion { failure ->
            LocalProbeAdmission.unregister(job)
            if (failure is CancellationException) {
                replyOnce {
                    error(
                        "local_probe_blocked",
                        "local probes are blocked during strict VPN transition",
                        null,
                    )
                }
            }
        }
        val admitted = LocalProbeAdmission.register(job)
        if (!admitted) {
            job.cancel(CancellationException("local probes are blocked during strict VPN transition"))
            replyOnce {
                error(
                    "local_probe_blocked",
                    "local probes are blocked during strict VPN transition",
                    null,
                )
            }
            return
        }
        job.start()
    }

    private suspend fun cancelLocalProbes(keepBlocked: Boolean): Long {
        val blockEpoch = LocalProbeAdmission.beginBlockTransitionAndDrain()
        if (!keepBlocked) {
            allowLocalProbes(blockEpoch)
        }
        return blockEpoch
    }

    private suspend fun allowLocalProbes(blockEpoch: Long): Boolean =
        BoxService.awaitLocalProbesForCurrentState(blockEpoch)

    private fun releaseStoppedPlatformService(mainActivity: MainActivity) {
        mainActivity.disconnectServiceBinding()
        appContext.stopService(Intent(appContext, Settings.serviceClass()))
    }

    private fun storeNativeResumeConfig(
        preparedPath: String,
        profileName: String,
    ): NativeResumeConfigStore.StoredConfig =
        NativeResumeConfigPublisher.store(appContext, File(preparedPath), profileName)

    private suspend fun awaitStoppedPlatformServiceRelease(
        ownerToken: Long,
        coreStopped: Boolean,
    ): Boolean {
        if (!coreStopped) {
            Log.e(TAG, "authoritative Android core/TUN stop did not finish")
        }
        val releaseState = awaitPlatformStopRelease(
            coreStopped = coreStopped,
            timeoutMs = PLATFORM_RELEASE_TIMEOUT_MS,
            isQuiescentBoundOwner = { BoxService.isQuiescentBoundOwner(ownerToken) },
            awaitCleanupAfterStop = { timeoutMs ->
                ServiceLifecycleOwnership.awaitCleanupAfterStop(ownerToken, timeoutMs)
            },
            isOwnVpnActive = { BoxService.isOwnVpnActive(appContext) },
            pollIntervalMs = OWN_VPN_RELEASE_POLL_MS,
        )

        if (releaseState.quiescentBoundOwner) {
            Log.i(TAG, "bound Android service is already quiescent; skipping destroy-only cleanup wait")
        }

        if (isPlatformStopReleaseComplete(
                coreStopped = releaseState.coreStopped,
                cleanupFinished = releaseState.cleanupFinished,
                vpnReleased = releaseState.vpnReleased,
            )
        ) {
            Log.i(TAG, "stopped Android service cleanup and VPN network release confirmed")
            return true
        }

        if (isPlatformStopSafeForUser(
                coreStopped = releaseState.coreStopped,
                vpnReleased = releaseState.vpnReleased,
            )
        ) {
            Log.w(
                TAG,
                "Android VPN/TUN release is complete while exact native cleanup remains deferred; " +
                    "keeping the ordinary stopped UI and blocking a new start on the close barrier",
            )
            return true
        }

        Log.e(
            TAG,
            "platform stop remains fail-closed in the authoritative service owner " +
                "core_stopped=${releaseState.coreStopped} " +
                "cleanup_finished=${releaseState.cleanupFinished} " +
                "vpn_released=${releaseState.vpnReleased}",
        )
        // Do not destroy the only owner while its bounded platform cleanup is
        // still running. BoxService publishes Stopped and calls stopSelf() only
        // after the VPN/TUN release barrier is confirmed; Android lockdown
        // keeps traffic blocked in the meantime.
        return false
    }

    private fun stableDeviceId(): String? {
        val androidId = rawAndroidId() ?: return null
        val material = "marten.android.device-id.v1:${appContext.packageName}:$androidId"
        return "android-v1:${sha256Hex(material)}"
    }

    private fun subscriptionClientMetadata(): Map<String, String> = buildMap {
        rawAndroidId()?.let { put("hwid", it) }
        put("os", "Android")
        put("osVersion", Build.VERSION.RELEASE.orEmpty())
        put("model", Build.MODEL.orEmpty())
        put("locale", Locale.getDefault().language.orEmpty())
    }

    private fun rawAndroidId(): String? {
        val androidId = AndroidSettings.Secure.getString(
            appContext.contentResolver,
            AndroidSettings.Secure.ANDROID_ID,
        )?.trim()
        if (androidId.isNullOrEmpty() || androidId == "9774d56d682e549c" || androidId == "unknown") {
            return null
        }
        return androidId
    }

    private fun sha256Hex(value: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
        return digest.joinToString(separator = "") { "%02x".format(it.toInt() and 0xff) }
    }
}
