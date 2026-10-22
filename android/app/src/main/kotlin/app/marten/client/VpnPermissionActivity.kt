package app.marten.client

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.util.Log
import app.marten.client.bg.BoxService
import app.marten.client.bg.QuickSettingsDiagnostics
import app.marten.client.bg.ServiceLifecycleOwnership
import app.marten.client.constant.Action
import app.marten.client.constant.ServiceMode
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * User-gesture bridge for entry points that do not already own an Activity.
 *
 * VpnService.prepare() is Android's authoritative, user-mediated transfer of
 * the single VPN slot. Boot, sticky restart and recovery never enter here.
 */
class VpnPermissionActivity : Activity() {
    private data class FlutterPermissionHostState(
        val vpnPermission: CompletableDeferred<Boolean>?,
    )

    companion object {
        private const val TAG = "VpnPermissionActivity"
        private const val VPN_PERMISSION_REQUEST_CODE = 1
        private const val STATE_EXPLICIT_START_LEASE = "explicit_start_lease"
        const val SOURCE_QUICK_SETTINGS = "quick_settings"
        const val SOURCE_SHORTCUT = "shortcut"
        const val SOURCE_NOTIFICATION = "notification"

        @Volatile
        private var activeFlutterPermissionHost: VpnPermissionActivity? = null
        @Volatile
        private var activePermissionActivity: VpnPermissionActivity? = null

        suspend fun awaitStrictVpnPermission(allowPrompt: Boolean): Boolean? {
            val pending = withContext(Dispatchers.Main.immediate) {
                activeFlutterPermissionHost
                    ?.takeIf(VpnPermissionActivity::canHostFlutterPermission)
                    ?.beginStrictVpnPermission(allowPrompt)
            } ?: return null
            return pending.await()
        }

        internal fun completeSatisfiedFlutterHandoff(source: String, requestId: Long) {
            val host = activeFlutterPermissionHost ?: return
            host.runOnUiThread {
                if (
                    activeFlutterPermissionHost === host &&
                    host.canHostFlutterPermission() &&
                    host.entrySource == source &&
                    host.nativeHandoffRequestId == requestId
                ) {
                    host.recordQuickSettings(
                        event = "service_connect",
                        outcome = "already_satisfied_host_finished",
                    )
                    host.finishFlutterPermissionHost(granted = true)
                }
            }
        }

        fun createIntent(
            context: Context,
            source: String = "unknown",
            requestId: Long = 0L,
        ): Intent = Intent(context, VpnPermissionActivity::class.java).apply {
            putExtra(Action.EXTRA_ENTRY_SOURCE, source)
            putExtra(Action.EXTRA_REQUEST_ID, requestId)
        }

        fun pendingIntent(
            context: Context,
            requestCode: Int,
            source: String = "unknown",
            requestId: Long = 0L,
            oneShot: Boolean = false,
        ): PendingIntent {
            val lifecycleFlags = if (oneShot) {
                PendingIntent.FLAG_ONE_SHOT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val flags =
                lifecycleFlags or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        PendingIntent.FLAG_IMMUTABLE
                    } else {
                        0
                    }
            return PendingIntent.getActivity(
                context,
                requestCode,
                createIntent(context, source, requestId),
                flags,
            )
        }
    }

    private val entrySource: String
        get() = intent?.getStringExtra(Action.EXTRA_ENTRY_SOURCE).orEmpty()
    private val entryRequestId: Long
        get() = intent?.getLongExtra(Action.EXTRA_REQUEST_ID, 0L) ?: 0L
    private val isQuickSettingsEntry: Boolean
        get() = entrySource == SOURCE_QUICK_SETTINGS
    private val nativeHandoffRequestId: Long
        get() = entryRequestId.takeIf { isQuickSettingsEntry } ?: 0L
    private var explicitStartLease: Long? = null
    private var flutterHandoffPending = false
    private var pendingStrictVpnPermission: CompletableDeferred<Boolean>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        recordQuickSettings(event = "permission_activity", outcome = if (savedInstanceState == null) "created" else "restored")
        if (savedInstanceState == null) {
            val existingHost = activePermissionActivity
            if (
                existingHost != null &&
                existingHost !== this &&
                existingHost.canCoalescePermissionRequest()
            ) {
                recordQuickSettings(event = "permission_activity", outcome = "coalesced_with_active_host")
                finish()
                return
            }
        }
        activePermissionActivity = this
        if (savedInstanceState == null) {
            explicitStartLease = ServiceLifecycleOwnership.issueExplicitStartLease()
            // A live Flutter isolate may own physical HTTP/DNS sockets. Hand
            // the gesture to its strict-egress gate before even asking Android
            // for VPN permission; Dart then owns the permission prompt through
            // beginVpnStartAdmission after all ordinary sockets are drained.
            // The exact lease is captured first, so a concurrent Stop wins.
            when (handOffExplicitLeaseToLiveFlutter()) {
                NativeConnectDispatchResult.FLUTTER_HANDOFF -> {
                    explicitStartLease = null
                    flutterHandoffPending = true
                    activeFlutterPermissionHost = this
                    recordQuickSettings(event = "service_connect", outcome = "flutter_handoff_waiting_for_vpn_prepare")
                    return
                }

                NativeConnectDispatchResult.REJECTED -> {
                    explicitStartLease = null
                    recordQuickSettings(event = "service_connect", outcome = "stale_lease_before_vpn_prepare")
                    finish()
                    return
                }

                NativeConnectDispatchResult.NO_ENGINE -> Unit
                NativeConnectDispatchResult.NATIVE_STARTED -> error(
                    "permission Activity cannot start native service before VPN preparation",
                )
            }
            requestVpnOwnership()
        } else {
            val retainedFlutterHost = lastNonConfigurationInstance as? FlutterPermissionHostState
            if (retainedFlutterHost != null) {
                flutterHandoffPending = true
                pendingStrictVpnPermission = retainedFlutterHost.vpnPermission
                activeFlutterPermissionHost = this
                recordQuickSettings(
                    event = "permission_activity",
                    outcome = "flutter_handoff_host_restored",
                )
                return
            }
            val restoredLease = savedInstanceState.getLong(STATE_EXPLICIT_START_LEASE, 0L)
                .takeIf { it > 0L }
            if (
                restoredLease == null ||
                !ServiceLifecycleOwnership.isExplicitStartLeaseCurrent(restoredLease)
            ) {
                recordQuickSettings(event = "vpn_prepare", outcome = "restored_stale_lease")
                finish()
                return
            }
            explicitStartLease = restoredLease
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        explicitStartLease?.let { outState.putLong(STATE_EXPLICIT_START_LEASE, it) }
        super.onSaveInstanceState(outState)
    }

    override fun onRetainNonConfigurationInstance(): Any? =
        if (flutterHandoffPending) {
            FlutterPermissionHostState(
                vpnPermission = pendingStrictVpnPermission,
            )
        } else {
            super.onRetainNonConfigurationInstance()
        }

    override fun onNewIntent(newIntent: Intent) {
        super.onNewIntent(newIntent)
        // An Activity already owns either one exact native lease or the
        // Flutter handoff derived from it. A second tile/shortcut tap must not
        // replace its source/request identity or open another permission flow.
        recordQuickSettings(
            event = "permission_activity",
            outcome = "coalesced_with_active_host",
            source = newIntent.getStringExtra(Action.EXTRA_ENTRY_SOURCE).orEmpty(),
            requestId = newIntent.getLongExtra(Action.EXTRA_REQUEST_ID, 0L),
        )
    }

    override fun onDestroy() {
        if (activePermissionActivity === this) activePermissionActivity = null
        if (activeFlutterPermissionHost === this) activeFlutterPermissionHost = null
        val transferringFlutterHandoff = flutterHandoffPending && isChangingConfigurations
        val abandonedFlutterHandoff = flutterHandoffPending && !transferringFlutterHandoff
        flutterHandoffPending = false
        if (!transferringFlutterHandoff) {
            pendingStrictVpnPermission?.takeIf { it.isActive }?.complete(false)
        }
        pendingStrictVpnPermission = null
        if (abandonedFlutterHandoff) {
            NativeConnectRequestBridge.cancelPermissionHandoff(entrySource, nativeHandoffRequestId)
        }
        if (!isChangingConfigurations) cancelExplicitStartLease()
        super.onDestroy()
    }

    private fun canHostFlutterPermission(): Boolean =
        flutterHandoffPending && !isFinishing && !isDestroyed

    private fun canCoalescePermissionRequest(): Boolean = !isFinishing && !isDestroyed

    private fun completedPermission(value: Boolean): CompletableDeferred<Boolean> =
        CompletableDeferred<Boolean>().also { it.complete(value) }

    @Suppress("DEPRECATION")
    private fun beginStrictVpnPermission(allowPrompt: Boolean): CompletableDeferred<Boolean> {
        if (Settings.serviceMode != ServiceMode.VPN) {
            finishFlutterPermissionHost(granted = true)
            return completedPermission(true)
        }
        pendingStrictVpnPermission?.takeIf { it.isActive }?.let { return it }
        val permissionResult = runCatching {
            VpnService.prepare(this)
        }.onFailure {
            Log.e(TAG, "failed to prepare Android VPN ownership transfer for Flutter handoff", it)
        }
        if (permissionResult.isFailure) {
            recordQuickSettings(event = "vpn_prepare", outcome = "failed")
            finishFlutterPermissionHost(granted = false)
            return completedPermission(false)
        }
        val permissionIntent = permissionResult.getOrNull()
        if (permissionIntent == null) {
            recordQuickSettings(event = "vpn_prepare", outcome = "already_granted")
            finishFlutterPermissionHost(granted = true)
            return completedPermission(true)
        }
        if (!allowPrompt) {
            recordQuickSettings(event = "vpn_prepare", outcome = "prompt_not_allowed")
            finishFlutterPermissionHost(granted = false)
            return completedPermission(false)
        }
        return CompletableDeferred<Boolean>().also { pending ->
            pendingStrictVpnPermission = pending
            recordQuickSettings(event = "vpn_prepare", outcome = "prompt_started")
            runCatching {
                startActivityForResult(permissionIntent, VPN_PERMISSION_REQUEST_CODE)
            }.onFailure {
                Log.e(TAG, "failed to open Android VPN permission prompt for Flutter handoff", it)
                pendingStrictVpnPermission = null
                pending.complete(false)
                finishFlutterPermissionHost(granted = false)
            }
        }
    }

    private fun finishFlutterPermissionHost(granted: Boolean) {
        if (!granted) {
            NativeConnectRequestBridge.cancelPermissionHandoff(entrySource, nativeHandoffRequestId)
        }
        flutterHandoffPending = false
        if (activeFlutterPermissionHost === this) activeFlutterPermissionHost = null
        finish()
    }

    private fun handOffExplicitLeaseToLiveFlutter(): NativeConnectDispatchResult {
        return NativeConnectRequestBridge.dispatchExplicitConnect(
            source = entrySource,
            requestId = nativeHandoffRequestId,
            explicitStartLease = checkNotNull(explicitStartLease),
        )
    }

    @Suppress("DEPRECATION")
    private fun requestVpnOwnership() {
        if (Settings.serviceMode != ServiceMode.VPN) {
            recordQuickSettings(event = "vpn_prepare", outcome = "not_required")
            startMartenFromUserGesture()
            return
        }

        val permissionResult = runCatching {
            VpnService.prepare(this)
        }.onFailure {
            Log.e(TAG, "failed to prepare Android VPN ownership transfer", it)
        }
        if (permissionResult.isFailure) {
            recordQuickSettings(event = "vpn_prepare", outcome = "failed")
            cancelExplicitStartLease()
            finish()
            return
        }
        val permissionIntent = permissionResult.getOrNull()

        if (permissionIntent == null) {
            recordQuickSettings(event = "vpn_prepare", outcome = "already_granted")
            startMartenFromUserGesture()
        } else {
            recordQuickSettings(event = "vpn_prepare", outcome = "prompt_started")
            runCatching {
                startActivityForResult(permissionIntent, VPN_PERMISSION_REQUEST_CODE)
            }.onFailure {
                Log.e(TAG, "failed to open Android VPN permission prompt", it)
                recordQuickSettings(event = "vpn_prepare", outcome = "prompt_failed")
                cancelExplicitStartLease()
                finish()
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_PERMISSION_REQUEST_CODE) return
        if (flutterHandoffPending) {
            val granted = resultCode == RESULT_OK
            pendingStrictVpnPermission?.takeIf { it.isActive }?.complete(granted)
            pendingStrictVpnPermission = null
            recordQuickSettings(event = "vpn_prepare", outcome = if (granted) "granted" else "denied")
            finishFlutterPermissionHost(granted)
            return
        }
        if (resultCode == RESULT_OK) {
            recordQuickSettings(event = "vpn_prepare", outcome = "granted")
            startMartenFromUserGesture()
        } else {
            recordQuickSettings(event = "vpn_prepare", outcome = "denied")
            cancelExplicitStartLease()
            finish()
        }
    }

    private fun startMartenFromUserGesture() {
        val startLease = explicitStartLease
        explicitStartLease = null
        if (startLease == null) {
            recordQuickSettings(event = "service_connect", outcome = "missing_or_consumed_lease")
            finish()
            return
        }

        // BoxService atomically closes the engine-attach race. If Flutter
        // appeared while Android's permission UI was visible, it receives
        // this same pre-prompt lease; otherwise native cold-start consumes it.
        recordQuickSettings(event = "service_connect", outcome = "permission_lease_dispatch")
        BoxService.connect(
            userInitiated = true,
            quickSettingsRequestId = nativeHandoffRequestId,
            entrySource = entrySource,
            explicitStartLease = startLease,
        )
        finish()
    }

    private fun cancelExplicitStartLease() {
        explicitStartLease?.let(ServiceLifecycleOwnership::releaseExplicitStartLease)
        explicitStartLease = null
    }

    private fun recordQuickSettings(
        event: String,
        outcome: String,
        source: String = entrySource,
        requestId: Long = entryRequestId,
    ) {
        if (source != SOURCE_QUICK_SETTINGS) return
        QuickSettingsDiagnostics.record(
            this,
            component = "permission",
            event = event,
            requestId = requestId,
            outcome = outcome,
        )
    }
}
