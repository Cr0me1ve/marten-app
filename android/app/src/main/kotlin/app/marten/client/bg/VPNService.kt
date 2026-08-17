package app.marten.client.bg
import android.util.Log

import app.marten.client.Settings
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.Network
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import app.marten.core.libbox.InterfaceUpdateListener
import app.marten.core.libbox.Notification
import app.marten.core.libbox.StringIterator
import app.marten.client.constant.PerAppProxyMode
import app.marten.client.crashreporting.NativeCrashDiagnostics
import app.marten.client.ktx.toIpPrefix
import app.marten.core.libbox.TunOptions

class VPNService : VpnService(), PlatformInterfaceWrapper {

    companion object {
        private const val TAG = "A/VPNService"
    }

    private lateinit var service: BoxService
    private val underlyingNetworkLock = Any()
    private var declaredUnderlyingNetwork: Network? = null
    private var underlyingNetworkDeclarationInitialized = false

    override fun onCreate() {
        super.onCreate()
        NativeCrashDiagnostics.logPhase("vpn_service", "on_create_start")
        // Android attaches the Service base Context before onCreate, but only
        // after invoking the Kotlin constructor. BoxService owns components
        // that resolve application-scoped Android services, so construct it at
        // the first lifecycle point where that Context is guaranteed usable.
        service = BoxService(this, this)
        NativeCrashDiagnostics.logPhase("vpn_service", "on_create_complete")
    }

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
        NativeCrashDiagnostics.logPhase("vpn_service", "on_destroy_start")
        try {
            if (::service.isInitialized) {
                service.onDestroy()
            }
        } finally {
            super.onDestroy()
            NativeCrashDiagnostics.logPhase("vpn_service", "on_destroy_complete")
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
        // VpnService's default implementation calls stopSelf() immediately.
        // BoxService owns an ordered core/TUN cleanup and calls stopSelf() only
        // after that cleanup finishes; racing it here can preserve stale user
        // intent or destroy the owner before it accepts the revoke.
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
    internal fun retirePlatformVpnSessionAfterCoreStop(
        retirementAllowed: () -> Boolean = { true },
    ): Boolean {
        if (!retirementAllowed()) {
            Log.i(TAG, "skipping framework VPN retirement because Marten no longer owns the VPN slot")
            return true
        }
        if (!BoxService.isOwnVpnActive(this)) return true
        if (!retirementAllowed()) {
            Log.i(TAG, "skipping framework VPN retirement after final ownership check")
            return true
        }

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
        val underlyingNetwork = DefaultNetworkMonitor.defaultNetwork
            ?: error("android: missing underlying network for socket")
        val descriptor = ParcelFileDescriptor.adoptFd(fd)
        try {
            // Network.bindSocket assigns the physical netId and requires an
            // unconnected descriptor. Protect only after that assignment so
            // netd never has to rewrite an already VPN-protected socket mark.
            underlyingNetwork.bindSocket(descriptor.fileDescriptor)
        } catch (error: Exception) {
            throw IllegalStateException(
                "android: failed to bind socket to underlying network",
                error,
            )
        } finally {
            descriptor.detachFd()
        }
        protectSocket(fd)
    }

    override fun protectSocket(fd: Int) {
        if (!protect(fd)) {
            error("android: failed to protect socket from VPN")
        }
    }

    /**
     * Keeps Android's VPN network attached to the physical network observed by
     * the platform monitor. Socket protection remains the only per-dial action;
     * declaring the underlying network on the VPN itself avoids a default-route
     * handoff window while Builder.establish() publishes the new TUN network.
     */
    internal fun updateUnderlyingNetwork(network: Network?) {
        publishUnderlyingNetwork(network, requireActiveVpn = true)
    }

    private fun publishUnderlyingNetwork(observedNetwork: Network?, requireActiveVpn: Boolean) {
        synchronized(underlyingNetworkLock) {
            // The monitor publishes its snapshot before invoking BoxService.
            // Re-read it under this short lock so an older callback can never
            // overwrite a newer physical-network handoff.
            val network = DefaultNetworkMonitor.defaultNetwork
            if (
                underlyingNetworkDeclarationInitialized &&
                declaredUnderlyingNetwork == network
            ) {
                return
            }
            if (requireActiveVpn && !BoxService.isOwnVpnActive(this)) return

            val accepted = runCatching {
                setUnderlyingNetworks(network?.let { arrayOf(it) } ?: emptyArray())
            }.onFailure {
                Log.w(TAG, "failed to update Android VPN underlying network", it)
            }.getOrDefault(false)
            if (!accepted) {
                Log.w(
                    TAG,
                    "Android rejected VPN underlying network update " +
                        "available=${network != null} callback_current=${network == observedNetwork}",
                )
                return
            }
            declaredUnderlyingNetwork = network
            underlyingNetworkDeclarationInitialized = true
            Log.i(
                TAG,
                "Android VPN underlying network updated " +
                    "available=${network != null} callback_current=${network == observedNetwork}",
            )
        }
    }

    var systemProxyAvailable = false
    var systemProxyEnabled = false
    fun addIncludePackage(builder: Builder, packageName: String) {
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
                    val bypassPackages = optionExcludePackages.filter { it != packageName }.toSet()
                    (appList + packageName).distinct().filter { !bypassPackages.contains(it) }.forEach {
                        addIncludePackage(builder, it)
                    }
                } else {
                    (appList + optionExcludePackages).distinct().filter { it != packageName }.forEach {
                        addExcludePackage(builder, it)
                    }
                }
            } else {
                if (optionIncludePackages.isNotEmpty()) {
                    val bypassPackages = optionExcludePackages.filter { it != packageName }.toSet()
                    (optionIncludePackages + packageName).distinct().filter { !bypassPackages.contains(it) }.forEach {
                        addIncludePackage(builder, it)
                    }
                } else {
                    optionExcludePackages.distinct().filter { it != packageName }.forEach {
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

        // Capture the physical network immediately before establish(), after
        // all other Builder work, to minimize the Android default-route handoff
        // window. A callback racing establish() is reconciled just after the
        // retained descriptor is admitted below.
        val initialUnderlyingNetwork = DefaultNetworkMonitor.defaultNetwork
        if (initialUnderlyingNetwork != null) {
            builder.setUnderlyingNetworks(arrayOf(initialUnderlyingNetwork))
        }

        Log.d(
            TAG,
            "openTun platform state permission=delegated_to_establish addresses_v4=$inet4AddressCount " +
            "addresses_v6=$inet6AddressCount routes_v4=$inet4RouteCount " +
            "routes_v6=$inet6RouteCount route_excludes=$routeExcludeCount " +
                "include_packages=$includePackageCount exclude_packages=$excludePackageCount " +
                "underlying_network_declared=${initialUnderlyingNetwork != null}",
        )
        service.requireTunCreationPrecondition()
        val pfd = builder.establish()
        if (pfd == null) {
            Log.w(TAG, "openTun permission outcome=not_prepared_or_revoked")
            error("android: the application is not prepared or is revoked")
        }
        if (!service.replaceTunFileDescriptor(pfd)) {
            error("android: VPN service stopped while creating TUN")
        }
        publishUnderlyingNetwork(
            DefaultNetworkMonitor.defaultNetwork,
            requireActiveVpn = false,
        )
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
            service.onTunCreationFailed()
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
