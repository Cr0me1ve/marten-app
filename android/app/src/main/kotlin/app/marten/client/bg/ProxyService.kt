package app.marten.client.bg

import android.app.Service
import android.content.Intent
import app.marten.core.libbox.InterfaceUpdateListener
import app.marten.core.libbox.Notification

class ProxyService :
    Service(),
    PlatformInterfaceWrapper {
    private val service = BoxService(this, this)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = service.onStartCommand(intent, flags)

    override fun onBind(intent: Intent) = service.onBind(intent)

    override fun onDestroy() = service.onDestroy()

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) =
        service.startDefaultInterfaceMonitor(listener)

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) =
        service.closeDefaultInterfaceMonitor(listener)

    override fun sendNotification(notification: Notification) = service.sendNotification(notification)

    override fun writePlatformLog(message: String) = service.writeDebugMessage(message)
}
