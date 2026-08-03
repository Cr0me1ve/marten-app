package app.marten.client

import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.SystemClock
import android.os.PowerManager
import android.util.Log
import androidx.core.content.getSystemService
import app.marten.client.bg.AppChangeReceiver
import go.Seq
import app.marten.client.Application as BoxApplication

class Application : Application() {

    override fun attachBaseContext(base: Context?) {
        if (processStartElapsedRealtimeMs == 0L) {
            processStartElapsedRealtimeMs = SystemClock.elapsedRealtime()
        }
        super.attachBaseContext(base)
        application = this
        logStartupPhase("application_attach")
    }

    override fun onCreate() {
        super.onCreate()
        logStartupPhase("application_on_create_start")

        Seq.setContext(this)

        registerReceiver(AppChangeReceiver(), IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addDataScheme("package")
        })
        logStartupPhase("application_on_create_end")
    }

    companion object {
        private const val STARTUP_TAG = "MartenStartup"

        @Volatile
        private var processStartElapsedRealtimeMs = 0L

        fun logStartupPhase(phase: String) {
            val start = processStartElapsedRealtimeMs
            val elapsed = if (start == 0L) 0L else SystemClock.elapsedRealtime() - start
            Log.i(STARTUP_TAG, "startup phase=$phase elapsed_ms=$elapsed")
        }

        lateinit var application: BoxApplication
        val notification by lazy { application.getSystemService<NotificationManager>()!! }
        val connectivity by lazy { application.getSystemService<ConnectivityManager>()!! }
        val packageManager by lazy { application.packageManager }
        val powerManager by lazy { application.getSystemService<PowerManager>()!! }
        val notificationManager by lazy { application.getSystemService<NotificationManager>()!! }

        val wifiManager by lazy { application.getSystemService<WifiManager>()!! }

    }

}
