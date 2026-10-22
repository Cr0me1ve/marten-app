package app.marten.client.bg

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import app.marten.client.Application
import app.marten.client.Settings
import app.marten.core.libbox.InterfaceUpdateListener
import app.marten.core.libbox.PlatformInterface
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** All native lifecycle work is replaceable. Waits exist only for admitted operations. */
internal object RemoteMobile {
    private const val BIND_TIMEOUT_MS = 5_000L
    private const val DEATH_TIMEOUT_MS = 5_000L
    private val lock = Any()
    private val attachmentExecutor = Executors.newCachedThreadPool { Thread(it, "marten-core-attachment").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var current: Session? = null
    @Volatile private var platformLease: PlatformLease? = null
    @Volatile var onUnexpectedDeath: (() -> Unit)? = null
    @Volatile var beforeForcedDeath: (() -> Boolean)? = null

    private class Session {
        val binding = CoreBindingLease()
        val lifetime = CoreProcessLifetime(Process.myPid())
        val ready = CompletableFuture<ICoreProcess>()
        val died = CountDownLatch(1)
        val retired = AtomicBoolean(false)
        val pending = ConcurrentHashMap.newKeySet<CompletableFuture<Bundle>>()
        @Volatile var remote: ICoreProcess? = null
        @Volatile var pid = 0
        @Volatile var bound = false
        lateinit var connection: ServiceConnection
    }

    private fun assertWorker() {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Core IPC must run off the UI thread" }
    }
    private fun session(): Session {
        assertWorker()
        val owner = synchronized(lock) {
            current ?: Session().also { session ->
                current = session
                session.connection = object : ServiceConnection {
                    override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                        val remote = ICoreProcess.Stub.asInterface(binder)
                        try { binder.linkToDeath({ death(session) }, 0) }
                        catch (error: Throwable) { death(session); return }
                        attachmentExecutor.execute {
                            try {
                                val pid = remote.pid()
                                synchronized(lock) {
                                    if (current !== session) return@execute
                                    session.lifetime.attached(pid)
                                    session.pid = pid
                                    session.remote = remote
                                    session.binding.attach()
                                    if (!session.retired.get()) session.ready.complete(remote)
                                }
                                // A bind issued before its deadline still owns the
                                // slot. Retire that exact late process and await
                                // Binder death before allowing any successor.
                                if (session.retired.get()) terminate(session)
                            } catch (error: Throwable) {
                                session.ready.completeExceptionally(error)
                                // A failed RPC/cleanup is not proof of process
                                // death. The linked Binder remains the barrier.
                                session.retired.set(true)
                            }
                        }
                    }
                    override fun onServiceDisconnected(name: ComponentName) { death(session) }
                    override fun onBindingDied(name: ComponentName) { death(session) }
                    override fun onNullBinding(name: ComponentName) {
                        session.ready.completeExceptionally(IllegalStateException("Core binding rejected"))
                        death(session)
                    }
                }
                main.post {
                    synchronized(lock) {
                    if (current !== session || session.retired.get() || !session.binding.issue()) return@post
                    try {
                        session.bound = Application.application.bindService(
                            Intent(Application.application, CoreProcessService::class.java),
                            session.connection, Context.BIND_AUTO_CREATE,
                        )
                        if (!session.bound) {
                            session.ready.completeExceptionally(IllegalStateException("Core binding rejected"))
                            death(session)
                        }
                    } catch (error: Throwable) { session.ready.completeExceptionally(error); death(session) }
                    }
                }
            }
        }
        try { owner.ready.get(BIND_TIMEOUT_MS, TimeUnit.MILLISECONDS) }
        catch (error: Throwable) {
            // Without a confirmed PID, retirement cannot claim process death.
            val neverIssued = synchronized(lock) {
                owner.retired.set(true)
                owner.binding.retire().also { unissued ->
                    if (unissued && current === owner) current = null
                }
            }
            if (neverIssued) {
                owner.ready.completeExceptionally(IllegalStateException("Core bind expired before issuance"))
            } else if (owner.pid > 0) {
                attachmentExecutor.execute { runCatching { terminate(owner) } }
            }
            // A missing PID is not proof that an already requested process died.
            // Keep the owner quarantined until Binder confirms death; no second bind.
            throw IllegalStateException("Core binding failed", error)
        }
        return owner
    }
    private fun unbind(owner: Session) {
        main.post {
            if (owner.bound) {
                owner.bound = false
                runCatching { Application.application.unbindService(owner.connection) }
            }
        }
    }
    private fun death(owner: Session) {
        var retiredLease: PlatformLease? = null
        // binderDied and onServiceDisconnected may race. Classification and removal
        // must be one transaction, otherwise the second callback can suppress recovery.
        val notifyUnexpected = synchronized(lock) {
            val wasCurrent = current === owner
            val unexpected = !owner.retired.getAndSet(true)
            owner.lifetime.confirmDeath()
            owner.binding.release()
            owner.died.countDown()
            if (wasCurrent) {
                retiredLease = platformLease
                platformLease = null
                current = null
            }
            wasCurrent && unexpected
        }
        owner.ready.completeExceptionally(IllegalStateException("Core process ended"))
        owner.pending.forEach { it.completeExceptionally(IllegalStateException("Core process ended")) }
        unbind(owner)
        if (notifyUnexpected) onUnexpectedDeath?.invoke()
        // Cleanup cannot suppress the authoritative process-death notification.
        runCatching { retiredLease?.close() }
    }
    private fun terminate(owner: Session) = synchronized(owner) {
        assertWorker()
        if (owner.died.count == 0L) return@synchronized
        check(owner.pid > 0 && owner.pid != Process.myPid()) { "No exact core process identity" }
        // Preserve the packet sink before cancellation can affect the native TUN.
        val protectionPreserved = beforeForcedDeath?.invoke() != false
        check(protectionPreserved) { "Traffic protection not preserved" }
        val cancelled = CompletableFuture<Bundle>()
        runCatching {
            owner.remote?.submit(Bundle().apply { putString("op", "cancel") }, object : ICoreResult.Stub() {
                override fun complete(result: Bundle) { cancelled.complete(result) }
            })
            cancelled.get(500L, TimeUnit.MILLISECONDS)
        }
        // Concurrent lifecycle deadlines share one retirement; never signal a PID twice.
        if (owner.died.count == 0L) return@synchronized
        val exactPid = owner.lifetime.beginRetirement(protectionPreserved)
        owner.retired.set(true)
        platformLease?.takeIf { it.owner === owner }?.close()
        Process.killProcess(exactPid)
        check(owner.died.await(DEATH_TIMEOUT_MS, TimeUnit.MILLISECONDS)) { "Core death not confirmed" }
        // binderDied is the barrier. No new bind/setup is permitted ahead of it.
    }
    private fun call(op: String, timeoutMs: Long = 15_000L, create: Boolean = true,
        exactOwner: Session? = null, fill: Bundle.() -> Unit = {}): Bundle {
        assertWorker()
        val owner = exactOwner ?: (if (create) session() else current) ?: return Bundle().apply { putBoolean("ok", true) }
        if (owner.retired.get()) {
            check(owner.died.await(DEATH_TIMEOUT_MS, TimeUnit.MILLISECONDS)) { "Core retirement incomplete" }
            if (op == "close" || op == "cancel") return Bundle().apply { putBoolean("ok", true) }
            error("Core operation belongs to a retired process")
        }
        check(current === owner && owner.lifetime.acceptsCallbacks()) { "Stale core operation" }
        val response = CompletableFuture<Bundle>()
        owner.pending.add(response)
        try {
            owner.remote!!.submit(Bundle().apply { putString("op", op); fill() }, object : ICoreResult.Stub() {
                override fun complete(result: Bundle) { response.complete(result) }
            })
            val result = response.get(timeoutMs, TimeUnit.MILLISECONDS)
            check(current === owner && owner.lifetime.acceptsCallbacks()) { "Stale core result" }
            check(result.getBoolean("ok")) { "Native core operation failed: ${result.getString("error")}" }
            return result
        } catch (error: java.util.concurrent.TimeoutException) {
            terminate(owner)
            if (op == "close") return Bundle().apply { putBoolean("ok", true) }
            throw IllegalStateException("Core operation deadline exceeded", error)
        } catch (error: Throwable) {
            if (op == "close" && owner.died.count == 0L) return Bundle().apply { putBoolean("ok", true) }
            throw error
        } finally { owner.pending.remove(response) }
    }

    fun setup(base: String, work: String, temp: String, mode: Long, listen: String,
        secret: String, debug: Boolean, platform: PlatformInterface?) {
        val owner = session()
        val lease = platform?.let { PlatformLease(owner, it) }
        if (lease != null) {
            platformLease?.close()
            platformLease = lease
        }
        call("setup", exactOwner = owner, fill = {
            putString("base", base); putString("work", work); putString("temp", temp); putLong("mode", mode)
            putString("listen", listen); putString("secret", secret); putBoolean("debug", debug)
            putBoolean("disableMemoryLimit", Settings.disableMemoryLimit)
            lease?.let { putBinder("platform", it.binder) }
        })
    }
    fun start(path: String, content: String) { call("start", 20_000L) { putString("path", path); putString("content", content) } }
    fun cancelStart(): Boolean = call("cancel", 1_000L, create = false).getBoolean("value")
    fun close(mode: Long) { call("close", 4_000L, create = false) { putLong("mode", mode) } }
    fun resetNetwork() { call("reset", 5_000L) }
    fun resetNetworkForRouteRecovery() { call("recover", 5_000L) }
    fun setDebug(debug: Boolean) { call("debug") { putBoolean("debug", debug) } }
    fun getServerPublicKey(): ByteArray = call("key").getByteArray("value") ?: byteArrayOf()
    fun runtimeState(): String = if (current?.remote != null) "core_process=attached" else "core_process=absent"


    fun updateCrashReporting(enabled: Boolean? = null, network: android.net.Network? = null) {
        val owner = current ?: return
        if (!owner.lifetime.acceptsCallbacks()) return
        val optIn = enabled ?: Application.application.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.enable_analytics", true)
        val verifiedNetwork = network ?: if (Settings.strictVpnRouteVerified) {
            Application.connectivity.allNetworks.firstOrNull {
                val capabilities = Application.connectivity.getNetworkCapabilities(it)
                capabilities?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) == true &&
                    (android.os.Build.VERSION.SDK_INT < 31 || capabilities.ownerUid == Process.myUid())
            }
        } else null
        // A presentation/diagnostics update never starts a process or waits on native work.
        runCatching {
            owner.remote?.submit(Bundle().apply {
                putString("op", "diagnostics")
                putBoolean("enabled", optIn)
                putParcelable("network", verifiedNetwork)
            }, object : ICoreResult.Stub() { override fun complete(result: Bundle) {} })
        }
    }
    private class PlatformLease(val owner: Session, private val platform: PlatformInterface) {
        private val active = AtomicBoolean(true)
        @Volatile private var listener: InterfaceUpdateListener? = null
        fun close() {
            active.set(false)
            listener?.let { platform.closeDefaultInterfaceMonitor(it) }
            listener = null
        }
        val binder = object : ICorePlatform.Stub() {
            override fun openTun(options: Bundle): ParcelFileDescriptor {
                check(android.os.Binder.getCallingUid() == Process.myUid())
                check(active.get() && current === owner && owner.lifetime.acceptsCallbacks())
                val vpn = platform as? VPNService ?: error("TUN owner unavailable")
                val fd = vpn.openRemoteTun(CoreTunSpec.from(options))
                // Duplicate without adopting the service-owned TUN descriptor.
                return ParcelFileDescriptor.fromFd(fd)
            }
            override fun call(request: Bundle): Bundle {
                check(android.os.Binder.getCallingUid() == Process.myUid())
                check(active.get() && current === owner && owner.lifetime.acceptsCallbacks()) { "Stale core platform lease" }
                val response = Bundle()
                when (request.getString("op")) {
                    "bind", "protect" -> {
                        @Suppress("DEPRECATION")
                        val fd = request.getParcelable<ParcelFileDescriptor>("fd") ?: error("Missing socket")
                        fd.use {
                            if (request.getString("op") == "bind") platform.autoDetectInterfaceControl(it.fd)
                            else platform.protectSocket(it.fd)
                        }
                    }
                    "owner" -> response.putInt("value", platform.findConnectionOwner(
                        request.getInt("protocol"), request.getString("source"), request.getInt("sourcePort"),
                        request.getString("destination"), request.getInt("destinationPort"),
                    ))
                    "monitor" -> {
                        val callback = ICoreResult.Stub.asInterface(request.getBinder("listener"))
                        val proxy = object : InterfaceUpdateListener {
                            override fun updateDefaultInterface(name: String, index: Int) {
                                if (active.get() && current === owner) runCatching {
                                    callback.complete(Bundle().apply { putString("name", name); putInt("index", index) })
                                }
                            }
                        }
                        listener?.let { platform.closeDefaultInterfaceMonitor(it) }
                        listener = proxy
                        platform.startDefaultInterfaceMonitor(proxy)
                    }
                    "unmonitor" -> { listener?.let { platform.closeDefaultInterfaceMonitor(it) }; listener = null }
                    "log" -> (platform as? PlatformInterfaceWrapper)?.writePlatformLog(request.getString("message").orEmpty())
                    else -> error("Unknown platform request")
                }
                response.putBoolean("ok", true)
                return response
            }
        }
    }
}
