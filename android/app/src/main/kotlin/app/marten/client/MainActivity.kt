package app.marten.client

import android.annotation.SuppressLint
import android.content.Intent
import android.Manifest
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.lifecycleScope
import app.marten.client.bg.BoxService
import app.marten.client.bg.ServiceConnection
import app.marten.client.bg.ServiceNotification
import app.marten.client.constant.Action
import app.marten.client.constant.Alert
import app.marten.client.constant.ServiceMode
import app.marten.client.constant.Status
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.LinkedList


class MainActivity : FlutterFragmentActivity(), ServiceConnection.Callback {
    companion object {
        private const val TAG = "ANDROID/MyActivity"
        lateinit var instance: MainActivity

        const val VPN_PERMISSION_REQUEST_CODE = 1001
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1010
    }

    private val connection = ServiceConnection(this, this)
    private var pendingStartConfigFingerprint: String? = null
    private var pendingStartConfigUsesTurncoat: Boolean? = null

    val logList = LinkedList<String>()
    var logCallback: ((Boolean) -> Unit)? = null
    val serviceStatus = MutableLiveData(Status.Stopped)
    val serviceAlerts = MutableLiveData<ServiceEvent?>(null)
    val boundServiceStatus get() = connection.currentStatus

    override fun onCreate(savedInstanceState: Bundle?) {
        Application.logStartupPhase("activity_on_create_start")
        // Cached Flutter engines do not guarantee a new plugin configuration
        // pass. Publish the visible Activity before super attaches the engine.
        instance = this
        super.onCreate(savedInstanceState)
        Application.logStartupPhase("activity_on_create_end")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        Application.logStartupPhase("flutter_engine_configure_start")
        super.configureFlutterEngine(flutterEngine)
        reconnect()
        flutterEngine.plugins.add(MethodHandler(lifecycleScope))
        flutterEngine.plugins.add(PlatformSettingsHandler())
        flutterEngine.plugins.add(EventHandler())
        flutterEngine.plugins.add(LogHandler())
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
        connection.reconnect()
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
        connection.connect()
    }

    fun disconnectServiceBinding() {
        connection.disconnect()
    }

    @SuppressLint("NewApi")
    fun startService(configFingerprint: String? = null, configUsesTurncoat: Boolean? = null) {
        pendingStartConfigFingerprint = configFingerprint
        pendingStartConfigUsesTurncoat = configUsesTurncoat.takeIf { configFingerprint != null }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !ServiceNotification.checkPermission()) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        startService0()
    }

    private fun startService0() {
        val requestedConfigFingerprint = pendingStartConfigFingerprint
        val requestedConfigUsesTurncoat = pendingStartConfigUsesTurncoat
        lifecycleScope.launch(Dispatchers.IO) {
            if (Settings.rebuildServiceMode()) {
                withContext(Dispatchers.Main) {
                    connection.reconnect()
                }
            }
            if (Settings.serviceMode == ServiceMode.VPN) {
                if (prepare()) {
                    return@launch
                }
            }
            val intent = Intent(Application.application, Settings.serviceClass())
                .putExtra(Action.EXTRA_USER_INITIATED, true)
            if (requestedConfigFingerprint != null) {
                intent.putExtra(Action.EXTRA_CONFIG_FINGERPRINT, requestedConfigFingerprint)
                intent.putExtra(
                    Action.EXTRA_CONFIG_USES_TURNCOAT,
                    requestedConfigUsesTurncoat ?: Settings.activeConfigUsesTurncoat,
                )
            }
            try {
                withContext(Dispatchers.Main) {
                    connection.connect()
                    ContextCompat.startForegroundService(this@MainActivity, intent)
                }
                Settings.startedByUser = true
            } finally {
                if (pendingStartConfigFingerprint == requestedConfigFingerprint) {
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
    private val notificationPermissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestPermission(),
        ) { isGranted ->
            if (Settings.dynamicNotification && !isGranted) {
                clearPendingStartConfigIdentity()
                onServiceAlert(Alert.RequestNotificationPermission, null)
            } else {
                startService0()
            }
        }

    private val prepareLauncher =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
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
    }

    override fun onServiceStatusChanged(status: Status) {
        serviceStatus.postValue(status)
    }

    override fun onServiceAlert(type: Alert, message: String?) {
        serviceAlerts.postValue(ServiceEvent(Status.Stopped, type, message))
    }

    override fun onServiceWriteLog(message: String?) {
        if (message.isNullOrBlank()) return
        runOnUiThread {
            logList.add(message)
            while (logList.size > 1000) {
                logList.removeFirst()
            }
            logCallback?.invoke(true)
        }
    }

    override fun onServiceResetLogs(messages: List<String?>?) {
        runOnUiThread {
            logList.clear()
            messages.orEmpty().filterNotNull().filter { it.isNotBlank() }.forEach {
                logList.add(it)
            }
            while (logList.size > 1000) {
                logList.removeFirst()
            }
            logCallback?.invoke(true)
        }
    }




    override fun onStart() {
        super.onStart()
        restoreServicePresentation()
    }

    override fun onResume() {
        super.onResume()
        // Notification shade / Quick Settings can pause without stopping the
        // Activity. connect() is idempotent, so resume closes that lifecycle
        // gap without replacing a healthy binding.
        restoreServicePresentation()
    }

    override fun onDestroy() {
        connection.disconnect()
        super.onDestroy()
    }

    @SuppressLint("NewApi")
    private fun grantNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST_CODE
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startService0()
            } else {
                clearPendingStartConfigIdentity()
                onServiceAlert(Alert.RequestNotificationPermission, null)
            }
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
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
        } else if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                startService0()
            } else {
                clearPendingStartConfigIdentity()
                onServiceAlert(Alert.RequestNotificationPermission, null)
            }
        }
    }
}
