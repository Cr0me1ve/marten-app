package app.marten.client.bg

import android.app.Service
import android.content.Intent
import app.marten.client.crashreporting.NativeCrashDiagnostics
import app.marten.core.libbox.InterfaceUpdateListener
import app.marten.core.libbox.Notification

class ProxyService :
    Service(),
    PlatformInterfaceWrapper {
    private lateinit var service: BoxService

    override fun onCreate() {
        super.onCreate()
        NativeCrashDiagnostics.logPhase("proxy_service", "on_create_start")
        service = BoxService(this, this)
        NativeCrashDiagnostics.logPhase("proxy_service", "on_create_complete")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = service.onStartCommand(intent, flags)

    override fun onBind(intent: Intent) = service.onBind(intent)

    override fun onDestroy() {
        NativeCrashDiagnostics.logPhase("proxy_service", "on_destroy_start")
        try {
            if (::service.isInitialized) {
                service.onDestroy()
            }
        } finally {
            super.onDestroy()
            NativeCrashDiagnostics.logPhase("proxy_service", "on_destroy_complete")
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) =
        service.startDefaultInterfaceMonitor(listener)

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) =
        service.closeDefaultInterfaceMonitor(listener)

    override fun sendNotification(notification: Notification) = service.sendNotification(notification)

    override fun writePlatformLog(message: String) = service.writeDebugMessage(message)
}
