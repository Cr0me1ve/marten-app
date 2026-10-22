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
import androidx.work.Configuration
import app.marten.client.bg.AppChangeReceiver
import app.marten.client.bg.LocalResolver
import app.marten.client.bg.StrictVpnWorkerFactory
import app.marten.client.crashreporting.NativeCrashDiagnostics
import app.marten.core.libbox.Libbox
import app.marten.core.mobile.Mobile
import go.Seq
import app.marten.client.Application as BoxApplication

class Application : Application(), Configuration.Provider {

    /**
     * WorkManager's manifest initializer stays disabled so a cold VpnService
     * process cannot launch a Dart worker before the fail-closed VPN exists.
     * Flutter's foreground plugin may still request WorkManager lazily; its
     * factory therefore replaces every background Dart worker with a wrapper
     * that retries without starting Flutter until native VPN admission is live.
     */
    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder()
            .setWorkerFactory(StrictVpnWorkerFactory)
            .build()

    override fun attachBaseContext(base: Context?) {
        if (processStartElapsedRealtimeMs == 0L) {
            processStartElapsedRealtimeMs = SystemClock.elapsedRealtime()
        }
        super.attachBaseContext(base)
        application = this
        if (isDiagnosticsProcess) return
        app.marten.client.crashreporting.EarlyCrashReports.install(this)
        // A fresh process has no socket that has been admitted through a
        // current VPN Network yet, even when no user session is persisted.
        // Keep native diagnostics and headless optional work cold until the
        // service publishes a current-generation data-plane proof.
        NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)
        if (!isCoreProcess) runCatching { Settings.strictVpnRouteVerified = false }
        logStartupPhase("application_attach")
    }

    override fun onCreate() {
        super.onCreate()
        if (isDiagnosticsProcess) {
            Seq.setContext(this)
            if (BuildConfig.ENERGY_DIAGNOSTICS) {
                runCatching { app.marten.client.bg.EnergyDiagnostics.start(this, false, true) }
            }
            return
        }
        logStartupPhase("application_on_create_start")
        if (BuildConfig.ENERGY_DIAGNOSTICS) {
            runCatching { app.marten.client.bg.EnergyDiagnostics.start(this, isCoreProcess) }
        }

        if (isCoreProcess) {
            Seq.setContext(this)
            Libbox.registerLocalDNSTransport(LocalResolver)
            Mobile.setEndpointResolver(LocalResolver)
            return
        }
        Seq.setContext(this)
        // The native "local" DNS transport must stay on Android's current
        // physical Network. Without the platform resolver, a cold VPN start can
        // send bootstrap resolution for the proxy hostname back into the new
        // TUN and wait forever for the very outbound it is trying to create.
        registerReceiver(AppChangeReceiver(), IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addDataScheme("package")
        })
        logStartupPhase("application_on_create_end")
    }

    companion object {
        val isDiagnosticsProcess: Boolean
            get() = android.app.Application.getProcessName().endsWith(":diagnostics")

        val isCoreProcess: Boolean
            get() = android.app.Application.getProcessName().endsWith(":core")

        private const val STARTUP_TAG = "MartenStartup"

        @Volatile
        private var processStartElapsedRealtimeMs = 0L

        fun logStartupPhase(phase: String) {
            val start = processStartElapsedRealtimeMs
            val elapsed = if (start == 0L) 0L else SystemClock.elapsedRealtime() - start
            Log.i(STARTUP_TAG, "startup phase=$phase elapsed_ms=$elapsed")
            NativeCrashDiagnostics.logPhase("application", phase)
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
