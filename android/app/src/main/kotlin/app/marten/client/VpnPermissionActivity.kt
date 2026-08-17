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
import app.marten.client.constant.ServiceMode

/**
 * User-gesture bridge for entry points that do not already own an Activity.
 *
 * VpnService.prepare() is Android's authoritative, user-mediated transfer of
 * the single VPN slot. Boot, sticky restart and recovery never enter here.
 */
class VpnPermissionActivity : Activity() {
    companion object {
        private const val TAG = "VpnPermissionActivity"
        private const val VPN_PERMISSION_REQUEST_CODE = 1

        fun createIntent(context: Context): Intent =
            Intent(context, VpnPermissionActivity::class.java)

        fun pendingIntent(context: Context, requestCode: Int): PendingIntent {
            val flags =
                PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        PendingIntent.FLAG_IMMUTABLE
                    } else {
                        0
                    }
            return PendingIntent.getActivity(
                context,
                requestCode,
                createIntent(context),
                flags,
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) {
            requestVpnOwnership()
        }
    }

    @Suppress("DEPRECATION")
    private fun requestVpnOwnership() {
        if (Settings.serviceMode != ServiceMode.VPN) {
            startMartenFromUserGesture()
            return
        }

        val permissionResult = runCatching {
            VpnService.prepare(this)
        }.onFailure {
            Log.e(TAG, "failed to prepare Android VPN ownership transfer", it)
        }
        if (permissionResult.isFailure) {
            finish()
            return
        }
        val permissionIntent = permissionResult.getOrNull()

        if (permissionIntent == null) {
            startMartenFromUserGesture()
        } else {
            startActivityForResult(permissionIntent, VPN_PERMISSION_REQUEST_CODE)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_PERMISSION_REQUEST_CODE) return
        if (resultCode == RESULT_OK) {
            startMartenFromUserGesture()
        } else {
            finish()
        }
    }

    private fun startMartenFromUserGesture() {
        BoxService.connect(userInitiated = true)
        finish()
    }
}
