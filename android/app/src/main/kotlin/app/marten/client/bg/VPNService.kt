package app.marten.client.bg
import android.util.Log

import app.marten.client.Settings
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import app.marten.core.libbox.InterfaceUpdateListener
import app.marten.core.libbox.Notification
import app.marten.core.libbox.StringIterator
import app.marten.client.constant.PerAppProxyMode
import app.marten.client.ktx.toIpPrefix
import app.marten.core.libbox.TunOptions
import kotlinx.coroutines.runBlocking

class VPNService : VpnService(), PlatformInterfaceWrapper {

    companion object {
        private const val TAG = "A/VPNService"
    }

    private val service = BoxService(this, this)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) =
        service.onStartCommand(intent, flags)

    override fun onBind(intent: Intent): IBinder {
        val binder = super.onBind(intent)
        if (binder != null) {
            return binder
        }
        return service.onBind(intent)
    }

    override fun onDestroy() {
        try {
            service.onDestroy()
        } finally {
            super.onDestroy()
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        service.startDefaultInterfaceMonitor(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        service.closeDefaultInterfaceMonitor(listener)
    }

    override fun onRevoke() {
        Log.w(TAG, "Android revoked Marten VPN service")
        service.onRevoke()
        super.onRevoke()
    }

    /**
     * Replaces an OEM-retained, already inert VPN interface with a local
     * no-route interface and closes it immediately.
     *
     * Android normally removes the VPN network when the descriptor returned by
     * Builder.establish() is closed. Some vendor builds can retain that first
     * framework interface after a native consumer used its fd, even though the
     * descriptor and core are both gone. Establishing a replacement makes the
     * framework synchronously retire the old interface; because this descriptor
     * never crosses into the native core, closing it is an unambiguous final
     * lifecycle signal. No Activity or other UI is involved.
     */
    internal fun retirePlatformVpnSessionAfterCoreStop(): Boolean {
        if (!BoxService.isOwnVpnActive(this)) return true

        Log.w(TAG, "retiring Android framework VPN session after completed core stop")
        val retirementDescriptor = runCatching {
            Builder()
                .setSession("marten-stop")
                .setMtu(1280)
                .addAddress("192.0.2.1", 32)
                .allowBypass()
                .apply {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        setMetered(false)
                    }
                }
                .establish()
        }.onFailure {
            Log.e(TAG, "failed to establish framework VPN retirement interface", it)
        }.getOrNull() ?: return false

        return runCatching {
            retirementDescriptor.close()
            Log.i(TAG, "framework VPN retirement descriptor closed")
            true
        }.onFailure {
            Log.e(TAG, "failed to close framework VPN retirement descriptor", it)
        }.getOrDefault(false)
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        if (!protect(fd)) {
            error("android: failed to protect socket from VPN")
        }
        val pfd = ParcelFileDescriptor.adoptFd(fd)
        try {
            bindSocketToDefaultNetwork(pfd)
        } finally {
            pfd.detachFd()
        }
    }

    private fun bindSocketToDefaultNetwork(pfd: ParcelFileDescriptor) {
        val network = runCatching {
            runBlocking {
                DefaultNetworkMonitor.require()
            }
        }.getOrElse {
            Log.w(TAG, "no default network available; continuing with protected socket", it)
            return
        }
        runCatching {
            network.bindSocket(pfd.fileDescriptor)
        }.onSuccess {
            return
        }.onFailure { firstError ->
            Log.w(TAG, "failed to bind socket to default network; refreshing network", firstError)
        }

        val refreshedNetwork = runBlocking {
            DefaultNetworkMonitor.refresh(network)
        }
        if (refreshedNetwork == null) {
            Log.w(TAG, "no refreshed default network available; continuing with protected socket")
            return
        }

        runCatching {
            refreshedNetwork.bindSocket(pfd.fileDescriptor)
        }.onFailure { retryError ->
            Log.w(TAG, "failed to bind socket to refreshed network; continuing with protected socket", retryError)
        }
    }

    override fun protectSocket(fd: Int) {
        if (!protect(fd)) {
            error("android: failed to protect socket from VPN")
        }
    }

    var systemProxyAvailable = false
    var systemProxyEnabled = false
    fun addIncludePackage(builder: Builder, packageName: String) {
        if (packageName == this.packageName) { 
            Log.d("VpnService","Cannot include myself: $packageName")
            return
        }
        try {     
            Log.d("VpnService","Including $packageName")
            builder.addAllowedApplication(packageName)
        } catch (e: NameNotFoundException) {
        }
    }

    fun addExcludePackage(builder: Builder, packageName: String) {
        try {     
            Log.d("VpnService","Excluding $packageName")
            builder.addDisallowedApplication(packageName)
        } catch (e: NameNotFoundException) {
        }
    }

    private fun collectPackages(iterator: StringIterator): List<String> {
        val packages = linkedSetOf<String>()
        while (iterator.hasNext()) {
            val packageName = iterator.next().trim()
            if (packageName.isNotEmpty()) {
                packages.add(packageName)
            }
        }
        return packages.toList()
    }

    @Synchronized
    override fun openTun(options: TunOptions): Int {
        Log.d(
            TAG,
            "openTun request mtu=${options.mtu} auto_route=${options.autoRoute} " +
                "http_proxy=${options.isHTTPProxyEnabled}",
        )
        try {
        var hasPermission = false
        for (i in 0 until 20) {
            if (prepare(this) != null) {
                Log.w("VPN", "android: missing vpn permission")
            } else {
                hasPermission = true
                break
            }
            Thread.sleep(50)
        }

        if (!hasPermission) {
             error("android: missing vpn permission")
    }
        val builder = Builder()
            .setSession("marten")
            .setMtu(options.mtu)
            .allowBypass()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        var hasInet4Address = false
        var inet4AddressCount = 0
        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val address = inet4Address.next()
            builder.addAddress(address.address(), address.prefix())
            hasInet4Address = true
            inet4AddressCount += 1
        }

        var hasInet6Address = false
        var inet6AddressCount = 0
        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val address = inet6Address.next()
            builder.addAddress(address.address(), address.prefix())
            hasInet6Address = true
            inet6AddressCount += 1
        }

        var inet4RouteCount = 0
        var inet6RouteCount = 0
        var routeExcludeCount = 0
        var includePackageCount = 0
        var excludePackageCount = 0
        if (options.autoRoute) {
            builder.addDnsServer(options.dnsServerAddress.value)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val inet4RouteAddress = options.inet4RouteAddress
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        builder.addRoute(inet4RouteAddress.next().toIpPrefix())
                        inet4RouteCount += 1
                    }
                } else if (hasInet4Address) {
                    builder.addRoute("0.0.0.0", 0)
                    inet4RouteCount += 1
                }

                val inet6RouteAddress = options.inet6RouteAddress
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        builder.addRoute(inet6RouteAddress.next().toIpPrefix())
                        inet6RouteCount += 1
                    }
                } else if (hasInet6Address) {
                    builder.addRoute("::", 0)
                    inet6RouteCount += 1
                }

                val inet4RouteExcludeAddress = options.inet4RouteExcludeAddress
                while (inet4RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet4RouteExcludeAddress.next().toIpPrefix())
                    routeExcludeCount += 1
                }

                val inet6RouteExcludeAddress = options.inet6RouteExcludeAddress
                while (inet6RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet6RouteExcludeAddress.next().toIpPrefix())
                    routeExcludeCount += 1
                }
            } else {
                val inet4RouteAddress = options.inet4RouteRange
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        val address = inet4RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                        inet4RouteCount += 1
                    }
                }

                val inet6RouteAddress = options.inet6RouteRange
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        val address = inet6RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                        inet6RouteCount += 1
                    }
                }
            }

            val optionIncludePackages = collectPackages(options.includePackage)
            val optionExcludePackages = collectPackages(options.excludePackage)
            includePackageCount = optionIncludePackages.size
            excludePackageCount = optionExcludePackages.size

            if (Settings.perAppProxyEnabled) {
                val appList = Settings.perAppProxyList
                if (Settings.perAppProxyMode == PerAppProxyMode.INCLUDE) {
                    val bypassPackages = optionExcludePackages.toSet()
                    appList.filter { !bypassPackages.contains(it) }.forEach {
                        addIncludePackage(builder, it)
                    }
//                    addIncludePackage(builder,packageName)
                } else {
                    (appList + optionExcludePackages + packageName).distinct().forEach {
                        addExcludePackage(builder, it)
                    }
                }
            } else {
                if (optionIncludePackages.isNotEmpty()) {
                    val bypassPackages = optionExcludePackages.toSet()
                    optionIncludePackages.filter { !bypassPackages.contains(it) }.forEach {
                        addIncludePackage(builder, it)
                    }
                    //                    addIncludePackage(builder,packageName)
                } else {
                    (optionExcludePackages + packageName).distinct().forEach {
                        addExcludePackage(builder, it)
                    }
                }
                
            }
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            systemProxyAvailable = true
            systemProxyEnabled = Settings.systemProxyEnabled
            if (systemProxyEnabled) builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer, options.httpProxyServerPort
                )
            )
        } else {
            systemProxyAvailable = false
            systemProxyEnabled = false
        }

        Log.d(
            TAG,
            "openTun platform state permission=true addresses_v4=$inet4AddressCount " +
                "addresses_v6=$inet6AddressCount routes_v4=$inet4RouteCount " +
                "routes_v6=$inet6RouteCount route_excludes=$routeExcludeCount " +
                "include_packages=$includePackageCount exclude_packages=$excludePackageCount",
        )
        service.requireTunCreationPrecondition()
        val pfd = builder.establish() ?: error("android: the application is not prepared or is revoked")
        if (!service.replaceTunFileDescriptor(pfd)) {
            error("android: VPN service stopped while creating TUN")
        }
        // The libbox Android wrapper duplicates this fd before creating its TUN
        // object and closes that duplicate with the core. It deliberately leaves
        // the fd returned by the platform open, so BoxService retains and closes
        // this exact ParcelFileDescriptor as the framework VPN lifetime owner.
        val nativeFd = pfd.fd
        Log.d(
            TAG,
            "openTun outcome=success retained_fd_valid=${pfd.fileDescriptor.valid()} native_fd=$nativeFd",
        )
        return nativeFd
        } catch (error: Throwable) {
            Log.e(
                TAG,
                "openTun outcome=failure error_type=${error.javaClass.simpleName}",
            )
            throw error
        }
    }

    override fun writePlatformLog(message: String) = service.writeDebugMessage(message)

    override fun sendNotification(notification: Notification) {
//        service.sendNotification(notification)
    }
}
