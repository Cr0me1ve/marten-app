package app.marten.client.bg

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.Process
import app.marten.client.Settings
import app.marten.core.libbox.InterfaceUpdateListener
import app.marten.core.libbox.Libbox
import app.marten.core.libbox.Notification
import app.marten.core.libbox.TunOptions
import app.marten.core.mobile.Mobile
import java.util.concurrent.Executors
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Bound only while native services are in use. Its death never releases the service-owned TUN. */
class CoreProcessService : Service() {
    private val lifecycle = Executors.newSingleThreadExecutor { Thread(it, "marten-core-lifecycle") }
    private val control = Executors.newSingleThreadExecutor { Thread(it, "marten-core-cancel") }
    private var diagnosticsInitialized = false
    private val diagnosticsLock = Any()
    private var backgroundOpen = false
    private val platforms = mutableListOf<CorePlatform>()
    private val binder = object : ICoreProcess.Stub() {
        override fun pid(): Int {
            check(Binder.getCallingUid() == Process.myUid())
            return Process.myPid()
        }
        override fun submit(request: Bundle, result: ICoreResult) {
            check(Binder.getCallingUid() == Process.myUid())
            val operation = request.getString("op")
            val executor = if (operation == "cancel" || operation == "diagnostics") control else lifecycle
            executor.execute {
                val response = Bundle()
                try {
                    when (operation) {
                        "diagnostics" -> {
                          synchronized(diagnosticsLock) {
                            @Suppress("DEPRECATION")
                            val network = request.getParcelable<android.net.Network>("network")
                            val enabled = request.getBoolean("enabled")
                            app.marten.client.crashreporting.EarlyCrashReports.setCollectionEnabled(applicationContext, enabled)
                            val connectivity = app.marten.client.Application.connectivity
                            val admitted = backgroundOpen && network != null && connectivity.bindProcessToNetwork(network)
                            app.marten.client.crashreporting.NativeCrashDiagnostics.setNetworkAdmissionAllowed(admitted)
                            if (admitted && enabled && !diagnosticsInitialized) {
                                app.marten.client.crashreporting.EarlyCrashReports.notePhase(applicationContext, "firebase_initializing")
                                checkNotNull(com.google.firebase.FirebaseApp.initializeApp(applicationContext))
                                com.google.firebase.crashlytics.FirebaseCrashlytics.getInstance()
                                    .setCrashlyticsCollectionEnabled(true)
                                app.marten.client.crashreporting.EarlyCrashReports.markSdkReady(applicationContext)
                                diagnosticsInitialized = true
                            }
                            if (diagnosticsInitialized) {
                                com.google.firebase.crashlytics.FirebaseCrashlytics.getInstance()
                                    .setCrashlyticsCollectionEnabled(enabled && admitted)
                            }
                          }
                        }
                        "setup" -> {
                            val platform = request.getBinder("platform")?.let {
                                CorePlatform(ICorePlatform.Stub.asInterface(it))
                            }
                            platform?.let { platforms.add(it) }
                            Mobile.setup(
                                request.getString("base"), request.getString("work"), request.getString("temp"),
                                request.getLong("mode"), request.getString("listen"), request.getString("secret"),
                                request.getBoolean("debug"), platform,
                            )
                            if (platform != null) synchronized(diagnosticsLock) { backgroundOpen = true }
                            Libbox.setMemoryLimit(!request.getBoolean("disableMemoryLimit"))
                        }
                        "start" -> Mobile.start(request.getString("path"), request.getString("content"))
                        "cancel" -> response.putBoolean("value", Mobile.cancelStart())
                        "close" -> {
                            val networkReleased = synchronized(diagnosticsLock) {
                                // Seal queued diagnostic callbacks before releasing the exact
                                // VPN binding. A stale proof must not rebind a stopped core.
                                backgroundOpen = false
                                app.marten.client.crashreporting.NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)
                                if (diagnosticsInitialized) {
                                    runCatching {
                                        com.google.firebase.crashlytics.FirebaseCrashlytics.getInstance()
                                            .setCrashlyticsCollectionEnabled(false)
                                    }
                                }
                                runCatching {
                                    app.marten.client.Application.connectivity.bindProcessToNetwork(null)
                                }.getOrDefault(false)
                            }
                            Mobile.close(request.getLong("mode"))
                            platforms.forEach { it.closeDescriptors() }
                            platforms.clear()
                            check(networkReleased) { "Core network binding release failed" }
                        }
                        "reset" -> Mobile.resetNetwork()
                        "recover" -> Mobile.resetNetworkForRouteRecovery()
                        "debug" -> Mobile.setDebug(request.getBoolean("debug"))
                        "key" -> response.putByteArray("value", Mobile.getServerPublicKey())
                        else -> error("Unsupported core operation")
                    }
                    response.putBoolean("ok", true)
                } catch (error: Throwable) {
                    if (operation == "diagnostics") app.marten.client.crashreporting.EarlyCrashReports.notePhase(applicationContext, "initialization_failed")
                    // Native messages may contain profile data. Only a category crosses into diagnostics.
                    response.putString("error", error.javaClass.simpleName)
                }
                runCatching { result.complete(response) }
            }
        }
    }
    override fun onCreate() {
        super.onCreate()
        check(android.app.Application.getProcessName().endsWith(":core"))
        // Core DNS waits use the existing event-driven physical-network listener.
        runBlocking { DefaultNetworkListener.start(this@CoreProcessService) { } }
    }
    override fun onBind(intent: Intent): IBinder = binder
    override fun onDestroy() {
        runBlocking { DefaultNetworkListener.stop(this@CoreProcessService) }
        lifecycle.shutdownNow(); control.shutdownNow()
        super.onDestroy()
        // A clean unbind must also retire native listeners; no UI process is touched.
        app.marten.client.crashreporting.EarlyCrashReports.markExpectedCoreExit(applicationContext, Process.myPid())
        Process.killProcess(Process.myPid())
    }
}

private class CorePlatform(private val remote: ICorePlatform) : PlatformInterfaceWrapper {
    private var listener: InterfaceUpdateListener? = null
    private val descriptors = mutableListOf<ParcelFileDescriptor>()
    fun closeDescriptors() { synchronized(descriptors) { descriptors.forEach { runCatching { it.close() } }; descriptors.clear() } }
    private val update = object : ICoreResult.Stub() {
        override fun complete(result: Bundle) {
            listener?.updateDefaultInterface(result.getString("name").orEmpty(), result.getInt("index"))
        }
    }
    private fun call(op: String, fill: Bundle.() -> Unit = {}): Bundle = remote.call(Bundle().apply {
        putString("op", op); fill()
    }).also { check(it.getBoolean("ok")) { "Core platform operation rejected" } }
    private fun socket(op: String, fd: Int) {
        // Binder transfers a duplicate of the socket, never the sender's fd number.
        val duplicate = ParcelFileDescriptor.fromFd(fd)
        duplicate.use { call(op) { putParcelable("fd", it) } }
    }
    override fun autoDetectInterfaceControl(fd: Int) = socket("bind", fd)
    override fun protectSocket(fd: Int) = socket("protect", fd)
    override fun openTun(options: TunOptions): Int {
        val descriptor = remote.openTun(CoreTunSpec.from(options).toBundle()) ?: error("Missing TUN descriptor")
        synchronized(descriptors) { descriptors.add(descriptor) }
        return descriptor.fd
    }
    override fun findConnectionOwner(ipProtocol: Int, sourceAddress: String, sourcePort: Int,
        destinationAddress: String, destinationPort: Int): Int = call("owner") {
        putInt("protocol", ipProtocol); putString("source", sourceAddress); putInt("sourcePort", sourcePort)
        putString("destination", destinationAddress); putInt("destinationPort", destinationPort)
    }.getInt("value")
    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        this.listener = listener
        call("monitor") { putBinder("listener", update) }
    }
    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        if (this.listener === listener) {
            this.listener = null
            call("unmonitor")
        }
    }
    override fun writePlatformLog(message: String) { call("log") { putString("message", message) } }
    override fun sendNotification(notification: Notification) {}
}
