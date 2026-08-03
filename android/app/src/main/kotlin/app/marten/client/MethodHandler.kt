package app.marten.client

import android.content.Context
import android.content.Intent
import android.provider.Settings as AndroidSettings
import android.util.Log
import app.marten.client.bg.BoxService
//import app.marten.client.bg.BoxService.Companion.workingDir
import app.marten.client.bg.MobileCoreLifecycle
import app.marten.client.bg.ServiceLifecycleOwnership
import app.marten.client.bg.awaitPlatformStopRelease
import app.marten.client.bg.isPlatformStopReleaseComplete
import app.marten.client.bg.isPlatformStopSafeForUser
import app.marten.client.bg.requestAuthoritativePlatformStop
import app.marten.client.constant.Action
import app.marten.client.constant.Status
import app.marten.client.security.NativeResumeConfigStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

import app.marten.core.libbox.Libbox
import app.marten.core.mobile.Mobile
import app.marten.client.bg.Bugs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.security.MessageDigest

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

        enum class Trigger(val method: String) {
            Setup("setup"),
            Start("start"),
            Stop("stop"),
            Restart("restart"),
            MarkStarted("markStarted"),
            GetStartedByUser("get_started_by_user"),
            GetServiceStatus("get_service_status"),
            TryBeginFlutterRestart("try_begin_flutter_restart"),
            EndFlutterRestart("end_flutter_restart"),
            AddGrpcClientPublicKey("add_grpc_client_public_key"),
            GetGrpcServerPublicKey("get_grpc_server_public_key"),
            GetStableDeviceID("get_stable_device_id"),
            ICMPPing("icmp_ping"),

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
            Trigger.ICMPPing.method -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val args = call.arguments as? Map<*, *> ?: error("missing ICMP ping arguments")
                        val host = args["host"] as? String ?: error("missing ICMP ping host")
                        val timeoutMs = (args["timeoutMs"] as? Number)?.toLong() ?: 4_000L
                        success(Libbox.icmpPing(host, timeoutMs))
                    }
                }
            }

            Trigger.GetStableDeviceID.method -> {
                result.success(stableDeviceId())
            }

            Trigger.AddGrpcClientPublicKey.method -> {
                GlobalScope.launch {
                    result.runCatching {
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
                    result.runCatching {
                        result.success(Mobile.getServerPublicKey())
                    }
                }
            }

            Trigger.Setup.method -> {
                scope.launch(Dispatchers.IO) {
                    result.runCatching {
                        val args = call.arguments as Map<*, *>
                        Settings.baseDir = args["baseDir"] as String
                        Settings.workingDir = args["workingDir"] as String
                        Settings.tempDir = args["tempDir"] as String
                        Settings.debugMode = args["debug"] as Boolean? ?: false
                        val mode = args["mode"] as Int
                        val grpcPort = args["grpcPort"] as Int
                        Log.d("debugmode","${Settings.debugMode}")
                        runCatching {
                            Log.d(
                                TAG,
                                "core setup request mode=foreground debug=${Settings.debugMode} " +
                                    "service_mode=${Settings.serviceMode} platform_interface=false",
                            )
                            MobileCoreLifecycle.run {
                                Mobile.setup(
                                    Settings.baseDir,
                                    Settings.workingDir,
                                    Settings.tempDir,
                                    mode.toLong(),
                                    "127.0.0.1:$grpcPort",
                                    "",
                                    Settings.debugMode,
                                    null,
                                )
                                Log.d(
                                    TAG,
                                    "core setup complete mode=foreground platform_interface=false ${Mobile.runtimeState()}",
                                )

//                                Libbox.setup(Settings.baseDir, Settings.workingDir, Settings.tempDir, false)
                                Libbox.redirectStderr("/dev/null")
                            }

                            success("")
                        }.onFailure {
                            error(it)
                        }

                    }
                }
            }


            Trigger.Start.method -> {
                scope.launch {
                    result.runCatching {
                        val args = call.arguments as Map<*, *>
                        val preparedPath = args["path"] as String? ?: ""
                        val stored = NativeResumeConfigStore.storeFromPlaintextFile(appContext, File(preparedPath))
                        Settings.activeConfigPath = stored.encryptedPath
                        Settings.activeConfigUsesTurncoat = stored.usesTurncoat
                        Settings.activeProfileName = args["name"] as String? ?: ""
                        Settings.debugMode = args["debug"] as Boolean? ?: false
                        Settings.grpcServiceModePort = args["grpcPort"] as Int
                        // The foreground/background gRPC services are long-lived.
                        // Refresh native diagnostic mode before Flutter or the
                        // service-owned recovery path constructs the next core.
                        Mobile.setDebug(Settings.debugMode)

                        val mainActivity = MainActivity.instance
//                        val started = mainActivity.serviceStatus.value == Status.Started
//                        if (started) {
//                            Log.w(TAG, "service is already running")
//                            return@launch success(true)
//                        }
                        Settings.startCoreAfterStartingService = false

                        mainActivity.startService()
                        success(true)
                    }
                }
            }

            Trigger.Stop.method -> {
                scope.launch {
                    result.runCatching {
                        Settings.startedByUser = false
                        Settings.startCoreAfterStartingService = false
                        NativeResumeConfigStore.cleanupPlaintextLeases(appContext)
                        val mainActivity = MainActivity.instance
                        val initialStatus = mainActivity.serviceStatus.value
                        val initialBoundStatus = mainActivity.boundServiceStatus
                        // Wait for the BoxService that can actually receive this
                        // stop. The global latest token can briefly belong to a
                        // constructed/replaced instance that is not active.
                        val stoppedOwnerToken = BoxService.currentActiveOwnerToken() ?: 0L
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
                            return@runCatching
                        }
                        // Core/TUN shutdown is authoritative and coalesced inside
                        // BoxService. Keep the Activity binding until the exact
                        // service owner acknowledges that shutdown; otherwise a
                        // Quick Settings-started service can be destroyed while
                        // its asynchronous stop command is still being admitted.
                        val coreStopped = requestAuthoritativePlatformStop(
                            requestCoreStop = BoxService::stop,
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
                    result.runCatching {
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

            Trigger.TryBeginFlutterRestart.method -> {
                val activity = MainActivity.instance
                val initialStatus = activity.boundServiceStatus ?: activity.serviceStatus.value ?: Status.Stopped
                if (initialStatus != Status.Started) {
                    result.success(null)
                    return
                }
                val token = ServiceLifecycleOwnership.tryAcquireFlutterRestart()
                val admittedStatus = activity.boundServiceStatus ?: activity.serviceStatus.value ?: Status.Stopped
                if (token != null && admittedStatus != Status.Started) {
                    ServiceLifecycleOwnership.releaseFlutterRestart(token)
                    result.success(null)
                } else {
                    result.success(token)
                }
            }

            Trigger.EndFlutterRestart.method -> {
                val token = (call.arguments as? Number)?.toLong()
                if (token != null) {
                    ServiceLifecycleOwnership.releaseFlutterRestart(token)
                }
                result.success(null)
            }

//            Trigger.Restart.method -> {
//                scope.launch(Dispatchers.IO) {
//                    result.runCatching {
//                        val args = call.arguments as Map<*, *>
//                        Settings.activeConfigPath = args["path"] as String? ?: ""
//                        Settings.activeProfileName = args["name"] as String? ?: ""
//                        val mainActivity = MainActivity.instance
//                        val started = mainActivity.serviceStatus.value == Status.Started
//                        if (!started) return@launch success(true)
//                        val restart = Settings.rebuildServiceMode()
//                        if (restart) {
//                            mainActivity.reconnect()
//                            BoxService.stop()
//                            delay(1000L)
//                            mainActivity.startService()
//                            return@launch success(true)
//                        }
//                        runCatching {
//                            Libbox.newStandaloneCommandClient().serviceReload()
//                            success(true)
//                        }.onFailure {
//                            error(it)
//                        }
//                    }
//                }
//            }

            else -> result.notImplemented()
        }
    }

    private fun releaseStoppedPlatformService(mainActivity: MainActivity) {
        mainActivity.disconnectServiceBinding()
        appContext.stopService(Intent(appContext, Settings.serviceClass()))
    }

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
                cleanupFinished = releaseState.cleanupFinished,
            )
        ) {
            Log.w(
                TAG,
                "Android framework VPN release is deferred after completed core/TUN stop; " +
                    "keeping the ordinary stopped UI while service-only teardown finishes",
            )
            return true
        }

        Log.e(
            TAG,
            "platform stop remains fail-closed without replacing the visible application " +
                "core_stopped=${releaseState.coreStopped} " +
                "cleanup_finished=${releaseState.cleanupFinished} " +
                "vpn_released=${releaseState.vpnReleased}",
        )
        if (!Settings.persistStoppedState()) {
            Log.e(TAG, "failed to persist stopped state after incomplete platform cleanup")
        }
        appContext.stopService(Intent(appContext, Settings.serviceClass()))
        return false
    }

    private fun stableDeviceId(): String? {
        val androidId = AndroidSettings.Secure.getString(
            appContext.contentResolver,
            AndroidSettings.Secure.ANDROID_ID,
        )?.trim()
        if (androidId.isNullOrEmpty() || androidId == "9774d56d682e549c" || androidId == "unknown") {
            return null
        }
        val material = "marten.android.device-id.v1:${appContext.packageName}:$androidId"
        return "android-v1:${sha256Hex(material)}"
    }

    private fun sha256Hex(value: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
        return digest.joinToString(separator = "") { "%02x".format(it.toInt() and 0xff) }
    }
}
