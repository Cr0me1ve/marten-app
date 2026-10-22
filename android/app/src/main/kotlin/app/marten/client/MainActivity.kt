package app.marten.client

import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.lifecycleScope
import app.marten.client.bg.BoxService
import app.marten.client.bg.ServiceConnection
import app.marten.client.bg.ServiceLifecycleOwnership
import app.marten.client.constant.Action
import app.marten.client.constant.Alert
import app.marten.client.constant.ServiceMode
import app.marten.client.constant.Status
import app.marten.client.crashreporting.NativeCrashDiagnostics
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
import io.flutter.plugin.common.MethodChannel
import app.marten.client.bg.EnergyProfileClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext


class MainActivity : FlutterFragmentActivity(), ServiceConnection.Callback {
    companion object {
        private const val TAG = "ANDROID/MyActivity"
        lateinit var instance: MainActivity

        const val VPN_PERMISSION_REQUEST_CODE = 1001
    }

    private val connection = ServiceConnection(this, this)
    private var pendingStartConfigFingerprint: String? = null
    private var pendingStartConfigUsesTurncoat: Boolean? = null
    private var pendingStartSessionEpoch: Long? = null
    private var pendingStrictVpnPermission: CompletableDeferred<Boolean>? = null
    @Volatile
    private var servicePresentationActive = true

    val serviceStatus = MutableLiveData(Status.Stopped)
    val serviceAlerts = MutableLiveData<ServiceEvent?>(null)
    val boundServiceStatus get() = connection.currentStatus

    // SurfaceView destroys its rendering surface on window visibility changes.
    // On Android 16 that path has blocked Flutter's main thread while hiding
    // Marten. A TextureView retains its surface through ordinary visibility
    // changes; engine teardown still happens on the normal detach lifecycle.
    override fun getRenderMode(): RenderMode = RenderMode.texture

    override fun onCreate(savedInstanceState: Bundle?) {
        Application.logStartupPhase("activity_on_create_start")
        // Cached Flutter engines do not guarantee a new plugin configuration
        // pass. Publish the visible Activity before super attaches the engine.
        instance = this
        if (BuildConfig.ENERGY_DIAGNOSTICS) {
            // Configure the bounded ring before VM creation. Runtime setFlag
            // cannot resize it; the default buffer retains only ~4 seconds.
            intent.putExtra("enable-dart-profiling",true)
            intent.putExtra("dart-flags", "--profile_period=10000,--sample-buffer-duration=600,--max_profile_depth=64")
        }
        super.onCreate(savedInstanceState)
        runCatching { ShortcutActivity.publishAuthenticatedDynamicShortcut(this) }.onFailure {
            Log.w(TAG, "failed to publish authenticated VPN toggle shortcut", it)
        }
        Application.logStartupPhase("activity_on_create_end")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        Application.logStartupPhase("flutter_engine_configure_start")
        super.configureFlutterEngine(flutterEngine)
        if (BuildConfig.ENERGY_DIAGNOSTICS) {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.marten/energy_profiler").setMethodCallHandler { call, result ->
                if (call.method == "registerVm" && call.arguments is String) {
                    EnergyProfileClient.registerVm(applicationContext, call.arguments as String)
                    result.success(null)
                } else result.notImplemented()
            }
        }
        reconnect()
        flutterEngine.plugins.add(MethodHandler(lifecycleScope))
        flutterEngine.plugins.add(PlatformSettingsHandler())
        flutterEngine.plugins.add(EventHandler())
        val renderer = flutterEngine.renderer
        renderer.addIsDisplayingFlutterUiListener(
            object : FlutterUiDisplayListener {
                override fun onFlutterUiDisplayed() {
                    Application.logStartupPhase("flutter_ui_displayed")
                    renderer.removeIsDisplayingFlutterUiListener(this)
                }

                override fun onFlutterUiNoLongerDisplayed() = Unit
            },
        )
        Application.logStartupPhase("flutter_engine_configure_end")
//        flutterEngine.plugins.add(GroupsChannel(lifecycleScope))
//        flutterEngine.plugins.add(ActiveGroupsChannel(lifecycleScope))
//        flutterEngine.plugins.add(StatsChannel(lifecycleScope))
    }

    fun reconnect() {
        if (servicePresentationActive) connection.reconnect()
    }

    private fun connectServicePresentation() {
        if (servicePresentationActive) connection.connect()
    }

    /**
     * Re-attaches the Activity presentation to the process-owned service.
     *
     * A manual stop deliberately releases the old binding. If Quick Settings
     * starts a new generation while the Flutter engine is retained, engine
     * configuration does not run again, so every foreground attach must seed
     * the cache from the service owner and restore the callback stream.
     */
    fun restoreServicePresentation() {
        serviceStatus.value = BoxService.currentPlatformStatus()
        connectServicePresentation()
    }

    fun disconnectServiceBinding() {
        connection.disconnect()
    }

    fun startService(
        configFingerprint: String? = null,
        configUsesTurncoat: Boolean? = null,
        userSessionEpoch: Long,
    ) {
        pendingStartConfigFingerprint = configFingerprint
        pendingStartConfigUsesTurncoat = configUsesTurncoat.takeIf { configFingerprint != null }
        pendingStartSessionEpoch = userSessionEpoch
        startService0()
    }

    private fun startService0() {
        val requestedConfigFingerprint = pendingStartConfigFingerprint
        val requestedConfigUsesTurncoat = pendingStartConfigUsesTurncoat
        val requestedSessionEpoch = pendingStartSessionEpoch
        if (requestedSessionEpoch == null) {
            Log.w(TAG, "rejecting Android service start without an admitted user-session epoch")
            clearPendingStartConfigIdentity()
            return
        }
        lifecycleScope.launch(Dispatchers.IO) {
            if (Settings.rebuildServiceMode()) {
                withContext(Dispatchers.Main) {
                    reconnect()
                }
            }
            if (Settings.serviceMode == ServiceMode.VPN) {
                if (prepare()) {
                    return@launch
                }
            }
            val intent = Intent(Application.application, Settings.serviceClass())
                .putExtra(Action.EXTRA_USER_INITIATED, true)
                .putExtra(Action.EXTRA_USER_SESSION_EPOCH, requestedSessionEpoch)
            if (requestedConfigFingerprint != null) {
                intent.putExtra(Action.EXTRA_CONFIG_FINGERPRINT, requestedConfigFingerprint)
                intent.putExtra(
                    Action.EXTRA_CONFIG_USES_TURNCOAT,
                    requestedConfigUsesTurncoat ?: Settings.activeConfigUsesTurncoat,
                )
            }
            try {
                var serviceDispatched = false
                val epochWasCurrent = withContext(Dispatchers.Main) {
                    ServiceLifecycleOwnership.runIfUserSessionEpochCurrent(requestedSessionEpoch) {
                        // Admission already persisted the new user intent. Do
                        // not write it again here: a Stop that advanced the
                        // epoch must remain authoritative while a VPN-permission
                        // callback or stale Flutter coroutine resumes.
                        if (!Settings.startedByUser) {
                            Log.i(TAG, "discarding Android service dispatch after durable user intent stopped")
                            return@runIfUserSessionEpochCurrent
                        }
                        NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)
                        connectServicePresentation()
                        ContextCompat.startForegroundService(this@MainActivity, intent)
                        serviceDispatched = true
                    }
                }
                if (!epochWasCurrent || !serviceDispatched) {
                    Log.i(TAG, "discarding Android service dispatch superseded by terminal Stop")
                }
            } finally {
                if (
                    pendingStartSessionEpoch == requestedSessionEpoch &&
                    pendingStartConfigFingerprint == requestedConfigFingerprint
                ) {
                    clearPendingStartConfigIdentity()
                }
            }
        }
    }

    private suspend fun prepare() = withContext(Dispatchers.Main) {
        try {
            val intent = VpnService.prepare(this@MainActivity)
            if (intent != null) {
                prepareLauncher.launch(intent)
                true
            } else {
                false
            }
        } catch (e: Exception) {
            clearPendingStartConfigIdentity()
            onServiceAlert(Alert.RequestVPNPermission, e.message)
            true
        }
    }

    /**
     * Resolves Android's user-mediated VPN permission before the strict
     * fail-closed admission transaction starts. A persisted session never
     * opens a permission UI during bootstrap: revoked permission is a terminal
     * admission failure and optional networking remains disabled.
     */
    suspend fun awaitStrictVpnPermission(allowPrompt: Boolean): Boolean {
        val pending = withContext(Dispatchers.Main.immediate) {
            val permissionIntent = VpnService.prepare(this@MainActivity)
            if (permissionIntent == null) {
                return@withContext null
            }
            if (!allowPrompt) {
                return@withContext CompletableDeferred(false)
            }
            pendingStrictVpnPermission?.takeIf { it.isActive }
                ?: CompletableDeferred<Boolean>().also {
                    pendingStrictVpnPermission = it
                    prepareLauncher.launch(permissionIntent)
                }
        }
        return pending?.await() ?: true
    }

    private val prepareLauncher =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            val strictPermission = pendingStrictVpnPermission
            if (strictPermission != null) {
                pendingStrictVpnPermission = null
                strictPermission.complete(result.resultCode == RESULT_OK)
                if (result.resultCode != RESULT_OK) {
                    onServiceAlert(Alert.RequestVPNPermission, null)
                }
                return@registerForActivityResult
            }
            if (result.resultCode == RESULT_OK) {
                startService0()
            } else {
                clearPendingStartConfigIdentity()
                onServiceAlert(Alert.RequestVPNPermission, null)
            }
        }

    private fun clearPendingStartConfigIdentity() {
        pendingStartConfigFingerprint = null
        pendingStartConfigUsesTurncoat = null
        pendingStartSessionEpoch = null
    }

    override fun onServiceStatusChanged(status: Status) {
        serviceStatus.postValue(status)
    }

    override fun onServiceAlert(type: Alert, message: String?) {
        serviceAlerts.postValue(ServiceEvent(Status.Stopped, type, message))
    }

    override fun onStart() {
        super.onStart()
        servicePresentationActive = true
        NativeConnectRequestBridge.onForegroundPresentationStarted()
        restoreServicePresentation()
    }

    override fun onResume() {
        super.onResume()
        // Notification shade / Quick Settings can pause without stopping the
        // Activity. connect() is idempotent, so resume closes that lifecycle
        // gap without replacing a healthy binding.
        restoreServicePresentation()
    }

    override fun onStop() {
        // The binding is presentation-only. The service remains the process
        // owner while a stopped Activity must not receive log/status Binder
        // callbacks or enqueue work on Flutter's UI thread.
        NativeConnectRequestBridge.onForegroundPresentationStopped()
        servicePresentationActive = false
        connection.disconnect()
        super.onStop()
    }

    override fun onDestroy() {
        NativeConnectRequestBridge.onForegroundPresentationStopped()
        connection.disconnect()
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                startService0()
            } else {
                clearPendingStartConfigIdentity()
                onServiceAlert(Alert.RequestVPNPermission, null)
            }
        }
    }
}
