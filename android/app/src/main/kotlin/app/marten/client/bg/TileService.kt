package app.marten.client.bg

import android.app.KeyguardManager
import android.content.ComponentName
import android.content.Context
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService as AndroidTileService
import androidx.annotation.RequiresApi
import app.marten.client.Settings
import app.marten.client.VpnPermissionActivity
import app.marten.client.constant.ServiceMode
import app.marten.client.constant.Status

@RequiresApi(24)
class TileService : AndroidTileService(), ServiceConnection.Callback {

    companion object {
        private val requestStateUpdateLock = Any()

        @Volatile
        private var lastRequestedStatus: Status? = null

        internal fun quickSettingsPendingIntentRequestCode(requestId: Long): Int =
            (requestId and 0x3fff_ffffL).toInt() or 0x4000_0000

        fun requestStateUpdate(context: Context, status: Status) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
            val shouldRequest = synchronized(requestStateUpdateLock) {
                if (lastRequestedStatus == status) {
                    false
                } else {
                    lastRequestedStatus = status
                    true
                }
            }
            if (!shouldRequest) return

            runCatching {
                AndroidTileService.requestListeningState(
                    context.applicationContext,
                    ComponentName(context, TileService::class.java),
                )
            }.onFailure {
                synchronized(requestStateUpdateLock) {
                    if (lastRequestedStatus == status) {
                        lastRequestedStatus = null
                    }
                }
            }
        }
    }

    private val connection = ServiceConnection(this, this)
    private var latestRequestId = 0L
    private var pendingToggleRequestId: Long? = null
    private var listening = false

    override fun onServiceStatusChanged(status: Status) {
        QuickSettingsDiagnostics.record(
            this,
            component = "tile",
            event = "status",
            requestId = latestRequestId,
            outcome = "observed",
            status = status,
        )
        qsTile?.apply {
            state =
                when (status) {
                    Status.Started -> Tile.STATE_ACTIVE
                    Status.Stopped -> Tile.STATE_INACTIVE
                    // Android renders UNAVAILABLE as a disabled grey tile.
                    // Lifecycle transitions own their exact command until a
                    // stable state arrives, so a tap cannot replace that intent.
                    Status.Starting, Status.Stopping -> Tile.STATE_UNAVAILABLE
                }
            updateTile()
        }

        val pendingRequestId = pendingToggleRequestId ?: return
        pendingToggleRequestId = null
        QuickSettingsDiagnostics.record(
            this,
            component = "tile",
            event = "status_ready",
            requestId = pendingRequestId,
            outcome = "resumed",
            status = status,
        )
        toggleService(pendingRequestId, status)
        if (!listening) connection.disconnect()
    }

    override fun onServiceBindingFailed() {
        val requestId = pendingToggleRequestId
        pendingToggleRequestId = null
        if (requestId != null) QuickSettingsDiagnostics.record(
            this, component = "tile", event = "status_binding", requestId = requestId, outcome = "failed",
        )
        qsTile?.apply { state = Tile.STATE_UNAVAILABLE; updateTile() }
        if (!listening) connection.disconnect()
    }

    override fun onStartListening() {
        super.onStartListening()
        listening = true
        QuickSettingsDiagnostics.record(
            this,
            component = "tile",
            event = "listening",
            requestId = latestRequestId,
            outcome = "started",
            status = connection.status,
        )
        connection.connect()
    }

    override fun onStopListening() {
        listening = false
        if (pendingToggleRequestId == null) connection.disconnect()
        super.onStopListening()
    }

    override fun onDestroy() {
        pendingToggleRequestId = null
        connection.disconnect()
        super.onDestroy()
    }

    private fun toggleWhenStatusKnown(requestId: Long) {
        val currentStatus = connection.currentStatus
        if (currentStatus != null) {
            toggleService(requestId, currentStatus)
            return
        }
        if (pendingToggleRequestId != null) {
            QuickSettingsDiagnostics.record(
                this,
                component = "tile",
                event = "toggle",
                requestId = requestId,
                outcome = "duplicate_pending",
            )
            return
        }
        pendingToggleRequestId = requestId
        QuickSettingsDiagnostics.record(
            this,
            component = "tile",
            event = "toggle",
            requestId = requestId,
            outcome = "status_pending",
        )
        connection.connect()
    }

    private fun toggleService(requestId: Long, status: Status) {
        when (status) {
            Status.Stopped -> {
                QuickSettingsDiagnostics.record(
                    this,
                    component = "tile",
                    event = "connect",
                    requestId = requestId,
                    outcome = "accepted",
                    status = status,
                )
                qsTile?.apply {
                    state = Tile.STATE_UNAVAILABLE
                    updateTile()
                }
                requestUserConnect(requestId)
            }
            Status.Started -> {
                QuickSettingsDiagnostics.record(
                    this,
                    component = "tile",
                    event = "stop",
                    requestId = requestId,
                    outcome = "accepted",
                    status = status,
                )
                qsTile?.apply {
                    state = Tile.STATE_UNAVAILABLE
                    updateTile()
                }
                BoxService.stop(quickSettingsRequestId = requestId)
            }
            Status.Starting, Status.Stopping -> {
                QuickSettingsDiagnostics.record(
                    this,
                    component = "tile",
                    event = "toggle",
                    requestId = requestId,
                    outcome = "ignored_transition",
                    status = status,
                )
                qsTile?.apply {
                    state = Tile.STATE_UNAVAILABLE
                    updateTile()
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun requestUserConnect(requestId: Long) {
        val permissionIntent = if (Settings.serviceMode == ServiceMode.VPN) {
            val prepareResult = runCatching { VpnService.prepare(applicationContext) }
            if (prepareResult.isFailure) {
                QuickSettingsDiagnostics.record(
                    this,
                    component = "tile",
                    event = "vpn_prepare",
                    requestId = requestId,
                    outcome = "failed",
                    status = connection.currentStatus,
                )
                qsTile?.apply {
                    state = Tile.STATE_INACTIVE
                    updateTile()
                }
                return
            }
            prepareResult.getOrNull()
        } else {
            null
        }

        if (permissionIntent == null) {
            QuickSettingsDiagnostics.record(
                this,
                component = "tile",
                event = "vpn_prepare",
                requestId = requestId,
                outcome = if (Settings.serviceMode == ServiceMode.VPN) {
                    "already_granted_direct_service"
                } else {
                    "not_required_direct_service"
                },
                status = connection.currentStatus,
            )
            BoxService.connect(
                userInitiated = true,
                quickSettingsRequestId = requestId,
                entrySource = VpnPermissionActivity.SOURCE_QUICK_SETTINGS,
            )
            return
        }

        QuickSettingsDiagnostics.record(
            this,
            component = "tile",
            event = "vpn_prepare",
            requestId = requestId,
            outcome = "prompt_required",
            status = connection.currentStatus,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                VpnPermissionActivity.pendingIntent(
                    context = this,
                    requestCode = quickSettingsPendingIntentRequestCode(requestId),
                    source = VpnPermissionActivity.SOURCE_QUICK_SETTINGS,
                    requestId = requestId,
                    oneShot = true,
                ),
            )
        } else {
            startActivityAndCollapse(
                VpnPermissionActivity.createIntent(
                    context = this,
                    source = VpnPermissionActivity.SOURCE_QUICK_SETTINGS,
                    requestId = requestId,
                ),
            )
        }
    }

    override fun onClick() {
        super.onClick()
        val requestId = QuickSettingsDiagnostics.nextRequestId()
        latestRequestId = requestId
        val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (keyguardManager.isKeyguardLocked) {
            QuickSettingsDiagnostics.record(
                this,
                component = "tile",
                event = "click",
                requestId = requestId,
                outcome = "unlock_pending",
                status = connection.currentStatus,
            )
            unlockAndRun {
                QuickSettingsDiagnostics.record(
                    this,
                    component = "tile",
                    event = "unlock",
                    requestId = requestId,
                    outcome = "completed",
                    status = connection.currentStatus,
                )
                toggleWhenStatusKnown(requestId)
            }
        } else {
            QuickSettingsDiagnostics.record(
                this,
                component = "tile",
                event = "click",
                requestId = requestId,
                outcome = "accepted",
                status = connection.currentStatus,
            )
            toggleWhenStatusKnown(requestId)
        }
    }

}
