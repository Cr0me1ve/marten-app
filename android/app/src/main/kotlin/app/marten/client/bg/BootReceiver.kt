package app.marten.client.bg
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import app.marten.client.Settings
import app.marten.client.constant.Action

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
            }

            else -> return
        }
        if (!Settings.startedByUser) return
        // This broadcast is only a system recovery hint. Never manufacture a
        // user Connect or set persisted intent here: a terminal Disconnect can
        // race delivery between the broadcast and the service main thread.
        // BoxService re-reads the authoritative persisted session when this
        // command is actually handled and ignores it after Disconnect.
        val recoveryIntent = Intent(context, Settings.serviceClass())
            .setAction(Action.SERVICE_RECOVER)
        ContextCompat.startForegroundService(context, recoveryIntent)
    }
}
