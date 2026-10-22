package app.marten.client

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutManager
import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.util.Log
import androidx.core.content.getSystemService
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import app.marten.client.bg.BoxService
import app.marten.client.bg.ServiceConnection
import app.marten.client.constant.Status
import java.security.MessageDigest
import java.security.SecureRandom

class ShortcutActivity : Activity(), ServiceConnection.Callback {

    companion object {
        private const val TAG = "ShortcutActivity"
        private const val ACTION_AUTHENTICATED_TOGGLE =
            "app.marten.client.action.AUTHENTICATED_SHORTCUT_TOGGLE"
        private const val EXTRA_TOGGLE_CAPABILITY =
            "app.marten.client.extra.SHORTCUT_TOGGLE_CAPABILITY"
        private const val CAPABILITY_PREFERENCES = "marten_private_shortcut_capability"
        private const val CAPABILITY_KEY = "toggle_capability"
        private const val PUBLISHED_CAPABILITY_KEY = "published_toggle_capability"

        private fun capability(context: Context): String {
            val preferences = context.getSharedPreferences(CAPABILITY_PREFERENCES, MODE_PRIVATE)
            preferences.getString(CAPABILITY_KEY, null)?.let { return it }
            val bytes = ByteArray(32).also(SecureRandom()::nextBytes)
            val generated = Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.URL_SAFE)
            check(preferences.edit().putString(CAPABILITY_KEY, generated).commit()) {
                "shortcut capability could not be persisted"
            }
            return generated
        }

        private fun storedCapability(context: Context): String? =
            context.getSharedPreferences(CAPABILITY_PREFERENCES, MODE_PRIVATE)
                .getString(CAPABILITY_KEY, null)

        private fun authenticatedToggleIntent(context: Context, token: String): Intent =
            Intent(context, ShortcutActivity::class.java)
                .setAction(ACTION_AUTHENTICATED_TOGGLE)
                .putExtra(EXTRA_TOGGLE_CAPABILITY, token)

        /**
         * Replaces the unauthenticated manifest shortcut with one publisher-owned
         * dynamic shortcut. The private preference makes this a one-time write;
         * normal foreground launches do not touch ShortcutManager or storage.
         */
        fun publishAuthenticatedDynamicShortcut(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
            val preferences = context.getSharedPreferences(CAPABILITY_PREFERENCES, MODE_PRIVATE)
            val token = capability(context)
            if (preferences.getString(PUBLISHED_CAPABILITY_KEY, null) == token) return
            val shortcut = ShortcutInfoCompat.Builder(context, "toggle")
                .setIntent(authenticatedToggleIntent(context, token))
                .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
                .setShortLabel(context.getString(R.string.quick_toggle))
                .setLongLabel(context.getString(R.string.quick_toggle))
                .build()
            check(ShortcutManagerCompat.addDynamicShortcuts(context, listOf(shortcut))) {
                "authenticated shortcut could not be published"
            }
            check(preferences.edit().putString(PUBLISHED_CAPABILITY_KEY, token).commit()) {
                "authenticated shortcut publication could not be persisted"
            }
        }

        private fun isTrustedCreator(activity: Activity): Boolean {
            val caller = activity.callingPackage ?: return false
            if (caller == activity.packageName) return true
            val defaultHome = activity.packageManager.resolveActivity(
                Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
                0,
            )?.activityInfo?.packageName
            return caller == defaultHome
        }

        private fun isAuthenticatedToggle(activity: Activity, intent: Intent?): Boolean {
            if (intent?.action != ACTION_AUTHENTICATED_TOGGLE) return false
            val supplied = intent.getStringExtra(EXTRA_TOGGLE_CAPABILITY) ?: return false
            val expected = storedCapability(activity) ?: return false
            return MessageDigest.isEqual(
                supplied.toByteArray(Charsets.UTF_8),
                expected.toByteArray(Charsets.UTF_8),
            )
        }
    }

    private val connection = ServiceConnection(this, this, false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.action == Intent.ACTION_CREATE_SHORTCUT && isTrustedCreator(this)) {
            setResult(
                RESULT_OK, ShortcutManagerCompat.createShortcutResultIntent(
                    this,
                    ShortcutInfoCompat.Builder(this, "toggle")
                        .setIntent(authenticatedToggleIntent(this, capability(this)))
                        .setIcon(
                            IconCompat.createWithResource(
                                this,
                                R.mipmap.ic_launcher
                            )
                        )
                        .setShortLabel(getString(R.string.quick_toggle))
                        .build()
                )
            )
            finish()
            return
        }
        if (isAuthenticatedToggle(this, intent)) {
            connection.connect()
            if (Build.VERSION.SDK_INT >= 25) {
                getSystemService<ShortcutManager>()?.reportShortcutUsed("toggle")
            }
        } else {
            Log.w(TAG, "rejecting unauthenticated exported shortcut request")
            setResult(RESULT_CANCELED)
            finish()
            return
        }
        moveTaskToBack(true)
    }

    override fun onServiceStatusChanged(status: Status) {
        when (status) {
            Status.Started -> BoxService.stop()
            Status.Stopped -> startActivity(
                VpnPermissionActivity.createIntent(
                    this,
                    source = VpnPermissionActivity.SOURCE_SHORTCUT,
                ),
            )
            else -> {}
        }
        finish()
    }

    override fun onDestroy() {
        connection.disconnect()
        super.onDestroy()
    }

}
