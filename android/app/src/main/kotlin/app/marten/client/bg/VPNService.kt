package app.marten.client.bg
import android.util.Log

import app.marten.client.Settings
import app.marten.client.R
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import app.marten.core.libbox.InterfaceUpdateListener
import app.marten.core.libbox.Notification
import app.marten.core.libbox.StringIterator
import app.marten.client.crashreporting.NativeCrashDiagnostics
import app.marten.core.libbox.TunOptions
import kotlinx.coroutines.delay
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.UUID

class VPNService : VpnService(), PlatformInterfaceWrapper {

    companion object {
        private const val TAG = "A/VPNService"
        private const val PLATFORM_VPN_RETIREMENT_TIMEOUT_MS = 5_000L
        private const val PLATFORM_VPN_RETIREMENT_POLL_MS = 50L
        private const val FAIL_CLOSED_VPN_IPV4_ADDRESS = "192.0.2.1"
        private const val FAIL_CLOSED_VPN_IPV4_PREFIX_LENGTH = 32
        private const val FAIL_CLOSED_VPN_IPV6_PREFIX_LENGTH = 128
        private const val RETIREMENT_VPN_IPV4_ADDRESS = "192.0.2.2"
        private const val STRICT_UNSUPPORTED_IPV4_ADDRESS = "192.0.2.3"
        private const val STRICT_UNSUPPORTED_IPV6_ADDRESS = "2001:db8::3"

        /**
         * Builder.establish() changes the one framework VPN slot before the
         * returned descriptor can be admitted by BoxService. Serialize every
         * precondition -> establish -> descriptor-install transaction so a
         * late data-plane callback can never deactivate a newer blocker and
         * then lose descriptor admission.
         */
        private val vpnBuilderTransactionLock = Any()
    }

    private lateinit var service: BoxService
    private val underlyingNetworkLock = Any()
    private var declaredUnderlyingNetwork: Network? = null
    private var underlyingNetworkDeclarationInitialized = false

    /**
     * Records whether Android's optional system-level bridge is enabled.
     * Marten's service-owned full-route blocker covers every managed lifecycle
     * transition and therefore does not require Always-on VPN. Android
     * lockdown remains the only OS guarantee after force-stop/process death,
     * but its absence must not reject an otherwise safe in-process start.
     */
    internal fun logSystemLockdownStatus() {
        val alwaysOn = runCatching { isAlwaysOn }.getOrDefault(false)
        val lockdown = runCatching { isLockdownEnabled }.getOrDefault(false)
        Log.i(
            TAG,
            "system kill-switch bridge always_on=$alwaysOn lockdown=$lockdown optional=true",
        )
    }

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
     * full-route blocking interface, observes that exact framework network,
     * and then closes it under one bounded release deadline.
     *
     * Android normally removes the VPN network when the descriptor returned by
     * Builder.establish() is closed. Some vendor builds can retain that first
     * framework interface after a native consumer used its fd, even though the
     * descriptor and core are both gone. Establishing a replacement makes the
     * framework retire the old interface. The replacement descriptor remains
     * open until Android publishes its marker Network; only then is it closed
     * and the exact Network is awaited to disappear. This prevents an
     * establish/close callback reorder from resurfacing `marten-stop` after the
     * next automatic generation has already passed its ownership gate. The
     * descriptor never crosses into the native core. No Activity or UI is
     * involved.
     */
    internal suspend fun retirePlatformVpnSessionAfterCoreStop(
        releaseDeadlineElapsedRealtimeMs: Long =
            SystemClock.elapsedRealtime() + PLATFORM_VPN_RETIREMENT_TIMEOUT_MS,
        terminalStopEpoch: Long? = null,
        retainForActiveSession: () -> Boolean = { false },
        retirementAllowed: () -> Boolean = { true },
    ): PlatformVpnRetirementOutcome = retirePlatformVpnSession(
        releaseDeadlineElapsedRealtimeMs,
        terminalStopEpoch,
        retainForActiveSession,
        retirementAllowed,
    )

    /**
     * Fail-closed escape hatch for a native cleanup that missed its deadline.
     * Replacing the framework VPN with the same full-route blocking interface
     * removes the stale data plane without opening the physical default route
     * while the one native close operation is allowed to finish in background.
     */
    internal suspend fun retirePlatformVpnSessionAfterFailedCoreCleanup(
        releaseDeadlineElapsedRealtimeMs: Long =
            SystemClock.elapsedRealtime() + PLATFORM_VPN_RETIREMENT_TIMEOUT_MS,
        terminalStopEpoch: Long? = null,
        retainForActiveSession: () -> Boolean = { false },
        retirementAllowed: () -> Boolean = { true },
    ): PlatformVpnRetirementOutcome = retirePlatformVpnSession(
        releaseDeadlineElapsedRealtimeMs,
        terminalStopEpoch,
        retainForActiveSession,
        retirementAllowed,
    )

    private suspend fun retirePlatformVpnSession(
        releaseDeadlineElapsedRealtimeMs: Long,
        terminalStopEpoch: Long?,
        retainForActiveSession: () -> Boolean,
        retirementAllowed: () -> Boolean,
    ): PlatformVpnRetirementOutcome {
        if (!retirementAllowed()) {
            Log.i(TAG, "skipping framework VPN retirement because Marten no longer owns the VPN slot")
            return PlatformVpnRetirementOutcome.RELEASED
        }
        if (service.hasUntrackedOwnVpnNetwork()) {
            Log.w(
                TAG,
                "refusing framework VPN retirement over an untracked previous-process Network",
            )
            return PlatformVpnRetirementOutcome.FAILED
        }
        // Android < 12 does not expose VPN ownerUid. A descriptor retained by
        // this exact service is therefore the ownership proof needed to retire
        // the session; relying only on ConnectivityManager would incorrectly
        // skip the replacement and could leave an OEM-retained VPN behind.
        if (!service.hasRetainedVpnDescriptor() && !BoxService.isOwnVpnActive(this)) {
            return PlatformVpnRetirementOutcome.RELEASED
        }
        if (!retirementAllowed()) {
            Log.i(TAG, "skipping framework VPN retirement after final ownership check")
            return PlatformVpnRetirementOutcome.RELEASED
        }

        Log.w(TAG, "retiring Android framework VPN session with a full-route blocking replacement")
        val retirementGeneration = newFailClosedVpnGeneration(FailClosedVpnKind.RETIREMENT)
        val retirementDescriptor = synchronized(vpnBuilderTransactionLock) {
            if (!retirementAllowed()) {
                return@synchronized null
            }
            if (service.hasUntrackedOwnVpnNetwork()) {
                return@synchronized null
            }
            if (!service.hasRetainedVpnDescriptor() && !BoxService.isOwnVpnActive(this)) {
                return@synchronized null
            }
            service.requireFailClosedTunInstallationPrecondition()
            val descriptor = runCatching {
                newFailClosedVpnBuilder(
                    session = "marten-stop",
                    generation = retirementGeneration,
                )
                    .establish()
            }.onFailure {
                Log.e(TAG, "failed to establish framework VPN retirement interface", it)
            }.getOrNull() ?: return@synchronized null
            if (!service.installFailClosedTunFileDescriptor(
                    descriptor,
                    replacingRetainedDescriptor = true,
                    generation = retirementGeneration,
                )
            ) {
                runCatching { descriptor.close() }
                return@synchronized null
            }
            descriptor
        } ?: return if (
            !retirementAllowed() ||
            (!service.hasRetainedVpnDescriptor() && !BoxService.isOwnVpnActive(this))
        ) {
            PlatformVpnRetirementOutcome.RELEASED
        } else {
            PlatformVpnRetirementOutcome.FAILED
        }

        var descriptorClosed = false
        var retainedForSuccessor = false
        try {
            val retirementNetwork = awaitPlatformVpnRetirementNetwork(
                retirementGeneration,
                releaseDeadlineElapsedRealtimeMs,
            ) {
                retirementAllowed() &&
                    (
                        terminalStopEpoch == null ||
                            ServiceLifecycleOwnership.isTerminalStopEpochCurrent(terminalStopEpoch) ||
                            retainForActiveSession()
                    )
            }
            if (retirementNetwork == null) {
                if (!retirementAllowed()) {
                    Log.i(TAG, "framework VPN retirement ownership was lost before marker publication")
                    return PlatformVpnRetirementOutcome.RELEASED
                }
                if (
                    retainForActiveSession() ||
                    (
                        terminalStopEpoch != null &&
                            !ServiceLifecycleOwnership.isTerminalStopEpochCurrent(terminalStopEpoch)
                    )
                ) {
                    retainedForSuccessor = true
                    Log.i(TAG, "pending framework VPN retirement descriptor retained for newer lifecycle owner")
                    return PlatformVpnRetirementOutcome.RETAINED
                }
                Log.e(TAG, "Android did not publish the framework VPN retirement network before deadline")
                return PlatformVpnRetirementOutcome.FAILED
            }

            if (retainForActiveSession()) {
                retainedForSuccessor = true
                Log.i(TAG, "framework VPN retirement descriptor retained for accepted successor")
                return PlatformVpnRetirementOutcome.RETAINED
            }

            val terminalCloseClaimed = terminalStopEpoch?.let { epoch ->
                ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(epoch) {
                    descriptorClosed = service.closeTunFileDescriptorIfCurrent(retirementDescriptor)
                }
            } ?: run {
                if (retainForActiveSession()) {
                    false
                } else {
                    descriptorClosed = service.closeTunFileDescriptorIfCurrent(retirementDescriptor)
                    true
                }
            }
            if (!terminalCloseClaimed) {
                retainedForSuccessor = true
                Log.i(TAG, "framework VPN retirement descriptor retained for newer lifecycle owner")
                return PlatformVpnRetirementOutcome.RETAINED
            }
            if (descriptorClosed) {
                Log.i(TAG, "framework VPN retirement descriptor closed after marker publication")
            } else {
                Log.e(TAG, "failed to close tracked framework VPN retirement descriptor")
            }
            if (!descriptorClosed) return PlatformVpnRetirementOutcome.FAILED

            return if (awaitPlatformVpnRetirementRelease(
                retirementNetwork,
                releaseDeadlineElapsedRealtimeMs,
                retirementAllowed,
            )) {
                PlatformVpnRetirementOutcome.RELEASED
            } else {
                PlatformVpnRetirementOutcome.FAILED
            }
        } finally {
            if (!retainedForSuccessor && !descriptorClosed) {
                descriptorClosed = service.closeTunFileDescriptorIfCurrent(retirementDescriptor)
                if (!descriptorClosed) {
                    runCatching { retirementDescriptor.close() }.onFailure {
                        Log.e(TAG, "failed to close unpublished framework VPN retirement descriptor", it)
                    }
                }
            }
        }
    }

    /**
     * Installs a service-owned packet sink before native setup/start. The same
     * descriptor is retained across native recovery and is atomically replaced
     * by the data-plane TUN only after Builder.establish() succeeds.
     */
    internal suspend fun ensureFailClosedVpn(): Boolean {
        if (service.isFailClosedTunBarrierActive()) {
            return true
        }
        if (service.hasFailClosedVpnDescriptor()) {
            // Another lifecycle owner has already installed a framework VPN
            // generation and is waiting for its exact marker Network. Reusing
            // that pending descriptor is safe; establishing here would stack a
            // third VPN generation over Stop -> Connect and can corrupt the
            // app UID's Android routing state.
            return true
        }
        if (
            !service.hasRetainedVpnDescriptor() &&
            BoxService.shouldRejectNewVpnStart(
                this,
                "startup blocker admission",
                explicitUserStart = service.hasPendingExplicitVpnStart(),
            )
        ) {
            return false
        }
        if (service.hasUntrackedOwnVpnNetwork()) {
            Log.w(
                TAG,
                "waiting for untracked previous-process VPN Network before startup blocker",
            )
            return false
        }

        // Android's VPN framework can retain the user's ACTIVATE_VPN consent
        // across reboot while still requiring VpnService.prepare() to refresh
        // the prepared package before the first Builder.establish(). The
        // foreground Connect path already performs this mandatory preflight;
        // native boot/package recovery has no Activity and must do the same
        // non-interactive check. A non-null Intent means consent is genuinely
        // unavailable, so never attempt to bypass it from the background.
        if (VpnService.prepare(this) != null) {
            Log.w(TAG, "fail-closed VPN admission requires renewed user consent")
            return false
        }

        var replacingRetainedDescriptor = false
        val installed = synchronized(vpnBuilderTransactionLock) {
            if (service.isFailClosedTunBarrierActive()) {
                replacingRetainedDescriptor = true
                return@synchronized true
            }
            if (service.hasFailClosedVpnDescriptor()) {
                replacingRetainedDescriptor = true
                return@synchronized true
            }
            if (
                !service.hasRetainedVpnDescriptor() &&
                BoxService.shouldRejectNewVpnStart(
                    this,
                    "serialized startup blocker admission",
                    explicitUserStart = service.hasPendingExplicitVpnStart(),
                )
            ) {
                return@synchronized false
            }
            if (service.hasUntrackedOwnVpnNetwork()) {
                return@synchronized false
            }
            replacingRetainedDescriptor = service.hasRetainedVpnDescriptor()
            service.requireFailClosedTunInstallationPrecondition()
            // A package-restored service establishes its blocker before the
            // owner-scoped monitor starts. Its cache is still null at that
            // point; resolve the physical Network now rather than publishing
            // a VPN with no underlying route on a connected device.
            val initialUnderlyingNetwork = DefaultNetworkMonitor.networkForSocket()
            val generation = newFailClosedVpnGeneration(FailClosedVpnKind.STARTUP)
            val descriptor = runCatching {
                newFailClosedVpnBuilder(
                    session = "marten-blocked",
                    generation = generation,
                )
                    .apply {
                        if (initialUnderlyingNetwork != null) {
                            setUnderlyingNetworks(arrayOf(initialUnderlyingNetwork))
                        }
                    }
                    .establish()
            }.onFailure {
                Log.e(TAG, "failed to establish fail-closed Android VPN", it)
            }.getOrNull() ?: return@synchronized false

            if (!service.installFailClosedTunFileDescriptor(
                    descriptor,
                    replacingRetainedDescriptor,
                    generation,
                )
            ) {
                runCatching { descriptor.close() }
                return@synchronized false
            }
            true
        }
        if (!installed) return false
        publishUnderlyingNetwork(
            DefaultNetworkMonitor.networkForSocket(),
            requireActiveVpn = false,
        )
        Log.i(
            TAG,
            if (replacingRetainedDescriptor) {
                "data-plane Android VPN atomically replaced by full-route fail-closed VPN"
            } else {
                "full-route fail-closed Android VPN established"
            },
        )
        return true
    }

    /**
     * Reports the unique marker addresses of Marten-owned fail-closed Networks.
     * A still-valid descriptor or a reusable startup/retirement address is not
     * enough: another Builder.establish() may already own the framework slot.
     */
    internal fun publishedFailClosedVpnMarkerAddresses(): Set<String> {
        val connectivity = getSystemService(ConnectivityManager::class.java) ?: return emptySet()
        return runCatching {
            connectivity.allNetworks.flatMapTo(linkedSetOf()) { network ->
                failClosedVpnMarkerAddresses(connectivity, network)
            }
        }.onFailure {
            Log.w(TAG, "failed to inspect fail-closed VPN network publication", it)
        }.getOrDefault(emptySet())
    }

    private fun newFailClosedVpnBuilder(
        session: String,
        generation: FailClosedVpnGeneration,
    ): Builder {
        val ipv4Address = when (generation.kind) {
            FailClosedVpnKind.STARTUP -> FAIL_CLOSED_VPN_IPV4_ADDRESS
            FailClosedVpnKind.RETIREMENT -> RETIREMENT_VPN_IPV4_ADDRESS
        }
        return Builder()
            .setSession(session)
            .setMtu(1280)
            .addAddress(ipv4Address, FAIL_CLOSED_VPN_IPV4_PREFIX_LENGTH)
            .addRoute("0.0.0.0", 0)
            .addAddress(generation.markerAddress, FAIL_CLOSED_VPN_IPV6_PREFIX_LENGTH)
            .addRoute("::", 0)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    setMetered(false)
                }
            }
    }

    private fun newFailClosedVpnGeneration(kind: FailClosedVpnKind): FailClosedVpnGeneration {
        val markerHex = UUID.randomUUID().toString().replace("-", "").take(24)
        val markerAddress = buildString {
            append("2001:db8")
            markerHex.chunked(4).forEach { group ->
                append(':')
                append(group)
            }
        }
        return FailClosedVpnGeneration(
            kind = kind,
            markerAddress = InetAddress.getByName(markerAddress).hostAddress.orEmpty(),
        )
    }

    private suspend fun awaitPlatformVpnRetirementNetwork(
        generation: FailClosedVpnGeneration,
        releaseDeadlineElapsedRealtimeMs: Long,
        retirementAllowed: () -> Boolean,
    ): Network? {
        val connectivity = getSystemService(ConnectivityManager::class.java) ?: return null
        while (retirementAllowed()) {
            val retirementNetwork = runCatching {
                findPlatformVpnRetirementNetwork(connectivity, generation)
            }.onFailure {
                Log.w(TAG, "failed to inspect framework VPN retirement publication", it)
            }.getOrNull()
            if (retirementNetwork != null) {
                Log.i(TAG, "framework VPN retirement network published")
                return retirementNetwork
            }

            val remainingMs = releaseDeadlineElapsedRealtimeMs - SystemClock.elapsedRealtime()
            if (remainingMs <= 0L) return null
            delay(minOf(PLATFORM_VPN_RETIREMENT_POLL_MS, remainingMs))
        }
        return null
    }

    private suspend fun awaitPlatformVpnRetirementRelease(
        retirementNetwork: Network,
        releaseDeadlineElapsedRealtimeMs: Long,
        retirementAllowed: () -> Boolean,
    ): Boolean {
        val connectivity = getSystemService(ConnectivityManager::class.java) ?: return false
        while (retirementAllowed()) {
            val stillPublished = runCatching {
                connectivity.allNetworks.any { it == retirementNetwork }
            }.onFailure {
                Log.w(TAG, "failed to inspect framework VPN retirement release", it)
            }.getOrElse { return false }
            if (!stillPublished) {
                Log.i(TAG, "framework VPN retirement network released")
                return true
            }

            val remainingMs = releaseDeadlineElapsedRealtimeMs - SystemClock.elapsedRealtime()
            if (remainingMs <= 0L) {
                Log.e(TAG, "Android retained the framework VPN retirement network past deadline")
                return false
            }
            delay(minOf(PLATFORM_VPN_RETIREMENT_POLL_MS, remainingMs))
        }

        Log.i(TAG, "framework VPN retirement ownership was lost while awaiting release")
        return true
    }

    private fun findPlatformVpnRetirementNetwork(
        connectivity: ConnectivityManager,
        generation: FailClosedVpnGeneration,
    ): Network? {
        val ownUid = applicationInfo.uid
        return connectivity.allNetworks.firstOrNull { network ->
            val capabilities = connectivity.getNetworkCapabilities(network)
                ?: return@firstOrNull false
            val vpnTransport = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            val ownerVerificationRequired = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            val ownerIsMarten = ownerVerificationRequired && capabilities.ownerUid == ownUid
            val hasRetirementAddress = connectivity.getLinkProperties(network)
                ?.linkAddresses
                ?.any { linkAddress ->
                    linkAddress.prefixLength == FAIL_CLOSED_VPN_IPV6_PREFIX_LENGTH &&
                        linkAddress.address.hostAddress == generation.markerAddress
                } == true
            isMartenRetirementNetworkCandidate(
                vpnTransport = vpnTransport,
                ownerVerificationRequired = ownerVerificationRequired,
                ownerIsMarten = ownerIsMarten,
                hasRetirementAddress = hasRetirementAddress,
            )
        }
    }

    private fun failClosedVpnMarkerAddresses(
        connectivity: ConnectivityManager,
        network: Network,
    ): Set<String> {
        val ownUid = applicationInfo.uid
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return emptySet()
        if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return emptySet()
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            capabilities.ownerUid != ownUid
        ) {
            return emptySet()
        }
        return connectivity.getLinkProperties(network)
            ?.linkAddresses
            .orEmpty()
            .asSequence()
            .filter { it.prefixLength == FAIL_CLOSED_VPN_IPV6_PREFIX_LENGTH }
            .mapNotNull { it.address.hostAddress }
            .filter { it.startsWith("2001:db8:", ignoreCase = true) }
            .toSet()
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        val underlyingNetwork = DefaultNetworkMonitor.networkForSocket()
            ?: error("android: missing underlying network for socket")
        val descriptor = ParcelFileDescriptor.fromFd(fd)
        try {
            // Network.bindSocket assigns the physical netId and requires an
            // unconnected descriptor. Protect only after that assignment so
            // netd never has to rewrite an already VPN-protected socket mark.
            underlyingNetwork.bindSocket(descriptor.fileDescriptor)
        } catch (error: Exception) {
            DefaultNetworkMonitor.reportSocketBindFailure(underlyingNetwork)
            throw IllegalStateException(
                "android: failed to bind socket to underlying network",
                error,
            )
        } finally {
            descriptor.close()
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
        val physicalSnapshot = DefaultNetworkMonitor.networkForSocket()
        synchronized(underlyingNetworkLock) {
            // The monitor publishes its snapshot before invoking BoxService.
            // Re-read it under this short lock so an older callback can never
            // overwrite a newer physical-network handoff.
            // Until the cold monitor has registered, its null cache must not
            // erase the physical Network assigned by Builder. Once registered,
            // the newest usable monitor publication wins over an older callback.
            val network = DefaultNetworkMonitor.defaultNetwork
                ?.takeIf(DefaultNetworkListener::isUsable)
                ?: physicalSnapshot?.takeIf(DefaultNetworkListener::isUsable)
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

    private fun addIncludePackage(builder: Builder, packageName: String): Boolean =
        try {
            builder.addAllowedApplication(packageName)
            true
        } catch (_: NameNotFoundException) {
            false
        }

    private fun addExcludePackage(builder: Builder, packageName: String): Boolean =
        try {
            builder.addDisallowedApplication(packageName)
            true
        } catch (_: NameNotFoundException) {
            false
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

    override fun openTun(options: TunOptions): Int = openRemoteTun(CoreTunSpec.from(options))

    internal fun openRemoteTun(options: CoreTunSpec): Int = synchronized(vpnBuilderTransactionLock) {
        Log.d(
            TAG,
            "openTun request mtu=${options.mtu} auto_route=${options.autoRoute} " +
                "http_proxy=${options.isHTTPProxyEnabled}",
        )
        try {
        val builder = Builder()
            .setSession("marten")
            .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        var hasInet4Address = false
        var inet4AddressCount = 0
        val inet4Address = options.inet4Address.iterator()
        while (inet4Address.hasNext()) {
            val address = inet4Address.next()
            builder.addAddress(address.address, address.prefix)
            hasInet4Address = true
            inet4AddressCount += 1
        }

        var hasInet6Address = false
        var inet6AddressCount = 0
        val inet6Address = options.inet6Address.iterator()
        while (inet6Address.hasNext()) {
            val address = inet6Address.next()
            builder.addAddress(address.address, address.prefix)
            hasInet6Address = true
            inet6AddressCount += 1
        }

        var inet4RouteCount = 0
        var inet6RouteCount = 0
        val routeExcludeCount = 0
        var includePackageCount = 0
        var excludePackageCount = 0
        var appRoutingMode = "full_device_strict"
        check(options.autoRoute) { "android: strict VPN requires auto_route" }
        check(hasInet4Address || hasInet6Address) {
            "android: strict VPN requires at least one native address family"
        }
        val dnsServer = InetAddress.getByName(options.dnsServer)
        check(
            (dnsServer is Inet4Address && hasInet4Address) ||
                (dnsServer is Inet6Address && hasInet6Address),
        ) { "android: strict VPN DNS family is not routed" }
        builder.addDnsServer(dnsServer)
        // Android only captures an address family when the VPN has both an
        // address and a route for that family. Marten's default core profile is
        // intentionally IPv4-only, so install a documentation-only address for
        // the unsupported family and still route it into this TUN. The native
        // stack cannot forward that family and drops it; Android must never
        // fall back to Wi-Fi/cellular for an application captured by this VPN.
        if (!hasInet4Address) {
            builder.addAddress(STRICT_UNSUPPORTED_IPV4_ADDRESS, FAIL_CLOSED_VPN_IPV4_PREFIX_LENGTH)
        }
        if (!hasInet6Address) {
            builder.addAddress(STRICT_UNSUPPORTED_IPV6_ADDRESS, FAIL_CLOSED_VPN_IPV6_PREFIX_LENGTH)
        }
        builder.addRoute("0.0.0.0", 0)
        inet4RouteCount = 1
        builder.addRoute("::", 0)
        inet6RouteCount = 1

        val optionIncludePackages = options.includePackage
        val optionExcludePackages = options.excludePackage
        val appRoutingPlan = resolveVpnAppRoutingPlan(
            ownPackageName = packageName,
            perAppProxyMode = Settings.perAppProxyMode,
            perAppProxyPackages = Settings.perAppProxyList,
            optionIncludePackages = optionIncludePackages,
            optionExcludePackages = optionExcludePackages,
        )
        when (appRoutingPlan) {
            is VpnAppRoutingPlan.IncludeOnly -> {
                appRoutingMode = "include_only"
                var installedExternalApplications = 0
                appRoutingPlan.packages.forEach { routedPackage ->
                    if (addIncludePackage(builder, routedPackage)) {
                        includePackageCount += 1
                        if (routedPackage != packageName) {
                            installedExternalApplications += 1
                        }
                    }
                }
                if (installedExternalApplications == 0) {
                    Log.w(
                        TAG,
                        "openTun routing rejected mode=include_only installed_external_applications=0",
                    )
                }
                check(installedExternalApplications > 0) {
                    "android: include-only VPN routing has no installed external applications"
                }
            }

            is VpnAppRoutingPlan.Exclude -> {
                appRoutingMode = "exclude"
                appRoutingPlan.packages.forEach { bypassedPackage ->
                    if (addExcludePackage(builder, bypassedPackage)) {
                        excludePackageCount += 1
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
                "app_routing=$appRoutingMode include_packages=$includePackageCount " +
                "exclude_packages=$excludePackageCount " +
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
        logSystemLockdownStatus()
        NativeCrashDiagnostics.setNetworkAdmissionAllowed(true)
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
