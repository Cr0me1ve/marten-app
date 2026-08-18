package app.marten.client.bg

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.TrafficStats
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import app.marten.client.Application
import app.marten.client.R
import app.marten.client.Settings
import app.marten.client.constant.Action
import app.marten.client.constant.Alert
import app.marten.client.constant.Status
import app.marten.native_resume.NativeResumeConfigStore
import app.marten.client.utils.GrpcClientProvider

import go.Seq
import app.marten.core.api.v2.hcommon.Empty
import app.marten.core.api.v2.hcore.CoreClient
import app.marten.core.api.v2.hcore.CoreStates
import app.marten.core.api.v2.hcore.TurncoatRouteEvidence
import app.marten.core.api.v2.hcore.UrlTestRequest
import app.marten.core.libbox.Libbox
import app.marten.core.mobile.Mobile


import app.marten.core.libbox.CommandServer
import app.marten.core.libbox.CommandServerHandler
import app.marten.core.libbox.InterfaceUpdateListener
import app.marten.core.libbox.Notification
import app.marten.core.libbox.PlatformInterface
import app.marten.core.libbox.SystemProxyStatus
import app.marten.client.BuildConfig
import app.marten.client.MainActivity
import app.marten.client.constant.Bugs
import app.marten.client.constant.ServiceMode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.net.NetworkInterface

class BoxService(
        private val service: Service,
        private val platformInterface: PlatformInterface
)  {

    companion object {
        private const val TAG = "A/BoxService"
        private const val CORE_WATCHDOG_CONFIRM_MS = 250L
        private const val CORE_WATCHDOG_GRPC_TIMEOUT_MS = 2_500L
        private const val CORE_RUNTIME_MONITOR_POLL_MS = 250L
        private const val CORE_RECOVERY_BACKOFF_MS = 2_000L
        private const val CORE_NATIVE_START_GRACE_MS = 20_000L
        private const val CORE_NATIVE_STARTING_STALL_MS = 20_000L
        private const val PROCESS_RECOVERY_RESTART_DELAY_MS = 2_000L
        private const val PROCESS_RECOVERY_REBIND_DELAY_MS = 3_000L
        private const val PROCESS_RECOVERY_REQUEST_CODE = 4031
        // Closing the retained Android descriptor and the native duplicate is
        // asynchronous under load. Two seconds produced false-positive
        // cleanup failures and killed the foreground app during an otherwise
        // healthy Disconnect/start cancellation. Keep this bounded, but give
        // Android enough time to remove the TUN before the fail-closed VPN
        // service replacement fallback is admitted.
        private const val TUN_RELEASE_TIMEOUT_MS = 5_000L
        private const val TUN_RELEASE_POLL_MS = 100L
        private const val CORE_RECOVERY_STALL_TIMEOUT_MS = 45_000L
        private const val CORE_RECOVERY_TURNCOAT_STALL_TIMEOUT_MS = 120_000L
        private const val CORE_FLUTTER_START_GRACE_MS = 5_000L
        private const val CORE_FLUTTER_STARTING_STALL_MS = 45_000L
        // Flutter first verifies the selected outbound, then Android performs
        // an independent VPN-network probe. Allow both bounded checks to finish
        // before native recovery is admitted; the shorter window raced a
        // successful slow route and could close the core during acknowledgement.
        // The Android VPN-bound GET can spend up to 30s bringing up a lazy
        // TURNcoat carrier on restricted mobile networks. Native recovery must
        // not tear that verified-route acknowledgement down mid-probe.
        private const val CORE_UNVERIFIED_STARTUP_RECOVERY_GRACE_MS = 45_000L
        private const val ROUTE_WATCHDOG_GROUP = "select"
        private const val ROUTE_WATCHDOG_INITIAL_DELAY_MS = 6_000L
        private const val ROUTE_WATCHDOG_ICMP_INITIAL_DELAY_MS = 2_000L
        private const val ROUTE_WATCHDOG_TURNCOAT_INITIAL_DELAY_MS = 60_000L
        private const val ROUTE_WATCHDOG_GRPC_TIMEOUT_MS = 8_000L
        private const val ROUTE_WATCHDOG_OPERATION_TIMEOUT_MS = 11_000L
        private const val ROUTE_RECOVERY_BACKOFF_MS = 10_000L
        private const val ROUTE_WATCHDOG_MAX_FAILURES = 3
        private const val ROUTE_WATCHDOG_TIMEOUT_DELAY = 65_535
        private const val ROUTE_WAKE_CHECK_DELAY_MS = 1_500L
        private const val NETWORK_ROUTE_RECOVERY_RETRY_MS = 2_000L
        private const val ROUTE_WATCHDOG_HEALTH_LOG_EVERY = 30
        private const val STARTUP_ROUTE_VERIFY_TIMEOUT_MS = 12_000L
        private const val STARTUP_ROUTE_VERIFY_TURNCOAT_TIMEOUT_MS = 75_000L
        private const val STARTUP_ROUTE_VERIFY_RETRY_MS = 700L
        private const val EXTERNAL_VPN_OWNERSHIP_LOSS_CONFIRMATIONS = 2
        private const val MARK_STARTED_TUN_SETTLE_MS = 750L
        private const val MARK_STARTED_TUN_POLL_MS = 100L

        private data class VpnOwnershipSnapshot(
            val visibilityKnown: Boolean,
            val known: Boolean,
            val anyActive: Boolean,
            val active: Boolean,
            val externalActive: Boolean,
            val interfaceNames: Set<String>,
        )

        @Volatile
        private var activeInstance: BoxService? = null

        private var initializeOnce = false
        private lateinit var workingDir: File
        private fun initialize() {
            if (BuildConfig.DEBUG) {
                System.setProperty("GODEBUG", "stacktraceback=2")
            }
            if (initializeOnce) return
            val baseDir = Application.application.filesDir

            baseDir.mkdirs()
            workingDir = Application.application.getExternalFilesDir(null) ?: return
            workingDir.mkdirs()
            val tempDir = Application.application.cacheDir
            tempDir.mkdirs()
            NativeResumeConfigStore.cleanupPlaintextLeases(Application.application)
            Log.d(TAG, "base dir: ${baseDir.path}")
            Log.d(TAG, "working dir: ${workingDir.path}")
            Log.d(TAG, "temp dir: ${tempDir.path}")

//
            //Mobile.setup(baseDir.path, workingDir.path, tempDir.path,  2L ,"127.0.0.1:{Setting}","",false,this)
//            Libbox.setup(baseDir.path, workingDir.path, tempDir.path, false)

//            Libbox.setup(SetupOptions().also {
//                it.basePath = baseDir.path
//                it.workingPath = workingDir.path
//                it.tempPath = tempDir.path
//                it.fixAndroidStack = Bugs.fixAndroidStack
//
//            })
            Libbox.redirectStderr("/dev/null")
            initializeOnce = true
            return
        }

        fun start() {
            val intent = Intent(Application.application, Settings.serviceClass())
            ContextCompat.startForegroundService(Application.application, intent)
        }

        fun connect(userInitiated: Boolean = false) {
            Settings.startCoreAfterStartingService = true
            val intent = Intent(Application.application, Settings.serviceClass())
                .setAction(Action.SERVICE_CONNECT)
                .putExtra(Action.EXTRA_USER_INITIATED, userInitiated)
            ContextCompat.startForegroundService(Application.application, intent)
        }

        fun stop() {
            val instance = activeInstance
            if (instance == null) {
                Log.i(TAG, "stop requested without an active Android service owner")
                return
            }

            // TileService, ShortcutActivity and MethodHandler share this
            // process. Admit their user stop directly into the service owner
            // so the caller can wait for the exact cleanup Job; a broadcast
            // leaves an avoidable registration window in which unbinding the
            // last client can destroy the service before it accepts Stop.
            if (Looper.myLooper() == Looper.getMainLooper()) {
                instance.stopService()
            } else {
                instance.mainHandler.post {
                    if (activeInstance === instance) {
                        instance.stopService()
                    }
                }
            }
        }

        suspend fun acknowledgeVerifiedRoute(): Boolean {
            val instance = activeInstance
            if (instance == null) {
                Log.w(TAG, "refusing verified-route acknowledgement: Android service instance is absent")
                return false
            }
            return instance.acknowledgeVerifiedRouteFromFlutter()
        }

        fun currentPlatformStatus(): Status =
            activeInstance?.status?.value ?: Status.Stopped

        /**
         * Returns the owner that can actually receive the stop request.
         *
         * The lifecycle registry's newest allocated token can briefly point
         * past [activeInstance] during rapid Android service replacement, so
         * it is not a safe stop-wait snapshot.
         */
        fun currentActiveOwnerToken(): Long? = activeInstance?.serviceOwnerToken

        fun isExternalVpnActive(context: Context, reason: String): Boolean {
            val ownership = readVpnOwnership(context)
            // ConnectivityManager can briefly retain the deactivated network
            // while Android transfers the single slot. Exact Marten ownership
            // wins that overlap; onRevoke()/prepare() still detect a real loss.
            val externalOwnsSlot = ownership.externalActive && !ownership.active
            if (externalOwnsSlot) {
                Log.w(TAG, "another app owns an active VPN network during $reason")
            }
            return externalOwnsSlot
        }

        fun isOwnVpnActive(context: Context): Boolean {
            return readVpnOwnership(context).active
        }

        fun shouldRejectNewVpnStart(
            context: Context,
            reason: String,
            explicitUserStart: Boolean = false,
        ): Boolean {
            val ownership = readVpnOwnership(context)
            val instance = activeInstance
            val retainedDescriptorValid = instance?.let {
                synchronized(it.fileDescriptorLock) {
                    it.fileDescriptor?.fileDescriptor?.valid() == true
                }
            } == true
            val currentGenerationOwnsVpn =
                retainedDescriptorValid &&
                    instance?.status?.value != Status.Stopping &&
                    instance?.status?.value != Status.Stopped &&
                    (!ownership.known || ownership.active)
            val externalOwnsSlot = ownership.externalActive && !ownership.active
            val rejected = shouldRejectNewVpnGeneration(
                vpnMode = Settings.serviceMode == ServiceMode.VPN,
                explicitUserStart = explicitUserStart,
                currentGenerationOwnsVpn = currentGenerationOwnsVpn,
                vpnNetworkVisibilityKnown = ownership.visibilityKnown,
                anyVpnNetworkActive = ownership.anyActive,
                externalVpnNetworkActive = externalOwnsSlot,
            )
            if (rejected) {
                Log.w(
                    TAG,
                    "rejecting new Marten VPN generation during $reason; " +
                        "visibility_known=${ownership.visibilityKnown} " +
                        "any_vpn=${ownership.anyActive} external_vpn_owns_slot=$externalOwnsSlot " +
                        "current_generation_owns_vpn=$currentGenerationOwnsVpn " +
                        "explicit_user_start=$explicitUserStart",
                )
            }
            return rejected
        }

        private fun readVpnOwnership(context: Context): VpnOwnershipSnapshot {
            val connectivity = context.getSystemService(ConnectivityManager::class.java)
                ?: return VpnOwnershipSnapshot(
                    visibilityKnown = false,
                    known = false,
                    anyActive = false,
                    active = false,
                    externalActive = false,
                    interfaceNames = emptySet(),
                )
            val vpnNetworks = runCatching {
                connectivity.allNetworks.filter { network ->
                    connectivity.getNetworkCapabilities(network)
                        ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
                }
            }.onFailure {
                Log.w(TAG, "failed to inspect active Android VPN networks", it)
            }.getOrElse {
                return VpnOwnershipSnapshot(
                    visibilityKnown = false,
                    known = false,
                    anyActive = false,
                    active = false,
                    externalActive = false,
                    interfaceNames = emptySet(),
                )
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                return VpnOwnershipSnapshot(
                    visibilityKnown = true,
                    known = false,
                    anyActive = vpnNetworks.isNotEmpty(),
                    active = false,
                    externalActive = false,
                    interfaceNames = emptySet(),
                )
            }
            val ownUid = context.applicationInfo.uid
            val ownerUids = vpnNetworks.associateWith { network ->
                connectivity.getNetworkCapabilities(network)?.ownerUid ?: -1
            }
            // Android can redact ownerUid even on API levels that expose the
            // property. Treat that as unknown ownership so runtime health uses
            // its conservative retained-descriptor/interface fallback. New
            // generation admission still sees anyActive and remains blocked.
            val ownershipKnown = ownerUids.values.none { it == -1 }
            val ownNetworks = if (ownershipKnown) {
                ownerUids.filterValues { it == ownUid }.keys
            } else {
                emptySet()
            }
            val externalActive = ownershipKnown && ownerUids.values.any { it != ownUid }
            return VpnOwnershipSnapshot(
                visibilityKnown = true,
                known = ownershipKnown,
                anyActive = vpnNetworks.isNotEmpty(),
                active = ownNetworks.isNotEmpty(),
                externalActive = externalActive,
                interfaceNames = ownNetworks.mapNotNull { network ->
                    connectivity.getLinkProperties(network)?.interfaceName
                }.toSet(),
            )
        }

        suspend fun awaitAuthoritativeStop(ownerToken: Long, timeoutMs: Long): Boolean {
            val stoppedInstance = activeInstance ?: return true
            if (stoppedInstance.serviceOwnerToken != ownerToken) return false

            return withTimeoutOrNull(timeoutMs.coerceAtLeast(0L)) {
                var completed: Boolean? = null
                while (completed == null) {
                    val stopJob = stoppedInstance.serviceStopJob
                    if (stopJob == null) {
                        if (
                            stoppedInstance.status.value == Status.Stopped &&
                            stoppedInstance.coreShutdownCompleted
                        ) {
                            completed = true
                            continue
                        }
                        // A non-main-thread request can be posted to the owner.
                        // Do not mistake that short admission window for a
                        // stopped core or race teardown against native close.
                        delay(10L)
                        continue
                    }

                    stopJob.join()
                    completed =
                        stoppedInstance.status.value == Status.Stopped &&
                            stoppedInstance.coreShutdownCompleted
                }
                completed == true
            } ?: false
        }

        fun isQuiescentBoundOwner(ownerToken: Long): Boolean {
            val instance = activeInstance ?: return false
            if (instance.serviceOwnerToken != ownerToken) return false
            return isQuiescentBoundServiceState(
                status = instance.status.value ?: Status.Stopped,
                coreShutdownCompleted = instance.coreShutdownCompleted,
                // The completed Job is retained so late waiters can join it.
                // It is not an outstanding cleanup barrier and must not make a
                // stopped, bound service wait for an onDestroy that may never
                // arrive while MainActivity intentionally keeps the binding.
                stopOperationActive = instance.serviceStopJob?.isActive == true,
            )
        }


    }

    private val fileDescriptorLock = Any()
    private var fileDescriptor: ParcelFileDescriptor? = null
    private var tunDescriptorAdmissionClosed = false
    @Volatile
    private var tunGeneration = 0L
    private val serviceOwnerToken = ServiceLifecycleOwnership.acquire()
    private val serviceJob = SupervisorJob()
    private val serviceScope = CoroutineScope(serviceJob + Dispatchers.IO)

    private val status = MutableLiveData(Status.Stopped)
    private val binder = ServiceBinder(status)
    private val notification = ServiceNotification(status, service)
//    private var boxService: BoxService? = null
    private var commandServer: CommandServer? = null
    private val lifecycleLock = Any()
    private var receiverRegistered = false
    @Volatile
    private var startGeneration = 0L
    @Volatile
    private var keepStoppedNotificationOnDestroy = false
    @Volatile
    private var closedByStopService = false
    @Volatile
    // A service created only by bindService() has never admitted a core/TUN
    // start, so it begins quiescent. startService() flips this to false before
    // it touches service-owned native state.
    private var coreShutdownCompleted = true
    @Volatile
    private var serviceStopJob: Job? = null
    @Volatile
    private var coreRuntimeMonitorJob: Job? = null
    @Volatile
    private var coreWatchdogJob: Job? = null
    @Volatile
    private var coreRecoveryJob: Job? = null
    @Volatile
    private var coreRecoveryAdmissionRetryJob: Job? = null
    @Volatile
    private var routeWatchdogJob: Job? = null
    @Volatile
    private var coreWatchdogSawHealthyCore = false
    @Volatile
    private var coreRecoveryInProgress = false
    @Volatile
    private var lastCoreRecoveryAttemptAt = 0L
    @Volatile
    private var coreRecoveryAttemptStartedAtElapsed = 0L
    @Volatile
    private var vpnServiceReplacementRequested = false
    @Volatile
    private var routeWatchdogFailures = 0
    @Volatile
    private var lastRouteRecoveryAttemptAt = 0L
    @Volatile
    private var routeWatchdogImmediateCheckJob: Job? = null
    @Volatile
    private var routeWatchdogCheckInProgress = false
    @Volatile
    private var externalVpnWatchdogJob: Job? = null
    @Volatile
    private var vpnOwnershipRevoked = false
    @Volatile
    private var vpnOwnershipWasEstablished = false
    @Volatile
    private var explicitUserVpnStartPending = false
    @Volatile
    private var routeWatchdogHealthyChecks = 0
    @Volatile
    private var routeWatchdogDegraded = false
    @Volatile
    private var lastVpnDataPlaneProof: VpnDataPlaneProof? = null
    @Volatile
    private var lastTunTrafficSnapshot: TunTrafficSnapshot? = null
    @Volatile
    private var lastSelectedOutboundType = ""
    @Volatile
    private var networkGeneration = 0L
    @Volatile
    private var observedUnderlyingNetwork: android.net.Network? = null
    @Volatile
    private var underlyingNetworkInitialized = false
    @Volatile
    private var networkRecoveryJob: Job? = null
    private val routeWatchdogCheckLock = Any()
    private val vpnDataPlaneProofLock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val vpnDataPlaneProbe = VpnDataPlaneProbe(service)

    init {
        activeInstance = this
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Action.SERVICE_CLOSE -> {
                    stopService(intent.getBooleanExtra(Action.EXTRA_KEEP_NOTIFICATION, false))
                }

                Action.SERVICE_MARK_STARTED -> {
                    serviceScope.launch(Dispatchers.IO) {
                        verifyAndMarkCoreRuntimeStarted("platform started signal")
                    }
                }

                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        serviceUpdateIdleMode()
                        if (!Application.powerManager.isDeviceIdleMode) {
                            requestRouteWatchdogCheck("device idle exit")
                        }
                    }
                }

                Intent.ACTION_SCREEN_ON -> {
                    requestRouteWatchdogCheck("screen on")
                }

                Intent.ACTION_USER_PRESENT -> {
                    requestRouteWatchdogCheck("user present", delayMs = 0L)
                }
            }
        }
    }
    


    private var activeProfileName = ""

    private fun nextStartGeneration(): Long {
        return synchronized(lifecycleLock) {
            startGeneration += 1
            startGeneration
        }
    }

    private fun cancelPendingStarts(): Long {
        return synchronized(lifecycleLock) {
            startGeneration += 1
            startGeneration
        }
    }

    private fun currentStartGeneration(): Long = synchronized(lifecycleLock) { startGeneration }

    private fun isCurrentLifecycleGeneration(generation: Long): Boolean =
        generation == currentStartGeneration()

    private fun shouldContinueStart(generation: Long): Boolean {
        return ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) &&
            shouldContinueCoreLifecycleOperation(
            operationGeneration = generation,
            currentGeneration = currentStartGeneration(),
            userSessionActive = Settings.startedByUser,
        ) &&
            status.value != Status.Stopping &&
            status.value != Status.Stopped
    }

    private suspend fun finishCancelledStart(generation: Long, reason: String) {
        if (shouldContinueStart(generation)) return
        if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
            Log.i(TAG, "stale service start owner discarded after $reason")
            return
        }
        if (!isCurrentLifecycleGeneration(generation)) {
            Log.i(TAG, "stale service start generation=$generation discarded after $reason")
            return
        }
        if (Settings.startedByUser && status.value != Status.Stopping && status.value != Status.Stopped) {
            Log.i(TAG, "service start cancelled by a newer start ($reason)")
            return
        }
        Log.w(TAG, "service start cancelled after $reason; closing mobile core")
        explicitUserVpnStartPending = false
        stopCoreRuntimeMonitor()
        stopCoreWatchdog()
        stopRouteWatchdog()
        stopExternalVpnWatchdog()
        resetUnderlyingNetworkGeneration()
        val cleanupResult = MobileCoreLifecycle.run {
            if (!isCurrentLifecycleGeneration(generation)) return@run null
            NativeResumeConfigStore.cleanupPlaintextLeases(service)
            DefaultNetworkMonitor.stop(serviceOwnerToken)
            runCatching {
                Mobile.stop()
            }.onFailure {
                Log.w(TAG, "error stopping mobile core after cancelled start", it)
            }
            closeMobileCoreAndAwaitTunQuiescence(
                "cancelled service start: $reason",
                serviceStopping = true,
            )
        }
        if (cleanupResult == null) return
        coreShutdownCompleted = cleanupResult.completed
        if (requiresCoreCleanupEscalation(
                cleanupResult.closeCompleted,
                cleanupResult.tunQuiescent,
            )
        ) {
            replaceVpnServiceAfterCoreCleanupFailure(
                "cancelled service start did not release the native core and TUN",
                preserveUserSession = false,
            )
            return
        }
        withContext(Dispatchers.Main) {
            if (
                isCurrentLifecycleGeneration(generation) &&
                (!Settings.startedByUser || status.value == Status.Stopping || status.value == Status.Stopped)
            ) {
                status.value = Status.Stopped
                notification.close()
                service.stopSelf()
            }
        }
    }

    private suspend fun startService(generation: Long) {
        if (
            !ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) ||
            !shouldContinueCoreLifecycleOperation(
                operationGeneration = generation,
                currentGeneration = currentStartGeneration(),
                userSessionActive = Settings.startedByUser,
            )
        ) {
            Log.i(TAG, "stale service start generation=$generation ignored")
            return
        }
        try {
            keepStoppedNotificationOnDestroy = false
            routeWatchdogDegraded = false
            invalidateVpnDataPlaneProof("service start")
            lastSelectedOutboundType = ""
            Log.d(TAG, "starting service")
            withContext(Dispatchers.Main) {
                status.value = Status.Starting
                notification.show(activeProfileName, R.string.status_starting)
            }

            val selectedConfigPath = Settings.activeConfigPath
            if (selectedConfigPath.isBlank()) {
                stopAndAlert(Alert.EmptyConfiguration)
                return
            }

            activeProfileName = Settings.activeProfileName

            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, R.string.status_starting)
                binder.broadcast {
                    it.onServiceResetLogs(listOf())
                }
            }

            if (!ServiceLifecycleOwnership.awaitPendingCleanup(serviceOwnerToken)) {
                if (ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
                    stopAndAlert(Alert.StartService, "previous service cleanup did not finish")
                }
                return
            }
            if (!shouldContinueStart(generation)) {
                finishCancelledStart(generation, "waiting for previous service cleanup")
                return
            }
            if (!MobileCoreCloser.waitForCloseToFinish("service start")) {
                stopAndAlert(Alert.StartService, "previous core is still stopping")
                return
            }
            if (!shouldContinueStart(generation)) {
                finishCancelledStart(generation, "waiting for previous core close")
                return
            }
            closedByStopService = false
            coreShutdownCompleted = false
            vpnOwnershipRevoked = false
            vpnOwnershipWasEstablished = false
            if (Settings.serviceMode == ServiceMode.VPN) {
                // Ownership can be lost after Builder.establish() but before
                // route verification publishes Started. Observe the entire
                // admitted generation instead of relying on onRevoke() or on
                // the post-Started watchdog alone.
                startExternalVpnWatchdog()
            }
            resetUnderlyingNetworkGeneration()
            if (!DefaultNetworkMonitor.start(serviceOwnerToken, ::onUnderlyingNetworkObserved)) {
                finishCancelledStart(generation, "default network monitor ownership")
                return
            }
            if (!shouldContinueStart(generation)) {
                finishCancelledStart(generation, "default network monitor start")
                return
            }
            if (shouldYieldToExternalVpn("service start before mobile setup")) {
                stopForExternalVpnOnMain("service start before mobile setup")
                return
            }
            Libbox.setMemoryLimit(!Settings.disableMemoryLimit)
            val setupCompleted = try {
                MobileCoreLifecycle.run {
                    if (!shouldContinueStart(generation)) return@run false
                    Log.d(
                        TAG,
                        "core setup request mode=background debug=${Settings.debugMode} " +
                            "service_mode=${Settings.serviceMode} platform_interface=true",
                    )
                    Mobile.setup(
                        Settings.baseDir,
                        Settings.workingDir,
                        Settings.tempDir,
                        4L,
                        "127.0.0.1:${Settings.grpcServiceModePort}",
                        "",
                        Settings.debugMode,
                        platformInterface,
                    )
                    Log.d(
                        TAG,
                        "core setup complete mode=background platform_interface=true ${Mobile.runtimeState()}",
                    )
                    true
                }
//                Libbox.newService(content,platformInterface)

            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                stopAndAlert(Alert.CreateService, e.message)
                return
            }
            if (!setupCompleted) {
                finishCancelledStart(generation, "mobile setup admission")
                return
            }
            if (!shouldContinueStart(generation)) {
                finishCancelledStart(generation, "mobile setup")
                return
            }
            val startCoreInService = Settings.startCoreAfterStartingService
            if (startCoreInService) {
                Settings.startCoreAfterStartingService = false
                if (!shouldContinueStart(generation)) {
                    finishCancelledStart(generation, "before mobile start")
                    return
                }
                if (shouldYieldToExternalVpn("service start before mobile start")) {
                    stopForExternalVpnOnMain("service start before mobile start")
                    return
                }
                startCoreRuntimeMonitor(nativeStartup = true)
                startCoreWatchdog()
                val routeVerified = startMobileCoreFromNativePath(
                    Settings.activeConfigPath,
                    "service start",
                    generation,
                    stopServiceOnRouteFailure = true,
                )
                if (!routeVerified) {
                    Log.w(TAG, "native service startup ended after terminal VPN data-plane failure")
                    return
                }
            }
            if (!shouldContinueStart(generation)) {
                finishCancelledStart(generation, "mobile start")
                return
            }
            if (startCoreInService) {
                markCoreRuntimeStarted(routeVerified = true, generation = generation)
            } else {
                startCoreRuntimeMonitor()
            }
//            if (delayStart) {
//                delay(1000L)
//            }

//            newService.start()
//            boxService = newService
//            commandServer?.setService(boxService)


        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            stopAndAlert(Alert.StartService, e.message)
            return
        }
    }

    fun serviceReload() {
        runBlocking {
            serviceReload0()
        }
    }

    suspend fun serviceReload0() {
        if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
            Log.i(TAG, "stale service reload ignored")
            return
        }
        val generation = nextStartGeneration()
        notification.close()
        stopCoreRuntimeMonitor()
        stopCoreWatchdog()
        stopRouteWatchdog()
        stopExternalVpnWatchdog()
        status.postValue(Status.Starting)

        val cleanupResult = MobileCoreLifecycle.run {
            if (!shouldContinueCoreLifecycleOperation(
                    operationGeneration = generation,
                    currentGeneration = currentStartGeneration(),
                    userSessionActive = Settings.startedByUser,
                )
            ) {
                return@run null
            }
            DefaultNetworkMonitor.clearListener(serviceOwnerToken)
            runCatching {
                Mobile.stop()
            }.onFailure {
                Log.w(TAG, "error stopping mobile core during service reload", it)
            }
            closeMobileCoreAndAwaitTunQuiescence("service reload")
        }
        coreShutdownCompleted = cleanupResult?.completed == true

//        boxService?.apply {
//            runCatching {
//                close()
//            }.onFailure {
//                writeLog("service: error when closing: $it")
//            }
//            Seq.destroyRef(refnum)
//        }
//        boxService = null
        if (cleanupResult == null) return
        if (requiresCoreCleanupEscalation(
                cleanupResult.closeCompleted,
                cleanupResult.tunQuiescent,
            )
        ) {
            replaceVpnServiceAfterCoreCleanupFailure(
                "service reload did not release the native core and TUN",
                preserveUserSession = true,
            )
            return
        }
        if (shouldContinueStart(generation)) {
            startService(generation)
        }
    }

    fun getSystemProxyStatus(): SystemProxyStatus {
        val status = SystemProxyStatus()
        if (service is VPNService) {
            status.available = service.systemProxyAvailable
            status.enabled = service.systemProxyEnabled
        }
        return status
    }

    fun setSystemProxyEnabled(isEnabled: Boolean) {
        serviceReload()
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun serviceUpdateIdleMode() {
        if (Application.powerManager.isDeviceIdleMode) {
//            boxService?.pause()
            //Mobile.pause()
        } else {
            // The current mobile ABI no longer exposes Mobile.wake().
//            boxService?.wake()
        }
    }

    private fun stopService(keepNotification: Boolean = false, vpnRevoked: Boolean = false) {
        if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
            Log.i(TAG, "stale service stop ignored")
            return
        }
        // A user-mediated takeover authorizes exactly one TUN creation attempt.
        // No stop, revoke, or later recovery may inherit that authorization.
        explicitUserVpnStartPending = false
        cancelProcessRecovery()
        if (vpnRevoked) {
            vpnOwnershipRevoked = true
            Log.w(TAG, "VPN permission revoked by Android; stopping without session restore")
            Settings.startedByUser = false
            Settings.startCoreAfterStartingService = false
            keepStoppedNotificationOnDestroy = false
            closedByStopService = true
            binder.broadcast { callback ->
                callback.onServiceAlert(Alert.VpnRevoked.ordinal, null)
            }
        }
        if (serviceStopJob?.isActive == true && !vpnRevoked) {
            Log.i(TAG, "coalescing duplicate service stop")
            return
        }
        val stopGeneration = cancelPendingStarts()
        closedByStopService = true
        synchronized(fileDescriptorLock) {
            // Seal descriptor admission atomically with the visible stop
            // transition. Otherwise openTun could pass its pre-stop checks,
            // lose the race to closeTunFileDescriptor(), and install a new
            // framework-owned descriptor after cleanup had already run.
            tunDescriptorAdmissionClosed = true
            if (status.value != Status.Stopped) {
                status.value = Status.Stopping
            }
        }
        keepStoppedNotificationOnDestroy = keepNotification && !vpnRevoked
        if (receiverRegistered) {
            runCatching {
                service.unregisterReceiver(receiver)
            }.onFailure {
                Log.w(TAG, "error unregistering service receiver", it)
            }
            receiverRegistered = false
        }
        notification.stopDynamicUpdates()
        if (!keepStoppedNotificationOnDestroy) {
            notification.close()
        } else {
            notification.show(activeProfileName, R.string.status_stopping)
        }
        stopCoreRuntimeMonitor()
        stopCoreWatchdog()
        stopRouteWatchdog()
        stopExternalVpnWatchdog()
        Settings.startedByUser = false
        Settings.startCoreAfterStartingService = false
        resetUnderlyingNetworkGeneration()
        val newStopJob = serviceScope.launch(
            Dispatchers.IO,
            start = CoroutineStart.LAZY,
        ) {
            val coreClosed = MobileCoreLifecycle.run {
                if (
                    !isCurrentLifecycleGeneration(stopGeneration) ||
                    !ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)
                ) {
                    Log.i(TAG, "discarding stale service stop generation=$stopGeneration")
                    return@run null
                }
                DefaultNetworkMonitor.clearListener(serviceOwnerToken)
                runCatching {
                    Mobile.stop()
                }.onFailure {
                    Log.w(TAG, "error stopping mobile core", it)
                }
                NativeResumeConfigStore.cleanupPlaintextLeases(service)
                DefaultNetworkMonitor.stop(serviceOwnerToken)
                closeMobileCoreAndAwaitTunQuiescence(
                    "service stop",
                    serviceStopping = true,
                )
            }
            if (coreClosed == null) return@launch
            coreShutdownCompleted = coreClosed.completed
            val externalVpnActive = isExternalVpnActive(service, "platform VPN retirement")
            val ownershipRevoked = vpnOwnershipRevoked
            val vpnService = service as? VPNService
            if (shouldRetirePlatformVpnAfterCoreStop(
                    coreStopped = coreClosed.completed,
                    vpnService = vpnService != null,
                    vpnOwnershipRevoked = ownershipRevoked,
                    externalVpnActive = externalVpnActive,
                )
            ) {
                if (!vpnService!!.retirePlatformVpnSessionAfterCoreStop {
                        !vpnOwnershipRevoked &&
                            !isExternalVpnActive(service, "platform VPN retirement final gate")
                    }
                ) {
                    Log.w(
                        TAG,
                        "Android framework VPN retirement is deferred after completed core stop",
                    )
                }
            } else if (coreClosed.completed && service is VPNService && ownershipRevoked) {
                Log.i(TAG, "skipping Android VPN retirement after ownership revoke")
            }
            if (requiresCoreCleanupEscalation(
                    coreClosed.closeCompleted,
                    coreClosed.tunQuiescent,
                )
            ) {
                replaceVpnServiceAfterCoreCleanupFailure(
                    "manual service stop did not release the native core and TUN",
                    preserveUserSession = false,
                )
                return@launch
            }
            withContext(Dispatchers.Main) {
                if (
                    !isCurrentLifecycleGeneration(stopGeneration) ||
                    !ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)
                ) {
                    return@withContext
                }
                status.value = Status.Stopped
                if (keepStoppedNotificationOnDestroy) {
                    notification.showStopped(activeProfileName)
                } else {
                    notification.close()
                }
                service.stopSelf()
            }
//            commandServer?.setService(null)
//            boxService?.apply {
//                runCatching {
//                    close()
//                }.onFailure {
//                    writeLog("service: error when closing: $it")
//                }
//                //Seq.destroyRef(refnum)
//            }

//            boxService = null
//            Libbox.registerLocalDNSTransport(null)

//            commandServer?.apply {
//                close()
//                Seq.destroyRef(refnum)
//            }
//            commandServer = null
        }
        serviceStopJob = newStopJob
        newStopJob.start()
    }

    fun replaceTunFileDescriptor(pfd: ParcelFileDescriptor): Boolean {
        var accepted = false
        var acceptedTunGeneration = 0L
        val previous = synchronized(fileDescriptorLock) {
            if (
                !tunDescriptorAdmissionClosed &&
                shouldAcceptTunFileDescriptor(
                    ownerIsCurrent = ServiceLifecycleOwnership.isCurrent(serviceOwnerToken),
                    userSessionActive = Settings.startedByUser,
                    status = status.value ?: Status.Stopped,
                )
            ) {
                accepted = true
                val previous = fileDescriptor
                fileDescriptor = pfd
                tunGeneration += 1
                acceptedTunGeneration = tunGeneration
                previous
            } else {
                null
            }
        }
        if (!accepted) {
            Log.w(TAG, "closing tun file descriptor created after service stop")
            runCatching { pfd.close() }.onFailure {
                Log.w(TAG, "error closing late tun file descriptor", it)
            }
            MobileCoreCloser.closeAsync("late tun after service stop")
            return false
        }
        if (Settings.serviceMode == ServiceMode.VPN) {
            vpnOwnershipWasEstablished = true
            explicitUserVpnStartPending = false
            invalidateVpnDataPlaneProof("Android TUN generation=$acceptedTunGeneration")
        }
        if (previous != null && previous !== pfd) {
            runCatching { previous.close() }.onFailure {
                Log.w(TAG, "error closing previous tun file descriptor", it)
            }
        }
        return true
    }

    fun onTunCreationFailed() {
        // Builder.establish() is the single attempt authorized by the user's
        // prepare flow. A retry must pass fresh ownership admission and must
        // never take a VPN that the user selected after this attempt began.
        explicitUserVpnStartPending = false
    }

    private fun closeTunFileDescriptor() {
        var closedTunGeneration = 0L
        val pfd = synchronized(fileDescriptorLock) {
            val pfd = fileDescriptor
            fileDescriptor = null
            if (pfd != null) {
                tunGeneration += 1
                closedTunGeneration = tunGeneration
            }
            pfd
        }
        if (pfd != null) {
            invalidateVpnDataPlaneProof("closed Android TUN generation=$closedTunGeneration")
            runCatching { pfd.close() }.onFailure {
                Log.w(TAG, "error closing tun file descriptor", it)
            }
        }
    }

    private fun startCoreRuntimeMonitor(nativeStartup: Boolean = false) {
        if (coreRuntimeMonitorJob?.isActive == true) return
        val generation = currentStartGeneration()
        val neverStartedGraceMs =
            if (nativeStartup) CORE_NATIVE_START_GRACE_MS else CORE_FLUTTER_START_GRACE_MS
        val startingStallMs =
            if (nativeStartup) CORE_NATIVE_STARTING_STALL_MS else CORE_FLUTTER_STARTING_STALL_MS
        val unverifiedTimeoutMs =
            if (nativeStartup) nativeUnverifiedStartupRecoveryTimeoutMs() else unverifiedStartupRecoveryTimeoutMs()
        val startupOwner = if (nativeStartup) "native service" else "Flutter"
        if (nativeStartup) {
            Log.w(
                TAG,
                "native startup recovery monitors armed " +
                    "grace_ms=$neverStartedGraceMs starting_stall_ms=$startingStallMs " +
                    "unverified_ms=$unverifiedTimeoutMs",
            )
        }

        coreRuntimeMonitorJob = serviceScope.launch(Dispatchers.IO) {
            val coreClient = GrpcClientProvider.coreClient(CORE_WATCHDOG_GRPC_TIMEOUT_MS)
            var sawStartedCore = false
            var startedAtElapsed = 0L
            val monitorStartedAtElapsed = SystemClock.elapsedRealtime()
            while (isActive) {
                try {
                    val serviceStatus = status.value
                    if (serviceStatus == Status.Stopped || serviceStatus == Status.Stopping) return@launch
                    if (serviceStatus == Status.Started) return@launch
                    val coreState = readCoreState(coreClient)
                    if (coreState == CoreStates.STARTED) {
                        if (!sawStartedCore) {
                            Log.i(TAG, "core runtime started; waiting for verified selected-route signal")
                            sawStartedCore = true
                            startedAtElapsed = SystemClock.elapsedRealtime()
                        }
                        val elapsedMs = SystemClock.elapsedRealtime() - startedAtElapsed
                        if (
                            shouldRecoverUnverifiedRunningCore(
                                sawStartedCore = sawStartedCore,
                                coreState = coreState,
                                userSessionActive = shouldWatchCore(generation),
                                elapsedMs = elapsedMs,
                                timeoutMs = unverifiedTimeoutMs,
                            )
                        ) {
                            if (requestCoreRecovery("selected-route verification timed out", generation)) {
                                Log.w(
                                    TAG,
                                    "selected-route verification did not complete within ${elapsedMs}ms; " +
                                        "entering native retry recovery",
                                )
                                return@launch
                            }
                        }
                    } else if (
                        shouldRecoverUnverifiedStartedCore(
                            sawStartedCore = sawStartedCore,
                            coreState = coreState,
                            userSessionActive = shouldWatchCore(generation),
                        )
                    ) {
                        if (
                            requestCoreRecovery(
                                "selected server unavailable during $startupOwner startup",
                                generation,
                            )
                        ) {
                            Log.w(TAG, "unverified startup core stopped; entering native retry recovery")
                            return@launch
                        }
                    } else if (
                        shouldRecoverNeverStartedCore(
                            sawStartedCore = sawStartedCore,
                            coreState = coreState,
                            userSessionActive = shouldWatchCore(generation),
                            elapsedMs = SystemClock.elapsedRealtime() - monitorStartedAtElapsed,
                            timeoutMs = neverStartedGraceMs,
                        )
                    ) {
                        if (requestCoreRecovery("core did not start within bounded grace period", generation)) {
                            Log.w(
                                TAG,
                                "core did not start within ${neverStartedGraceMs}ms; " +
                                    "entering native retry recovery",
                            )
                            return@launch
                        }
                    } else if (
                        shouldRecoverStalledStartingCore(
                            sawStartedCore = sawStartedCore,
                            coreState = coreState,
                            userSessionActive = shouldWatchCore(generation),
                            elapsedMs = SystemClock.elapsedRealtime() - monitorStartedAtElapsed,
                            timeoutMs = startingStallMs,
                        )
                    ) {
                        if (requestCoreRecovery("core remained STARTING beyond bounded startup window", generation)) {
                            Log.w(
                                TAG,
                                "core remained STARTING for ${startingStallMs}ms; " +
                                    "entering native retry recovery",
                            )
                            return@launch
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    if (status.value == Status.Started) return@launch
                    Log.d(TAG, "core runtime monitor waiting for started core", e)
                }
                delay(CORE_RUNTIME_MONITOR_POLL_MS)
            }
        }
    }

    private fun unverifiedStartupRecoveryTimeoutMs(): Long {
        val verificationTimeout = if (Settings.activeConfigUsesTurncoat) {
            STARTUP_ROUTE_VERIFY_TURNCOAT_TIMEOUT_MS
        } else {
            STARTUP_ROUTE_VERIFY_TIMEOUT_MS
        }
        return verificationTimeout + CORE_UNVERIFIED_STARTUP_RECOVERY_GRACE_MS
    }

    private fun nativeUnverifiedStartupRecoveryTimeoutMs(): Long =
        unverifiedStartupRecoveryTimeoutMs() + ROUTE_WATCHDOG_GRPC_TIMEOUT_MS

    private fun stopCoreRuntimeMonitor() {
        coreRuntimeMonitorJob?.cancel()
        coreRuntimeMonitorJob = null
    }

    private fun startExternalVpnWatchdog() {
        if (externalVpnWatchdogJob?.isActive == true) return

        externalVpnWatchdogJob = serviceScope.launch(Dispatchers.IO) {
            var consecutiveOwnVpnMisses = 0
            while (isActive) {
                delay(vpnOwnershipWatchdogPollDelayMs(Application.powerManager.isInteractive))
                if (!shouldWatchCore()) continue
                val externalVpnActive = shouldYieldToExternalVpn("runtime watchdog")
                if (externalVpnActive) {
                    stopForExternalVpnOnMain("runtime watchdog")
                    return@launch
                }
                val ownership = readVpnOwnership(service)
                if (ownership.active) {
                    vpnOwnershipWasEstablished = true
                    consecutiveOwnVpnMisses = 0
                    continue
                }
                if (!ownership.known || !vpnOwnershipWasEstablished) {
                    consecutiveOwnVpnMisses = 0
                    continue
                }
                consecutiveOwnVpnMisses += 1
                if (shouldStopForLostVpnOwnership(
                        externalVpnActive = externalVpnActive,
                        authorizationRevoked = false,
                        ownershipKnown = ownership.known,
                        ownVpnActive = ownership.active,
                        consecutiveOwnVpnMisses = consecutiveOwnVpnMisses,
                        requiredMisses = EXTERNAL_VPN_OWNERSHIP_LOSS_CONFIRMATIONS,
                    )
                ) {
                    stopForExternalVpnOnMain(
                        "runtime watchdog lost Marten VPN network " +
                            "confirmations=$consecutiveOwnVpnMisses",
                    )
                    return@launch
                }
            }
        }
    }

    private fun stopExternalVpnWatchdog() {
        externalVpnWatchdogJob?.cancel()
        externalVpnWatchdogJob = null
    }

    private suspend fun verifyAndMarkCoreRuntimeStarted(reason: String) {
        val generation = currentStartGeneration()
        if (!shouldContinueStart(generation)) return
        val routeVerified = verifyNativeStartupRoute(
            usesTurncoat = configUsesTurncoat(Settings.activeConfigPath),
            reason = reason,
            generation = generation,
            stopServiceOnFailure = true,
        )
        if (routeVerified) {
            markCoreRuntimeStarted(routeVerified = true, generation = generation)
        }
    }

    private suspend fun acknowledgeVerifiedRouteFromFlutter(): Boolean {
        val generation = currentStartGeneration()
        if (!shouldContinueStart(generation)) return false
        if (Settings.serviceMode == ServiceMode.VPN && !hasReusableVpnDataPlaneProof(generation)) {
            // Flutter may reach this acknowledgement before the lazy
            // TURNcoat/Hysteria carrier has finished its first recovery. Use
            // the same bounded, real VPN-network retry gate as native startup
            // instead of tearing the service down after one slow GET.
            val verified = verifyNativeStartupRoute(
                usesTurncoat = configUsesTurncoat(Settings.activeConfigPath),
                reason = "Flutter started acknowledgement",
                generation = generation,
                stopServiceOnFailure = true,
            )
            if (!verified) return false
        }
        return markCoreRuntimeStarted(routeVerified = true, generation = generation)
    }

    private fun hasReusableVpnDataPlaneProof(generation: Long): Boolean {
        if (Settings.serviceMode != ServiceMode.VPN) return true
        val proof = currentVpnDataPlaneProof(generation) ?: return false
        val proofAgeMs = SystemClock.elapsedRealtime() - proof.completedAtElapsedRealtimeMs
        return proofAgeMs in 0..VPN_DATA_PLANE_PROOF_REUSE_MS
    }

    private fun currentVpnDataPlaneProof(generation: Long): VpnDataPlaneProof? {
        return synchronized(vpnDataPlaneProofLock) {
            val proof = lastVpnDataPlaneProof ?: return@synchronized null
            proof.takeIf {
                it.startGeneration == generation &&
                    it.networkGeneration == networkGeneration &&
                    it.tunGeneration == tunGeneration &&
                    it.vpnNetworkHandle == vpnDataPlaneProbe.currentVpnNetworkHandle()
            }
        }
    }

    private fun recordVpnDataPlaneProof(
        proofStartGeneration: Long,
        proofNetworkGeneration: Long,
        proofTunGeneration: Long,
        proofVpnNetworkHandle: Long,
    ): Boolean {
        val trafficSnapshot = readTunTrafficSnapshot(readTunRuntimeHealth())
        return synchronized(vpnDataPlaneProofLock) {
            if (
                proofStartGeneration != startGeneration ||
                proofNetworkGeneration != networkGeneration ||
                proofTunGeneration != tunGeneration ||
                proofVpnNetworkHandle != vpnDataPlaneProbe.currentVpnNetworkHandle()
            ) {
                return@synchronized false
            }
            lastVpnDataPlaneProof = VpnDataPlaneProof(
                startGeneration = proofStartGeneration,
                networkGeneration = proofNetworkGeneration,
                tunGeneration = proofTunGeneration,
                vpnNetworkHandle = proofVpnNetworkHandle,
                completedAtElapsedRealtimeMs = SystemClock.elapsedRealtime(),
            )
            lastTunTrafficSnapshot = trafficSnapshot
            true
        }
    }

    private fun invalidateVpnDataPlaneProof(reason: String) {
        val invalidated = synchronized(vpnDataPlaneProofLock) {
            val hadProof = lastVpnDataPlaneProof != null
            lastVpnDataPlaneProof = null
            lastTunTrafficSnapshot = null
            hadProof
        }
        if (invalidated) {
            Log.i(TAG, "invalidating VPN data-plane proof: $reason")
        }
    }

    private suspend fun markCoreRuntimeStarted(
        routeVerified: Boolean = false,
        generation: Long = currentStartGeneration(),
    ): Boolean {
        if (!shouldContinueStart(generation)) {
            Log.i(TAG, "discarding stale core-start signal generation=$generation")
            return false
        }
        if (coreRecoveryInProgress && !routeVerified) {
            Log.w(TAG, "ignoring unverified core started signal while route recovery is in progress")
            return false
        }
        if (!hasReusableVpnDataPlaneProof(generation)) {
            Log.w(TAG, "refusing Started without a fresh current-generation VPN data-plane proof")
            withContext(Dispatchers.Main) {
                if (shouldContinueStart(generation)) {
                    status.value = Status.Starting
                    notification.show(activeProfileName, R.string.status_starting)
                }
            }
            return false
        }
        val tunHealth = awaitTunRuntimeHealthForStarted()
        if (!tunHealth.healthy) {
            Log.w(TAG, "refusing Started without a healthy Android TUN: ${tunHealth.summary}")
            withContext(Dispatchers.Main) {
                if (shouldContinueStart(generation)) {
                    status.value = Status.Starting
                    notification.show(activeProfileName, R.string.status_starting)
                }
            }
            if (!coreRecoveryInProgress) {
                requestCoreRecovery("verified route did not produce a healthy Android TUN", generation)
            }
            return false
        }
        if (activeProfileName.isBlank()) {
            activeProfileName = Settings.activeProfileName
        }
        val currentJob = currentCoroutineContext()[Job]
        coreRuntimeMonitorJob?.takeIf { it != currentJob }?.cancel()
        coreRuntimeMonitorJob = null
        cancelCoreRecoveryAdmissionRetry()
        val marked = withContext(Dispatchers.Main) {
            if (!shouldContinueStart(generation)) {
                return@withContext false
            }
            // TUN or Android Network ownership can change after the first
            // proof check while TUN health settles. Revalidate at the exact
            // publication point so a proof from the replaced generation can
            // never promote the new generation to Started.
            if (!hasReusableVpnDataPlaneProof(generation)) {
                Log.w(TAG, "refusing Started because VPN data-plane proof changed before publication")
                status.value = Status.Starting
                notification.show(activeProfileName, R.string.status_starting)
                return@withContext false
            }
            status.value = Status.Started
            notification.show(activeProfileName, R.string.status_started)
            true
        }
        if (!marked) {
            if (shouldContinueStart(generation)) {
                routeWatchdogDegraded = true
                requestRouteWatchdogCheck("VPN data-plane proof changed before Started", delayMs = 0L)
            }
            return false
        }
        if (Settings.serviceMode == ServiceMode.VPN) {
            vpnOwnershipWasEstablished = true
        }
        notification.start()
        startExternalVpnWatchdog()
        startCoreWatchdog()
        startRouteWatchdog()
        Log.d(TAG, "accepted Started after platform readiness: ${tunHealth.summary}")
        return true
    }

    private suspend fun awaitTunRuntimeHealthForStarted(): TunRuntimeHealth {
        var health = readTunRuntimeHealth()
        if (health.healthy) return health
        val deadline = SystemClock.elapsedRealtime() + MARK_STARTED_TUN_SETTLE_MS
        while (SystemClock.elapsedRealtime() < deadline) {
            delay(MARK_STARTED_TUN_POLL_MS)
            health = readTunRuntimeHealth()
            if (health.healthy) return health
        }
        return health
    }

    private fun startCoreWatchdog() {
        if (coreWatchdogJob?.isActive == true) return
        val generation = currentStartGeneration()

        coreWatchdogJob = serviceScope.launch(Dispatchers.IO) {
            coreWatchdogSawHealthyCore = false
            val coreClient = GrpcClientProvider.coreClient(CORE_WATCHDOG_GRPC_TIMEOUT_MS)

            while (isActive) {
                try {
                    delay(coreWatchdogPollDelayMs(coreRecoveryInProgress))
                    if (!shouldWatchCore(generation)) {
                        coreWatchdogSawHealthyCore = false
                        continue
                    }

                    val coreState = readCoreStateSnapshot(coreClient)
                    if (coreRecoveryInProgress) {
                        val recoveryStartedAt = coreRecoveryAttemptStartedAtElapsed
                        val elapsedMs = if (recoveryStartedAt > 0L) {
                            SystemClock.elapsedRealtime() - recoveryStartedAt
                        } else {
                            0L
                        }
                        val stallTimeoutMs = coreRecoveryStallTimeoutMs()
                        if (shouldRestartProcessForStalledCoreRecovery(
                                recoveryInProgress = true,
                                userSessionActive = shouldWatchCore(generation),
                                coreState = coreState,
                                elapsedMs = elapsedMs,
                                timeoutMs = stallTimeoutMs,
                            )
                        ) {
                            replaceVpnServiceForStalledCoreRecovery(coreState, elapsedMs)
                            return@launch
                        }
                        continue
                    }

                    if (isCoreRuntimeHealthy(coreState)) {
                        coreWatchdogSawHealthyCore = true
                        continue
                    }

                    if (!coreWatchdogSawHealthyCore) continue

                    delay(CORE_WATCHDOG_CONFIRM_MS)
                    if (!isActive || !shouldWatchCore(generation)) continue
                    if (isCoreRuntimeHealthy(readCoreStateSnapshot(coreClient))) {
                        coreWatchdogSawHealthyCore = true
                        continue
                    }

                    requestCoreRecovery("local core runtime is not started", generation)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    Log.w(TAG, "core watchdog iteration failed", e)
                }
            }
        }
    }

    private fun stopCoreWatchdog() {
        coreWatchdogJob?.cancel()
        coreWatchdogJob = null
        coreWatchdogSawHealthyCore = false
        cancelCoreRecoveryAdmissionRetry()
        val recoveryJob = synchronized(lifecycleLock) {
            val active = coreRecoveryJob
            coreRecoveryJob = null
            coreRecoveryInProgress = false
            lastCoreRecoveryAttemptAt = 0L
            coreRecoveryAttemptStartedAtElapsed = 0L
            active
        }
        recoveryJob?.cancel()
    }

    private fun cancelCoreRecoveryAdmissionRetry() {
        val retryJob = synchronized(lifecycleLock) {
            val active = coreRecoveryAdmissionRetryJob
            coreRecoveryAdmissionRetryJob = null
            active
        }
        retryJob?.cancel()
    }

    private fun startRouteWatchdog() {
        if (routeWatchdogJob?.isActive == true) return

        routeWatchdogJob = serviceScope.launch(Dispatchers.IO) {
            routeWatchdogFailures = 0
            routeWatchdogHealthyChecks = 0
            val initialDelay = routeWatchdogInitialDelayMs()
            Log.i(TAG, "route watchdog started; first check in ${initialDelay}ms")
            delay(initialDelay)
            val healthClient = GrpcClientProvider.coreClient(CORE_WATCHDOG_GRPC_TIMEOUT_MS)
            val routeClient = GrpcClientProvider.coreClient(ROUTE_WATCHDOG_GRPC_TIMEOUT_MS)

            while (isActive) {
                runRouteWatchdogCheck("periodic", healthClient, routeClient)
                delay(routeWatchdogPollDelayMs())
            }
        }
    }

    private fun stopRouteWatchdog() {
        routeWatchdogJob?.cancel()
        routeWatchdogJob = null
        routeWatchdogImmediateCheckJob?.cancel()
        routeWatchdogImmediateCheckJob = null
        routeWatchdogFailures = 0
        routeWatchdogHealthyChecks = 0
        lastRouteRecoveryAttemptAt = 0L
        Log.i(TAG, "route watchdog stopped")
    }

    private fun resetUnderlyingNetworkGeneration() {
        networkRecoveryJob?.cancel()
        networkRecoveryJob = null
        invalidateVpnDataPlaneProof("underlying network monitor reset")
        networkGeneration = 0L
        observedUnderlyingNetwork = null
        underlyingNetworkInitialized = false
    }

    private fun onUnderlyingNetworkObserved(network: android.net.Network?) {
        if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
            Log.i(TAG, "ignoring underlying network callback for stale service owner")
            return
        }
        val previous = observedUnderlyingNetwork
        observedUnderlyingNetwork = network
        if (!underlyingNetworkInitialized) {
            underlyingNetworkInitialized = true
            Log.i(TAG, "underlying network generation=0 initialized available=${network != null}")
            return
        }
        if (previous == network) return

        if (service is VPNService) {
            service.updateUnderlyingNetwork(network)
        }

        val generation = ++networkGeneration
        invalidateVpnDataPlaneProof("underlying network generation=$generation")
        Log.w(TAG, "underlying network changed generation=$generation available=${network != null}")
        val wasConnected = status.value == Status.Started
        val wasRecovering = networkRecoveryJob?.isActive == true
        if ((!wasConnected && !wasRecovering) || !shouldWatchCore()) return

        launchNetworkRouteRecovery(
            generation = generation,
            reason = "underlying network generation=$generation",
            settleDelayMs = ROUTE_WAKE_CHECK_DELAY_MS,
            replaceActive = true,
        )
    }

    private fun launchNetworkRouteRecovery(
        generation: Long,
        reason: String,
        settleDelayMs: Long,
        replaceActive: Boolean,
        forceTurncoatCarrierRetirement: Boolean = false,
    ) {
        if (!shouldWatchCore() || status.value == Status.Stopped || status.value == Status.Stopping) return
        val activeJob = networkRecoveryJob
        if (!replaceActive && activeJob?.isActive == true) {
            Log.i(TAG, "network route recovery already active; keeping current owner ($reason)")
            return
        }
        activeJob?.cancel()

        mainHandler.post {
            if (
                generation == networkGeneration &&
                shouldWatchCore() &&
                status.value != Status.Stopped &&
                status.value != Status.Stopping
            ) {
                if (activeProfileName.isBlank()) {
                    activeProfileName = Settings.activeProfileName
                }
                status.value = Status.Starting
                notification.show(activeProfileName, R.string.status_recovering)
            }
        }

        networkRecoveryJob = serviceScope.launch(Dispatchers.IO) {
            val currentJob = currentCoroutineContext()[Job]
            try {
                if (settleDelayMs > 0L) delay(settleDelayMs)
                recoverNetworkRoute(
                    generation = generation,
                    reason = reason,
                    forceTurncoatCarrierRetirement = forceTurncoatCarrierRetirement,
                )
            } finally {
                synchronized(lifecycleLock) {
                    if (networkRecoveryJob === currentJob) {
                        networkRecoveryJob = null
                    }
                }
            }
        }
    }

    private suspend fun recoverNetworkRoute(
        generation: Long,
        reason: String,
        forceTurncoatCarrierRetirement: Boolean,
    ) {
        val healthClient = GrpcClientProvider.coreClient(CORE_WATCHDOG_GRPC_TIMEOUT_MS)
        val routeClient = GrpcClientProvider.coreClient(ROUTE_WATCHDOG_GRPC_TIMEOUT_MS)
        var routeAttempt = 0
        var forcedTurncoatRetirementAttempted = false

        while (currentCoroutineContext().isActive) {
            if (generation != networkGeneration || !shouldWatchCore()) {
                Log.i(TAG, "discarding stale network route recovery ($reason)")
                return
            }
            if (underlyingNetworkInitialized && observedUnderlyingNetwork == null) {
                Log.i(TAG, "waiting for an underlying network before route recovery generation=$generation")
                delay(NETWORK_ROUTE_RECOVERY_RETRY_MS)
                continue
            }
            if (shouldYieldToExternalVpn("network route recovery")) {
                stopForExternalVpnOnMain("network route recovery")
                return
            }
            if (coreRecoveryInProgress) {
                delay(NETWORK_ROUTE_RECOVERY_RETRY_MS)
                continue
            }

            val coreState = readCoreStateSnapshot(healthClient)
            if (!isCoreRuntimeHealthy(coreState)) {
                Log.w(TAG, "local core became unhealthy during network route recovery: state=$coreState")
                requestCoreRecovery("network route recovery found an unhealthy core: state=$coreState")
                return
            }

            val forceTurncoatCarrier = forceTurncoatCarrierRetirement && !forcedTurncoatRetirementAttempted
            if (forceTurncoatCarrier) {
                // Consume the stronger reset before crossing the native boundary:
                // a partial failure must not repeatedly retire a freshly rebuilding
                // carrier on every retry.
                forcedTurncoatRetirementAttempted = true
            }
            val resetResult = runCatching {
                MobileCoreLifecycle.run {
                    if (forceTurncoatCarrier) {
                        Mobile.resetNetworkForRouteRecovery()
                    } else {
                        Mobile.resetNetwork()
                    }
                }
            }
            if (resetResult.isFailure) {
                val resetKind = if (forceTurncoatCarrier) "forced TURNcoat carrier reset" else "network reset"
                Log.w(TAG, "native $resetKind failed ($reason); retrying", resetResult.exceptionOrNull())
                delay(NETWORK_ROUTE_RECOVERY_RETRY_MS)
                continue
            }
            val resetKind = if (forceTurncoatCarrier) "forced TURNcoat carrier reset" else "network reset"
            Log.i(TAG, "native $resetKind completed ($reason); awaiting fresh VPN data-plane proof")

            if (!beginRouteWatchdogCheck()) {
                delay(NETWORK_ROUTE_RECOVERY_RETRY_MS)
                continue
            }
            val result = try {
                runCatching {
                    checkSelectedRoute(routeClient, requireVpnDataPlane = true)
                }.getOrElse {
                    if (it is CancellationException) throw it
                    RouteHealth(false, "network route check error: ${it.message ?: it.javaClass.simpleName}")
                }
            } finally {
                endRouteWatchdogCheck()
            }
            if (generation != networkGeneration || !shouldWatchCore()) {
                Log.i(TAG, "discarding stale VPN data-plane result ($reason)")
                return
            }
            if (result.outboundType.isNotBlank()) {
                lastSelectedOutboundType = result.outboundType
            }

            routeAttempt += 1
            if (
                isCurrentNetworkRouteProof(
                    proofGeneration = generation,
                    currentGeneration = networkGeneration,
                    routeHealthy = result.healthy,
                    userSessionActive = shouldWatchCore(),
                )
            ) {
                routeWatchdogFailures = 0
                routeWatchdogDegraded = false
                Log.i(TAG, "network route recovered ($reason, attempt $routeAttempt): ${result.summary}")
                markCoreRuntimeStarted(routeVerified = true)
                return
            }

            Log.w(TAG, "network route still unavailable ($reason, attempt $routeAttempt): ${result.summary}")
            if (result.requiresCoreRecovery && routeAttempt >= 2) {
                Log.w(TAG, "VPN data plane remained unavailable after network reset; rebuilding core and TUN")
                requestCoreRecovery(
                    "network route recovery could not restore the VPN data plane: ${result.summary}",
                )
                return
            }
            delay(NETWORK_ROUTE_RECOVERY_RETRY_MS)
        }
    }

    private fun requestRouteWatchdogCheck(reason: String, delayMs: Long = ROUTE_WAKE_CHECK_DELAY_MS) {
        if (status.value == Status.Stopped || status.value == Status.Stopping) return
        startRouteWatchdog()
        if (routeWatchdogImmediateCheckJob?.isActive == true) return

        routeWatchdogImmediateCheckJob = serviceScope.launch(Dispatchers.IO) {
            if (delayMs > 0L) delay(delayMs)
            val healthClient = GrpcClientProvider.coreClient(CORE_WATCHDOG_GRPC_TIMEOUT_MS)
            val routeClient = GrpcClientProvider.coreClient(ROUTE_WATCHDOG_GRPC_TIMEOUT_MS)
            runRouteWatchdogCheck(reason, healthClient, routeClient, logHealthy = true, logSkips = true)
        }
    }

    private suspend fun runRouteWatchdogCheck(
        reason: String,
        healthClient: CoreClient,
        routeClient: CoreClient,
        logHealthy: Boolean = false,
        logSkips: Boolean = false,
    ) {
        if (!beginRouteWatchdogCheck()) {
            if (logSkips) Log.d(TAG, "route watchdog skipped ($reason): another check is running")
            return
        }

        try {
            if (shouldYieldToExternalVpn("route watchdog check")) {
                routeWatchdogFailures = 0
                stopForExternalVpnOnMain("route watchdog check")
                return
            }
            if (!shouldWatchCore()) {
                routeWatchdogFailures = 0
                if (logSkips) Log.i(TAG, "route watchdog skipped ($reason): no user-started core")
                return
            }
            if (coreRecoveryInProgress) {
                if (logSkips) Log.i(TAG, "route watchdog skipped ($reason): recovery already in progress")
                return
            }
            if (networkRecoveryJob?.isActive == true) {
                if (logSkips) Log.i(TAG, "route watchdog skipped ($reason): network recovery already owns validation")
                return
            }
            val coreState = readCoreStateSnapshot(healthClient)
            if (!isCoreRuntimeHealthy(coreState)) {
                routeWatchdogFailures = 0
                Log.w(TAG, "route watchdog found an unhealthy local core ($reason): state=$coreState")
                requestCoreRecovery("route watchdog found an unhealthy core: state=$coreState")
                return
            }

            val tunHealth = readTunRuntimeHealth()
            val tunTrafficAdvanced = hasTunTrafficAdvanced(
                previous = lastTunTrafficSnapshot,
                current = readTunTrafficSnapshot(tunHealth),
            )
            val nowElapsedRealtimeMs = SystemClock.elapsedRealtime()
            val currentProof = currentVpnDataPlaneProof(currentStartGeneration())
            val usesTurncoat = configUsesTurncoat(Settings.activeConfigPath)
            val scheduledVpnDataPlaneProof = Settings.serviceMode == ServiceMode.VPN &&
                shouldRunVpnDataPlaneProbe(
                    forced = status.value == Status.Starting,
                    degraded = routeWatchdogDegraded,
                    turncoatRoute = usesTurncoat,
                    deviceInteractive = Application.powerManager.isInteractive,
                    tunTrafficAdvanced = tunTrafficAdvanced,
                    lastProofElapsedRealtimeMs = currentProof?.completedAtElapsedRealtimeMs ?: 0L,
                    nowElapsedRealtimeMs = nowElapsedRealtimeMs,
                )
            val turncoatEvidence = if (tunHealth.healthy && usesTurncoat) {
                runCatching {
                    readTurncoatRouteEvidence(routeClient)
                }.onFailure {
                    Log.w(TAG, "route watchdog could not read TURNcoat carrier evidence", it)
                }.getOrNull()
            } else {
                null
            }
            val turncoatCarrierNeedsProof = usesTurncoat && (
                turncoatEvidence == null ||
                    !isLiveTurncoatCarrier(
                        rxProofCount = turncoatEvidence.rx_proof_count,
                        activeSessions = turncoatEvidence.active_sessions,
                    )
            )
            val requireVpnDataPlane = scheduledVpnDataPlaneProof || turncoatCarrierNeedsProof
            val result = if (!tunHealth.healthy) {
                RouteHealth(
                    healthy = false,
                    summary = tunHealth.summary,
                    outboundType = lastSelectedOutboundType,
                    requiresCoreRecovery = true,
                )
            } else if (requireVpnDataPlane) {
                runCatching {
                    checkSelectedRoute(routeClient, requireVpnDataPlane = true)
                }.getOrElse {
                    if (it is CancellationException) throw it
                    RouteHealth(
                        false,
                        "VPN data-plane watchdog error: ${it.javaClass.simpleName}",
                        lastSelectedOutboundType,
                        requiresCoreRecovery = true,
                    )
                }
            } else if (usesTurncoat && currentProof != null) {
                val proofAgeMs = (nowElapsedRealtimeMs - currentProof.completedAtElapsedRealtimeMs)
                    .coerceAtLeast(0L)
                RouteHealth(
                    true,
                    "recent VPN data-plane proof retained age=${proofAgeMs}ms; " +
                        "TURNcoat carrier telemetry active=${turncoatEvidence?.active_sessions ?: -1} " +
                        "ready=${turncoatEvidence?.ready_sessions ?: -1}",
                )
            } else if (usesTurncoat) {
                RouteHealth(
                    false,
                    "TURNcoat route has no current VPN data-plane proof",
                    lastSelectedOutboundType,
                    requiresCoreRecovery = true,
                )
            } else {
                runCatching {
                    checkSelectedRoute(routeClient)
                }.getOrElse {
                    if (it is CancellationException) throw it
                    RouteHealth(false, "route watchdog check error: ${it.message ?: it.javaClass.simpleName}")
                }
            }
            if (result.healthy) {
                if (result.outboundType.isNotBlank()) {
                    lastSelectedOutboundType = result.outboundType
                }
                routeWatchdogHealthyChecks += 1
                val recoveredFromDegradedRoute = routeWatchdogDegraded && status.value == Status.Starting
                if (routeWatchdogFailures > 0) {
                    Log.i(
                        TAG,
                        "route watchdog recovered after $routeWatchdogFailures failed check(s): ${result.summary}",
                    )
                } else if (logHealthy || routeWatchdogHealthyChecks % ROUTE_WATCHDOG_HEALTH_LOG_EVERY == 0) {
                    Log.i(TAG, "route watchdog healthy ($reason): ${result.summary}")
                }
                routeWatchdogFailures = 0
                routeWatchdogDegraded = false
                if (recoveredFromDegradedRoute && !coreRecoveryInProgress) {
                    markCoreRuntimeStarted(routeVerified = true)
                }
            } else {
                if (result.outboundType.isNotBlank()) {
                    lastSelectedOutboundType = result.outboundType
                }
                routeWatchdogFailures += 1
                routeWatchdogDegraded = true
                markRouteDegraded(result.summary)
                Log.w(
                    TAG,
                    "route watchdog failed ($reason, $routeWatchdogFailures/$ROUTE_WATCHDOG_MAX_FAILURES): ${result.summary}",
                )
                val isICMPRoute = lastSelectedOutboundType.equals("icmp", ignoreCase = true)
                val recoveryThreshold = if (result.requiresCoreRecovery) 2 else ROUTE_WATCHDOG_MAX_FAILURES
                if (shouldEscalateRouteRecovery(routeWatchdogFailures, recoveryThreshold)) {
                    recoverRoute("selected route unavailable: ${result.summary}")
                    routeWatchdogFailures = 0
                } else if (isICMPRoute && !result.requiresCoreRecovery) {
                    Log.i(TAG, "ICMP route recovery remains in-place before bounded core restart; Android TUN is retained")
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            routeWatchdogFailures += 1
            routeWatchdogDegraded = true
            markRouteDegraded(e.message ?: e.javaClass.simpleName)
            Log.w(
                TAG,
                "route watchdog iteration failed ($reason, $routeWatchdogFailures/$ROUTE_WATCHDOG_MAX_FAILURES)",
                e,
            )
            if (routeWatchdogFailures >= ROUTE_WATCHDOG_MAX_FAILURES) {
                recoverRoute("selected route watchdog error: ${e.message ?: e.javaClass.simpleName}")
                routeWatchdogFailures = 0
            }
        } finally {
            endRouteWatchdogCheck()
        }
    }

    private fun beginRouteWatchdogCheck(): Boolean {
        return synchronized(routeWatchdogCheckLock) {
            if (routeWatchdogCheckInProgress) {
                false
            } else {
                routeWatchdogCheckInProgress = true
                true
            }
        }
    }

    private fun endRouteWatchdogCheck() {
        synchronized(routeWatchdogCheckLock) {
            routeWatchdogCheckInProgress = false
        }
    }

    private fun routeWatchdogInitialDelayMs(): Long {
        val configPath = Settings.activeConfigPath
        if (configPath.isBlank()) return ROUTE_WATCHDOG_INITIAL_DELAY_MS
        return when {
            configUsesTurncoat(configPath) -> ROUTE_WATCHDOG_TURNCOAT_INITIAL_DELAY_MS
            lastSelectedOutboundType.equals("icmp", ignoreCase = true) -> ROUTE_WATCHDOG_ICMP_INITIAL_DELAY_MS
            else -> ROUTE_WATCHDOG_INITIAL_DELAY_MS
        }
    }

    private fun routeWatchdogPollDelayMs(): Long = selectedRouteWatchdogPollDelayMs(
        degraded = routeWatchdogDegraded,
        icmpRoute = lastSelectedOutboundType.equals("icmp", ignoreCase = true),
        deviceInteractive = Application.powerManager.isInteractive,
    )

    private fun configUsesTurncoat(configPath: String): Boolean {
        if (configPath.isBlank()) return false
        if (configPath == Settings.activeConfigPath) return Settings.activeConfigUsesTurncoat
        return runCatching {
            File(configPath).takeIf { it.exists() }?.readText()?.contains("\"turncoat\"", ignoreCase = true) == true
        }.getOrDefault(false)
    }

    private suspend fun checkSelectedRoute(
        coreClient: CoreClient,
        requireVpnDataPlane: Boolean = false,
        dataPlaneAttemptTimeoutMs: Long? = null,
    ): RouteHealth {
        if (requireVpnDataPlane && Settings.serviceMode == ServiceMode.VPN) {
            val timeoutMs = dataPlaneAttemptTimeoutMs ?: vpnDataPlaneAttemptTimeoutMs(
                turncoatRoute = configUsesTurncoat(Settings.activeConfigPath),
            )
            return checkVpnDataPlaneRoute(timeoutMs)
        }
        val result = withTimeoutOrNull(ROUTE_WATCHDOG_OPERATION_TIMEOUT_MS) {
            val selected = coreClient.ProbeSelectedRoute().executeBlocking(
                UrlTestRequest(group_tag = ROUTE_WATCHDOG_GROUP),
            )
            val delay = selected.url_test_delay
            val outboundType = selected.type.trim().lowercase()
            if (selected.tag.isBlank() || selected.url_test_time == null) {
                RouteHealth(
                    false,
                    "selected route probe returned an incomplete result type=${outboundType.ifBlank { "unknown" }}",
                    outboundType,
                )
            } else if (!isUsableRouteDelay(delay)) {
                RouteHealth(
                    false,
                    "selected route failed [${selected.tag}]: type=${outboundType.ifBlank { "unknown" }} delay=$delay",
                    outboundType,
                )
            } else {
                RouteHealth(
                    true,
                    "selected route verified [${selected.tag}]: type=${outboundType.ifBlank { "unknown" }} ${delay}ms",
                    outboundType,
                )
            }
        }
        return result ?: RouteHealth(
            false,
            "route watchdog timed out waiting for selected route probe",
            lastSelectedOutboundType,
        )
    }

    private suspend fun checkVpnDataPlaneRoute(attemptTimeoutMs: Long): RouteHealth {
        if (Settings.serviceMode != ServiceMode.VPN) {
            return RouteHealth(true, "proxy service mode does not use Android TUN", lastSelectedOutboundType)
        }
        val proofStartGeneration = currentStartGeneration()
        val proofNetworkGeneration = networkGeneration
        val proofTunGeneration = tunGeneration
        val result = vpnDataPlaneProbe.run(
            DefaultNetworkMonitor.defaultNetwork,
            timeoutMs = attemptTimeoutMs,
        )
        if (
            proofStartGeneration != currentStartGeneration() ||
            proofNetworkGeneration != networkGeneration ||
            proofTunGeneration != tunGeneration ||
            !shouldWatchCore(proofStartGeneration)
        ) {
            invalidateVpnDataPlaneProof("stale probe generation")
            return RouteHealth(
                false,
                "VPN data-plane proof became stale during network/session transition",
                lastSelectedOutboundType,
                requiresCoreRecovery = true,
            )
        }
        if (!result.healthy) {
            invalidateVpnDataPlaneProof(result.summary)
            return RouteHealth(
                false,
                result.summary,
                lastSelectedOutboundType,
                requiresCoreRecovery = true,
            )
        }
        val proofVpnNetworkHandle = result.vpnNetworkHandle
            ?: return RouteHealth(
                false,
                "VPN data-plane proof did not identify its Android Network",
                lastSelectedOutboundType,
                requiresCoreRecovery = true,
            )
        if (
            !recordVpnDataPlaneProof(
                proofStartGeneration,
                proofNetworkGeneration,
                proofTunGeneration,
                proofVpnNetworkHandle,
            )
        ) {
            return RouteHealth(
                false,
                "VPN data-plane proof became stale before publication",
                lastSelectedOutboundType,
                requiresCoreRecovery = true,
            )
        }
        return RouteHealth(true, result.summary, lastSelectedOutboundType)
    }

    private fun readTunTrafficSnapshot(health: TunRuntimeHealth): TunTrafficSnapshot? {
        val interfaceName = health.interfaceName ?: return null
        val (rxBytes, txBytes) = runCatching {
            TrafficStats.getRxBytes(interfaceName) to TrafficStats.getTxBytes(interfaceName)
        }.getOrNull() ?: return null
        if (rxBytes == TrafficStats.UNSUPPORTED.toLong() || txBytes == TrafficStats.UNSUPPORTED.toLong()) {
            return null
        }
        return TunTrafficSnapshot(interfaceName, rxBytes, txBytes)
    }

    private fun isUsableRouteDelay(delay: Int): Boolean {
        return delay > 0 && delay < ROUTE_WATCHDOG_TIMEOUT_DELAY
    }

    private suspend fun recoverRoute(reason: String) {
        val now = System.currentTimeMillis()
        if (now - lastRouteRecoveryAttemptAt < ROUTE_RECOVERY_BACKOFF_MS) return
        lastRouteRecoveryAttemptAt = now
        if (
            configUsesTurncoat(Settings.activeConfigPath) ||
            lastSelectedOutboundType.equals("icmp", ignoreCase = true)
        ) {
            launchNetworkRouteRecovery(
                generation = networkGeneration,
                reason = "route watchdog recovery: $reason",
                settleDelayMs = 0L,
                replaceActive = false,
                forceTurncoatCarrierRetirement = configUsesTurncoat(Settings.activeConfigPath),
            )
        } else {
            requestCoreRecovery("route watchdog recovery: $reason")
        }
    }

    private data class RouteHealth(
        val healthy: Boolean,
        val summary: String,
        val outboundType: String = "",
        val requiresCoreRecovery: Boolean = false,
    )

    private data class VpnDataPlaneProof(
        val startGeneration: Long,
        val networkGeneration: Long,
        val tunGeneration: Long,
        val vpnNetworkHandle: Long,
        val completedAtElapsedRealtimeMs: Long,
    )

    private data class TunRuntimeHealth(
        val healthy: Boolean,
        val descriptorValid: Boolean,
        val ownVpnActive: Boolean,
        val ownershipKnown: Boolean,
        val ownedCandidateCount: Int,
        val globalCandidateCount: Int,
        val interfaceName: String?,
        val summary: String,
    )

    private data class CoreCleanupResult(
        val closeCompleted: Boolean,
        val tunQuiescent: Boolean,
    ) {
        val completed: Boolean
            get() = closeCompleted && tunQuiescent
    }

    private fun readTunRuntimeHealth(): TunRuntimeHealth {
        if (Settings.serviceMode != ServiceMode.VPN) {
            return TunRuntimeHealth(
                healthy = true,
                descriptorValid = false,
                ownVpnActive = false,
                ownershipKnown = true,
                ownedCandidateCount = 0,
                globalCandidateCount = 0,
                interfaceName = null,
                summary = "proxy service mode",
            )
        }
        val descriptorValid = synchronized(fileDescriptorLock) {
            fileDescriptor?.fileDescriptor?.valid() == true
        }
        val ownership = readVpnOwnership(service)
        val tunnelsResult = runCatching {
            NetworkInterface.getNetworkInterfaces()
                ?.toList()
                .orEmpty()
                .filter { it.name.startsWith("tun") }
                .map { tunnel ->
                    TunInterfaceState(
                        name = tunnel.name,
                        index = tunnel.index,
                        up = runCatching { tunnel.isUp }.getOrDefault(false),
                        mtu = runCatching { tunnel.mtu }.getOrDefault(0),
                        addressCount = runCatching { tunnel.inetAddresses.toList().size }.getOrDefault(0),
                    )
                }
        }
        val tunnels = tunnelsResult.getOrDefault(emptyList())
        // Unknown must never be interpreted as permission-safe zero.
        val globalCandidateCount = if (tunnelsResult.isSuccess) tunnels.size else -1
        val ownedTunnels = if (ownership.known) {
            tunnels.filter { ownership.interfaceNames.contains(it.name) }
        } else {
            tunnels
        }
        val ownedCandidateCount = if (tunnelsResult.isSuccess) ownedTunnels.size else -1
        val tunnel = selectTunRuntimeInterface(ownedTunnels)
        val interfaceUp = tunnel?.up == true
        val healthy = isOwnedTunRuntimeHealthy(
            descriptorValid = descriptorValid,
            ownVpnActive = ownership.active,
            ownershipKnown = ownership.known,
            interfaceUp = interfaceUp,
            ownedCandidateCount = ownedCandidateCount,
            globalCandidateCount = globalCandidateCount,
        )
        return TunRuntimeHealth(
            healthy,
            descriptorValid,
            ownership.active,
            ownership.known,
            ownedCandidateCount,
            globalCandidateCount,
            tunnel?.name,
            "Android TUN health: fd_valid=$descriptorValid interface=${tunnel?.name ?: "missing"} " +
                "up=$interfaceUp mtu=${tunnel?.mtu ?: 0} addresses=${tunnel?.addressCount ?: 0} " +
                "own_vpn=${ownership.active} owner_known=${ownership.known} " +
                "owned_candidates=$ownedCandidateCount global_candidates=$globalCandidateCount " +
                "inspection_ok=${tunnelsResult.isSuccess}",
        )
    }

    internal fun requireTunCreationPrecondition() {
        val allowPlatformVpnReplacement = explicitUserVpnStartPending
        if (
            shouldRejectNewVpnStart(
                service,
                "TUN creation",
                explicitUserStart = allowPlatformVpnReplacement,
            )
        ) {
            vpnOwnershipRevoked = true
            mainHandler.post {
                if (ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
                    stopForExternalVpn("TUN creation ownership conflict")
                }
            }
            error("android: another VPN is already active")
        }
        val health = readTunRuntimeHealth()
        if (
            isOwnedTunRuntimeQuiescent(
                descriptorValid = health.descriptorValid,
                ownVpnActive = health.ownVpnActive,
                ownershipKnown = health.ownershipKnown,
                globalCandidateCount = health.globalCandidateCount,
                allowPlatformVpnReplacement = allowPlatformVpnReplacement,
            )
        ) {
            return
        }

        Log.e(TAG, "rejecting openTun while a previous generation is still active; ${health.summary}")
        error("android: previous TUN generation is still active")
    }

    private suspend fun awaitTunRuntimeQuiescence(
        reason: String,
        serviceStopping: Boolean,
        releaseDeadlineElapsedRealtimeMs: Long =
            SystemClock.elapsedRealtime() + TUN_RELEASE_TIMEOUT_MS,
    ): Boolean {
        if (Settings.serviceMode != ServiceMode.VPN) return true

        var health = readTunRuntimeHealth()
        while (
            !isOwnedTunReleaseCompleteForCleanup(
                descriptorValid = health.descriptorValid,
                ownVpnActive = health.ownVpnActive,
                ownershipKnown = health.ownershipKnown,
                globalCandidateCount = health.globalCandidateCount,
                serviceStopping = serviceStopping,
            ) &&
            SystemClock.elapsedRealtime() < releaseDeadlineElapsedRealtimeMs
        ) {
            delay(TUN_RELEASE_POLL_MS)
            health = readTunRuntimeHealth()
        }
        val quiescent = isOwnedTunReleaseCompleteForCleanup(
            descriptorValid = health.descriptorValid,
            ownVpnActive = health.ownVpnActive,
            ownershipKnown = health.ownershipKnown,
            globalCandidateCount = health.globalCandidateCount,
            serviceStopping = serviceStopping,
        )
        if (quiescent) {
            if (serviceStopping && health.ownVpnActive) {
                Log.i(
                    TAG,
                    "Android TUN descriptor release confirmed after $reason; " +
                        "VpnService stop will remove the remaining interface",
                )
            } else {
                Log.i(TAG, "Android TUN release confirmed after $reason")
            }
        } else {
            Log.e(TAG, "Android TUN release did not finish after $reason; ${health.summary}")
        }
        return quiescent
    }

    private suspend fun closeMobileCoreAndAwaitTunQuiescence(
        reason: String,
        serviceStopping: Boolean = false,
    ): CoreCleanupResult {
        closeTunFileDescriptor()
        val closeCompleted = MobileCoreCloser.closeBlocking(reason)
        if (!closeCompleted) {
            Log.w(TAG, "Mobile.close did not fully finish during $reason")
        }
        // Framework retirement and TUN quiescence are one release barrier;
        // neither phase receives a fresh grace period after the other.
        val releaseDeadlineElapsedRealtimeMs =
            SystemClock.elapsedRealtime() + TUN_RELEASE_TIMEOUT_MS
        val platformVpnRetired = if (
            closeCompleted &&
            !serviceStopping &&
            service is VPNService
        ) {
            service.retirePlatformVpnSessionAfterCoreStop(releaseDeadlineElapsedRealtimeMs) {
                !vpnOwnershipRevoked &&
                    !isExternalVpnActive("core restart VPN retirement")
            }
        } else {
            true
        }
        if (!platformVpnRetired) {
            Log.w(TAG, "Android framework VPN retirement did not finish during $reason")
        }
        val tunQuiescent = awaitTunRuntimeQuiescence(
            reason,
            serviceStopping,
            releaseDeadlineElapsedRealtimeMs,
        )
        return CoreCleanupResult(closeCompleted && platformVpnRetired, tunQuiescent)
    }

    private suspend fun markRouteDegraded(reason: String) {
        val changed = withContext(Dispatchers.Main) {
            if (!shouldWatchCore() || status.value != Status.Started) {
                return@withContext false
            }
            status.value = Status.Starting
            notification.show(activeProfileName, R.string.status_starting)
            true
        }
        if (changed) {
            Log.w(TAG, "route degraded; keeping VPN fail-closed while recovering: $reason")
        }
    }

    private fun shouldWatchCore(generation: Long? = null): Boolean {
        val sessionActive =
            ServiceLifecycleOwnership.isCurrent(serviceOwnerToken) &&
                Settings.startedByUser &&
                Settings.activeConfigPath.isNotBlank()
        return if (generation == null) {
            sessionActive
        } else {
            shouldContinueCoreLifecycleOperation(
                operationGeneration = generation,
                currentGeneration = currentStartGeneration(),
                userSessionActive = sessionActive,
            )
        }
    }

    private fun isExternalVpnActive(reason: String): Boolean {
        return isExternalVpnActive(service, reason)
    }

    private fun shouldYieldToExternalVpn(reason: String): Boolean {
        val externalVpnActive = isExternalVpnActive(reason)
        if (
            externalVpnActive &&
            explicitUserVpnStartPending &&
            !vpnOwnershipWasEstablished
        ) {
            Log.i(TAG, "allowing one explicit user VPN ownership transfer during $reason")
            return false
        }
        return externalVpnActive
    }

    private fun stopForExternalVpn(reason: String) {
        Log.w(TAG, "stopping Marten because Android VPN ownership was lost: $reason")
        stopService(vpnRevoked = true)
    }

    private suspend fun stopForExternalVpnOnMain(reason: String) {
        withContext(Dispatchers.Main) {
            stopForExternalVpn(reason)
        }
    }

    private suspend fun readCoreStateSnapshot(coreClient: CoreClient): CoreStates? {
        return withTimeoutOrNull(CORE_WATCHDOG_GRPC_TIMEOUT_MS + 500L) {
            runCatching {
                readCoreState(coreClient)
            }.getOrElse {
                if (it is CancellationException) throw it
                null
            }
        }
    }

    private fun coreRecoveryStallTimeoutMs(): Long =
        if (configUsesTurncoat(Settings.activeConfigPath)) {
            CORE_RECOVERY_TURNCOAT_STALL_TIMEOUT_MS
        } else {
            CORE_RECOVERY_STALL_TIMEOUT_MS
        }

    private suspend fun replaceVpnServiceForStalledCoreRecovery(coreState: CoreStates?, elapsedMs: Long) {
        if (vpnServiceReplacementRequested || !shouldWatchCore()) return
        replaceVpnServiceAfterCoreCleanupFailure(
            "core recovery stalled for ${elapsedMs}ms in state=${coreState ?: "unavailable"}",
            preserveUserSession = true,
        )
    }

    private suspend fun replaceVpnServiceAfterCoreCleanupFailure(
        reason: String,
        preserveUserSession: Boolean,
    ) {
        if (vpnServiceReplacementRequested) return
        vpnServiceReplacementRequested = true
        val restoreSession =
            preserveUserSession &&
                Settings.startedByUser &&
                NativeResumeConfigStore.hasStoredConfig(service)
        Settings.startedByUser = restoreSession
        Settings.startCoreAfterStartingService = restoreSession
        val recoveryScheduled = restoreSession && scheduleProcessRecovery()
        Log.e(
            TAG,
            "native core cleanup incomplete; replacing VPN service without terminating app process: $reason; " +
                "${readTunRuntimeHealth().summary}; recovery_scheduled=$recoveryScheduled",
        )
        withContext(Dispatchers.Main) {
            if (restoreSession) {
                status.value = Status.Starting
                notification.show(activeProfileName, R.string.status_recovering)
                if (recoveryScheduled) {
                    releaseActivityServiceBindingForRecovery()
                }
            } else {
                status.value = Status.Stopping
                notification.stopDynamicUpdates()
                notification.close()
            }
        }
        if (!restoreSession || recoveryScheduled) {
            service.stopSelf()
        } else {
            Log.w(TAG, "VPN service recovery alarm unavailable; preserving sticky service ownership")
        }
    }

    private fun releaseActivityServiceBindingForRecovery() {
        val activity = runCatching { MainActivity.instance }.getOrNull() ?: return
        if (activity.isFinishing || activity.isDestroyed) return
        Log.w(TAG, "temporarily releasing Activity binding for VPN service replacement")
        activity.disconnectServiceBinding()
        mainHandler.postDelayed({
            val currentActivity = runCatching { MainActivity.instance }.getOrNull()
            if (
                currentActivity === activity &&
                !activity.isFinishing &&
                !activity.isDestroyed
            ) {
                activity.reconnect()
            }
        }, PROCESS_RECOVERY_REBIND_DELAY_MS)
    }

    private fun scheduleProcessRecovery(): Boolean = runCatching {
        val pendingIntent = processRecoveryPendingIntent(
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        ) ?: error("failed to create VPN recovery intent")
        val alarmManager = service.getSystemService(AlarmManager::class.java)
            ?: error("AlarmManager unavailable")
        alarmManager.setAndAllowWhileIdle(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + PROCESS_RECOVERY_RESTART_DELAY_MS,
            pendingIntent,
        )
        Log.w(
            TAG,
            "scheduled user-started VPN recovery in ${PROCESS_RECOVERY_RESTART_DELAY_MS}ms",
        )
        true
    }.onFailure {
        Log.e(TAG, "failed to schedule user-started VPN process recovery", it)
    }.getOrDefault(false)

    private fun cancelProcessRecovery() {
        val pendingIntent = processRecoveryPendingIntent(
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        ) ?: return
        service.getSystemService(AlarmManager::class.java)?.cancel(pendingIntent)
        pendingIntent.cancel()
        Log.i(TAG, "cancelled pending VPN service recovery")
    }

    private fun processRecoveryPendingIntent(flags: Int): PendingIntent? {
        val recoveryIntent = Intent(service, Settings.serviceClass())
            .setAction(Action.SERVICE_RECOVER)
            .setPackage(service.packageName)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(
                service,
                PROCESS_RECOVERY_REQUEST_CODE,
                recoveryIntent,
                flags,
            )
        } else {
            PendingIntent.getService(
                service,
                PROCESS_RECOVERY_REQUEST_CODE,
                recoveryIntent,
                flags,
            )
        }
    }

    private fun readTurncoatRouteEvidence(coreClient: CoreClient): TurncoatRouteEvidence {
        return coreClient.GetTurncoatRouteEvidence().executeBlocking(Empty())
    }

    private fun readCoreState(coreClient: CoreClient): CoreStates? {
        val (sink, source) = coreClient.CoreInfoListener().executeBlocking()
        return try {
            sink.write(Empty())
            sink.close()
            source.read()?.core_state
        } finally {
            runCatching { sink.close() }
            runCatching { source.close() }
        }
    }

    private fun launchCoreRecovery(
        reason: String,
        generation: Long = currentStartGeneration(),
    ): Boolean {
        val now = System.currentTimeMillis()
        return synchronized(lifecycleLock) {
            if (
                !shouldContinueCoreLifecycleOperation(
                    operationGeneration = generation,
                    currentGeneration = startGeneration,
                    userSessionActive = Settings.startedByUser,
                )
            ) {
                return@synchronized false
            }
            if (coreRecoveryJob?.isActive == true) {
                return@synchronized true
            }
            if (now - lastCoreRecoveryAttemptAt < CORE_RECOVERY_BACKOFF_MS) {
                return@synchronized false
            }
            if (!ServiceLifecycleOwnership.tryAcquireNativeRecovery(serviceOwnerToken)) {
                Log.i(TAG, "deferring native recovery while another lifecycle owner is active")
                return@synchronized false
            }

            lateinit var launched: Job
            launched = serviceScope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                recoverMobileCore(reason, generation)
            }
            coreRecoveryJob = launched
            coreRecoveryInProgress = true
            lastCoreRecoveryAttemptAt = now
            coreRecoveryAttemptStartedAtElapsed = SystemClock.elapsedRealtime()
            launched.invokeOnCompletion {
                synchronized(lifecycleLock) {
                    if (coreRecoveryJob === launched) {
                        coreRecoveryJob = null
                        coreRecoveryInProgress = false
                        coreRecoveryAttemptStartedAtElapsed = 0L
                    }
                }
                ServiceLifecycleOwnership.releaseNativeRecovery(serviceOwnerToken)
            }
            launched.start()
            true
        }
    }

    private fun requestCoreRecovery(
        reason: String,
        generation: Long = currentStartGeneration(),
    ): Boolean {
        if (launchCoreRecovery(reason, generation)) return true

        return synchronized(lifecycleLock) {
            if (
                !shouldContinueCoreLifecycleOperation(
                    operationGeneration = generation,
                    currentGeneration = startGeneration,
                    userSessionActive = Settings.startedByUser,
                )
            ) {
                return@synchronized false
            }
            if (coreRecoveryAdmissionRetryJob?.isActive == true) {
                return@synchronized true
            }

            lateinit var scheduled: Job
            scheduled = serviceScope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                var rejectedAttempts = 0
                while (currentCoroutineContext().isActive && shouldWatchCore(generation)) {
                    delay(CORE_RECOVERY_BACKOFF_MS)
                    if (launchCoreRecovery(reason, generation)) {
                        Log.w(
                            TAG,
                            "core recovery admitted after ${rejectedAttempts + 1} delayed attempt(s): $reason",
                        )
                        return@launch
                    }
                    rejectedAttempts += 1
                    Log.w(
                        TAG,
                        "core recovery admission remains pending attempt=$rejectedAttempts: $reason",
                    )
                }
            }
            coreRecoveryAdmissionRetryJob = scheduled
            scheduled.invokeOnCompletion {
                synchronized(lifecycleLock) {
                    if (coreRecoveryAdmissionRetryJob === scheduled) {
                        coreRecoveryAdmissionRetryJob = null
                    }
                }
            }
            Log.w(
                TAG,
                "core recovery admission retry scheduled in ${CORE_RECOVERY_BACKOFF_MS}ms: $reason",
            )
            scheduled.start()
            true
        }
    }

    private suspend fun recoverMobileCore(reason: String, generation: Long) {
        coreWatchdogSawHealthyCore = false

        try {
            var failedAttempts = 0

            while (currentCoroutineContext().isActive && shouldWatchCore(generation)) {
                val attempt = failedAttempts + 1
                coreRecoveryAttemptStartedAtElapsed = SystemClock.elapsedRealtime()
                val configPath = Settings.activeConfigPath
                if (configPath.isBlank()) return
                if (shouldYieldToExternalVpn("core watchdog recovery")) {
                    stopForExternalVpnOnMain("core watchdog recovery")
                    return
                }

                Log.w(TAG, "core watchdog recovery attempt $attempt: $reason")
                withContext(Dispatchers.Main) {
                    if (!shouldWatchCore(generation)) return@withContext
                    status.value = Status.Starting
                    notification.show(activeProfileName, R.string.status_starting)
                }

                var preparationCleanupFailed = false
                val prepared = try {
                    MobileCoreLifecycle.run {
                        if (!shouldWatchCore(generation)) return@run false
                        DefaultNetworkMonitor.clearListener(serviceOwnerToken)
                        runCatching {
                            Mobile.stop()
                        }.onFailure {
                            Log.w(TAG, "error stopping mobile core before recovery attempt $attempt", it)
                        }
                        val cleanupResult =
                            closeMobileCoreAndAwaitTunQuiescence("core watchdog recovery attempt $attempt")
                        if (requiresCoreCleanupEscalation(
                                cleanupResult.closeCompleted,
                                cleanupResult.tunQuiescent,
                            )
                        ) {
                            Log.w(
                                TAG,
                                "previous mobile core or TUN did not quiesce before recovery attempt $attempt",
                            )
                            preparationCleanupFailed = true
                            return@run false
                        }
                        if (!shouldWatchCore(generation)) return@run false
                        if (shouldYieldToExternalVpn("core watchdog recovery before mobile setup")) {
                            return@run false
                        }
                        Mobile.setup(
                            Settings.baseDir,
                            Settings.workingDir,
                            Settings.tempDir,
                            4L,
                            "127.0.0.1:${Settings.grpcServiceModePort}",
                            "",
                            Settings.debugMode,
                            platformInterface,
                        )
                        true
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    Log.e(TAG, "core watchdog recovery preparation $attempt failed", e)
                    false
                }

                if (!prepared) {
                    if (preparationCleanupFailed) {
                        replaceVpnServiceAfterCoreCleanupFailure(
                            "recovery attempt $attempt could not release the previous native core and TUN",
                            preserveUserSession = true,
                        )
                        return
                    }
                    if (shouldYieldToExternalVpn("core watchdog recovery preparation")) {
                        stopForExternalVpnOnMain("core watchdog recovery preparation")
                        return
                    }
                }

                val started = if (prepared && shouldWatchCore(generation)) {
                    try {
                        if (shouldYieldToExternalVpn("core watchdog recovery before mobile start")) {
                            stopForExternalVpnOnMain("core watchdog recovery before mobile start")
                            return
                        }
                        startMobileCoreFromNativePath(
                            configPath,
                            "core watchdog recovery attempt $attempt",
                            generation = generation,
                            stopServiceOnRouteFailure = false,
                        )
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Throwable) {
                        Log.e(TAG, "core watchdog recovery attempt $attempt failed", e)
                        false
                    }
                } else {
                    false
                }

                if (started) {
                    if (!shouldWatchCore(generation)) return
                    if (markCoreRuntimeStarted(routeVerified = true, generation = generation)) {
                        Log.i(TAG, "core watchdog recovery started mobile core after $attempt attempt(s)")
                        return
                    }
                    Log.w(TAG, "core watchdog recovery did not produce a current healthy Android VPN generation")
                }

                failedAttempts = attempt
                // A retry is admitted only after both native close and
                // permission-safe zero-TUN quiescence have completed.
                when (closeFailedRecoveryRuntime("failed core recovery attempt $attempt", generation)) {
                    null -> return
                    false -> {
                        replaceVpnServiceAfterCoreCleanupFailure(
                            "failed recovery attempt $attempt did not release the native core and TUN",
                            preserveUserSession = true,
                        )
                        return
                    }
                    true -> Unit
                }
                if (!shouldWatchCore(generation)) return
                val retryDelayMs = coreRecoveryRetryDelayMs(failedAttempts)
                Log.w(TAG, "core watchdog recovery retry scheduled in ${retryDelayMs}ms")
                delay(retryDelayMs)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            Log.e(TAG, "core watchdog recovery loop failed", e)
            if (shouldWatchCore(generation)) {
                stopAndAlert(Alert.StartService, "core watchdog recovery loop failed")
            }
        }
    }

    private suspend fun closeFailedRecoveryRuntime(reason: String, generation: Long): Boolean? =
        runNonCancellableServiceCleanup {
            MobileCoreLifecycle.run {
                if (!shouldWatchCore(generation)) return@run null
                DefaultNetworkMonitor.clearListener(serviceOwnerToken)
                runCatching {
                    Mobile.stop()
                }.onFailure {
                    Log.w(TAG, "error stopping mobile core after $reason", it)
                }
                val cleanupResult = closeMobileCoreAndAwaitTunQuiescence(reason)
                cleanupResult.completed
            }
        }

    private suspend fun stopAndAlert(type: Alert, message: String? = null) {
        if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)) {
            Log.i(TAG, "stale service alert ignored: $type")
            return
        }
        explicitUserVpnStartPending = false
        // This path can run inside a watchdog that it cancels below. Cleanup must still reach
        // Mobile.close() and stopSelf(), otherwise Android keeps a dead VPN network active.
        runNonCancellableServiceCleanup {
            val stopGeneration = cancelPendingStarts()
            Settings.startedByUser = false
            Settings.startCoreAfterStartingService = false
            closedByStopService = true
            stopCoreRuntimeMonitor()
            stopCoreWatchdog()
            stopRouteWatchdog()
            stopExternalVpnWatchdog()
            resetUnderlyingNetworkGeneration()
            val coreClosed = MobileCoreLifecycle.run {
                if (
                    !isCurrentLifecycleGeneration(stopGeneration) ||
                    !ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)
                ) {
                    return@run null
                }
                DefaultNetworkMonitor.clearListener(serviceOwnerToken)
                runCatching {
                    Mobile.stop()
                }.onFailure {
                    Log.w(TAG, "error stopping mobile core after service alert", it)
                }
                NativeResumeConfigStore.cleanupPlaintextLeases(service)
                DefaultNetworkMonitor.stop(serviceOwnerToken)
                closeMobileCoreAndAwaitTunQuiescence(
                    "service alert",
                    serviceStopping = true,
                )
            }
            if (coreClosed == null) return@runNonCancellableServiceCleanup
            coreShutdownCompleted = coreClosed.completed
            if (requiresCoreCleanupEscalation(
                    coreClosed.closeCompleted,
                    coreClosed.tunQuiescent,
                )
            ) {
                replaceVpnServiceAfterCoreCleanupFailure(
                    "service alert did not release the native core and TUN",
                    preserveUserSession = false,
                )
                return@runNonCancellableServiceCleanup
            }
            withContext(Dispatchers.Main) {
                if (
                    !isCurrentLifecycleGeneration(stopGeneration) ||
                    !ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)
                ) {
                    return@withContext
                }
                if (receiverRegistered) {
                    runCatching {
                        service.unregisterReceiver(receiver)
                    }.onFailure {
                        Log.w(TAG, "error unregistering service receiver", it)
                    }
                    receiverRegistered = false
                }
                notification.stopDynamicUpdates()
                notification.close()
                binder.broadcast { callback ->
                    callback.onServiceAlert(type.ordinal, message)
                }
                status.value = Status.Stopped
                service.stopSelf()
            }
        }
    }

    @Suppress("SameReturnValue")
    internal fun onStartCommand(intent: Intent?, flags: Int): Int {
        val connectFromNotification = intent?.action == Action.SERVICE_CONNECT
        val processRecoveryRequested = intent?.action == Action.SERVICE_RECOVER
        if (processRecoveryRequested) {
            // AlarmManager delivers recovery through startForegroundService on
            // Android O+. A stale alarm may race a manual Disconnect, but every
            // delivery must still acknowledge the foreground-service contract
            // before an early stopSelf()/return.
            notification.show(activeProfileName, R.string.status_recovering)
        }
        val restartedBySystem = intent == null ||
            (flags and Service.START_FLAG_REDELIVERY) != 0 ||
            (flags and Service.START_FLAG_RETRY) != 0
        val explicitUserStartRequested =
            !restartedBySystem &&
                !processRecoveryRequested &&
                intent?.getBooleanExtra(Action.EXTRA_USER_INITIATED, false) == true
        val shouldRestoreUserSession = shouldRestoreUserSessionFromServiceCommand(
            restartedBySystem = restartedBySystem,
            processRecoveryRequested = processRecoveryRequested,
            connectFromNotification = connectFromNotification,
            userSessionActive = Settings.startedByUser,
            activeConfigAvailable = Settings.activeConfigPath.isNotBlank(),
        )

        if (
            shouldRejectNewVpnStart(
                service,
                "service start",
                explicitUserStart = explicitUserStartRequested,
            )
        ) {
            Settings.startedByUser = false
            Settings.startCoreAfterStartingService = false
            if (status.value != Status.Stopped) {
                stopForExternalVpn("service start")
            } else {
                binder.broadcast { callback ->
                    callback.onServiceAlert(Alert.VpnRevoked.ordinal, null)
                }
                notification.close()
                service.stopSelf()
            }
            return Service.START_NOT_STICKY
        }

        if (shouldRestoreUserSession && !NativeResumeConfigStore.hasStoredConfig(service)) {
            Log.w(TAG, "discarding stale user-session restore without encrypted recovery config")
            Settings.startedByUser = false
            Settings.startCoreAfterStartingService = false
            notification.close()
            service.stopSelf()
            return Service.START_NOT_STICKY
        }

        if (status.value != Status.Stopped) {
            if (
                processRecoveryRequested &&
                vpnServiceReplacementRequested &&
                shouldRestoreUserSession
            ) {
                Log.w(
                    TAG,
                    "scheduled VPN recovery found the old service still active; " +
                        "retrying after releasing Activity binding",
                )
                releaseActivityServiceBindingForRecovery()
                scheduleProcessRecovery()
                service.stopSelf()
                return Service.START_STICKY
            }
            if ((restartedBySystem || processRecoveryRequested) && !connectFromNotification) {
                Log.i(TAG, "ignoring system service restart while service is already active")
                return Service.START_STICKY
            }
            if (connectFromNotification && status.value == Status.Started) {
                Settings.startCoreAfterStartingService = false
                Log.i(TAG, "ignoring notification connect while core is already started")
                return Service.START_STICKY
            }
            if ((connectFromNotification || Settings.startCoreAfterStartingService) && status.value != Status.Stopping) {
                Settings.startCoreAfterStartingService = false
                serviceScope.launch(Dispatchers.IO) {
                    startStoredCoreFromNativeEntryPoint()
                }
            }
            return Service.START_STICKY
        }
        explicitUserVpnStartPending =
            explicitUserStartRequested && Settings.serviceMode == ServiceMode.VPN
        synchronized(fileDescriptorLock) {
            // A bound VpnService instance can survive stopSelf() after a clean
            // Disconnect. Re-open descriptor admission only for this newly
            // accepted start; stopService() seals it again under the same lock.
            tunDescriptorAdmissionClosed = false
            status.value = Status.Starting
        }

        if (shouldRestoreUserSession) {
            Log.w(TAG, "restoring user-started VPN after system service restart")
            Settings.startCoreAfterStartingService = true
        } else if ((restartedBySystem || processRecoveryRequested) && !connectFromNotification) {
            Log.i(TAG, "ignoring system service restart without explicit connect")
            Settings.startedByUser = false
            Settings.startCoreAfterStartingService = false
            service.stopSelf()
            return Service.START_NOT_STICKY
        }

        if (
            Settings.activeConfigPath.isNotBlank() &&
            connectFromNotification
        ) {
            Settings.startCoreAfterStartingService = true
        }

        if (!receiverRegistered) {
            ContextCompat.registerReceiver(service, receiver, IntentFilter().apply {
                addAction(Action.SERVICE_CLOSE)
                addAction(Action.SERVICE_MARK_STARTED)
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_USER_PRESENT)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                }
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        }

        serviceScope.launch(Dispatchers.IO) {
            val generation = nextStartGeneration()
            Settings.startedByUser = true
            initialize()
//            try {
//                startCommandServer()
//            } catch (e: Exception) {
//                stopAndAlert(Alert.StartCommandServer, e.message)
//                return@launch
//            }
            startService(generation)
        }
        return Service.START_STICKY
    }

    private suspend fun startStoredCoreFromNativeEntryPoint() {
        val generation = currentStartGeneration()
        if (shouldYieldToExternalVpn("native core start")) {
            stopForExternalVpnOnMain("native core start")
            return
        }
        if (status.value == Status.Started) {
            Log.i(TAG, "ignoring native core start while core is already started")
            return
        }
        val configPath = Settings.activeConfigPath
        if (configPath.isBlank()) {
            stopAndAlert(Alert.EmptyConfiguration)
            return
        }
        if (!NativeResumeConfigStore.hasStoredConfig(service)) {
            stopAndAlert(Alert.EmptyConfiguration)
            return
        }
        try {
            startCoreRuntimeMonitor(nativeStartup = true)
            startCoreWatchdog()
            val routeVerified = startMobileCoreFromNativePath(
                configPath,
                "native core start",
                generation = generation,
                stopServiceOnRouteFailure = true,
            )
            if (routeVerified) {
                markCoreRuntimeStarted(routeVerified = true, generation = generation)
                return
            }
            Log.w(TAG, "native entry-point startup ended after terminal VPN data-plane failure")
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            stopAndAlert(Alert.StartService, error.message)
        }
    }

    private suspend fun startMobileCoreFromNativePath(
        configPath: String,
        reason: String,
        generation: Long? = null,
        stopServiceOnRouteFailure: Boolean = true,
    ): Boolean {
        val usesTurncoat = if (configPath == Settings.activeConfigPath) {
            Settings.activeConfigUsesTurncoat
        } else {
            configUsesTurncoat(configPath)
        }
        val started = MobileCoreLifecycle.run {
            if (generation != null && !shouldContinueStart(generation)) {
                return@run false
            }
            val lease = if (configPath == Settings.activeConfigPath) {
                NativeResumeConfigStore.createPlaintextLease(service, generation ?: currentStartGeneration())
            } else {
                null
            }
            val actualPath = lease?.absolutePath ?: configPath
            try {
                Mobile.start(actualPath, "")
            } finally {
                NativeResumeConfigStore.deleteLease(lease)
            }
            true
        }
        if (!started) return false
        if (generation != null && !shouldContinueStart(generation)) return false
        return verifyNativeStartupRoute(usesTurncoat, reason, generation, stopServiceOnRouteFailure)
    }

    private suspend fun verifyNativeStartupRoute(
        usesTurncoat: Boolean,
        reason: String,
        generation: Long? = null,
        stopServiceOnFailure: Boolean = true,
    ): Boolean {
        val timeoutMs = if (usesTurncoat) {
            STARTUP_ROUTE_VERIFY_TURNCOAT_TIMEOUT_MS
        } else {
            STARTUP_ROUTE_VERIFY_TIMEOUT_MS
        }
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        val routeClient = GrpcClientProvider.coreClient(ROUTE_WATCHDOG_GRPC_TIMEOUT_MS)
        var attempt = 0
        var lastSummary = "not checked"
        if (usesTurncoat) {
            lastSelectedOutboundType = "turncoat"
        }

        while (SystemClock.elapsedRealtime() < deadline) {
            if (generation != null && !shouldContinueStart(generation)) {
                finishCancelledStart(generation, "startup route verification")
                return false
            }
            if (shouldYieldToExternalVpn("startup route verification")) {
                stopForExternalVpnOnMain("startup route verification")
                return false
            }
            if (underlyingNetworkInitialized && observedUnderlyingNetwork == null) {
                lastSummary = "waiting for an underlying network"
                val remainingMs = deadline - SystemClock.elapsedRealtime()
                if (remainingMs <= 0L) break
                delay(minOf(STARTUP_ROUTE_VERIFY_RETRY_MS, remainingMs))
                continue
            }

            attempt += 1
            val probeNetworkGeneration = networkGeneration
            val remainingBudgetMs = deadline - SystemClock.elapsedRealtime()
            val attemptTimeoutMs = vpnDataPlaneAttemptTimeoutMs(
                turncoatRoute = usesTurncoat,
                remainingBudgetMs = remainingBudgetMs,
            )
            val result = runCatching {
                // Carrier telemetry and direct outbound urltest remain useful
                // diagnostics, but neither proves that Android application
                // traffic crossed the current TUN. Startup is admitted only
                // by the real VPN Network GET below.
                checkSelectedRoute(
                    routeClient,
                    requireVpnDataPlane = true,
                    dataPlaneAttemptTimeoutMs = attemptTimeoutMs,
                )
            }.getOrElse {
                if (it is CancellationException) throw it
                RouteHealth(false, "startup route check error: ${it.message ?: it.javaClass.simpleName}")
            }
            if (probeNetworkGeneration != networkGeneration) {
                lastSummary =
                    "discarded stale VPN data-plane proof from network generation=$probeNetworkGeneration"
                Log.w(TAG, "native startup route changed during probe ($reason): $lastSummary")
                val remainingMs = deadline - SystemClock.elapsedRealtime()
                if (remainingMs <= 0L) break
                delay(minOf(STARTUP_ROUTE_VERIFY_RETRY_MS, remainingMs))
                continue
            }
            lastSummary = result.summary
            if (result.outboundType.isNotBlank()) {
                lastSelectedOutboundType = result.outboundType
            }
            if (result.healthy) {
                if (generation != null && !shouldContinueStart(generation)) {
                    finishCancelledStart(generation, "selected route verification")
                    return false
                }
                Log.i(TAG, "native startup route verified ($reason): ${result.summary}")
                return true
            }
            Log.w(TAG, "native startup route not ready ($reason, attempt $attempt): ${result.summary}")
            val remainingMs = deadline - SystemClock.elapsedRealtime()
            if (remainingMs <= 0L) break
            delay(minOf(STARTUP_ROUTE_VERIFY_RETRY_MS, remainingMs))
        }

        Log.w(TAG, "native startup route failed ($reason): $lastSummary")
        if (stopServiceOnFailure) {
            stopAndAlert(Alert.StartService, "VPN data plane failed startup connectivity check: $lastSummary")
        } else {
            Log.w(TAG, "native startup route will be closed and retried ($reason)")
        }
        return false
    }

    fun onBind(intent: Intent): IBinder {
        return binder
    }

    fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(serviceOwnerToken, listener)
    }

    fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.clearListener(serviceOwnerToken, listener)
    }

    fun onDestroy() {
        if (activeInstance === this) {
            activeInstance = null
        }
        explicitUserVpnStartPending = false
        synchronized(fileDescriptorLock) {
            tunDescriptorAdmissionClosed = true
        }
        cancelPendingStarts()
        val stopWasRequested = closedByStopService
        val externalVpnActive = BoxService.isExternalVpnActive(service, "service destroy")
        val ownership = readVpnOwnership(service)
        val establishedVpnOwnershipLost =
            Settings.serviceMode == ServiceMode.VPN &&
                vpnOwnershipWasEstablished &&
                ownership.known &&
                !ownership.active
        val shouldPreserveUserSession =
            !stopWasRequested &&
                !externalVpnActive &&
                !establishedVpnOwnershipLost &&
                !vpnOwnershipRevoked &&
                Settings.startedByUser &&
                Settings.activeConfigPath.isNotBlank()
        if (establishedVpnOwnershipLost || vpnOwnershipRevoked) {
            Log.w(
                TAG,
                "service destroy observed lost Marten VPN ownership; sticky restore disabled",
            )
        }
        stopCoreRuntimeMonitor()
        stopCoreWatchdog()
        stopRouteWatchdog()
        stopExternalVpnWatchdog()
        resetUnderlyingNetworkGeneration()
        serviceJob.cancel()
        closeTunFileDescriptor()

        val cleanupAccepted = ServiceLifecycleOwnership.beginCleanup(serviceOwnerToken) {
            DefaultNetworkMonitor.stop(serviceOwnerToken)
            NativeResumeConfigStore.cleanupPlaintextLeases(service)
            MobileCoreLifecycle.run {
                if (!coreShutdownCompleted) {
                    runCatching {
                        Mobile.stop()
                    }.onFailure {
                        Log.w(TAG, "error stopping mobile core during service destroy", it)
                    }
                    val cleanupResult = closeMobileCoreAndAwaitTunQuiescence(
                        "service destroy",
                        serviceStopping = true,
                    )
                    coreShutdownCompleted = cleanupResult.completed
                    if (requiresCoreCleanupEscalation(
                            cleanupResult.closeCompleted,
                            cleanupResult.tunQuiescent,
                        )
                    ) {
                        error("mobile core or TUN cleanup did not finish during service destroy")
                    }
                }
            }
        }

        if (cleanupAccepted) {
            if (shouldPreserveUserSession) {
                Log.w(TAG, "service destroyed unexpectedly; preserving user-started VPN session for sticky restart")
            }
            if (!shouldPreserveUserSession) {
                Settings.startedByUser = false
            }
            Settings.startCoreAfterStartingService = shouldPreserveUserSession
            status.value = Status.Stopped
            notification.close(removeNotification = !keepStoppedNotificationOnDestroy)
            keepStoppedNotificationOnDestroy = false
        } else {
            Log.i(TAG, "stale service destroy skipped shared network/core cleanup")
        }
        binder.close()
    }

    fun onRevoke() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            stopService(vpnRevoked = true)
        } else {
            mainHandler.post {
                stopService(vpnRevoked = true)
            }
        }
    }

    internal fun sendNotification(notification: Notification) {
        return
        val builder =
            NotificationCompat.Builder(service, notification.identifier).setShowWhen(false)
                .setContentTitle(notification.title).setContentText(notification.body)
                .setOnlyAlertOnce(true).setSmallIcon(R.drawable.ic_stat_logo_sharp)
                .setCategory(NotificationCompat.CATEGORY_EVENT)
                .setPriority(NotificationCompat.PRIORITY_HIGH).setAutoCancel(true)
        if (!notification.subtitle.isNullOrBlank()) {
            builder.setContentInfo(notification.subtitle)
        }
        if (!notification.openURL.isNullOrBlank()) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    service,
                    0,
                    Intent(
                        service,
                        MainActivity::class.java,
                    ).apply {
                        setAction(Action.SERVICE).setData(Uri.parse(notification.openURL))
                        setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    },
                    ServiceNotification.flags,
                ),
            )
        }
        serviceScope.launch(Dispatchers.Main) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Application.notification.createNotificationChannel(
                    NotificationChannel(
                        notification.identifier,
                        notification.typeName,
                        NotificationManager.IMPORTANCE_HIGH,
                    ),
                )
            }
            Application.notification.notify(notification.typeID, builder.build())
        }
    }

     fun writeDebugMessage(message: String?) {
        if (message.isNullOrBlank()) return
        Log.d("BoxService", message)
        binder.broadcast {
            it.onServiceWriteLog(message)
        }
    }

}
