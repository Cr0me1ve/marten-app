package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnReliabilitySourceGuardTest {
    @Test
    fun `fail closed barrier revalidates the exact descriptor generation after Android inspection`() {
        val box = sourceFile("BoxService.kt")
        val barrier = functionBody(box, "isFailClosedTunBarrierActive")

        val initialSnapshot = barrier.indexOf("val retainedBarrier = synchronized(fileDescriptorLock)")
        val snapshotGeneration = barrier.indexOf("failClosedVpnGeneration?.let { generation", initialSnapshot)
        val snapshotDescriptor = barrier.indexOf("fileDescriptor?.takeIf { descriptor", snapshotGeneration)
        val markerRead = barrier.indexOf("publishedFailClosedVpnMarkerAddresses()", snapshotDescriptor)
        val healthRead = barrier.indexOf("readTunRuntimeHealth().healthy", markerRead)
        val policy = barrier.indexOf("isFailClosedVpnBarrierReady(", markerRead)
        val readyReturn = barrier.indexOf("if (!barrierReady) return false", policy)
        val revalidation = barrier.indexOf("return synchronized(fileDescriptorLock)", readyReturn)
        assertTrue(
            "the fail-closed proof must snapshot the tracked generation and ParcelFileDescriptor before Android marker and health reads",
            initialSnapshot >= 0 && snapshotGeneration > initialSnapshot && snapshotDescriptor > snapshotGeneration &&
                markerRead > snapshotDescriptor && policy > markerRead && healthRead > policy &&
                readyReturn > healthRead && revalidation > readyReturn,
        )
        val revalidationBlock = barrier.substring(revalidation)
        assertTrue(
            "post-inspection proof must require the same generation, the same PFD object, FAIL_CLOSED mode, and a valid fd",
            revalidationBlock.contains("failClosedVpnGeneration == retainedBarrier.first") &&
                revalidationBlock.contains("tunDescriptorMode == TunDescriptorMode.FAIL_CLOSED") &&
                revalidationBlock.contains("fileDescriptor === retainedBarrier.second") &&
                revalidationBlock.contains("retainedBarrier.second.fileDescriptor.valid()"),
        )
    }

    @Test
    fun `retirement VPN remains an exact tracked barrier through successor handoff or terminal release`() {
        val vpn = sourceFile("VPNService.kt")
        val retirement = sourceSection(
            vpn,
            "private suspend fun retirePlatformVpnSession(",
            "\n    /**\n     * Installs a service-owned packet sink",
        )
        val ensureFailClosedVpn = functionBody(vpn, "ensureFailClosedVpn")
        val openTun = sourceSection(vpn, "override fun openTun", "override fun writePlatformLog")
        val box = sourceFile("BoxService.kt")
        val cleanup = functionBody(box, "closeMobileCoreAndAwaitTunQuiescence")

        val install = retirement.indexOf("service.installFailClosedTunFileDescriptor(")
        val retirementGeneration = retirement.indexOf("newFailClosedVpnGeneration(FailClosedVpnKind.RETIREMENT)")
        val trackedGeneration = retirement.indexOf("generation = retirementGeneration", install)
        val publicationWait = retirement.indexOf("awaitPlatformVpnRetirementNetwork(", trackedGeneration)
        assertTrue(
            "the unique .2 retirement generation must become a tracked barrier before its marker is awaited",
            retirementGeneration >= 0 && install > retirementGeneration && trackedGeneration > install &&
                publicationWait > trackedGeneration,
        )

        val retainForSuccessor = retirement.indexOf("if (retainForActiveSession())")
        val retainedForSuccessor = retirement.indexOf("retainedForSuccessor = true", retainForSuccessor)
        val successorLog = retirement.indexOf(
            "framework VPN retirement descriptor retained for accepted successor",
            retainedForSuccessor,
        )
        val successorReturn = retirement.indexOf("return PlatformVpnRetirementOutcome.RETAINED", successorLog)
        val terminalClose = retirement.indexOf("service.closeTunFileDescriptorIfCurrent(retirementDescriptor)")
        val releaseWait = retirement.indexOf("awaitPlatformVpnRetirementRelease(", terminalClose)
        assertTrue(
            "an accepted exact Connect must retain the tracked .2 descriptor and return before terminal release work",
            retainForSuccessor > publicationWait && retainedForSuccessor > retainForSuccessor &&
                successorLog > retainedForSuccessor && successorReturn > successorLog &&
                terminalClose > successorReturn,
        )
        assertTrue(
            "without a successor, terminal Stop must close that exact tracked .2 descriptor before awaiting its release",
            terminalClose >= 0 && releaseWait > terminalClose,
        )
        val terminalEpochClaim = retirement.indexOf("ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(")
        val staleTerminalRetained = retirement.indexOf("return PlatformVpnRetirementOutcome.RETAINED", terminalEpochClaim)
        assertTrue(
            "only the current terminal Stop epoch may close .2; a Connect-winning epoch must retain it",
            terminalEpochClaim >= 0 && terminalClose > terminalEpochClaim && staleTerminalRetained > terminalEpochClaim,
        )
        assertTrue(
            "retirement must report all explicit ownership outcomes",
            retirement.contains("PlatformVpnRetirementOutcome.RELEASED") &&
                retirement.contains("PlatformVpnRetirementOutcome.RETAINED") &&
                retirement.contains("PlatformVpnRetirementOutcome.FAILED"),
        )

        val successorBranch = retirement.substring(retainForSuccessor, terminalClose)
        assertFalse(
            "successor handoff must not close or establish a third fail-closed VPN generation",
            successorBranch.contains(".close()") || successorBranch.contains("newFailClosedVpnBuilder"),
        )
        val reusableBarrier = ensureFailClosedVpn.indexOf("if (service.isFailClosedTunBarrierActive())")
        val barrierReturn = ensureFailClosedVpn.indexOf("return true", reusableBarrier)
        val prepare = ensureFailClosedVpn.indexOf("if (VpnService.prepare(this) != null)")
        assertTrue(
            "normal fail-closed admission must reuse any exact tracked barrier before trying to establish .1",
            reusableBarrier >= 0 && barrierReturn > reusableBarrier && prepare > barrierReturn,
        )
        assertTrue(
            "openTun must replace the retained successor descriptor directly with the data-plane TUN",
            openTun.indexOf("service.replaceTunFileDescriptor(pfd)") > openTun.indexOf("val pfd = builder.establish()") &&
                !openTun.contains("ensureFailClosedVpn("),
        )
        assertFalse(
            "accepted Connect may not install a fallback .1 while a missing exact barrier is being handled",
            cleanup.contains("ensurePhysicalFailClosedVpn(\"accepted Connect superseded platform release"),
        )
    }

    @Test
    fun `fail closed VPN reuse waits for the exact published barrier`() {
        val vpn = sourceFile("VPNService.kt")
        val ensureFailClosedVpn = functionBody(vpn, "ensureFailClosedVpn")
        val box = sourceFile("BoxService.kt")
        val ensurePhysicalFailClosedVpn = functionBody(box, "ensurePhysicalFailClosedVpn")

        val reuseBarrier = ensureFailClosedVpn.indexOf("service.isFailClosedTunBarrierActive()")
        assertTrue(
            "VPNService may reuse a fail-closed TUN only after BoxService confirms the exact barrier",
            reuseBarrier >= 0,
        )
        val pendingDescriptor = ensureFailClosedVpn.indexOf("if (service.hasFailClosedVpnDescriptor())")
        val pendingReturn = ensureFailClosedVpn.indexOf("return true", pendingDescriptor)
        val prepare = ensureFailClosedVpn.indexOf("if (VpnService.prepare(this) != null)")
        assertTrue(
            "a tracked pending fail-closed descriptor must be reused before publication instead of creating another VPN",
            pendingDescriptor > reuseBarrier && pendingReturn > pendingDescriptor && prepare > pendingReturn,
        )
        assertFalse(
            "pending-descriptor reuse must neither establish a VPN nor open native diagnostics before BoxService verifies marker and TUN health",
            Regex("(?m)^\\s*\\.establish\\(\\)").containsMatchIn(
                ensureFailClosedVpn.substring(pendingDescriptor, prepare),
            ) ||
                ensureFailClosedVpn.substring(pendingDescriptor, prepare)
                    .contains("NativeCrashDiagnostics.setNetworkAdmissionAllowed"),
        )
        assertFalse(
            "VPNService must leave diagnostics admission closed; the exact BoxService barrier owns that decision",
            ensureFailClosedVpn.contains("NativeCrashDiagnostics.setNetworkAdmissionAllowed"),
        )

        val install = ensurePhysicalFailClosedVpn.indexOf("vpnService.ensureFailClosedVpn()")
        val verifiedBarrier = ensurePhysicalFailClosedVpn.indexOf(
            "isFailClosedTunBarrierActive()",
            install,
        )
        val successfulReturn = ensurePhysicalFailClosedVpn.indexOf("if (installed) return true")
        assertTrue(
            "a successful fail-closed install must wait for the exact active barrier before BoxService reports success",
            install >= 0 && verifiedBarrier > install,
        )
        assertFalse(
            "an install result alone must not report physical fail-closed VPN success",
            successfulReturn >= 0,
        )
    }

    @Test
    fun `new terminal Stop supersedes Stop Connect Stop race while regular cleanup remains active`() {
        val box = sourceFile("BoxService.kt")
        val stopService = functionBody(box, "stopService")
        val deferStop = functionBody(box, "deferTerminalStopUntilCleanupCompletes")
        val completion = functionBody(box, "onServiceStopCleanupCompleted")

        val terminalIntent = stopService.indexOf("val terminalIntent = if (terminalStopAlreadyClaimed)")
        val terminalAdmission = stopService.indexOf("val terminalStopAdmitted =", terminalIntent)
        val predecessor = stopService.indexOf("val predecessorStopJob = serviceStopJob", terminalAdmission)
        val activePredecessor = stopService.indexOf("predecessorStopJob?.isActive == true", predecessor)
        val invalidatedGeneration = stopService.indexOf("val deferredStopGeneration = cancelPendingStarts()", activePredecessor)
        val deferCall = stopService.indexOf("deferTerminalStopUntilCleanupCompletes(", invalidatedGeneration)
        val deferredReturn = stopService.indexOf("return", deferCall)
        val activeCleanupBranch = stopService.substring(activePredecessor, deferCall)

        assertTrue(
            "a second terminal Stop must be admitted after its own exact terminal intent and observe the still-active regular cleanup job",
            terminalIntent >= 0 && terminalAdmission > terminalIntent && predecessor > terminalAdmission &&
                activePredecessor > predecessor,
        )
        assertTrue(
            "Stop -> Connect -> Stop must invalidate current start work before retaining the newest Stop behind the predecessor cleanup",
            invalidatedGeneration > activePredecessor && deferCall > invalidatedGeneration && deferredReturn > deferCall,
        )
        assertFalse(
            "an active regular serviceStopJob must not coalesce or return before the new terminal epoch is retained",
            activeCleanupBranch.contains("if (serviceStopJob?.isActive == true) return") ||
                activeCleanupBranch.contains("if (predecessorStopJob?.isActive == true) return"),
        )
        assertTrue(
            "only the newest exact terminal Stop must retain its predecessor Job, terminal epoch, and Quick Settings identity",
            deferStop.contains("deferredTerminalStopAfterCleanup = DeferredTerminalStopAfterCleanup(") &&
                deferStop.contains("predecessorJob = predecessorJob") &&
                deferStop.contains("terminalIntent = terminalIntent") &&
                deferStop.contains("quickSettingsRequestId = quickSettingsRequestId"),
        )

        val completionHook = stopService.indexOf("newStopJob.invokeOnCompletion {")
        val completionCallback = stopService.indexOf("onServiceStopCleanupCompleted(newStopJob)", completionHook)
        val publishedJob = stopService.indexOf("serviceStopJob = newStopJob", completionCallback)
        val startJob = stopService.indexOf("newStopJob.start()", publishedJob)
        val earlyClear = stopService.indexOf("serviceStopJob = null")
        assertTrue(
            "serviceStopJob must remain published until its completion callback is installed and the cleanup has actually started",
            completionHook >= 0 && completionCallback > completionHook && publishedJob > completionCallback && startJob > publishedJob,
        )
        assertTrue(
            "the regular cleanup body must not clear serviceStopJob before invokeOnCompletion fires",
            earlyClear < 0,
        )

        val completedOwner = completion.indexOf("if (serviceStopJob === completedJob)")
        val clearCompletedJob = completion.indexOf("serviceStopJob = null", completedOwner)
        val matchingPredecessor = completion.indexOf("it.predecessorJob === completedJob", clearCompletedJob)
        val terminalEpochCurrent = completion.indexOf("isTerminalStopEpochCurrent(", matchingPredecessor)
        val supersededLog = completion.indexOf("discarding deferred terminal Stop superseded", terminalEpochCurrent)
        val supersededReturn = completion.indexOf("return@post", supersededLog)
        val replay = completion.indexOf("target.stopService(", supersededReturn)
        assertTrue(
            "completion must clear only the finished job and consume only a deferred Stop owned by that exact predecessor",
            completedOwner >= 0 && clearCompletedJob > completedOwner && matchingPredecessor > clearCompletedJob,
        )
        assertTrue(
            "the predecessor completion event must discard a superseded terminal epoch before replaying only the still-current exact Stop",
            terminalEpochCurrent > matchingPredecessor && supersededLog > terminalEpochCurrent &&
                supersededReturn > supersededLog && replay > supersededReturn,
        )
        assertTrue(
            "event-driven replay must forward the deferred terminal epoch and exact persisted/probe fields rather than creating a fresh Stop",
            completion.substring(replay).contains("terminalStopAlreadyClaimed = true") &&
                completion.substring(replay).contains("terminalSessionEpoch = deferredStop.terminalIntent.terminalSessionEpoch") &&
                completion.substring(replay).contains("terminalProbeBlockEpoch = deferredStop.terminalIntent.probeBlockEpoch"),
        )
        assertFalse(
            "the Stop race must not add timer, delay, or scheduled watchdog workaround work",
            stopService.contains("Timer(") || stopService.contains("delay(") ||
                deferStop.contains("Timer(") || deferStop.contains("delay(") ||
                completion.contains("Timer(") || completion.contains("delay("),
        )
    }

    @Test
    fun `Samsung framework Always-on commands restore only the persisted session and never start in parallel`() {
        val box = sourceFile("BoxService.kt")
        val command = sourceSection(box, "internal fun onStartCommand", "\n    private suspend fun startStoredCoreFromNativeEntryPoint")

        val restartedBySystem = command.indexOf("val restartedBySystem = intent == null")
        val frameworkAction = command.indexOf("intent.action == VpnService.SERVICE_INTERFACE", restartedBySystem)
        val restorePolicy = command.indexOf("val shouldRestoreUserSession = shouldRestoreUserSessionFromServiceCommand(", frameworkAction)
        val persistedIntent = command.indexOf("userSessionActive = Settings.startedByUser", restorePolicy)
        val persistedConfig = command.indexOf("activeConfigAvailable = Settings.activeConfigPath.isNotBlank()", persistedIntent)
        assertTrue(
            "a non-null Samsung VpnService command with flags=0 must be classified as a system restart using the persisted session and config identity",
            restartedBySystem >= 0 && frameworkAction > restartedBySystem && restorePolicy > frameworkAction &&
                persistedIntent > restorePolicy && persistedConfig > persistedIntent,
        )

        val activeService = command.indexOf("if (status.value != Status.Stopped)")
        val activeSystemRedelivery = command.indexOf(
            "if ((restartedBySystem || processRecoveryRequested) && !connectFromNotification)",
            activeService,
        )
        val activeIgnored = command.indexOf("ignoring system service restart while service is already active", activeSystemRedelivery)
        val activeReturn = command.indexOf("return Service.START_STICKY", activeIgnored)
        val nextActiveBranch = command.indexOf("if (connectFromNotification && status.value == Status.Started)", activeReturn)
        val activeRedeliveryBranch = command.substring(activeSystemRedelivery, nextActiveBranch)
        assertTrue(
            "a repeated framework command during an active pipeline must return as a system redelivery",
            activeSystemRedelivery > activeService && activeIgnored > activeSystemRedelivery && activeReturn > activeIgnored,
        )
        assertFalse(
            "an active framework redelivery must not bypass the sealed pipeline with another native start",
            activeRedeliveryBranch.contains("startStoredCoreFromNativeEntryPoint()") ||
                activeRedeliveryBranch.contains("launchServiceStart(") ||
                activeRedeliveryBranch.contains("serviceScope.launch(Dispatchers.IO)"),
        )

        val restoreBranch = command.indexOf("if (shouldRestoreUserSession)", activeService)
        val restorePending = command.indexOf("Settings.startCoreAfterStartingService = true", restoreBranch)
        val restoreLaunch = command.indexOf("launchServiceStart(", restorePending)
        assertTrue(
            "a persisted session with its stored config must enqueue exactly that recovery for the normal service pipeline",
            restoreBranch > activeService && restorePending > restoreBranch && restoreLaunch > restorePending,
        )

        val terminalSystemRedelivery = command.indexOf(
            "} else if ((restartedBySystem || processRecoveryRequested) && !connectFromNotification)",
            restorePending,
        )
        val clearIntent = command.indexOf("Settings.startedByUser = false", terminalSystemRedelivery)
        val clearPending = command.indexOf("Settings.startCoreAfterStartingService = false", clearIntent)
        val stopSelf = command.indexOf("service.stopSelf()", clearPending)
        val notSticky = command.indexOf("return Service.START_NOT_STICKY", stopSelf)
        val terminalBranch = command.substring(terminalSystemRedelivery, notSticky)
        assertTrue(
            "after authoritative Disconnect, a framework restart must clear pending state, stop itself, and be non-sticky without manufacturing user intent",
            terminalSystemRedelivery > restorePending && clearIntent > terminalSystemRedelivery && clearPending > clearIntent &&
                stopSelf > clearPending && notSticky > stopSelf,
        )
        assertFalse(
            "onStartCommand is no longer allowed to write a new user intent; only the exact admission epoch transaction may do so",
            command.contains("Settings.startedByUser = true"),
        )
        assertFalse(
            "the no-session framework branch must not initialize setup, core, watchdog, or another start pipeline",
            terminalBranch.contains("initialize()") ||
                terminalBranch.contains("startStoredCoreFromNativeEntryPoint()") ||
                terminalBranch.contains("launchServiceStart(") ||
                terminalBranch.contains("startIcmp") ||
                terminalBranch.contains("startRoute"),
        )
    }

    @Test
    fun `service start pipeline preserves newest full request and rejects stale native work`() {
        val box = sourceFile("BoxService.kt")
        val launch = functionBody(box, "launchServiceStart")
        val pipeline = functionBody(box, "runServiceStartPipeline")
        val serviceStart = functionBody(box, "startService")
        val nativeStart = functionBody(box, "startStoredCoreFromNativeEntryPoint")
        val destroy = functionBody(box, "onDestroy")
        val command = sourceSection(box, "internal fun onStartCommand", "\n    private suspend fun startStoredCoreFromNativeEntryPoint")

        assertTrue(
            "a queued pipeline request must retain both generation and config-migration ownership",
            box.contains("private data class ServiceStartRequest(") &&
                box.contains("val generation: Long") &&
                box.contains("val allowStoredIdentityMigration: Boolean"),
        )
        val activeLock = launch.indexOf("val admitted = synchronized(lifecycleLock)")
        val activate = launch.indexOf("serviceStartPipelineActive = true", activeLock)
        val launchAsync = launch.indexOf("serviceScope.launch(Dispatchers.IO)", activate)
        val pipelineCall = launch.indexOf("runServiceStartPipeline(request)", launchAsync)
        assertTrue(
            "the sole pipeline owner must be admitted under lifecycleLock before its coroutine is launched",
            activeLock >= 0 && activate > activeLock && launchAsync > activate && pipelineCall > launchAsync,
        )
        assertTrue(
            "a newer generation must replace the complete pending request rather than only a boolean start flag",
            launch.contains("generation > serviceStartPipelineGeneration") &&
                launch.contains("pendingServiceStartRequest = request"),
        )
        assertTrue(
            "duplicate generation commands must coalesce while preserving the stricter migration prohibition",
            launch.contains("generation == pending.generation") &&
                launch.contains("userSessionEpoch == pending.userSessionEpoch") &&
                launch.contains("pendingServiceStartRequest = pending.copy(") &&
                launch.contains("pending.allowStoredIdentityMigration && allowStoredIdentityMigration"),
        )

        val nativeClaimLock = serviceStart.indexOf("val startCoreInService = synchronized(lifecycleLock)")
        val pendingFlag = serviceStart.indexOf("Settings.startCoreAfterStartingService &&", nativeClaimLock)
        val ownerCheck = serviceStart.indexOf("shouldContinueStart(generation)", pendingFlag)
        val clearPendingFlag = serviceStart.indexOf("Settings.startCoreAfterStartingService = false", ownerCheck)
        val claimEnd = serviceStart.indexOf("if (startCoreInService)", clearPendingFlag)
        val nativeClaim = serviceStart.substring(nativeClaimLock, claimEnd)
        assertTrue(
            "the global native-start flag may be claimed only while lifecycleLock verifies the exact pipeline generation",
            nativeClaimLock >= 0 && pendingFlag > nativeClaimLock && ownerCheck > pendingFlag &&
                clearPendingFlag > ownerCheck,
        )
        assertTrue(
            "a stale setup generation must leave the shared native-start flag for the newer pipeline handoff",
            nativeClaim.contains("} else {\n                    false") &&
                Regex("Settings\\.startCoreAfterStartingService\\s*=\\s*false")
                    .findAll(nativeClaim)
                    .count() == 1,
        )

        val pipelineStart = pipeline.indexOf("pipeline@ while (true)")
        val setup = pipeline.indexOf("startService(", pipelineStart)
        val pendingLock = pipeline.indexOf("val startPendingCore = synchronized(lifecycleLock)", setup)
        val pendingRead = pipeline.indexOf("val pending = pendingServiceStartRequest", pendingLock)
        val takePending = pipeline.indexOf("pendingServiceStartRequest = null", pendingRead)
        val transferGeneration = pipeline.indexOf("serviceStartPipelineGeneration = pending.generation", takePending)
        val handoff = pipeline.indexOf("request = queued", transferGeneration)
        val continuePipeline = pipeline.indexOf("continue@pipeline", handoff)
        val release = pipeline.indexOf("serviceStartPipelineActive = false", pendingLock)
        assertTrue(
            "the old owner must hand off the newest request and its generation before it can release the sole pipeline",
            pipelineStart >= 0 && setup > pipelineStart && pendingLock > setup && pendingRead > pendingLock &&
                takePending > pendingRead && transferGeneration > takePending && handoff > transferGeneration &&
                continuePipeline > handoff && release > pendingRead,
        )
        assertTrue(
            "pipeline release is allowed only when no newer full request remains",
            pipeline.substring(pendingRead, release).contains("if (pending != null)") &&
                pipeline.substring(pendingRead, release).contains("nextRequest = pending"),
        )

        assertTrue(
            "pipeline drain must pass its owned request generation into native core start",
            pipeline.contains("startStoredCoreFromNativeEntryPoint(") &&
                pipeline.contains("generation = request.generation"),
        )
        val standaloneGeneration = command.indexOf("val nativeStartGeneration = currentStartGeneration()")
        val standaloneLaunch = command.indexOf("serviceScope.launch(Dispatchers.IO)", standaloneGeneration)
        val standaloneStart = command.indexOf("startStoredCoreFromNativeEntryPoint(", standaloneLaunch)
        val standaloneGenerationArg = command.indexOf("generation = nativeStartGeneration", standaloneStart)
        assertTrue(
            "a standalone native-start coroutine must capture its generation before release to prevent a later start from being stolen",
            standaloneGeneration >= 0 && standaloneLaunch > standaloneGeneration &&
                standaloneStart > standaloneLaunch && standaloneGenerationArg > standaloneStart,
        )

        val staleGuard = nativeStart.indexOf("!ServiceLifecycleOwnership.isUserSessionEpochCurrent(userSessionEpoch)")
        val staleReturn = nativeStart.indexOf("return", staleGuard)
        val externalCheck = nativeStart.indexOf("shouldYieldToExternalVpn", staleReturn)
        val monitor = nativeStart.indexOf("startCoreRuntimeMonitor", externalCheck)
        val alert = nativeStart.indexOf("stopAndAlert(", externalCheck)
        val staleReturnAfterChecks = nativeStart.indexOf("return", externalCheck)
        assertTrue(
            "a stale owned generation must return before any stop, monitor, or core-start side effect",
            staleGuard >= 0 && staleReturn >= 0 && staleReturn > staleGuard &&
                externalCheck > staleReturn &&
                monitor > externalCheck &&
                staleReturnAfterChecks > externalCheck,
        )
        assertTrue(
            "failure publication after native work must remain generation-gated",
            nativeStart.contains("if (shouldContinueStart(generation)) {") &&
                nativeStart.contains("discarding stale native core start failure generation=\$generation"),
        )

        val finallyLock = pipeline.indexOf("synchronized(lifecycleLock)", pipeline.indexOf("finally"))
        val clearActive = pipeline.indexOf("serviceStartPipelineActive = false", finallyLock)
        val clearGeneration = pipeline.indexOf("serviceStartPipelineGeneration = 0L", clearActive)
        val clearRequest = pipeline.indexOf("pendingServiceStartRequest = null", clearGeneration)
        val destroyCancel = destroy.indexOf("cancelPendingStarts()")
        val destroyJobCancel = destroy.indexOf("serviceJob.cancel()", destroyCancel)
        assertTrue(
            "cancellation must atomically clear all instance-local pipeline state",
            finallyLock >= 0 && clearActive > finallyLock && clearGeneration > clearActive && clearRequest > clearGeneration,
        )
        assertTrue(
            "onDestroy must cancel pending generations before cancelling the instance job that performs the atomic pipeline cleanup",
            destroyCancel >= 0 && destroyJobCancel > destroyCancel,
        )
    }

    @Test
    fun `native user connect is handed to the live Flutter strict-egress owner before native service start`() {
        val events = mainSourceFile("EventHandler.kt")
        val bridge = sourceSection(events, "object NativeConnectRequestBridge", "\nclass EventHandler")
        val eventHandler = sourceSection(events, "class EventHandler", "\ndata class ServiceEvent")
        val permissionActivity = mainSourceFile("VpnPermissionActivity.kt")
        val activityCreate = functionBody(permissionActivity, "onCreate")
        val permissionRequest = functionBody(permissionActivity, "requestVpnOwnership")
        val userGesture = sourceSection(
            permissionActivity,
            "private fun startMartenFromUserGesture()",
            "\n    private fun recordQuickSettings",
        )
        val box = sourceFile("BoxService.kt")
        val connect = functionBody(box, "connect")

        assertTrue(
            "native connect requests must use their dedicated EventChannel name",
            events.contains("const val CONNECT_REQUESTS = \"app.marten.client/connect.requests\"") &&
                eventHandler.contains("EventChannel(flutterPluginBinding.binaryMessenger, CONNECT_REQUESTS"),
        )
        assertTrue(
            "a request can be handed to Flutter only when its engine, foreground presentation, and Dart EventSink are all live",
            bridge.contains("if (!engineAttached || !foregroundPresentationActive || events == null) return false") &&
                bridge.contains("fun onForegroundPresentationStarted()") &&
                bridge.contains("fun onForegroundPresentationStopped()") &&
                bridge.contains("fun requestFlutterConnect(source: String, requestId: Long = 0L): Boolean"),
        )
        assertTrue(
            "an early native request must be retained until Dart starts listening",
            bridge.contains("pending.addLast(") && bridge.contains("fun onListen(eventSink: EventChannel.EventSink?)"),
        )
        assertTrue(
            "attached Flutter engines must receive retained native connect requests",
                eventHandler.contains("NativeConnectRequestBridge.onEngineAttached()") &&
                eventHandler.contains("NativeConnectRequestBridge.onListen(events)"),
        )

        val issuedLease = activityCreate.indexOf("explicitStartLease = ServiceLifecycleOwnership.issueExplicitStartLease()")
        val earlyHandoff = activityCreate.indexOf("when (handOffExplicitLeaseToLiveFlutter())", issuedLease)
        val flutterHandoff = activityCreate.indexOf("NativeConnectDispatchResult.FLUTTER_HANDOFF", earlyHandoff)
        val handoffLeaseClear = activityCreate.indexOf("explicitStartLease = null", flutterHandoff)
        val handoffPending = activityCreate.indexOf("flutterHandoffPending = true", handoffLeaseClear)
        val permissionHost = activityCreate.indexOf("activeFlutterPermissionHost = this", handoffPending)
        val earlyReturn = activityCreate.indexOf("return", permissionHost)
        val permissionRequestCall = activityCreate.indexOf("requestVpnOwnership()", earlyHandoff)
        assertTrue(
            "a live Flutter listener receives the captured lease while the permission Activity remains foreground host until Dart requests real VPN preparation",
            issuedLease >= 0 && earlyHandoff > issuedLease && flutterHandoff > earlyHandoff &&
                handoffLeaseClear > flutterHandoff && handoffPending > handoffLeaseClear &&
                permissionHost > handoffPending && earlyReturn > permissionHost && permissionRequestCall > earlyHandoff &&
                !activityCreate.substring(flutterHandoff, earlyReturn).contains("finish()"),
        )
        assertTrue(
            "VpnService.prepare must remain exclusively behind the cold-engine permission path",
            permissionRequest.contains("VpnService.prepare(this)"),
        )

        assertTrue(
            "a cold permission prompt must capture its exact lease before VpnService.prepare can be reached",
            issuedLease >= 0 && permissionRequestCall > issuedLease,
        )

        val gestureLease = userGesture.indexOf("val startLease = explicitStartLease")
        val clearActivityLease = userGesture.indexOf("explicitStartLease = null", gestureLease)
        val missingLeaseReturn = userGesture.indexOf("if (startLease == null)", clearActivityLease)
        val permissionDispatch = userGesture.indexOf("BoxService.connect(", missingLeaseReturn)
        val sameLeaseArgument = userGesture.indexOf("explicitStartLease = startLease", permissionDispatch)
        assertTrue(
            "RESULT_OK must atomically consume the Activity field and forward that same pre-prompt lease to BoxService",
            gestureLease >= 0 && clearActivityLease > gestureLease && missingLeaseReturn > clearActivityLease &&
                permissionDispatch > missingLeaseReturn && sameLeaseArgument > permissionDispatch,
        )

        val explicitLeaseBranch = connect.indexOf("if (explicitStartLease != null)")
        val exactDispatch = connect.indexOf("NativeConnectRequestBridge.dispatchExplicitConnect(", explicitLeaseBranch)
        val dispatchedLease = connect.indexOf("explicitStartLease = explicitStartLease", exactDispatch)
        val explicitReturn = connect.indexOf("return", dispatchedLease)
        val ordinaryHandoff = connect.indexOf("NativeConnectRequestBridge.requestFlutterConnect(entrySource, quickSettingsRequestId)", explicitReturn)
        assertTrue(
            "post-prompt live Flutter dispatch must receive the already captured lease before the ordinary native handoff path",
            explicitLeaseBranch >= 0 && exactDispatch > explicitLeaseBranch && dispatchedLease > exactDispatch &&
                explicitReturn > dispatchedLease && ordinaryHandoff > explicitReturn,
        )
        assertTrue(
            "the generic no-lease native route remains distinct from a permission-owned exact lease",
            connect.substring(explicitLeaseBranch, ordinaryHandoff).contains("NativeConnectDispatchResult.FLUTTER_HANDOFF"),
        )
    }

    @Test
    fun `permission prompt preserves one exact lease across recreation engine attach and terminal Stop`() {
        val activity = mainSourceFile("VpnPermissionActivity.kt")
        val events = mainSourceFile("EventHandler.kt")
        val bridge = sourceSection(events, "object NativeConnectRequestBridge", "\nclass EventHandler")
        val onCreate = functionBody(activity, "onCreate")
        val onSave = functionBody(activity, "onSaveInstanceState")
        val onDestroy = functionBody(activity, "onDestroy")
        val permission = functionBody(activity, "requestVpnOwnership")
        val result = functionBody(activity, "onActivityResult")
        val gesture = sourceSection(
            activity,
            "private fun startMartenFromUserGesture()",
            "\n    private fun cancelExplicitStartLease",
        )
        val dispatch = sourceSection(bridge, "fun dispatchExplicitConnect(", "fun claimFlutterConnect")
        val attach = sourceSection(bridge, "fun onEngineAttached()", "fun onEngineDetached()")

        val restoredLease = onCreate.indexOf("val restoredLease = savedInstanceState.getLong(STATE_EXPLICIT_START_LEASE, 0L)")
        val restoredValidation = onCreate.indexOf("!ServiceLifecycleOwnership.isExplicitStartLeaseCurrent(restoredLease)", restoredLease)
        val restoreAssignment = onCreate.indexOf("explicitStartLease = restoredLease", restoredValidation)
        assertTrue(
            "configuration recreation must restore and validate the original prompt lease instead of issuing another one",
            restoredLease >= 0 && restoredValidation > restoredLease && restoreAssignment > restoredValidation &&
                onCreate.substring(restoredLease).let { !it.contains("issueExplicitStartLease()") },
        )
        assertTrue(
            "an ordinary prompt lease must survive only configuration recreation",
            onSave.contains("explicitStartLease?.let { outState.putLong(STATE_EXPLICIT_START_LEASE, it) }") &&
                onDestroy.contains("if (!isChangingConfigurations) cancelExplicitStartLease()"),
        )
        assertTrue(
            "a Flutter handoff recreation must retain and restore the pending VPN Deferred and transfer host ownership without cancelling the exact bridge request",
            activity.contains("private data class FlutterPermissionHostState(") &&
                activity.contains("override fun onRetainNonConfigurationInstance(): Any?") &&
                activity.contains("if (flutterHandoffPending)") &&
                activity.contains("vpnPermission = pendingStrictVpnPermission") &&
                onCreate.contains("lastNonConfigurationInstance as? FlutterPermissionHostState") &&
                onCreate.contains("pendingStrictVpnPermission = retainedFlutterHost.vpnPermission") &&
                onCreate.contains("activeFlutterPermissionHost = this") &&
                onDestroy.contains("val transferringFlutterHandoff = flutterHandoffPending && isChangingConfigurations"),
        )
        assertTrue(
            "only dismissal or process death may complete the pending VPN Deferred false and cancel its exact handoff; a configuration transfer skips it",
            onDestroy.contains("if (!transferringFlutterHandoff)") &&
                onDestroy.contains("pendingStrictVpnPermission?.takeIf { it.isActive }?.complete(false)") &&
                onDestroy.contains("if (abandonedFlutterHandoff)") &&
                onDestroy.contains(
                    "NativeConnectRequestBridge.cancelPermissionHandoff(entrySource, nativeHandoffRequestId)",
                ),
        )

        val prepare = permission.indexOf("VpnService.prepare(this)")
        val prepareFailureCancel = permission.indexOf("cancelExplicitStartLease()", prepare)
        val prepareFailureFinish = permission.indexOf("finish()", prepareFailureCancel)
        val promptFailureCancel = permission.indexOf("cancelExplicitStartLease()", prepareFailureFinish)
        assertTrue(
            "prepare and prompt-launch failures must release the captured exact lease before finishing",
            prepare >= 0 && prepareFailureCancel > prepare && prepareFailureFinish > prepareFailureCancel &&
                promptFailureCancel > prepareFailureFinish,
        )
        val granted = result.indexOf("if (resultCode == RESULT_OK)")
        val grantedDispatch = result.indexOf("startMartenFromUserGesture()", granted)
        val denied = result.indexOf("cancelExplicitStartLease()", grantedDispatch)
        assertTrue(
            "permission denial releases the same prompt lease while RESULT_OK can only dispatch it through the exact user gesture method",
            granted >= 0 && grantedDispatch > granted && denied > grantedDispatch,
        )
        assertTrue(
            "the Activity must not mint another lease after Android returns RESULT_OK",
            !gesture.contains("issueExplicitStartLease()"),
        )

        val dispatchLock = dispatch.indexOf("val result = synchronized(lock)")
        val currentLease = dispatch.indexOf("!ServiceLifecycleOwnership.isExplicitStartLeaseCurrent(explicitStartLease)", dispatchLock)
        val rejected = dispatch.indexOf("NativeConnectDispatchResult.REJECTED", currentLease)
        val noFlutterOwner = dispatch.indexOf(
            "if (!engineAttached || !foregroundPresentationActive || events == null)",
            rejected,
        )
        val nativeStart = dispatch.indexOf("startNative()", noFlutterOwner)
        val flutterClaim = dispatch.indexOf("claimedStartLease = explicitStartLease", nativeStart)
        val flutterDelivery = dispatch.indexOf("if (dispatchFlutter) dispatchPendingOnMainThread()", flutterClaim)
        assertTrue(
            "a Stop during the permission prompt must reject its stale lease before either native start or Flutter delivery",
            dispatchLock >= 0 && currentLease > dispatchLock && rejected > currentLease && noFlutterOwner > rejected &&
                nativeStart > noFlutterOwner && flutterClaim > nativeStart && flutterDelivery > flutterClaim,
        )
        assertTrue(
            "engine attachment and explicit post-prompt dispatch must share one lock, so an old Activity cannot race a new engine into native start",
            attach.contains("synchronized(lock)") && dispatch.contains("synchronized(lock)") &&
                dispatch.substring(dispatchLock, flutterDelivery).contains("claimedStartLease = explicitStartLease"),
        )
        assertTrue(
            "a live engine after the prompt receives the exact pre-prompt lease instead of a freshly issued bridge lease",
            dispatch.contains("claimedStartLease = explicitStartLease") && !dispatch.contains("issueExplicitStartLease()"),
        )
    }

    @Test
    fun `KR-057 Flutter handoff retains one foreground permission host and MethodHandler prefers it`() {
        val activity = mainSourceFile("VpnPermissionActivity.kt")
        val onCreate = functionBody(activity, "onCreate")
        val onNewIntent = functionBody(activity, "onNewIntent")
        val beginVpnPermission = functionBody(activity, "beginStrictVpnPermission")
        val finishHost = functionBody(activity, "finishFlutterPermissionHost")
        val methodHandler = mainSourceFile("MethodHandler.kt")
        val admission = sourceSection(
            methodHandler,
            "Trigger.BeginVpnStartAdmission.method -> {",
            "Trigger.ICMPPing.method -> {",
        )
        val manifest = File("src/main/AndroidManifest.xml").readText()
        val activityDeclaration = manifest.substring(
            manifest.indexOf("android:name=\".VpnPermissionActivity\""),
            manifest.indexOf("/>", manifest.indexOf("android:name=\".VpnPermissionActivity\"")) + 2,
        )

        val handoff = onCreate.indexOf("NativeConnectDispatchResult.FLUTTER_HANDOFF")
        val pending = onCreate.indexOf("flutterHandoffPending = true", handoff)
        val host = onCreate.indexOf("activeFlutterPermissionHost = this", pending)
        val handoffReturn = onCreate.indexOf("return", host)
        assertTrue(
            "the FLUTTER_HANDOFF Activity must remain the active foreground permission host instead of finishing before VpnService.prepare",
            handoff >= 0 && pending > handoff && host > pending && handoffReturn > host &&
                !onCreate.substring(handoff, handoffReturn).contains("finish()"),
        )
        val existingPermissionHost = onCreate.indexOf("val existingHost = activePermissionActivity")
        val coalescePredicate = onCreate.indexOf("existingHost.canCoalescePermissionRequest()", existingPermissionHost)
        val coalesceLog = onCreate.indexOf("coalesced_with_active_host", coalescePredicate)
        val coalesceFinish = onCreate.indexOf("finish()", coalesceLog)
        val coalesceReturn = onCreate.indexOf("return", coalesceFinish)
        val publishHost = onCreate.indexOf("activePermissionActivity = this", coalesceReturn)
        val issueLease = onCreate.indexOf("explicitStartLease = ServiceLifecycleOwnership.issueExplicitStartLease()", publishHost)
        val coldNoListener = onCreate.indexOf("NativeConnectDispatchResult.NO_ENGINE -> Unit", issueLease)
        val coldPrepare = onCreate.indexOf("requestVpnOwnership()", coldNoListener)
        assertTrue(
            "rapid QS taps must coalesce for every active permission flow, including a cold engine with no EventSink, before a second lease or VpnService.prepare is possible",
            activityDeclaration.contains("android:launchMode=\"singleTop\"") &&
                activity.contains("private fun canCoalescePermissionRequest(): Boolean = !isFinishing && !isDestroyed") &&
                existingPermissionHost >= 0 && coalescePredicate > existingPermissionHost && coalesceLog > coalescePredicate &&
                coalesceFinish > coalesceLog && coalesceReturn > coalesceFinish && publishHost > coalesceReturn &&
                issueLease > publishHost && coldNoListener > issueLease && coldPrepare > coldNoListener,
        )
        assertTrue(
            "onNewIntent must preserve the first source/request identity and only record the coalesced tap",
            onNewIntent.contains("coalesced_with_active_host") &&
                !onNewIntent.contains("intent = newIntent") &&
                !onNewIntent.contains("issueExplicitStartLease()") &&
                !onNewIntent.contains("requestVpnOwnership()"),
        )

        val prepare = beginVpnPermission.indexOf("VpnService.prepare(this)")
        val prompt = beginVpnPermission.indexOf("startActivityForResult(permissionIntent, VPN_PERMISSION_REQUEST_CODE)", prepare)
        val finishAfterPrepare = beginVpnPermission.indexOf("finishFlutterPermissionHost", prepare)
        assertTrue(
            "only the retained permission host may invoke Android's real VPN preparation and finish once that permission path resolves",
            prepare >= 0 && (prompt > prepare || finishAfterPrepare > prepare),
        )
        assertTrue(
            "host completion must use the exact normalized ID supplied to dispatch, preserving QS IDs while mapping shortcut/notification to zero",
            activity.contains("private val nativeHandoffRequestId: Long") &&
                activity.contains("get() = entryRequestId.takeIf { isQuickSettingsEntry } ?: 0L") &&
                finishHost.contains(
                    "NativeConnectRequestBridge.cancelPermissionHandoff(entrySource, nativeHandoffRequestId)",
                ) &&
                activity.contains("requestId = nativeHandoffRequestId"),
        )

        val vpnHost = admission.indexOf("VpnPermissionActivity.awaitStrictVpnPermission")
        val vpnFallback = admission.indexOf(
            "?: MainActivity.instance.awaitStrictVpnPermission",
            vpnHost,
        )
        assertTrue(
            "MethodHandler must prefer the retained Flutter permission host for VPN permission; MainActivity is a lazy fallback only after that host is absent",
            vpnHost >= 0 && vpnFallback > vpnHost &&
                !admission.contains("val activity = MainActivity.instance"),
        )
        listOf(
            "awaitStrictNotificationPermission",
            "POST_NOTIFICATIONS",
            "RequestNotificationPermission",
        ).forEach { notificationAdmissionArtifact ->
            assertFalse(
                "MethodHandler VPN admission must not wait for or report notification permission through $notificationAdmissionArtifact",
                admission.contains(notificationAdmissionArtifact),
            )
        }
    }

    @Test
    fun `failed VPN admission immediately rolls back user intent and seals native networking`() {
        val methodHandler = mainSourceFile("MethodHandler.kt")
        val methodAdmission = sourceSection(
            methodHandler,
            "Trigger.BeginVpnStartAdmission.method -> {",
            "Trigger.ICMPPing.method -> {",
        )
        val permission = methodAdmission.indexOf("awaitStrictVpnPermission(allowPrompt = !resumeSession)")
        val permissionDeniedRelease = methodAdmission.indexOf(
            "explicitStartLease?.let(ServiceLifecycleOwnership::releaseExplicitStartLease)",
            permission,
        )
        val permissionDeniedError = methodAdmission.indexOf("error(\"Android VPN permission was not granted\")", permissionDeniedRelease)
        val beginAdmission = methodAdmission.indexOf("BoxService.beginVpnStartAdmission(")
        assertTrue(
            "a denied Android VPN permission must release only its unconsumed exact lease before reporting failure",
            permission >= 0 && permissionDeniedRelease > permission && permissionDeniedError > permissionDeniedRelease,
        )
        assertTrue(
            "permission rejection must not proceed into the native admission transaction or abort a newer admission",
            beginAdmission > permissionDeniedError,
        )
        assertFalse(
            "permission denial occurs before BoxService has an epoch-owned admission, so it must not abort shared state",
            methodAdmission.contains("BoxService.abortVpnStartAdmission("),
        )

        val service = sourceFile("BoxService.kt")
        val admission = functionBody(service, "beginVpnStartAdmission")
        val dispatch = admission.indexOf("val dispatched = ServiceLifecycleOwnership.runIfUserSessionEpochCurrent(sessionEpoch)")
        val dispatchFailure = admission.indexOf("if (!dispatched)", dispatch)
        val dispatchCompletion = admission.indexOf("completeVpnStartAdmissionFailure(", dispatchFailure)
        assertTrue(
            "a dispatch superseded by Stop must fail only its exact epoch-owned admission",
            dispatch >= 0 && dispatchFailure > dispatch && dispatchCompletion > dispatchFailure,
        )

        val timeout = admission.indexOf("if (outcome == null)")
        val timeoutAbort = admission.indexOf("abortVpnStartAdmission(sessionEpoch, \"Android VPN admission timed out\")", timeout)
        val deferredFailure = admission.indexOf("outcome.exceptionOrNull()?.let { failure ->")
        val deferredAbort = admission.indexOf("abortVpnStartAdmission(\n                    sessionEpoch,", deferredFailure)
        assertTrue("a timed-out deferred admission must use the same terminal rollback", timeout >= 0 && timeoutAbort > timeout)
        assertTrue("every deferred admission failure must use the same terminal rollback", deferredFailure > timeout && deferredAbort > deferredFailure)

        val abort = functionBody(service, "abortVpnStartAdmission")
        val terminalClaim = abort.indexOf("NativeConnectRequestBridge.cancelPendingFlutterConnectIfUserSessionEpochCurrent(")
        val staleClaim = abort.indexOf("if (terminalClaim == null)", terminalClaim)
        val completeFailure = abort.indexOf("completeVpnStartAdmissionFailure(userSessionEpoch, reason)", staleClaim)
        val staleReturn = abort.indexOf("return", completeFailure)
        val persistTerminal = abort.indexOf("persistTerminalStopIntent(", staleReturn)
        val dispatchTerminal = abort.indexOf("dispatchTerminalStopIntent(terminalIntent)", persistTerminal)
        val staleIgnore = abort.indexOf("stale VPN admission abort ignored for epoch")
        assertTrue("rollback must claim the exact current epoch before it can mutate terminal state", terminalClaim >= 0 && staleClaim > terminalClaim)
        assertTrue(
            "a stale rollback must complete only its matching deferred and return before terminal persistence or dispatch",
            completeFailure > staleClaim && staleReturn > completeFailure && staleIgnore > completeFailure &&
                persistTerminal > staleReturn && dispatchTerminal > persistTerminal,
        )
    }

    @Test
    fun `terminal stop marker remains authoritative before automatic admission may coalesce`() {
        val box = sourceFile("BoxService.kt")
        val admission = functionBody(box, "beginVpnStartAdmission")

        val automaticMarkerCheck = admission.indexOf("if (resumeSession && !Settings.startedByUser)")
        val processAdmission = admission.indexOf("val currentAdmissionReady = current?.hasProcessNetworkAdmission()")
        val coalescing = admission.indexOf("synchronized(vpnStartAdmissionLock)")
        val explicitStart = admission.indexOf("if (!resumeSession)")
        assertTrue(
            "automatic resume must consult marker-aware native intent, while manual exact lease validation happens before any process-admission join or shared coalescing",
            automaticMarkerCheck >= 0 && explicitStart > automaticMarkerCheck && processAdmission > explicitStart && coalescing > processAdmission,
        )

        val automaticPath = admission.substring(automaticMarkerCheck, explicitStart)
        assertFalse(
            "automatic resume must never manufacture user intent or clear a durable terminal-stop marker",
            automaticPath.contains("Settings.startedByUser = true") ||
                automaticPath.contains("clearTerminalStopMarker"),
        )

        val explicitPath = admission.substring(explicitStart)
        val createExplicitIntent = explicitPath.indexOf("Settings.startedByUser = true")
        val markerAwareRecheck = explicitPath.indexOf("check(Settings.startedByUser)", createExplicitIntent)
        val rejectedStart = explicitPath.indexOf("explicit VPN start could not replace durable terminal stop", markerAwareRecheck)
        val serviceIntent = explicitPath.indexOf("val intent = Intent(", rejectedStart)
        assertTrue(
            "only an explicit command may attempt to replace the stop marker, and it must recheck the marker-aware value before constructing any Android service start",
            createExplicitIntent >= 0 && markerAwareRecheck > createExplicitIntent && rejectedStart > markerAwareRecheck &&
                serviceIntent > rejectedStart,
        )

        val nativeHandoffRequired = admission.indexOf("require(!nativeHandoffClaim || explicitStartLease != null)")
        val nativeHandoffCompletion = admission.indexOf("nativeHandoffClaim &&", nativeHandoffRequired)
        val nativeHandoffExactAck = admission.indexOf(
            "NativeConnectRequestBridge.completeFlutterConnectClaim(checkNotNull(explicitStartLease))",
            nativeHandoffCompletion,
        )
        assertTrue(
            "a normal Flutter lease must not be consumed as a native handoff; only the marked handoff branch may complete its exact bridge claim",
            nativeHandoffRequired >= 0 && nativeHandoffCompletion > nativeHandoffRequired && nativeHandoffExactAck > nativeHandoffCompletion,
        )

        val settings = mainSourceFile("Settings.kt")
        val startedByUser = sourceSection(settings, "var startedByUser: Boolean", "\n\n    var strictVpnRouteVerified")
        assertTrue(
            "the native startedByUser getter must treat the durable terminal-stop marker as authoritative over any stale preference snapshot",
            startedByUser.contains("!hasTerminalStopMarkerLocked()") &&
                startedByUser.contains("preferences.getBoolean(SettingsKey.STARTED_BY_USER, false)"),
        )
        assertTrue(
            "an explicit marker-clear failure must reset intent and preserve fail-closed startup state",
            startedByUser.contains("if (value && !clearTerminalStopMarkerLocked())") &&
                startedByUser.contains("putBoolean(SettingsKey.STARTED_BY_USER, false)") &&
                startedByUser.contains("putBoolean(SettingsKey.STRICT_VPN_ROUTE_VERIFIED, false)"),
        )
        assertTrue(
            "an accepted start must synchronously commit its durable user intent and restore the terminal marker on commit failure",
            startedByUser.contains("if (!editor.commit())") &&
                startedByUser.contains("persistTerminalStopMarkerLocked()") &&
                startedByUser.contains("failed to durably persist accepted VPN start") &&
                startedByUser.contains("putBoolean(SettingsKey.START_CORE_ON_STARTING_SERVICE, false)"),
        )

        val methodHandler = mainSourceFile("MethodHandler.kt")
        val claimLease = sourceSection(methodHandler, "Trigger.ClaimVpnStartLease.method -> {", "Trigger.CancelVpnStartLease.method -> {")
        val cancelLease = sourceSection(methodHandler, "Trigger.CancelVpnStartLease.method -> {", "Trigger.BeginVpnStartAdmission.method -> {")
        assertTrue(
            "Flutter's ordinary UI lease must be claimed synchronously so a later Stop has one exact token to invalidate",
            claimLease.contains("result.success(ServiceLifecycleOwnership.issueExplicitStartLease())") &&
                !claimLease.contains("scope.launch"),
        )
        assertTrue(
            "an unused ordinary UI lease must have an exact cancel path without clearing a native bridge request",
            cancelLease.contains("ServiceLifecycleOwnership.releaseExplicitStartLease(token)") &&
                cancelLease.contains("result.success(token != null)"),
        )
        val flutterAdmission = sourceSection(
            methodHandler,
            "Trigger.BeginVpnStartAdmission.method -> {",
            "Trigger.ICMPPing.method -> {",
        )
        assertTrue(
            "Flutter may request only resume mode and an exact native-start lease; marker-aware Settings remains the admission authority",
            flutterAdmission.contains(".get(\"resumeSession\")") &&
                flutterAdmission.contains(".get(\"explicitStartLease\")") &&
                flutterAdmission.contains(".get(\"nativeHandoffClaim\")") &&
                flutterAdmission.contains("BoxService.beginVpnStartAdmission(") &&
                flutterAdmission.contains("explicitStartLease = explicitStartLease") &&
                flutterAdmission.contains("nativeHandoffClaim = nativeHandoffClaim"),
        )
        assertFalse(
            "a stale Flutter bootstrap started flag must never be accepted as resume authority",
            flutterAdmission.contains("get(\"startedByUser\")") || flutterAdmission.contains("get(\"started\")"),
        )
    }

    @Test
    fun `exact user-session epoch gates every explicit Android service dispatch`() {
        val box = sourceFile("BoxService.kt")
        val admission = functionBody(box, "beginVpnStartAdmission")
        val command = sourceSection(box, "internal fun onStartCommand", "\n    private suspend fun startStoredCoreFromNativeEntryPoint")
        val nativeStart = functionBody(box, "startStoredCoreFromNativeEntryPoint")
        val pipeline = functionBody(box, "runServiceStartPipeline")

        val exactLeaseRequired = admission.indexOf("require(resumeSession || explicitStartLease != null)")
        val explicitEpoch = admission.indexOf("val sessionEpoch = if (!resumeSession)")
        val lifecycleAdmission = admission.indexOf("ServiceLifecycleOwnership.admitExplicitUserSession(", explicitEpoch)
        val prepareAction = admission.indexOf("Action.SERVICE_PREPARE_VPN", lifecycleAdmission)
        val prepareEpoch = admission.indexOf("Action.EXTRA_USER_SESSION_EPOCH, sessionEpoch", prepareAction)
        val completedEpochCheck = admission.indexOf("ServiceLifecycleOwnership.isUserSessionEpochCurrent(sessionEpoch)", prepareEpoch)
        val returnEpoch = admission.lastIndexOf("return sessionEpoch")
        assertTrue(
            "manual Flutter admission must require an exact lease and return the exact lifecycle epoch after its final ownership check",
            exactLeaseRequired >= 0 && explicitEpoch > exactLeaseRequired && lifecycleAdmission > explicitEpoch &&
                prepareAction > lifecycleAdmission && prepareEpoch > prepareAction &&
                completedEpochCheck > prepareEpoch && returnEpoch > completedEpochCheck,
        )

        val epochRequired = command.indexOf("val userSessionEpochRequired =")
        val suppliedEpoch = command.indexOf("val suppliedUserSessionEpoch =", epochRequired)
        val staleReject = command.indexOf("!ServiceLifecycleOwnership.isUserSessionEpochCurrent(suppliedUserSessionEpoch)", suppliedEpoch)
        val rejectReturn = command.indexOf("return Service.START_NOT_STICKY", staleReject)
        val prepare = command.indexOf("return prepareVpnStartAdmission(checkNotNull(suppliedUserSessionEpoch))", rejectReturn)
        val connect = command.indexOf("val connectFromNotification", prepare)
        assertTrue(
            "SERVICE_PREPARE_VPN, SERVICE_CONNECT, and UI-initiated commands must reject a missing or stale epoch before any service side effect",
            epochRequired >= 0 && suppliedEpoch > epochRequired && staleReject > suppliedEpoch &&
                rejectReturn > staleReject && prepare > rejectReturn && connect > prepare,
        )
        assertTrue(
            "the command handler must not re-create user intent after Stop; only exact admission owns Settings.startedByUser=true",
            !command.contains("Settings.startedByUser = true"),
        )
        assertTrue(
            "a stale native pipeline generation must return before core-start side effects and cannot resurrect the Stop tombstone",
            nativeStart.indexOf("if (!shouldContinueStart(generation))") >= 0 &&
                !nativeStart.contains("Settings.startedByUser = true") &&
                !pipeline.contains("Settings.startedByUser = true"),
        )

        val methodHandler = mainSourceFile("MethodHandler.kt")
        val start = sourceSection(methodHandler, "Trigger.Start.method -> {", "Trigger.Stop.method -> {")
        val channelEpoch = start.indexOf("val userSessionEpoch = (args[\"userSessionEpoch\"] as? Number)?.toLong()")
        val channelCheck = start.indexOf("ServiceLifecycleOwnership.isUserSessionEpochCurrent(userSessionEpoch)", channelEpoch)
        val durableIntentCheck = start.indexOf("!Settings.startedByUser", channelCheck)
        val terminalSupersession = start.indexOf("discarding Android background start superseded by terminal Stop", durableIntentCheck)
        val quietResult = start.indexOf("success(false)", terminalSupersession)
        val quietReturn = start.indexOf("return@respondCatching", quietResult)
        val normalStart = start.indexOf("mainActivity.startService(", quietReturn)
        val activityDispatch = start.indexOf("userSessionEpoch = userSessionEpoch", normalStart)
        assertTrue(
            "the final MethodChannel start must quietly reject a terminal-superseded exact epoch or durable intent before normal service dispatch",
            channelEpoch >= 0 && channelCheck > channelEpoch && durableIntentCheck > channelCheck &&
                terminalSupersession > durableIntentCheck && quietResult > terminalSupersession &&
                quietReturn > quietResult && normalStart > quietReturn && activityDispatch > normalStart,
        )
        val supersededStart = start.substring(terminalSupersession, normalStart)
        assertFalse(
            "a terminal-superseded MethodChannel Start is an expected lifecycle result, not a check/error/throw failure",
            supersededStart.contains("check(") || supersededStart.contains("error(") || supersededStart.contains("throw "),
        )

        val mainActivity = mainSourceFile("MainActivity.kt")
        val activityStart = functionBody(mainActivity, "startService")
        val activityStart0 = functionBody(mainActivity, "startService0")
        val vpnCallback = sourceSection(mainActivity, "private val prepareLauncher", "\n\n    private fun clearPendingStartConfigIdentity")
        val clearPending = functionBody(mainActivity, "clearPendingStartConfigIdentity")
        val storedEpoch = activityStart.indexOf("pendingStartSessionEpoch = userSessionEpoch")
        val requestedEpoch = activityStart0.indexOf("val requestedSessionEpoch = pendingStartSessionEpoch")
        val missingEpoch = activityStart0.indexOf("if (requestedSessionEpoch == null)", requestedEpoch)
        val intentEpoch = activityStart0.indexOf(".putExtra(Action.EXTRA_USER_SESSION_EPOCH, requestedSessionEpoch)", missingEpoch)
        val finalLock = activityStart0.indexOf("ServiceLifecycleOwnership.runIfUserSessionEpochCurrent(requestedSessionEpoch)", intentEpoch)
        val durableIntent = activityStart0.indexOf("if (!Settings.startedByUser)", finalLock)
        val durableDropLog = activityStart0.indexOf(
            "discarding Android service dispatch after durable user intent stopped",
            durableIntent,
        )
        val durableDrop = activityStart0.indexOf("return@runIfUserSessionEpochCurrent", durableDropLog)
        val serviceDispatch = activityStart0.indexOf("ContextCompat.startForegroundService", durableDrop)
        val staleDrop = activityStart0.indexOf("if (!epochWasCurrent || !serviceDispatched)", serviceDispatch)
        val staleDropLog = activityStart0.indexOf(
            "discarding Android service dispatch superseded by terminal Stop",
            staleDrop,
        )
        assertTrue(
            "MainActivity must retain the admitted epoch across the VPN-permission callback",
            storedEpoch >= 0 && requestedEpoch >= 0 && vpnCallback.contains("startService0()") &&
                clearPending.contains("pendingStartSessionEpoch = null"),
        )
        assertTrue(
            "MainActivity must validate exact epoch and durable intent under the lifecycle lock before final service dispatch, then quietly discard terminal Stop supersession",
            missingEpoch > requestedEpoch && intentEpoch > missingEpoch && finalLock > intentEpoch &&
                durableIntent > finalLock && durableDropLog > durableIntent && durableDrop > durableDropLog &&
                serviceDispatch > durableDrop && staleDrop > serviceDispatch && staleDropLog > staleDrop,
        )
        assertFalse(
            "terminal Stop supersession is an expected fail-closed race, not an uncaught assertion or exception",
            activityStart0.contains("check(Settings.startedByUser)") ||
                activityStart0.contains("error(") || activityStart0.contains("throw "),
        )
        assertFalse(
            "the VPN-permission callback and final dispatch must not write Settings.startedByUser=true again after admission",
            activityStart.contains("Settings.startedByUser = true") || activityStart0.contains("Settings.startedByUser = true") ||
                vpnCallback.contains("Settings.startedByUser = true"),
        )
    }

    @Test
    fun `strict VPN admission orders permission prepare blocker publication and prepared-service continuation`() {
        val methodHandler = File("src/main/kotlin/app/marten/client/MethodHandler.kt").readText()
        val methodAdmission = sourceSection(
            methodHandler,
            "Trigger.BeginVpnStartAdmission.method -> {",
            "Trigger.ICMPPing.method -> {",
        )
        val permission = methodAdmission.indexOf("awaitStrictVpnPermission(allowPrompt = !resumeSession)")
        val nativeAdmission = methodAdmission.indexOf("BoxService.beginVpnStartAdmission(")
        assertTrue("Android permission must precede native VPN admission", permission >= 0 && nativeAdmission > permission)

        val box = sourceFile("BoxService.kt")
        val admission = functionBody(box, "beginVpnStartAdmission")
        val manualBranch = admission.indexOf("if (!resumeSession)")
        val userIntent = admission.indexOf("Settings.startedByUser = true")
        val recoverAction = admission.indexOf("Action.SERVICE_RECOVER")
        val prepareAction = admission.indexOf("Action.SERVICE_PREPARE_VPN")
        val foregroundStart = admission.indexOf("ContextCompat.startForegroundService", prepareAction)
        val automaticBranch = admission.lastIndexOf("} else {", recoverAction)
        assertTrue("manual admission must create user intent in its explicit-start branch", manualBranch >= 0 && userIntent > manualBranch)
        assertTrue("cold resumption must use SERVICE_RECOVER only in its automatic branch", recoverAction > automaticBranch && automaticBranch > manualBranch)
        assertTrue("manual admission must use SERVICE_PREPARE_VPN in its explicit-start branch", prepareAction > userIntent)
        assertTrue("the selected admission action must be sent to Android foreground service", foregroundStart > prepareAction)

        val prepare = functionBody(box, "prepareVpnStartAdmission")
        val prepareBlocker = prepare.indexOf("ensurePhysicalFailClosedVpn(\"early VPN start admission\")")
        val prepareNetworkAdmission = prepare.indexOf("NativeCrashDiagnostics.setNetworkAdmissionAllowed(true)", prepareBlocker)
        val prepareEarlyReady = prepare.indexOf("earlyVpnStartAdmissionReady = true", prepareNetworkAdmission)
        val prepareSuccess = prepare.indexOf("completeVpnStartAdmissionSuccess(userSessionEpoch)", prepareEarlyReady)
        assertTrue(
            "prepare admission must establish the fail-closed blocker before signaling process network admission",
            prepareBlocker >= 0 && prepareNetworkAdmission > prepareBlocker,
        )
        assertTrue(
            "prepare admission completes only after blocker and network admission are ready",
            prepareEarlyReady > prepareNetworkAdmission && prepareSuccess > prepareEarlyReady,
        )
        assertFalse(
            "prepare admission must not use strict-system lockdown as a gate",
            prepare.contains("strictKillSwitchAdmissionError()") || prepare.contains("isAlwaysOn") ||
                prepare.contains("isLockdownEnabled"),
        )

        val startService = functionBody(box, "startService")
        val startBlocker = startService.indexOf(
            "ensurePhysicalFailClosedVpn(\n                    \"service start admission\",",
        )
        val startNetworkAdmission = startService.indexOf("NativeCrashDiagnostics.setNetworkAdmissionAllowed(true)", startBlocker)
        val startSuccess = startService.indexOf("completeVpnStartAdmissionSuccess(userSessionEpoch)", startNetworkAdmission)
        val predecessorCleanup = startService.indexOf("ServiceLifecycleOwnership.awaitPendingCleanup(")
        val coreCloseWait = startService.indexOf("MobileCoreCloser.waitForCloseToFinish(")
        val networkMonitor = startService.indexOf("DefaultNetworkMonitor.start(")
        val setup = startService.indexOf("Mobile.setup(")
        assertTrue(
            "service start must install its fail-closed blocker before admitting process networking",
            startBlocker >= 0 && startNetworkAdmission > startBlocker,
        )
        assertTrue(
            "the packet sink must precede cleanup waits, network monitoring, and every native setup path that could use ordinary networking",
            predecessorCleanup > startBlocker && coreCloseWait > startBlocker && networkMonitor > startBlocker &&
                setup > startSuccess,
        )
        assertFalse(
            "service start must not use strict-system lockdown as a gate",
            startService.contains("strictKillSwitchAdmissionError()") ||
                startService.contains("isAlwaysOn") || startService.contains("isLockdownEnabled"),
        )

        val vpn = sourceFile("VPNService.kt")
        val failClosed = functionBody(vpn, "ensureFailClosedVpn")
        val establish = failClosed.indexOf(".establish()")
        val descriptorInstall = failClosed.indexOf("service.installFailClosedTunFileDescriptor(", establish)
        val publishUnderlying = failClosed.indexOf("publishUnderlyingNetwork(", descriptorInstall)
        assertTrue(
            "full-route blocker establishment, descriptor installation, and underlying-network publication must complete before BoxService admits diagnostics",
            establish >= 0 && descriptorInstall > establish && publishUnderlying > descriptorInstall,
        )
        assertFalse("VPNService must not independently open native diagnostics", failClosed.contains("NativeCrashDiagnostics.setNetworkAdmissionAllowed"))

        val openTun = functionBody(vpn, "openTun")
        val terminalRetirement = functionBody(vpn, "retirePlatformVpnSession")
        val terminalStop = functionBody(box, "stopService")
        listOf(failClosed, openTun, terminalRetirement, terminalStop).forEach { guardedPath ->
            listOf(
                "bindProcessToNetwork",
                "boundNetworkForProcess",
                "bindProcessToOwnedVpnNetwork",
                "processVpnBindingReleased",
            ).forEach { forbidden ->
                assertFalse(
                    "VPN startup, data TUN replacement, and terminal cleanup must not use stale process-wide binding helper `$forbidden`",
                    guardedPath.contains(forbidden),
                )
            }
        }

        val command = sourceSection(box, "internal fun onStartCommand", "\n    fun onDestroy")
        val prepared = command.indexOf("earlyVpnStartAdmissionReady && explicitUserStartRequested")
        val identity = command.indexOf("runtimeConfigOwnership.admit(", prepared)
        val continuationLaunch = command.indexOf("launchServiceStart(", identity)
        assertTrue("prepared continuation must accept the config identity before scheduling its serialized service pipeline", prepared >= 0 && identity > prepared && continuationLaunch > identity)
        assertFalse(
            "prepared continuation must not tear down the admitted packet sink before core setup",
            command.substring(identity, continuationLaunch).contains("closeTunFileDescriptor()"),
        )
    }

    @Test
    fun `notification visibility never gates manual Quick Settings or recovery VPN admission`() {
        val methodHandler = mainSourceFile("MethodHandler.kt")
        val methodAdmission = sourceSection(
            methodHandler,
            "Trigger.BeginVpnStartAdmission.method -> {",
            "Trigger.ICMPPing.method -> {",
        )
        val vpnHost = methodAdmission.indexOf("VpnPermissionActivity.awaitStrictVpnPermission(allowPrompt = !resumeSession)")
        val vpnFallback = methodAdmission.indexOf(
            "?: MainActivity.instance.awaitStrictVpnPermission(allowPrompt = !resumeSession)",
            vpnHost,
        )
        val nativeAdmission = methodAdmission.indexOf("BoxService.beginVpnStartAdmission(")
        assertTrue(
            "strict VPN consent must remain the only Android runtime permission before native fail-closed admission",
            vpnHost >= 0 && vpnFallback > vpnHost && nativeAdmission > vpnFallback &&
                !methodAdmission.contains("val activity = MainActivity.instance"),
        )

        val activity = mainSourceFile("MainActivity.kt")
        val activityStart = functionBody(activity, "startService")
        val storedEpoch = activityStart.indexOf("pendingStartSessionEpoch = userSessionEpoch")
        val dispatch = activityStart.indexOf("startService0()", storedEpoch)
        assertTrue(
            "manual Flutter Connect must dispatch its admitted epoch directly to VPN admission without a notification-permission branch",
            storedEpoch >= 0 && dispatch > storedEpoch,
        )

        val permissionActivity = mainSourceFile("VpnPermissionActivity.kt")
        val box = sourceFile("BoxService.kt")
        val vpn = sourceFile("VPNService.kt")
        listOf(methodAdmission, activity, permissionActivity, box, vpn).forEach { admissionPath ->
            listOf(
                "awaitStrictNotificationPermission",
                "notificationPermissionLauncher",
                "pendingStrictNotificationPermission",
                "Manifest.permission.POST_NOTIFICATIONS",
                "Alert.RequestNotificationPermission",
            ).forEach { notificationAdmissionArtifact ->
                assertFalse(
                    "notification state must not gate a VPN admission entry path through $notificationAdmissionArtifact",
                    admissionPath.contains(notificationAdmissionArtifact),
                )
            }
        }

        val notification = sourceFile("ServiceNotification.kt")
        val show = functionBody(notification, "show")
        val showStopped = functionBody(notification, "showStopped")
        val dynamicStart = functionBody(notification, "start")
        assertTrue(
            "the foreground-service notification must always be submitted when ServiceNotification.show runs",
            show.contains("service.startForeground(serviceNotificationId, runningBuilder(title, content).build())"),
        )
        assertFalse(
            "foreground-service presentation must not be conditional on notification visibility",
            show.contains("checkPermission()") || show.contains("areNotificationsEnabled()") || show.contains("return"),
        )
        assertTrue(
            "notification visibility may gate only optional stopped or dynamic notification updates",
            showStopped.contains("if (!checkPermission())") && dynamicStart.contains("val permissionGranted = checkPermission()"),
        )
    }

    @Test
    fun `fail-closed VPN establishes and publishes a full-route path before native diagnostics admission`() {
        val vpn = sourceFile("VPNService.kt")
        val failClosed = functionBody(vpn, "ensureFailClosedVpn")

        val retainedFastPath = failClosed.indexOf("if (service.isFailClosedTunBarrierActive())")
        val retainedReturn = failClosed.indexOf("return true", retainedFastPath)
        val prepare = failClosed.indexOf("if (VpnService.prepare(this) != null)")
        val establishAfterPrepare = failClosed.substring(prepare).indexOf(".establish()")
        val establish = if (establishAfterPrepare >= 0) prepare + establishAfterPrepare else -1
        val renewedConsentLog = failClosed.indexOf("fail-closed VPN admission requires renewed user consent", prepare)
        val consentFailure = failClosed.indexOf("return false", renewedConsentLog)
        assertTrue(
            "the verified retained blocker fast path must return before consent preflight without opening native diagnostics itself",
            retainedFastPath >= 0 && retainedReturn > retainedFastPath && prepare > retainedReturn &&
                !failClosed.contains("NativeCrashDiagnostics.setNetworkAdmissionAllowed"),
        )
        assertTrue(
            "a new blocking TUN must refresh VpnService consent before its first Builder.establish",
            prepare > retainedReturn && establish > prepare,
        )
        assertTrue(
            "missing renewed consent must log and return false before any Builder.establish attempt",
            renewedConsentLog > prepare && consentFailure > renewedConsentLog && establish > consentFailure,
        )
        val physicalSnapshot = failClosed.indexOf("val initialUnderlyingNetwork = DefaultNetworkMonitor.networkForSocket()")
        val builderCall = failClosed.indexOf("newFailClosedVpnBuilder(", physicalSnapshot)
        val underlyingDeclaration = failClosed.indexOf("setUnderlyingNetworks(arrayOf(initialUnderlyingNetwork))", builderCall)
        val establishAfterSnapshot = failClosed.indexOf(".establish()", builderCall)
        assertTrue(
            "cold fail-closed startup must resolve the current physical Network before its sole Builder establishment",
            physicalSnapshot >= 0 && builderCall > physicalSnapshot && underlyingDeclaration > builderCall &&
                establishAfterSnapshot > underlyingDeclaration &&
                Regex("newFailClosedVpnBuilder\\(").findAll(failClosed).count() == 1 &&
                failClosed.lines().count { it.trim() == ".establish()" } == 1 &&
                !failClosed.contains("DefaultNetworkMonitor.defaultNetwork"),
        )
        val descriptorInstall = failClosed.indexOf("service.installFailClosedTunFileDescriptor(", establish)
        val publishUnderlying = failClosed.indexOf("publishUnderlyingNetwork(", descriptorInstall)
        assertTrue("full-route Builder.establish must happen before install", establish >= 0 && descriptorInstall > establish)
        assertTrue("underlying network publication must occur after descriptor installation", publishUnderlying > descriptorInstall)
        assertFalse("VPNService must leave diagnostics admission to BoxService's exact barrier", failClosed.contains("NativeCrashDiagnostics.setNetworkAdmissionAllowed"))
        assertFalse(
            "fail-closed startup must not gate admit on strict-system lockdown",
            failClosed.contains("isAlwaysOn") || failClosed.contains("isLockdownEnabled") || failClosed.contains("strictKillSwitch"),
        )
        val failClosedBuilder = sourceSection(vpn, "private fun newFailClosedVpnBuilder", "override fun writePlatformLog")
        assertTrue(
            "fail-closed builder still keeps dual-stack full-route paths",
            failClosedBuilder.contains("addRoute(\"0.0.0.0\", 0)") && failClosedBuilder.contains("addRoute(\"::\", 0)") &&
                failClosedBuilder.contains("ipv4Address") && failClosedBuilder.contains("generation.markerAddress"),
        )
    }

    @Test
    fun `retained full-route blocker remains the replacement boundary until a new data TUN establishes`() {
        val box = sourceFile("BoxService.kt")
        val vpn = sourceFile("VPNService.kt")
        val openTun = sourceSection(vpn, "override fun openTun", "override fun writePlatformLog")
        val failClosed = functionBody(vpn, "ensureFailClosedVpn")
        val precondition = functionBody(box, "requireFailClosedTunInstallationPrecondition")

        val retainedReplacement = failClosed.indexOf("replacingRetainedDescriptor = service.hasRetainedVpnDescriptor()")
        val establish = failClosed.indexOf(".establish()", retainedReplacement)
        val install = failClosed.indexOf("service.installFailClosedTunFileDescriptor(", establish)
        assertTrue("a retained data-plane descriptor must be recognized before a fail-closed replacement establish", retainedReplacement >= 0 && establish > retainedReplacement)
        assertTrue("the replacement descriptor must be retained only after Builder.establish succeeds", install > establish)
        assertTrue("sealed recovery may replace only the descriptor retained by the current owner", precondition.contains("(retainedDescriptor || freshStrictStart)"))

        val dataEstablish = openTun.indexOf("val pfd = builder.establish()")
        val dataReplacement = openTun.indexOf("service.replaceTunFileDescriptor(pfd)", dataEstablish)
        assertTrue("the next data-plane TUN must replace the retained blocker only after successful establish", dataEstablish >= 0 && dataReplacement > dataEstablish)
    }

    @Test
    fun `runtime ownership recovery is callback driven and independent from strict-lockdown polling`() {
        val service = sourceFile("BoxService.kt")
        val ownershipLoop = functionBody(service, "startExternalVpnWatchdog")

        assertFalse("strict lockdown polling helpers must be removed", service.contains("checkStrictLockdownState("))
        assertFalse("strict lockdown recovery branch must be removed", service.contains("handleStrictLockdownLoss("))
        assertFalse("strict lockdown periodic constants must be removed", service.contains("STRICT_LOCKDOWN_WATCHDOG_POLL_MS"))
        assertFalse("strict lockdown watchdog launcher must be removed", service.contains("startStrictLockdownWatchdog"))
        assertTrue(
            "stable ownership supervision must wait for VPN network callbacks",
            ownershipLoop.contains("changes.receive()"),
        )
        assertFalse(
            "ownership supervision must not poll on an interactive or screen-off timer",
            ownershipLoop.contains("vpnOwnershipWatchdogPollDelayMs"),
        )
        assertTrue(
            "only suspected ownership loss may use the bounded confirmation delay",
            ownershipLoop.contains("delay(CORE_WATCHDOG_CONFIRM_MS)"),
        )
        assertFalse(
            "runtime recovery loop must not branch on lock-state flags",
            ownershipLoop.contains("isAlwaysOn") || ownershipLoop.contains("isLockdownEnabled"),
        )
        assertTrue(
            "runtime recovery should request core recovery only after repeated ownership misses",
            ownershipLoop.contains("shouldRecoverMissingOwnVpn(") && ownershipLoop.contains("requestCoreRecovery("),
        )
    }

    @Test
    fun `probe waits cancellably for Android to publish the active VPN before GET`() {
        val source = sourceFile("VpnDataPlaneProbe.kt")
        val run = functionBody(source, "run")
        val endpoint = functionBody(source, "runEndpoint")
        val wait = functionBody(source, "awaitActiveVpnNetwork")

        val awaitNetwork = run.indexOf("awaitActiveVpnNetwork(")
        val vpnSocket = endpoint.indexOf("val openedSocket = Socket()")
        val failClosed = run.indexOf("VpnDataPlaneProbeStage.VPN_NETWORK")
        assertTrue("GET must wait for the VPN Network published after core STARTED", awaitNetwork >= 0)
        assertTrue("GET must create an ordinary Socket() after VPN route is active", vpnSocket > awaitNetwork)
        assertFalse(
            "startup probe must stay on the app UID path, not explicit VPN socket factory",
            endpoint.contains("vpnNetwork.socketFactory.createSocket()"),
        )
        assertTrue("timeout must remain fail-closed after the bounded wait", failClosed > awaitNetwork)
        assertTrue(
            "startup proof should publish the active VPN network handle",
            endpoint.contains("vpnNetworkHandle = vpnNetwork.networkHandle"),
        )

        assertTrue(wait.contains("SystemClock.elapsedRealtime() + ACTIVE_VPN_WAIT_TIMEOUT_MS"))
        assertTrue(wait.contains("delay(ACTIVE_VPN_WAIT_POLL_MS)"))
        assertTrue("the wait must cooperate with cancellation", wait.contains("currentCoroutineContext().ensureActive()"))
        assertTrue("only a VPN Network can satisfy the wait", wait.contains("hasTransport(NetworkCapabilities.TRANSPORT_VPN)"))
        assertTrue("a bounded wait must not silently use Wi-Fi", wait.contains("return null"))
    }

    @Test
    fun `autoDetectInterfaceControl binds unconnected physical socket then protects fd and fails closed on any underlying failure`() {
        val source = sourceFile("VPNService.kt")
        val sourceWithoutLineComments = source
            .lines()
            .filter { !it.trimStart().startsWith("//") }
            .joinToString("\n")
        val autoDetect = functionBody(source, "autoDetectInterfaceControl")
        val protect = functionBody(source, "protectSocket")

        assertTrue(
            "autoDetectInterfaceControl should resolve an admitted physical Network or fail closed",
            autoDetect.contains("DefaultNetworkMonitor.networkForSocket()") &&
                autoDetect.contains("error(\"android: missing underlying network for socket\")"),
        )
        assertTrue(
            "autoDetectInterfaceControl should duplicate the borrowed fd before binding to the physical Network",
            autoDetect.contains("val descriptor = ParcelFileDescriptor.fromFd(fd)"),
        )
        assertTrue(
            "autoDetectInterfaceControl should bind the descriptor's fd before protection",
            autoDetect.contains("underlyingNetwork.bindSocket(descriptor.fileDescriptor)"),
        )
        assertTrue(
            "autoDetectInterfaceControl should protect the same fd after successful bind",
            autoDetect.contains("protectSocket(fd)"),
        )
        assertTrue(
            "autoDetectInterfaceControl should close only its duplicate after binding, including failures",
            autoDetect.contains("finally") && autoDetect.contains("descriptor.close()") &&
                autoDetect.indexOf("descriptor.close()") < autoDetect.indexOf("protectSocket(fd)"),
        )
        assertFalse(
            "autoDetectInterfaceControl must not adopt or close the borrowed core socket fd",
            autoDetect.contains("ParcelFileDescriptor.adoptFd(fd)"),
        )
        assertTrue(
            "protection failure must still be an explicit check",
            protect.contains("if (!protect(fd))"),
        )
        assertTrue(
            "protection failure should be explicit",
            protect.contains("error(\"android: failed to protect socket from VPN\")"),
        )
        assertTrue(
            "bind failure should be fail-closed and surfaced",
            autoDetect.contains("throw IllegalStateException(") &&
                autoDetect.contains("failed to bind socket to underlying network"),
        )
        assertTrue(
            "a rejected netd bind must invalidate and refresh the rejected physical network before surfacing failure",
            autoDetect.indexOf("DefaultNetworkMonitor.reportSocketBindFailure(underlyingNetwork)") >
                autoDetect.indexOf("underlyingNetwork.bindSocket(descriptor.fileDescriptor)") &&
                autoDetect.indexOf("DefaultNetworkMonitor.reportSocketBindFailure(underlyingNetwork)") <
                    autoDetect.indexOf("throw IllegalStateException("),
        )
        assertTrue(
            "bind must occur before protection to avoid socket rewrite races",
            autoDetect.indexOf("underlyingNetwork.bindSocket(descriptor.fileDescriptor)") <
                autoDetect.indexOf("protectSocket(fd)"),
        )
        assertFalse(
            "autoDetectInterfaceControl must not use legacy fail-open bindSocketToDefaultNetwork path",
            sourceWithoutLineComments.contains("bindSocketToDefaultNetwork"),
        )
    }

    @Test
    fun `openTun declares current default network and runtime network updates stay ownership-checked and deduped`() {
        val source = sourceFile("VPNService.kt")
        val openTun = functionBody(source, "openRemoteTun")
        val updateUnderlying = functionBody(source, "updateUnderlyingNetwork")
        val publishUnderlying = functionBody(source, "publishUnderlyingNetwork")

        val defaultNetworkCapture = openTun.indexOf("val initialUnderlyingNetwork = DefaultNetworkMonitor.defaultNetwork")
        val setInitial = openTun.indexOf("builder.setUnderlyingNetworks(arrayOf(initialUnderlyingNetwork))")
        val establish = openTun.indexOf("val pfd = builder.establish()")
        val publishAfterEstablish = openTun.indexOf("publishUnderlyingNetwork(")
        assertTrue(
            "openTun should read the current default network before building the VPN",
            defaultNetworkCapture >= 0 &&
                setInitial > defaultNetworkCapture &&
                establish > setInitial,
        )
        assertTrue(
            "openTun should reconcile initial declaration after establishing descriptor",
            publishAfterEstablish > establish,
        )

        assertTrue(
            "runtime update should forward callback network into publish helper",
            updateUnderlying.contains("publishUnderlyingNetwork(network, requireActiveVpn = true)"),
        )

        val dedupeGuard = publishUnderlying.indexOf("underlyingNetworkDeclarationInitialized &&")
        val dedupeEquals = publishUnderlying.indexOf("declaredUnderlyingNetwork == network")
        val ownershipCheck = publishUnderlying.indexOf("if (requireActiveVpn && !BoxService.isOwnVpnActive(this))")
        val acceptedCall = publishUnderlying.indexOf("runCatching {")
        val setUnderlying = publishUnderlying.indexOf("setUnderlyingNetworks(network?.let { arrayOf(it) } ?: emptyArray())")
        val markSet = publishUnderlying.indexOf("declaredUnderlyingNetwork = network")
        val freshPhysicalSnapshot = publishUnderlying.indexOf("val physicalSnapshot = DefaultNetworkMonitor.networkForSocket()")
        val lock = publishUnderlying.indexOf("synchronized(underlyingNetworkLock)")
        val monitorSnapshot = publishUnderlying.indexOf("val network = DefaultNetworkMonitor.defaultNetwork", lock)
        val physicalFallback = publishUnderlying.indexOf(
            "?: physicalSnapshot?.takeIf(DefaultNetworkListener::isUsable)",
            monitorSnapshot,
        )
        assertTrue("runtime update must check ownership before changing underlying network", ownershipCheck > dedupeEquals)
        assertTrue("runtime update should call setUnderlyingNetworks only after ownership check", setUnderlying > ownershipCheck)
        assertTrue(
            "accepted result should be required before state is advanced",
            acceptedCall < setUnderlying && markSet > setUnderlying,
        )
        assertTrue("runtime update should dedupe unchanged physical network callbacks", dedupeGuard >= 0 && dedupeEquals > dedupeGuard)
        assertTrue(
            "a fresh physical snapshot should be captured before locking, then reconciled with the newest usable monitor snapshot under lock",
            freshPhysicalSnapshot >= 0 && lock > freshPhysicalSnapshot && monitorSnapshot > lock &&
                physicalFallback > monitorSnapshot && setUnderlying > physicalFallback,
        )
        assertTrue(
            "runtime update must retain its exact active-VPN owner check inside the reconciliation lock",
            ownershipCheck > lock && ownershipCheck > physicalFallback,
        )
    }

    @Test
    fun `startup failure diagnostics persist only a fixed category before alert cleanup`() {
        val box = sourceFile("BoxService.kt")
        val start = functionBody(box, "startService")
        val startFailureBlocks = Regex("""catch \(e: Exception\) \{([\s\S]*?)stopAndAlert\(""")
            .findAll(start)
            .map { it.groupValues[1] }
            .toList()

        assertEquals("both setup and outer startup failures must use the privacy-safe diagnostic path", 2, startFailureBlocks.size)
        assertTrue(
            "startup failure records must contain only fixed outcome, phase, and category fields before user-facing error handling",
            startFailureBlocks.all { block ->
                block.contains("event = \"start_failure\"") &&
                    block.contains("outcome = \"failed\"") &&
                    block.contains("stage = startupStage") &&
                    block.contains("category = nativeStartFailureCategory(e)") &&
                    !block.contains("e.message") &&
                    !block.contains("e.toString()") &&
                    !block.contains("e.stackTrace")
            },
        )
    }

    @Test
    fun `socket-level probe path uses single protected Socket() connect without fallback bind or retry`() {
        val source = sourceFile("VpnDataPlaneProbe.kt")
        val endpoint = functionBody(source, "runEndpoint")
        val endpointWithoutLineComments = endpoint
            .lines()
            .filter { !it.trimStart().startsWith("//") }
            .joinToString("\n")

        val firstConnect = endpoint.indexOf("openedSocket.connect(")
        val secondConnect = if (firstConnect >= 0) endpoint.indexOf("openedSocket.connect(", firstConnect + 1) else -1
        assertTrue("probe should explicitly open a normal Socket before connect", endpoint.contains("Socket().apply {"))
        assertTrue("probe should include one and only one direct connect attempt", firstConnect >= 0 && secondConnect == -1)
        assertFalse(
            "per-socket path should never bind Socket() to default or tracked Network callbacks",
            endpointWithoutLineComments.contains("bindSocket("),
        )
        assertFalse(
            "per-socket path should not use ParcelFileDescriptor",
            endpointWithoutLineComments.contains("ParcelFileDescriptor"),
        )
        assertFalse(
            "per-socket path should not refresh default-network transport as part of probe connect",
            endpointWithoutLineComments.contains("defaultNetwork") && endpointWithoutLineComments.contains("refresh"),
        )
    }

    @Test
    fun `onUnderlyingNetworkObserved callback only forwards physical network updates into VPNService`() {
        val service = sourceFile("BoxService.kt")
        val monitorStart = service.indexOf("DefaultNetworkMonitor.start(serviceOwnerToken, ::onUnderlyingNetworkObserved)")
        val onObserved = functionBody(service, "onUnderlyingNetworkObserved")

        assertTrue(
            "BoxService must subscribe monitor through the onUnderlyingNetworkObserved callback",
            monitorStart >= 0,
        )
        assertTrue(
            "onUnderlyingNetworkObserved should be the monitor callback body",
            onObserved.contains("service.updateUnderlyingNetwork(network)") &&
                onObserved.contains("if (service is VPNService)")
        )
        assertFalse(
            "observed callback should not directly bypass VPNService ownership checks",
            onObserved.contains("setUnderlyingNetworks("),
        )
    }

    @Test
    fun `default network refresh is internal and keyed to the active monitor registration`() {
        val monitor = sourceFile("DefaultNetworkMonitor.kt")
        val listener = sourceFile("DefaultNetworkListener.kt")
        val monitorWithoutLineComments = monitor
            .lines()
            .filter { !it.trimStart().startsWith("//") }
            .joinToString("\n")
        val listenerWithoutLineComments = listener
            .lines()
            .filter { !it.trimStart().startsWith("//") }
            .joinToString("\n")

        assertFalse(
            "default network monitor should not provide refresh API",
            monitorWithoutLineComments.contains("fun refresh(") ||
                monitorWithoutLineComments.contains("suspend fun refresh("),
        )
        assertTrue("refresh message must carry an exact listener owner key", listenerWithoutLineComments.contains("class Refresh(val key: Any)"))
        assertTrue("refresh must stay inaccessible as a broad external action", listenerWithoutLineComments.contains("internal suspend fun refresh(key: Any): Boolean"))
        val refreshStart = listenerWithoutLineComments.indexOf("is NetworkMessage.Refresh ->")
        val refreshEnd = listenerWithoutLineComments.indexOf("is NetworkMessage.Put ->", refreshStart)
        assertTrue("refresh actor branch is required", refreshStart >= 0 && refreshEnd > refreshStart)
        val refresh = listenerWithoutLineComments.substring(refreshStart, refreshEnd)
        assertTrue("refresh must accept only the active owner key", refresh.contains("listeners.containsKey(message.key)"))
        assertTrue("refresh must clear the actor cache", refresh.contains("network = null"))
        val unregister = refresh.indexOf("unregister()")
        val register = refresh.indexOf("register()")
        assertTrue("refresh must unregister stale OEM callback before re-registering", unregister >= 0 && register > unregister)
    }

    @Test
    fun `Application onCreate sets Seq context before registering LocalResolver and does it before receiver bootstrap`() {
        val source = mainSourceFile("Application.kt")
        val onCreate = functionBody(source, "onCreate")
        val seqContext = onCreate.indexOf("Seq.setContext(this)")
        val registerTransport = onCreate.indexOf("Libbox.registerLocalDNSTransport(LocalResolver)")
        val registerReceiver = onCreate.indexOf("registerReceiver(AppChangeReceiver()")
        assertTrue("Application must initialize native sequence context first", seqContext >= 0)
        assertTrue("LocalResolver must be registered as local DNS transport", registerTransport >= 0)
        assertTrue("Seq.setContext must run before LocalResolver registration", seqContext < registerTransport)
        assertTrue("LocalResolver must be registered before registerReceiver bootstrap", registerTransport < registerReceiver)
    }

    @Test
    fun `LocalResolver native requests own cancellation before waiting for the physical Network`() {
        val source = sourceFile("LocalResolver.kt")
        val legacyDnsWorker = sourceFile("LegacyDnsWorker.kt")
        val exchange = functionBody(source, "exchange")
        val lookup = functionBody(source, "lookup")

        for ((name, body) in listOf("exchange" to exchange, "lookup" to lookup)) {
            val request = body.indexOf("runNativeDnsRequest(")
            val nativeCancellation = body.indexOf("ctx.onCancel { cancel() }", request)
            val physicalNetworkAssignment = body.indexOf("val physicalNetwork = try {", request)
            val requirePhysicalNetwork = body.indexOf("DefaultNetworkMonitor.require()", physicalNetworkAssignment)
            val resolverWait = body.indexOf("awaitNativeDnsAnswer", requirePhysicalNetwork)
            assertTrue(
                "$name() must register Go cancellation before waiting for the physical Network and Android DNS callback",
                request >= 0 && nativeCancellation > request && physicalNetworkAssignment > nativeCancellation &&
                    requirePhysicalNetwork > physicalNetworkAssignment && resolverWait > requirePhysicalNetwork,
            )
            val cancellationRethrow = body.indexOf("catch (error: CancellationException)", requirePhysicalNetwork)
            val unavailableMapping = body.indexOf("OsConstants.ENETUNREACH", cancellationRethrow)
            assertTrue(
                "$name() must preserve cancellation and map ordinary physical-network lookup failures to ENETUNREACH",
                cancellationRethrow > requirePhysicalNetwork && body.indexOf("throw error", cancellationRethrow) > cancellationRethrow &&
                    unavailableMapping > cancellationRethrow,
            )
        }

        val exchangePhysicalNetwork = exchange.indexOf("val physicalNetwork = try {")
        val rawQuery = exchange.indexOf("DnsResolver.getInstance().rawQuery", exchangePhysicalNetwork)
        assertTrue(
            "rawQuery must receive the actual physical Network returned by DefaultNetworkMonitor.require",
            exchangePhysicalNetwork >= 0 && rawQuery > exchangePhysicalNetwork &&
                exchange.substring(exchangePhysicalNetwork, rawQuery).contains("DefaultNetworkMonitor.require()") &&
                exchange.substring(rawQuery).contains("physicalNetwork,"),
        )
        val lookupPhysicalNetwork = lookup.indexOf("val physicalNetwork = try {")
        val firstQuery = lookup.indexOf("DnsResolver.getInstance().query(", lookupPhysicalNetwork)
        assertTrue(
            "lookup queries must use the actual physical Network returned by DefaultNetworkMonitor.require",
            lookupPhysicalNetwork >= 0 && firstQuery > lookupPhysicalNetwork &&
                lookup.substring(lookupPhysicalNetwork, firstQuery).contains("DefaultNetworkMonitor.require()") &&
                lookup.substring(firstQuery).contains("physicalNetwork,") &&
                lookup.substring(firstQuery).contains("physicalNetwork, domain"),
        )

        val exchangeCallbackStart = exchange.indexOf("object : DnsResolver.Callback<ByteArray>")
        val exchangeCallbackEnd = exchange.indexOf("\n                    )", exchangeCallbackStart)
        val lookupCallbackStart = lookup.indexOf("object : DnsResolver.Callback<Collection<InetAddress>>")
        val lookupCallbackEnd = lookup.indexOf("\n                        }", lookupCallbackStart)
        assertTrue("rawQuery must complete through the cancellable callback bridge", exchangeCallbackStart >= 0 && exchangeCallbackEnd > exchangeCallbackStart)
        assertTrue("lookup must complete through the cancellable callback bridge", lookupCallbackStart >= 0 && lookupCallbackEnd > lookupCallbackStart)
        assertFalse("rawQuery callback must not mutate native exchange state directly", exchange.substring(exchangeCallbackStart, exchangeCallbackEnd).contains("ctx."))
        assertFalse("lookup callback must not mutate native exchange state directly", lookup.substring(lookupCallbackStart, lookupCallbackEnd).contains("ctx."))
        assertFalse("native DNS callbacks must not use uncancellable suspendCoroutine", source.contains("suspendCoroutine"))

        assertTrue(
            "legacy Android DNS must use a bounded worker and return through the cancellable native answer bridge",
            lookup.contains("LegacyDnsWorker.lookup { physicalNetwork.getAllByName(domain).asList() }") &&
                legacyDnsWorker.contains("ThreadPoolExecutor(0, 2") &&
                legacyDnsWorker.contains("SynchronousQueue()") &&
                legacyDnsWorker.contains("awaitNativeDnsAnswer({") &&
                legacyDnsWorker.contains("task.get()?.cancel(true)"),
        )

        assertTrue(
            "lookup path must preserve Android normal DNS cache policy",
            lookup.contains("DnsResolver.FLAG_EMPTY"),
        )
        assertTrue(
            "exchange path must preserve Android normal DNS cache policy",
            exchange.contains("DnsResolver.FLAG_EMPTY"),
        )
        assertFalse(
            "DNS policy must not force no-retry behavior",
            source.contains("FLAG_NO_RETRY"),
        )
    }

    @Test
    fun `full startup proof resolves bootstrap then authenticates a numeric VPN HTTPS GET and VPN DNS`() {
        val source = sourceFile("VpnDataPlaneProbe.kt")
        val run = functionBody(source, "run")
        val endpoint = functionBody(source, "runEndpoint")
        val vpnDns = functionBody(source, "verifyVpnDns")
        val resolveNetworkDnsAsync = functionBody(source, "resolveNetworkDnsAsync")

        val activeVpn = run.indexOf("awaitActiveVpnNetwork(")
        val underlyingNetwork = run.indexOf("val resolverNetwork = underlyingNetwork")
        val selectedEndpoint = run.indexOf("val endpoints = nextProbeEndpoints(")
        val underlyingDns = endpoint.indexOf("val underlyingDns = resolveNetworkDns(")
        val vpnSocket = endpoint.indexOf("val openedSocket = Socket().apply {")
        val numericConnect = endpoint.indexOf("connect(InetSocketAddress(probeAddress, PROBE_PORT), connectTimeoutMs)")
        val tlsSocket = endpoint.indexOf(".createSocket(openedSocket, probeEndpoint.host, PROBE_PORT, true) as SSLSocket")
        val hostnameVerification = endpoint.indexOf("endpointIdentificationAlgorithm = \"HTTPS\"")
        val explicitSni = endpoint.indexOf("serverNames = listOf(SNIHostName(probeEndpoint.host))")
        val handshake = endpoint.indexOf("tlsSocket.startHandshake()")
        val rawGet = endpoint.indexOf("append(\"GET \${probeEndpoint.path}?marten=\$nonce HTTP/1.1")
        val hostHeader = endpoint.indexOf("append(\"Host: \${probeEndpoint.host}")
        val responseCode = endpoint.indexOf("val statusCode = statusLine.split")
        val expectedStatus = endpoint.indexOf("if (statusCode != probeEndpoint.expectedStatusCode)")
        val vpnDnsCall = endpoint.indexOf("val dnsFailure = verifyVpnDns(vpnNetwork, probeEndpoint.host, dnsTimeoutMs)")
        val dnsFailureGate = endpoint.indexOf("if (dnsFailure != null)", vpnDnsCall)
        val responseHeaders = endpoint.indexOf("readResponseHeaders(BufferedInputStream(tlsSocket.getInputStream()))")
        val healthyResult = endpoint.indexOf("healthy = true")

        assertTrue("the probe must use the current active VPN Network", activeVpn >= 0)
        assertTrue("the pre-VPN default Network is required solely for DNS bootstrap", underlyingNetwork > activeVpn)
        assertTrue("each attempt must select an endpoint before its protected underlying DNS bootstrap", selectedEndpoint > underlyingNetwork && underlyingDns >= 0)
        assertTrue("underlying DNS must resolve the selected endpoint host", endpoint.substring(underlyingDns, vpnSocket).contains("probeEndpoint.host"))
        assertTrue("the numeric probe must use the ordinary Socket() path after bootstrap", vpnSocket > underlyingDns)
        assertTrue("the VPN socket must connect to the resolved numeric address", numericConnect > vpnSocket)
        assertTrue("TLS must wrap that same UID-routed numeric socket with the selected host for SNI", tlsSocket > numericConnect)
        assertTrue("TLS must enforce HTTPS hostname verification before proof traffic", hostnameVerification > tlsSocket)
        assertTrue("the upgraded socket must explicitly set SNI to the selected endpoint", explicitSni > hostnameVerification)
        assertTrue("the certificate handshake must complete after explicit SNI and before the GET", handshake > explicitSni)
        assertTrue("startup proof must write the HTTPS GET after TLS authentication", rawGet > handshake)
        assertTrue("the encrypted request must use the selected host in its Host header", hostHeader > rawGet)
        assertTrue("startup proof must read the HTTPS response over the TLS socket", responseHeaders > hostHeader)
        assertTrue("startup proof must inspect the GET response", responseCode > responseHeaders)
        assertTrue("only the selected endpoint's exact expected HTTP status may satisfy startup", expectedStatus > responseCode)
        assertTrue("a successful selected-endpoint GET must be followed by a VPN-bound DNS proof of that same host", vpnDnsCall > expectedStatus)
        assertTrue("DNS proof failure must return before a healthy result", dnsFailureGate > vpnDnsCall && healthyResult > dnsFailureGate)

        assertTrue("DNS proof must include a bounded timeout before resolving through VPN", vpnDns.contains("boundedTimeoutMs"))
        assertTrue(
            "DNS proof must bind to the same VPN Network and selected host as the HTTPS GET",
            vpnDns.contains("resolveNetworkDns(vpnNetwork, host,") && vpnDns.contains("bypassCache = true"),
        )
        assertTrue("DNS proof must delegate API 29+ to Android's no-cache resolver", resolveNetworkDnsAsync.contains("DnsResolver.getInstance().query("))
        assertTrue(
            "DNS proof must use the active VPN Network",
            vpnDns.contains("resolveNetworkDns(vpnNetwork, host,") && resolveNetworkDnsAsync.contains("network,\n                host,"),
        )
        assertTrue("DNS proof must query an A record through the TUN", resolveNetworkDnsAsync.contains("DnsResolver.TYPE_A"))
        assertTrue("DNS proof must bypass positive and negative cache state", resolveNetworkDnsAsync.contains("DnsResolver.FLAG_NO_CACHE_LOOKUP or DnsResolver.FLAG_NO_CACHE_STORE"))
        assertTrue("VPN DNS proof must have a bounded timeout", vpnDns.contains("VPN_DNS_TIMEOUT_MS") && resolveNetworkDnsAsync.contains("timeoutMs"))
        assertTrue("VPN DNS cancellation must cancel the Android resolver query", resolveNetworkDnsAsync.contains("cancellationSignal.cancel()"))

        assertFalse("bootstrap DNS must not be attempted through the unready VPN route", run.contains("vpnNetwork.getAllByName"))
        assertFalse("a URL connection would resolve its hostname through the VPN and reintroduce bootstrap deadlock", run.contains("openConnection"))
        assertFalse("the selected-route bootstrap must use a numeric socket, not URL DNS", run.contains("java.net.URL"))
        assertFalse("a single fixed probe host must not decide service admission", source.contains("PROBE_HOST"))
        assertFalse("a single fixed probe path must not decide service admission", source.contains("PROBE_PATH"))
        assertFalse("a single global expected status must bypass endpoint policy", source.contains("EXPECTED_STATUS_CODE"))
        assertTrue("the authenticated proof must use HTTPS port 443", source.contains("private const val PROBE_PORT = 443"))
        assertFalse("plaintext HTTP port 80 must not remain as a data-plane proof endpoint", source.contains("private const val PROBE_PORT = 80"))
        assertFalse("the GET must not be written to the unauthenticated TCP socket", run.contains("openedSocket.getOutputStream()"))
        assertFalse("the response must not be read from the unauthenticated TCP socket", run.contains("openedSocket.getInputStream()"))
        assertFalse("VALIDATED is not a substitute for the dedicated startup GET", source.contains("NET_CAPABILITY_VALIDATED"))
        assertFalse("initial startup must not have an Android validated fallback", source.contains("validatedFallback"))
        assertFalse("initial startup must not publish an android_validated proof", source.contains("android_validated"))

        val service = sourceFile("BoxService.kt")
        val recordProof = functionBody(service, "recordVpnDataPlaneProof")
        val currentProof = functionBody(service, "currentVpnDataPlaneProof")
        val currentHandleLookup = "val currentVpnNetworkHandle = vpnDataPlaneProbe.currentVpnNetworkHandle()"
        val recordProofLock = recordProof.indexOf("synchronized(vpnDataPlaneProofLock)")
        val currentProofLock = currentProof.indexOf("synchronized(vpnDataPlaneProofLock)")
        assertTrue(
            "Android proof must publish an active-network handle and replay-check it against captured current handles outside proof locks",
            endpoint.contains("vpnNetworkHandle = vpnNetwork.networkHandle") &&
                recordProof.indexOf(currentHandleLookup) >= 0 &&
                recordProofLock > recordProof.indexOf(currentHandleLookup) &&
                recordProof.indexOf("proofVpnNetworkHandle != currentVpnNetworkHandle", recordProofLock) > recordProofLock &&
                currentProof.indexOf(currentHandleLookup) >= 0 &&
                currentProofLock > currentProof.indexOf(currentHandleLookup) &&
                currentProof.indexOf("it.vpnNetworkHandle == currentVpnNetworkHandle", currentProofLock) > currentProofLock,
        )
    }

    @Test
    fun `data plane endpoints rotate independently while preserving authenticated HTTPS proof semantics`() {
        val source = sourceFile("VpnDataPlaneProbe.kt")
        val run = functionBody(source, "run")
        val endpoint = functionBody(source, "runEndpoint")
        val select = functionBody(source, "nextProbeEndpoints")
        val endpoints = sourceSection(source, "private val PROBE_ENDPOINTS = listOf(", "private const val PROBE_PORT")

        val configured = Regex("HttpsProbeEndpoint\\(\\\"([^\\\"]+)\\\",\\s*\\\"([^\\\"]+)\\\",\\s*(\\d+)\\)")
            .findAll(endpoints)
            .map { it.groupValues.drop(1) }
            .toList()
        assertTrue("at least three independent HTTPS endpoint hosts are required", configured.size >= 3)
        assertTrue("endpoint hosts must be distinct so a provider outage cannot pin every retry", configured.map { it[0] }.distinct().size >= 3)
        assertTrue("each endpoint must preserve the exact authenticated 204 contract", configured.all { it[1].isNotBlank() && it[2] == "204" })
        assertTrue("the endpoint cursor must be atomic across concurrent probe attempts", source.contains("private val endpointCursor = AtomicInteger(0)"))
        assertTrue(
            "endpoint selection must use floorMod over a monotonic atomic cursor rather than one provider fallback",
            select.contains("val start = endpointCursor.getAndIncrement()") &&
                select.contains("PROBE_ENDPOINTS[Math.floorMod(start + offset, PROBE_ENDPOINTS.size)]"),
        )

        val selection = run.indexOf("val endpoints = nextProbeEndpoints(")
        val underlyingDns = endpoint.indexOf("resolveNetworkDns(\n            resolverNetwork,\n            probeEndpoint.host,")
        val sni = endpoint.indexOf("createSocket(openedSocket, probeEndpoint.host, PROBE_PORT, true)", underlyingDns)
        val explicitSni = endpoint.indexOf("serverNames = listOf(SNIHostName(probeEndpoint.host))", sni)
        val requestPath = endpoint.indexOf("probeEndpoint.path", explicitSni)
        val hostHeader = endpoint.indexOf("probeEndpoint.host", requestPath)
        val status = endpoint.indexOf("probeEndpoint.expectedStatusCode", hostHeader)
        val vpnDns = endpoint.indexOf("verifyVpnDns(vpnNetwork, probeEndpoint.host", status)
        assertTrue(
            "one selected endpoint must drive underlying DNS, explicit SNI, Host header, exact 204 comparison, and fresh VPN DNS in order",
            selection >= 0 && underlyingDns >= 0 && sni > underlyingDns && explicitSni > sni && requestPath > explicitSni &&
                hostHeader > requestPath && status > hostHeader && vpnDns > status,
        )
        assertTrue("all rotated endpoints must still use HTTPS port 443", source.contains("private const val PROBE_PORT = 443"))
        assertFalse("endpoint rotation must not reintroduce plaintext port 80", source.contains("PROBE_PORT = 80"))
        assertFalse("endpoint rotation must not add a URLConnection plaintext fallback", endpoint.contains("openConnection") || endpoint.contains("HttpURLConnection"))
    }

    @Test
    fun `TLS HTTPS or post-GET VPN DNS failures remain fail closed`() {
        val source = sourceFile("VpnDataPlaneProbe.kt")
        val run = functionBody(source, "run")
        val endpoint = functionBody(source, "runEndpoint")
        val vpnDns = functionBody(source, "verifyVpnDns")
        val resolveNetworkDnsAsync = functionBody(source, "resolveNetworkDnsAsync")
        val socketLease = sourceFile("ProbeSocketLease.kt")
        val socketLeaseClose = functionBody(socketLease, "close(expired: Boolean)")
        val stagedFailure = Regex("""failure\(\s*stage,""").containsMatchIn(endpoint)

        assertTrue(
            "missing underlying DNS bootstrap must fail with its underlying-network stage",
            run.contains("VpnDataPlaneProbeStage.UNDERLYING_NETWORK") &&
                run.contains("\"underlying_network_unavailable\"") &&
                run.contains("networkReadinessPending = true"),
        )
        assertTrue(
            "failed underlying DNS must fail the proof",
            endpoint.contains("underlyingDns.failure") && endpoint.contains("\"underlying_dns_unavailable\""),
        )
        assertTrue(
            "TLS must have its own diagnostic stage before the encrypted GET is written",
            endpoint.contains("stage = VpnDataPlaneProbeStage.TLS_HANDSHAKE") &&
                endpoint.indexOf("tlsSocket.startHandshake()") < endpoint.indexOf("stage = VpnDataPlaneProbeStage.HTTP_WRITE"),
        )
        assertTrue(
            "a malformed raw HTTP response must fail with the HTTP-read stage",
            endpoint.contains("stage = VpnDataPlaneProbeStage.HTTP_READ") &&
                endpoint.contains("failure(stage, \"malformed_http_response\", probeStartedAt)"),
        )
        assertTrue(
            "a non-204 response must fail with the HTTP-read stage",
            endpoint.contains("failure(stage, \"unexpected_http_status\", probeStartedAt)"),
        )
        assertTrue(
            "VPN DNS failure must fail the entire proof",
            endpoint.contains("stage = VpnDataPlaneProbeStage.VPN_DNS") &&
                endpoint.contains("failure(stage, \"vpn_dns_\$dnsFailure\", probeStartedAt)"),
        )
        assertTrue(
            "DNS helper failures must stay distinct from a successful numeric GET",
            vpnDns.contains("result.failure") && resolveNetworkDnsAsync.contains("withTimeoutOrNull(timeoutMs)"),
        )
        assertTrue(
            "GET timeout must fail the proof at the current stage",
            endpoint.contains("catch (_: SocketTimeoutException)") && endpoint.contains("failure(stage, \"timeout\", probeStartedAt)"),
        )
        assertTrue(
            "GET IO failure must fail the proof via dedicated IOException branch",
            endpoint.contains("catch (error: IOException)") &&
                endpoint.contains("vpnDataPlaneExceptionCategory(error, unexpected = false)") &&
                stagedFailure,
        )
        assertTrue(
            "unexpected GET/body failure must fail the proof",
            endpoint.contains("catch (error: Exception)") &&
                endpoint.contains("vpnDataPlaneExceptionCategory(error, unexpected = true)") &&
                stagedFailure,
        )
        assertTrue(
            "raw and TLS sockets must both transfer to a lease that closes every owned socket on every result",
            endpoint.contains("return withBoundedProbeSockets(socketBudgetMs) { sockets ->") &&
                endpoint.contains("sockets.own(openedSocket)") &&
                endpoint.contains("sockets.own(tlsSocket)") &&
                socketLease.contains("finally") &&
                socketLease.contains("deadline.cancel()") &&
                socketLease.contains("sockets.close()") &&
                socketLeaseClose.contains("owned.forEach { runCatching { it.close() } }"),
        )
        assertTrue(
            "cancellation must rethrow through explicit CancellationException branch",
            endpoint.contains("catch (error: CancellationException)") && endpoint.contains("throw error"),
        )
        assertFalse(
            "failed GET category must not be remapped to a dedicated fallback token",
            endpoint.contains("failure(\"fallback\")") || endpoint.contains("failure(\"android_validated\")"),
        )
    }

    @Test
    fun `failed dedicated GET cannot race a stale start into Started`() {
        val service = sourceFile("BoxService.kt")
        val routeCheck = functionBody(service, "checkVpnDataPlaneRoute")
        val acknowledgement = functionBody(service, "acknowledgeVerifiedRouteFromFlutter")
        val retry = functionBody(service, "verifyNativeStartupRoute")
        val recoveryPolicy = sourceFile("ServiceRecoveryPolicy.kt")

        val cancellationAwareProbe = routeCheck.indexOf("val result = try")
        val probe = routeCheck.indexOf("vpnDataPlaneProbe.run(", cancellationAwareProbe)
        val probeNetwork = routeCheck.indexOf("DefaultNetworkMonitor.defaultNetwork", probe)
        val staleGeneration = routeCheck.indexOf("proofStartGeneration != currentStartGeneration()")
        val rejectStale = routeCheck.indexOf("invalidateVpnDataPlaneProof(\"stale probe generation\")")
        assertTrue(
            "the cancellation-aware result must still invoke the probe with the pre-start default network snapshot",
            cancellationAwareProbe >= 0 && probe > cancellationAwareProbe && probeNetwork > probe,
        )
        assertTrue("the probe result must be generation-checked", staleGeneration > probeNetwork)
        assertTrue("stale proof must be rejected before it can be recorded", rejectStale > staleGeneration)

        val publication = acknowledgement.indexOf("awaitStartupRoutePublication(")
        assertTrue("acknowledgement must use bounded same-owner publication after native VPN proof", publication >= 0)
        assertTrue("publication retry must remain in the same lifecycle generation", acknowledgement.contains("isCurrent = { shouldContinueStart(generation) }"))
        assertTrue("publication retry must yield to native route recovery", acknowledgement.contains("recoveryActive = { nativeRouteRecoveryOwnsGeneration(generation) }"))
        assertTrue("publication logic receives the exact current-generation proof predicate", acknowledgement.contains("hasCurrentProof = { hasReusableVpnDataPlaneProof(generation) }"))
        assertTrue("publication re-verification shares the original operation deadline", acknowledgement.contains("operationDeadlineElapsedMs = deadline"))
        assertTrue("only this Flutter acknowledgement opts out of watchdog recovery on proof races", acknowledgement.contains("recoverOnProofChange = false"))
        assertFalse("a failed GET must not admit Started directly", acknowledgement.contains("Status.Started"))
        assertFalse("acknowledgement must not terminally stop a transient route failure", acknowledgement.contains("stopAndAlert(Alert.StartService"))
        assertFalse("acknowledgement must not retain terminal route-stop control", acknowledgement.contains("stopServiceOnRouteFailure"))

        assertTrue("native retry must repeatedly perform the real VPN data-plane check", retry.contains("while (SystemClock.elapsedRealtime() < deadline)"))
        assertTrue(
            "native retry may only use the authoritative VPN data-plane request",
            retry.indexOf("checkSelectedRoute(") > -1 &&
                retry.indexOf("routeClient", retry.indexOf("checkSelectedRoute(")) > retry.indexOf("checkSelectedRoute(") &&
                retry.indexOf("requireVpnDataPlane = true", retry.indexOf("routeClient", retry.indexOf("checkSelectedRoute("))) > retry.indexOf("routeClient", retry.indexOf("checkSelectedRoute(")),
        )
        assertTrue("native retry must use bounded retry delay", retry.contains("delay(minOf(STARTUP_ROUTE_VERIFY_RETRY_MS, remainingMs))"))
        val exhausted = retry.indexOf("native startup route failed")
        val retryGate = retry.indexOf("shouldRetryFailedNativeStartup(", exhausted)
        val recoveryRequest = retry.indexOf("requestCoreRecovery(", retryGate)
        assertTrue("retry exhaustion must inspect whether this is still the current active session", retryGate > exhausted)
        assertTrue("only an active current failed route is handed to recovery", recoveryRequest > retryGate)
        assertTrue("stale or inactive route failure must be discarded", retry.contains("stale or inactive generation"))
        assertFalse("retry exhaustion must not terminally stop the service", retry.contains("stopAndAlert(Alert.StartService"))
        assertTrue(
            "retry eligibility must require both active user intent and current generation",
            recoveryPolicy.contains("): Boolean = !routeVerified && userSessionActive && startStillCurrent"),
        )
    }

    @Test
    fun `flutter startup timeout reserves route and Android proof grace`() {
        val service = sourceFile("BoxService.kt")
        val timeout = functionBody(service, "unverifiedStartupRecoveryTimeoutMs")

        assertTrue(service.contains("private const val STARTUP_ROUTE_VERIFY_TIMEOUT_MS = 12_000L"))
        assertTrue(service.contains("private const val CORE_UNVERIFIED_STARTUP_RECOVERY_GRACE_MS = 45_000L"))
        assertTrue(timeout.contains("return verificationTimeout + CORE_UNVERIFIED_STARTUP_RECOVERY_GRACE_MS"))
        assertTrue(
            "the independent data-plane bootstrap must allow a slow TURNcoat route",
            sourceFile("VpnDataPlaneProbe.kt").contains("private const val DEFAULT_PROBE_TIMEOUT_MS = 30_000L"),
        )
    }

    @Test
    fun `recovery retains fail-closed TUN while terminal paths release the platform VPN`() {
        val service = sourceFile("BoxService.kt")
        val cleanup = functionBody(service, "closeMobileCoreAndAwaitTunQuiescence")

        val admissionSealLock = cleanup.indexOf("synchronized(fileDescriptorLock)")
        val admissionSeal = cleanup.indexOf("tunDescriptorAdmissionClosed = true", admissionSealLock)
        val retain = cleanup.indexOf("val failClosedVpnInstalled = ensurePhysicalFailClosedVpn(reason)", admissionSeal)
        val close = cleanup.indexOf("MobileCoreCloser.closeBlocking(reason)")
        val platformRetirement = cleanup.indexOf("val platformVpnRetired = when {")
        val recoveryRetain = cleanup.indexOf("failClosedVpnInstalled && isFailClosedTunBarrierActive()", platformRetirement)
        val terminalRetirement = cleanup.indexOf("service.retirePlatformVpnSessionAfterCoreStop", platformRetirement)
        val terminalDescriptorClose = cleanup.indexOf("closeTunFileDescriptor()", platformRetirement)
        val terminalQuiescence = cleanup.indexOf("awaitTunRuntimeQuiescence(", terminalDescriptorClose)
        assertTrue("cleanup must seal TUN admission before retaining its packet sink", admissionSealLock >= 0 && admissionSeal > admissionSealLock)
        assertTrue(
            "native close must begin only after the physical full-route packet sink is admitted",
            close > retain,
        )
        assertTrue(
            "ordinary cleanup result must distinguish native close, platform retirement, and TUN quiescence",
            service.contains("val nativeCloseCompleted: Boolean") &&
                service.contains("val platformVpnRetired: Boolean") &&
                service.contains("val tunQuiescent: Boolean") &&
                cleanup.contains("CoreCleanupResult(closeCompleted, platformVpnRetired, tunQuiescent)"),
        )
        assertTrue(
            "automatic recovery keeps the retained full-route descriptor as its active barrier",
            recoveryRetain > platformRetirement,
        )
        assertTrue(
            "manual/revoke terminal cleanup must retire the framework VPN before closing the descriptor",
            terminalRetirement > platformRetirement && terminalDescriptorClose > terminalRetirement &&
                terminalQuiescence > terminalDescriptorClose,
        )

        val automaticCleanup = functionBody(service, "awaitRecoverableCoreCleanup")
        val automaticSealLock = automaticCleanup.indexOf("synchronized(fileDescriptorLock)")
        val automaticSeal = automaticCleanup.indexOf("tunDescriptorAdmissionClosed = true", automaticSealLock)
        val automaticRetain = automaticCleanup.indexOf("ensurePhysicalFailClosedVpn(", automaticSeal)
        val exactCloseJoin = automaticCleanup.indexOf("MobileCoreCloser.awaitCloseToFinish(", automaticRetain)
        val completionResult = automaticCleanup.indexOf("result = CoreCleanupResult(", exactCloseJoin)

        assertTrue("automatic pending cleanup must keep TUN admission sealed", automaticSealLock >= 0 && automaticSeal > automaticSealLock)
        assertTrue("automatic pending cleanup must retain the descriptor as its packet sink", automaticRetain > automaticSeal)
        assertTrue("automatic pending cleanup must join the exact in-flight native close", exactCloseJoin > automaticRetain)
        assertTrue("automatic pending cleanup may publish completion only after joining the exact close", completionResult > exactCloseJoin)
        assertFalse("automatic pending cleanup must not create another blocking native close", automaticCleanup.contains("MobileCoreCloser.closeBlocking("))
        assertFalse("automatic recovery must not close the retained fail-closed descriptor", automaticCleanup.contains("closeTunFileDescriptor()"))
        assertFalse("automatic recovery must not retire the framework VPN", automaticCleanup.contains("retirePlatformVpnSession"))
        assertFalse("automatic pending cleanup must not terminally drop user intent", automaticCleanup.contains("finishCoreCleanupFailure("))

        val recovery = functionBody(service, "recoverMobileCore")
        val initialCleanup = recovery.indexOf("val initialCleanupResult = closeMobileCoreAndAwaitTunQuiescence(")
        val recoverableWait = recovery.indexOf("awaitRecoverableCoreCleanup(", initialCleanup)
        val completionGate = recovery.indexOf("cleanupResult?.completed != true", recoverableWait)
        val setup = recovery.indexOf("Mobile.setup(", completionGate)
        assertTrue("recovery must begin with one ordinary cleanup barrier", initialCleanup >= 0)
        assertTrue("recovery must wait through pending cleanup before setup", recoverableWait > initialCleanup)
        assertTrue("recovery must reject setup until every cleanup barrier completed", completionGate > recoverableWait)
        assertTrue("a replacement core/TUN setup must remain after the completion gate", setup > completionGate)

        val stop = functionBody(service, "stopService")
        assertTrue("terminal service stop retains its existing tolerant cleanup mode", stop.contains("\"service stop\""))
        assertTrue("terminal service stop must still be marked serviceStopping", stop.contains("serviceStopping = true"))
    }

    @Test
    fun `strict VPN supplies a sink for an unsupported family and applies only its resolved app routing plan`() {
        val source = sourceFile("VPNService.kt")
        val openTun = functionBody(source, "openRemoteTun")
        val failClosedBuilder = sourceSection(
            source,
            "private fun newFailClosedVpnBuilder",
            "override fun writePlatformLog",
        )
        val codeOnly = source.lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")

        listOf(
            "allowBypass(",
            "excludeRoute(",
        ).forEach { forbidden ->
            assertFalse("user VPN must not contain $forbidden", codeOnly.contains(forbidden))
        }
        assertTrue(
            "app-specific routing must be reduced from Settings and TunOptions to one explicit plan",
            openTun.contains("val optionIncludePackages = options.includePackage") &&
                openTun.contains("val optionExcludePackages = options.excludePackage") &&
                openTun.contains("val appRoutingPlan = resolveVpnAppRoutingPlan(") &&
                openTun.contains("ownPackageName = packageName") &&
                openTun.contains("perAppProxyMode = Settings.perAppProxyMode") &&
                openTun.contains("perAppProxyPackages = Settings.perAppProxyList"),
        )
        assertTrue(
            "only the resolved IncludeOnly and Exclude branches may apply Android app routing",
            source.contains("private fun addIncludePackage") &&
                source.contains("builder.addAllowedApplication(packageName)") &&
                source.contains("private fun addExcludePackage") &&
                source.contains("builder.addDisallowedApplication(packageName)") &&
                openTun.contains("is VpnAppRoutingPlan.IncludeOnly") &&
                openTun.contains("addIncludePackage(builder, routedPackage)") &&
                openTun.contains("is VpnAppRoutingPlan.Exclude") &&
                openTun.contains("addExcludePackage(builder, bypassedPackage)"),
        )
        assertTrue("strict user VPN must reject disabled auto-route", openTun.contains("check(options.autoRoute)"))
        val familyAdmission = openTun.indexOf("check(hasInet4Address || hasInet6Address)")
        val syntheticIpv4 = openTun.indexOf("builder.addAddress(STRICT_UNSUPPORTED_IPV4_ADDRESS")
        val syntheticIpv6 = openTun.indexOf("builder.addAddress(STRICT_UNSUPPORTED_IPV6_ADDRESS")
        val ipv4DefaultRoute = openTun.indexOf("builder.addRoute(\"0.0.0.0\", 0)")
        val ipv6DefaultRoute = openTun.indexOf("builder.addRoute(\"::\", 0)")
        assertTrue(
            "strict user VPN must require at least one native family and reject none",
            familyAdmission >= 0 && openTun.contains("strict VPN requires at least one native address family"),
        )
        assertTrue(
            "an IPv6-only core must receive a synthetic IPv4 sink before IPv4 default routing",
            syntheticIpv4 > familyAdmission && ipv4DefaultRoute > syntheticIpv4 &&
                openTun.substring(familyAdmission, syntheticIpv4).contains("if (!hasInet4Address)"),
        )
        assertTrue(
            "an IPv4-only core must receive a synthetic IPv6 sink before IPv6 default routing",
            syntheticIpv6 > syntheticIpv4 && ipv6DefaultRoute > syntheticIpv6 &&
                openTun.substring(syntheticIpv4, syntheticIpv6).contains("if (!hasInet6Address)"),
        )
        assertTrue(
            "both default routes must remain unconditional after synthetic family admission",
            ipv6DefaultRoute > ipv4DefaultRoute &&
                !openTun.substring(syntheticIpv6, ipv6DefaultRoute).contains("if (hasInet6Address)"),
        )
        assertTrue(
            "the bootstrap packet sink must itself be dual-stack and full-route",
            failClosedBuilder.contains(".addAddress(ipv4Address") &&
                failClosedBuilder.contains(".addRoute(\"0.0.0.0\", 0)") &&
                failClosedBuilder.contains(".addAddress(generation.markerAddress") &&
                failClosedBuilder.contains(".addRoute(\"::\", 0)"),
        )
    }

    @Test
    fun `VPN startup does not require always-on lockdown but still records lock bridge diagnostics`() {
        val boxService = sourceFile("BoxService.kt")
        val start = functionBody(boxService, "startService")
        val prepare = functionBody(boxService, "prepareVpnStartAdmission")

        assertTrue(
            "service start must still establish its bounded fail-closed blocker before process/network admission",
            start.contains("ensurePhysicalFailClosedVpn(\n                    \"service start admission\",") &&
                start.contains("NativeCrashDiagnostics.setNetworkAdmissionAllowed(true)") &&
                start.indexOf("ensurePhysicalFailClosedVpn(\n                    \"service start admission\",") <
                    start.indexOf("NativeCrashDiagnostics.setNetworkAdmissionAllowed(true)"),
        )
        assertFalse(
            "startup path must not gate on strict-system lockdown",
            start.contains("strictKillSwitchAdmissionError()") || start.contains("isAlwaysOn") || start.contains("isLockdownEnabled") ||
                prepare.contains("strictKillSwitchAdmissionError()") || prepare.contains("isAlwaysOn") || prepare.contains("isLockdownEnabled"),
        )

        val vpnService = sourceFile("VPNService.kt")
        val statusLog = sourceSection(
            vpnService,
            "internal fun logSystemLockdownStatus()",
            "\n\n    override fun onCreate",
        )
        assertTrue(
            "system lock-bridge diagnostics remain optional telemetry",
            statusLog.contains("isAlwaysOn") && statusLog.contains("isLockdownEnabled") && statusLog.contains("optional=true"),
        )

        val allProductionKotlin = File("src/main/kotlin")
            .walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .joinToString("\n") { it.readText() }
        assertEquals(
            "isAlwaysOn may be read only by optional logSystemLockdownStatus diagnostics",
            1,
            Regex("\\bisAlwaysOn\\b").findAll(allProductionKotlin).count(),
        )
        assertEquals(
            "isLockdownEnabled may be read only by optional logSystemLockdownStatus diagnostics",
            1,
            Regex("\\bisLockdownEnabled\\b").findAll(allProductionKotlin).count(),
        )

        val obsoleteLockdownResource = "error_vpn_" + "lockdown"
        assertFalse(
            "Always-on/lockdown is optional, so production code and resources must not retain its old startup error",
            File("src/main").walkTopDown().any { file ->
                file.isFile && file.readText().contains(obsoleteLockdownResource)
            },
        )
    }

    @Test
    fun `dynamic shortcut capability authenticates the exported legacy creator before service access`() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        val createShortcutAction = manifest.indexOf("android.intent.action.CREATE_SHORTCUT")
        check(createShortcutAction >= 0) { "missing exported shortcut creator action" }
        val creatorStart = manifest.lastIndexOf("<activity", createShortcutAction)
        val creatorEnd = manifest.indexOf("</activity>", createShortcutAction)
        check(creatorStart >= 0 && creatorEnd > creatorStart) { "shortcut creator activity is malformed" }
        val shortcutCreator = manifest.substring(creatorStart, creatorEnd)
        assertTrue("Android's legacy shortcut creator must remain exported only for CREATE_SHORTCUT", shortcutCreator.contains("android:exported=\"true\""))
        assertFalse("the legacy creator must not expose a static ACTION_MAIN shortcut target", shortcutCreator.contains("android.intent.action.MAIN"))
        assertFalse("manifest metadata must not restore an unauthenticated static shortcuts.xml entry", manifest.contains("@xml/shortcuts"))
        assertFalse("the deleted static shortcut resource must stay absent", File("src/main/res/xml/shortcuts.xml").exists())

        val executorSource = mainSourceFile("ShortcutActivity.kt")
        val mainActivity = mainSourceFile("MainActivity.kt")
        val capability = functionBody(executorSource, "capability")
        val publish = functionBody(executorSource, "publishAuthenticatedDynamicShortcut")
        val mainOnCreate = functionBody(mainActivity, "onCreate")
        val executorOnCreate = sourceSection(
            executorSource,
            "override fun onCreate(savedInstanceState: Bundle?)",
            "override fun onServiceStatusChanged",
        )
        val authenticatedToggle = functionBody(executorSource, "isAuthenticatedToggle")

        assertTrue(
            "the exported creator must reject non-HOME/non-app callers before producing a shortcut",
            executorSource.contains("callingPackage") &&
                executorSource.contains("packageName") &&
                (executorSource.contains("Intent.CATEGORY_HOME") || executorSource.contains("RoleManager.ROLE_HOME")),
        )
        assertTrue(
            "the dynamic shortcut capability must be a persisted 256-bit per-install secret",
            capability.contains("ByteArray(32)") &&
                capability.contains("SecureRandom") &&
                capability.contains("getSharedPreferences") &&
                publish.contains("getSharedPreferences") &&
                publish.contains("PUBLISHED_CAPABILITY_KEY"),
        )
        assertTrue(
            "only MainActivity publishes the authenticated dynamic toggle and records it after publishing",
                mainOnCreate.indexOf("super.onCreate(savedInstanceState)") >= 0 &&
                mainOnCreate.indexOf("ShortcutActivity.publishAuthenticatedDynamicShortcut(this)") > mainOnCreate.indexOf("super.onCreate(savedInstanceState)") &&
                publish.indexOf("ShortcutManagerCompat.addDynamicShortcuts") > publish.indexOf("authenticatedToggleIntent") &&
                publish.lastIndexOf("PUBLISHED_CAPABILITY_KEY") > publish.indexOf("ShortcutManagerCompat.addDynamicShortcuts"),
        )
        assertTrue(
            "the toggle must validate an already-persisted capability with constant-time comparison, never mint one on launch",
            authenticatedToggle.contains("intent?.action != ACTION_AUTHENTICATED_TOGGLE") &&
                authenticatedToggle.contains("getStringExtra(EXTRA_TOGGLE_CAPABILITY)") &&
                authenticatedToggle.contains("storedCapability(activity)") &&
                authenticatedToggle.contains("MessageDigest.isEqual") &&
                !authenticatedToggle.contains("capability(activity)"),
        )

        val createShortcut = executorOnCreate.indexOf("intent.action == Intent.ACTION_CREATE_SHORTCUT")
        val trustedCreator = executorOnCreate.indexOf("isTrustedCreator(this)", createShortcut)
        val authenticatedGate = executorOnCreate.indexOf("if (isAuthenticatedToggle(this, intent))")
        val connect = executorOnCreate.indexOf("connection.connect()")
        val rejectedBranch = executorOnCreate.indexOf("} else {", authenticatedGate)
        val rejectedFinish = executorOnCreate.indexOf("finish()", rejectedBranch)
        val rejectedReturn = executorOnCreate.indexOf("return", rejectedFinish)
        assertTrue(
            "only a trusted HOME/app request can create a shortcut capability",
            createShortcut >= 0 && trustedCreator > createShortcut,
        )
        assertTrue(
            "an unauthenticated exported toggle must take the rejecting branch instead of binding ServiceConnection",
            authenticatedGate >= 0 && connect > authenticatedGate && rejectedBranch > connect &&
                rejectedFinish > rejectedBranch && rejectedReturn > rejectedFinish,
        )
        val creatorBranch = executorOnCreate.substring(createShortcut, authenticatedGate)
        assertFalse(
            "the exported creator branch must never bind a service or stop the VPN",
            creatorBranch.contains("connection.connect()") || creatorBranch.contains("BoxService.stop("),
        )
        assertFalse("the raw exported toggle entry must not stop the VPN before capability validation", executorOnCreate.substring(0, connect).contains("BoxService.stop("))
    }

    @Test
    fun `physical fail-closed builder barrier is bounded and prevents native close before establishment`() {
        val source = sourceFile("BoxService.kt")
        val physicalBarrier = functionBody(source, "ensurePhysicalFailClosedVpn")
        val cleanup = functionBody(source, "closeMobileCoreAndAwaitTunQuiescence")
        val recovery = functionBody(source, "awaitRecoverableCoreCleanup")

        val deadline = physicalBarrier.indexOf("FAIL_CLOSED_VPN_INSTALL_TIMEOUT_MS")
        val establish = physicalBarrier.indexOf("vpnService.ensureFailClosedVpn()")
        val retry = physicalBarrier.indexOf("delay(FAIL_CLOSED_VPN_RETRY_MS)")
        val timeout = physicalBarrier.indexOf("leaving the existing VPN generation in place")
        assertTrue("physical Builder.establish barrier must have a finite deadline", deadline >= 0)
        assertTrue("cleanup must still attempt a physical fail-closed Builder establish under retry loop", establish > deadline)
        assertTrue("failed establishes must retry only with the configured bounded cadence", retry > establish)
        assertTrue("bounded blocker must report its failed barrier result", timeout > retry)

        val cleanupBarrier = cleanup.indexOf("ensurePhysicalFailClosedVpn(reason)")
        val nativeClose = cleanup.indexOf("MobileCoreCloser.closeBlocking(reason)")
        assertTrue("native close must remain after physical blocking-TUN admission", cleanupBarrier >= 0 && nativeClose > cleanupBarrier)
        assertTrue("a failed physical blocker must make cleanup fail closed", cleanup.contains("failClosedVpnInstalled && isFailClosedTunBarrierActive()"))

        val recoveryBarrier = recovery.indexOf("ensurePhysicalFailClosedVpn(")
        val existingCloseWait = recovery.indexOf("MobileCoreCloser.awaitCloseToFinish(")
        assertTrue("same-instance recovery must obtain a physical barrier before joining native close", recoveryBarrier >= 0 && existingCloseWait > recoveryBarrier)
        assertTrue(
            "failed recovery barrier must return fail-closed, and final quiescence must require the current physical barrier",
            recovery.contains("if (!failClosedVpnInstalled)") &&
                recovery.contains("tunQuiescent = blockerReady && isFailClosedTunBarrierActive()"),
        )
    }

    @Test
    fun `retained Flutter bootstrap may join only an exact route-verified Started VPN generation`() {
        val box = sourceFile("BoxService.kt")
        val join = functionBody(box, "tryJoinVerifiedVpnAdmission")

        val activeInstance = join.indexOf("val current = activeInstance ?: return null")
        val sessionEpoch = join.indexOf("ServiceLifecycleOwnership.currentUserSessionEpoch() ?: return null", activeInstance)
        val exactEpoch = join.indexOf("ServiceLifecycleOwnership.runIfUserSessionEpochCurrent(sessionEpoch)", sessionEpoch)
        val localProbeAdmission = join.indexOf("LocalProbeAdmission.isAllowed()", exactEpoch)
        val verifiedRoute = join.indexOf("current.hasVerifiedRouteForOptionalBackgroundWork()", localProbeAdmission)
        assertTrue(
            "a retained join must use the exact current epoch plus native local-probe admission and the authoritative route predicate",
            activeInstance >= 0 && sessionEpoch > activeInstance && exactEpoch > sessionEpoch &&
                localProbeAdmission > exactEpoch && verifiedRoute > localProbeAdmission,
        )
        val verifiedRoutePredicate = sourceSection(
            box,
            "private fun hasVerifiedRouteForOptionalBackgroundWork(): Boolean",
            "\n    private fun shouldContinueStart",
        )
        val owner = verifiedRoutePredicate.indexOf("ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)")
        val started = verifiedRoutePredicate.indexOf("status.value == Status.Started", owner)
        val durableIntent = verifiedRoutePredicate.indexOf("Settings.startedByUser", started)
        val strictRoute = verifiedRoutePredicate.indexOf("Settings.strictVpnRouteVerified", durableIntent)
        val processAdmission = verifiedRoutePredicate.indexOf("hasProcessNetworkAdmission()", strictRoute)
        val currentProof = verifiedRoutePredicate.indexOf("hasReusableVpnDataPlaneProof(generation)", processAdmission)
        val processAdmissionPredicate = sourceSection(
            box,
            "private fun hasProcessNetworkAdmission(): Boolean",
            "\n    private fun hasVerifiedRouteForOptionalBackgroundWork",
        )
        val vpnService = processAdmissionPredicate.indexOf("service is VPNService")
        val retainedTun = processAdmissionPredicate.indexOf("hasRetainedVpnDescriptor()", vpnService)
        val nativeAdmission = processAdmissionPredicate.indexOf("NativeCrashDiagnostics.isNetworkAdmissionAllowed()", retainedTun)
        assertTrue(
            "the authoritative verified-route predicate must prove current owner, Started state, user intent, strict route, process admission, and current-generation data-plane proof",
            owner >= 0 && started > owner && durableIntent > started && strictRoute > durableIntent &&
                processAdmission > strictRoute && currentProof > processAdmission,
        )
        assertTrue(
            "process admission must itself require a VPN service, a retained TUN, and native network admission",
            vpnService >= 0 && retainedTun > vpnService && nativeAdmission > retainedTun,
        )
        assertTrue(
            "the retained join is a read-only probe: it must not seal/reset admission or dispatch a service start",
            !join.contains("LocalProbeAdmission.blockAndCancel") &&
                !join.contains("NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)") &&
                !join.contains("Settings.strictVpnRouteVerified = false") &&
                !join.contains("ContextCompat.startForegroundService") &&
                !join.contains("beginVpnStartAdmission("),
        )

        val methodHandler = mainSourceFile("MethodHandler.kt")
        val joinHandler = sourceSection(
            methodHandler,
            "Trigger.TryJoinVerifiedVpnAdmission.method ->",
            "Trigger.BeginVpnStartAdmission.method ->",
        )
        assertTrue(
            "the platform method must expose the read-only native join without creating a new admission",
            joinHandler.contains("BoxService.tryJoinVerifiedVpnAdmission()") &&
                !joinHandler.contains("BoxService.beginVpnStartAdmission("),
        )
    }

    @Test
    fun `service establishes fail-closed packet sink before native setup and data TUN replaces it only after establish`() {
        val service = sourceFile("BoxService.kt")
        val start = functionBody(service, "startService")
        val earlyPrepare = functionBody(service, "prepareVpnStartAdmission")
        val boundedBarrier = functionBody(service, "ensurePhysicalFailClosedVpn")
        val vpn = sourceFile("VPNService.kt")
        val openTun = sourceSection(vpn, "override fun openTun", "override fun writePlatformLog")

        val failClosed = start.indexOf("ensurePhysicalFailClosedVpn(\n                    \"service start admission\",")
        val setup = start.indexOf("Mobile.setup(")
        assertTrue(
            "the normal VPN service start must use the bounded physical blocker before Mobile.setup",
            failClosed >= 0 && setup > failClosed,
        )

        val earlyAdmission = earlyPrepare.indexOf("ensurePhysicalFailClosedVpn(\"early VPN start admission\")")
        val earlyLaunch = earlyPrepare.indexOf("serviceScope.launch(Dispatchers.IO)")
        assertTrue(
            "early Android VPN preparation must use the bounded physical blocker in its IO admission coroutine",
            earlyAdmission > earlyLaunch,
        )
        assertFalse(
            "neither primary VPN admission point may bypass retries with a direct one-shot blocker call",
            start.contains("service.ensureFailClosedVpn(") ||
                earlyPrepare.contains("service.ensureFailClosedVpn("),
        )
        assertTrue(
            "the bounded helper remains the sole permitted owner of its direct retry attempt",
            boundedBarrier.contains("vpnService.ensureFailClosedVpn()"),
        )

        val establish = openTun.indexOf("val pfd = builder.establish()")
        val dataReplacement = openTun.indexOf("service.replaceTunFileDescriptor(pfd)")
        val nativeFd = openTun.indexOf("val nativeFd = pfd.fd")
        assertTrue("data-plane descriptor replacement needs a successful establish first", establish >= 0 && dataReplacement > establish)
        assertTrue("native receives the descriptor only after service retains the data-plane owner", nativeFd > dataReplacement)
    }

    @Test
    fun `fresh process waits for its untracked own VPN before any replacement establish`() {
        val box = sourceFile("BoxService.kt")
        val start = functionBody(box, "startService")
        val awaitRelease = start.indexOf("awaitUntrackedOwnVpnRelease(")
        val physicalBarrier = start.indexOf("ensurePhysicalFailClosedVpn(\n                    \"service start admission\",")
        assertTrue(
            "a visible Marten Network without this process's PFD must be released before the start blocker can establish a replacement",
            awaitRelease >= 0 && physicalBarrier > awaitRelease,
        )

        val await = functionBody(box, "awaitUntrackedOwnVpnRelease")
        val timeout = await.indexOf("withTimeoutOrNull")
        val timeoutStop = functionBody(box, "stopAfterUntrackedOwnVpnReleaseTimeout")
        val terminalIntent = timeoutStop.indexOf("persistTerminalStopIntent(")
        val persistTerminalStop = functionBody(box, "persistTerminalStopIntent")
        val durableStoppedState = persistTerminalStop.indexOf("Settings.persistStoppedState()")
        assertTrue(
            "an untracked-own-VPN timeout must enter its own durable terminal Stop path",
            timeout >= 0 && start.indexOf("stopAfterUntrackedOwnVpnReleaseTimeout(", awaitRelease) > awaitRelease &&
                terminalIntent >= 0 && durableStoppedState >= 0,
        )
        assertFalse(
            "the timeout must never attempt another fail-closed establish or platform retirement",
            timeoutStop.contains("ensurePhysicalFailClosedVpn(") ||
                timeoutStop.contains("ensureFailClosedVpn(") ||
                timeoutStop.contains("retirePlatformVpnSession("),
        )

        assertFalse(
            "a process-local PFD cannot be conflated with a visible orphaned Android Network",
            box.contains("reclaimableOrphanedOwnVpn") ||
                box.contains("currentGenerationOwnsVpn = currentGenerationOwnsVpn ||"),
        )
    }

    @Test
    fun `fail closed builder hard-gates untracked own VPN both before and inside its transaction`() {
        val vpn = sourceFile("VPNService.kt")
        val ensure = functionBody(vpn, "ensureFailClosedVpn")

        val transaction = ensure.indexOf("synchronized(vpnBuilderTransactionLock)")
        val firstGate = ensure.indexOf("service.hasUntrackedOwnVpnNetwork()")
        val secondGate = ensure.indexOf("service.hasUntrackedOwnVpnNetwork()", transaction)
        val establish = ensure.indexOf(".establish()", transaction)
        assertTrue(
            "a stale Android Network may appear between checks, so both the preflight and serialized Builder transaction must refuse establish",
            transaction >= 0 && firstGate >= 0 && firstGate < transaction &&
                secondGate > transaction && establish > secondGate,
        )

        val retirement = sourceSection(
            vpn,
            "private suspend fun retirePlatformVpnSession(",
            "\n    /**\n     * Installs a service-owned packet sink",
        )
        val retirementTransaction = retirement.indexOf("synchronized(vpnBuilderTransactionLock)")
        val retirementFirstGate = retirement.indexOf("service.hasUntrackedOwnVpnNetwork()")
        val earlyDescriptorOrOwnerReturn = retirement.indexOf(
            "if (!service.hasRetainedVpnDescriptor() && !BoxService.isOwnVpnActive(this))",
        )
        val retirementSecondGate = retirement.indexOf("service.hasUntrackedOwnVpnNetwork()", retirementTransaction)
        val retirementEstablish = retirement.indexOf(".establish()", retirementTransaction)
        assertTrue(
            "retirement must reject a latched old Network before ownerUid-dependent RELEASED fallback and again inside its Builder transaction",
            retirementTransaction >= 0 && retirementFirstGate >= 0 &&
                retirementFirstGate < earlyDescriptorOrOwnerReturn && earlyDescriptorOrOwnerReturn < retirementTransaction &&
                retirementSecondGate > retirementTransaction && retirementEstablish > retirementSecondGate,
        )
    }

    @Test
    fun `terminal timeout keeps local probes sealed until the latched VPN snapshot is empty`() {
        val box = sourceFile("BoxService.kt")
        val releaseAfterLoss = functionBody(box, "releaseLocalProbesAfterUntrackedVpnNetworkLoss")
        val awaitRelease = functionBody(box, "awaitUntrackedOwnVpnRelease")
        val latchedOwnership = releaseAfterLoss.indexOf("hasUntrackedOwnVpnNetwork()")
        val legacyOwnership = releaseAfterLoss.indexOf("isOwnVpnActive(")
        val terminalReleaseClaim = releaseAfterLoss.indexOf(
            "ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(terminalStopEpoch)",
            latchedOwnership,
        )
        val platformReleased = releaseAfterLoss.indexOf("platformShutdownCompleted = true", terminalReleaseClaim)
        val staleRelease = releaseAfterLoss.indexOf("if (!terminalReleaseStillCurrent)", platformReleased)
        val probeRelease = releaseAfterLoss.indexOf("tryAllowLocalProbesForCurrentState(blockEpoch)", staleRelease)
        assertTrue(
            "ownerUid redaction after timeout must not release probes: the latched predicate and exact terminal epoch claim gate platform release before probes",
            latchedOwnership >= 0 && terminalReleaseClaim > latchedOwnership &&
                platformReleased > terminalReleaseClaim &&
                releaseAfterLoss.substring(terminalReleaseClaim, platformReleased).contains(") {") &&
                staleRelease > platformReleased && probeRelease > staleRelease,
        )
        assertFalse(
            "the terminal callback must not substitute a transient self-owner observation for the latch",
            legacyOwnership >= 0,
        )
        assertTrue(
            "both the terminal callback and its event-driven wait must use the exact latched Network predicate",
            awaitRelease.contains("hasUntrackedOwnVpnNetwork()") &&
                !awaitRelease.contains("isOwnVpnActive(") &&
                !releaseAfterLoss.contains("ownership.anyActive"),
        )

        val untrackedOwnership = functionBody(box, "hasUntrackedOwnVpnNetwork")
        val latchBranch = untrackedOwnership.indexOf("if (!untrackedOwnVpnReleaseRequired)")
        val unknownVisibility = untrackedOwnership.indexOf(
            "else if (!ownership.visibilityKnown)",
            latchBranch,
        )
        val trackedHandles = untrackedOwnership.indexOf("val trackedHandles = untrackedOwnVpnNetworkHandles", unknownVisibility)
        val intersection = untrackedOwnership.indexOf("trackedHandles.intersect(ownership.vpnNetworkHandles)", trackedHandles)
        val retainedHandles = untrackedOwnership.indexOf("untrackedOwnVpnNetworkHandles = remainingHandles", intersection)
        val pendingCapturedHandle = untrackedOwnership.indexOf("if (remainingHandles.isNotEmpty())", retainedHandles)
        val clearLatch = untrackedOwnership.indexOf("untrackedOwnVpnReleaseRequired = false", pendingCapturedHandle)
        val capture = untrackedOwnership.indexOf("requireUntrackedOwnVpnRelease(ownership.ownNetworkHandles)")
        assertTrue(
            "the latch captures own handles, remains sealed for unknown visibility or any captured VPN handle, and clears only after those exact handles vanish",
            latchBranch >= 0 && unknownVisibility > latchBranch && trackedHandles > unknownVisibility &&
                intersection > trackedHandles && retainedHandles > intersection && pendingCapturedHandle > retainedHandles &&
                clearLatch > pendingCapturedHandle && capture > clearLatch,
        )
    }

    @Test
    fun `old-network release re-arbitrates a foreign VPN before automatic or builder admission`() {
        val box = sourceFile("BoxService.kt")
        val start = functionBody(box, "startService")
        val earlyAdmission = functionBody(box, "prepareVpnStartAdmission")

        fun assertPostReleaseArbitration(
            branch: String,
            blockerCall: String,
            expectedStopReason: String,
        ) {
            val release = branch.indexOf("awaitUntrackedOwnVpnRelease(")
            val arbitration = branch.indexOf("shouldRejectNewVpnStart(", release)
            val stopForForeignOwner = branch.indexOf(expectedStopReason, arbitration)
            val blocker = branch.indexOf(blockerCall, stopForForeignOwner)
            assertTrue(
                "after old Marten handle release, $blockerCall must re-arbitrate and yield to a foreign owner before establishing",
                release >= 0 && arbitration > release && stopForForeignOwner > arbitration && blocker > stopForForeignOwner,
            )
        }

        assertPostReleaseArbitration(
            branch = start,
            blockerCall = "ensurePhysicalFailClosedVpn(",
            expectedStopReason = "stopForExternalVpnOnMain(\"previous-process VPN release handoff\")",
        )
        assertPostReleaseArbitration(
            branch = earlyAdmission,
            blockerCall = "ensurePhysicalFailClosedVpn(\"early VPN start admission\")",
            expectedStopReason = "stopForExternalVpnOnMain(\"previous-process VPN admission handoff\")",
        )

        val vpn = sourceFile("VPNService.kt")
        val ensure = functionBody(vpn, "ensureFailClosedVpn")
        val transaction = ensure.indexOf("synchronized(vpnBuilderTransactionLock)")
        val outerNoDescriptor = ensure.indexOf("!service.hasRetainedVpnDescriptor()")
        val outerArbitration = ensure.indexOf("BoxService.shouldRejectNewVpnStart(")
        val outerExplicitUserStart = ensure.indexOf(
            "explicitUserStart = service.hasPendingExplicitVpnStart(),",
            outerArbitration,
        )
        val innerNoDescriptor = ensure.indexOf("!service.hasRetainedVpnDescriptor()", transaction)
        val innerArbitration = ensure.indexOf(
            "BoxService.shouldRejectNewVpnStart(",
            transaction,
        )
        val innerExplicitUserStart = ensure.indexOf(
            "explicitUserStart = service.hasPendingExplicitVpnStart(),",
            innerArbitration,
        )
        val establish = ensure.indexOf(".establish()", transaction)
        assertTrue(
            "a no-descriptor startup blocker must re-arbitrate with the pending explicit gesture both before and inside its transaction before Builder.establish",
            transaction >= 0 && outerNoDescriptor >= 0 && outerArbitration > outerNoDescriptor &&
                outerExplicitUserStart > outerArbitration && outerExplicitUserStart < transaction &&
                innerNoDescriptor > transaction && innerArbitration > innerNoDescriptor &&
                innerExplicitUserStart > innerArbitration && establish > innerExplicitUserStart,
        )
    }

    @Test
    fun `untracked VPN timeout terminal race yields to a newer Connect without stopping it`() {
        val box = sourceFile("BoxService.kt")
        val timeoutStop = functionBody(box, "stopAfterUntrackedOwnVpnReleaseTimeout")

        val durablePersistence = timeoutStop.indexOf("persistTerminalStopIntent(")
        val admissionClaim = timeoutStop.indexOf(
            "ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(",
            durablePersistence,
        )
        val stopping = timeoutStop.indexOf("status.value = Status.Stopping", admissionClaim)
        val cancelStarts = timeoutStop.indexOf("cancelPendingStarts()", stopping)
        assertTrue(
            "after durable timeout persistence, the exact terminal epoch must atomically publish Stopping before it can cancel pending starts",
            durablePersistence >= 0 && admissionClaim > durablePersistence && stopping > admissionClaim &&
                cancelStarts > stopping,
        )

        val finalClaim = timeoutStop.indexOf(
            "ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(",
            cancelStarts,
        )
        val stopSelf = timeoutStop.indexOf("service.stopSelf()", finalClaim)
        assertTrue(
            "final self-stop must remain inside a second exact terminal-epoch claim",
            finalClaim > cancelStarts && stopSelf > finalClaim &&
                timeoutStop.substring(finalClaim, stopSelf).contains(") {"),
        )

        val receiverRegistered = timeoutStop.indexOf("if (receiverRegistered)", cancelStarts)
        val unregisterReceiver = timeoutStop.indexOf("service.unregisterReceiver(receiver)", receiverRegistered)
        val receiverCleared = timeoutStop.indexOf("receiverRegistered = false", unregisterReceiver)
        val coreWatchdog = timeoutStop.indexOf("stopCoreWatchdog()", receiverCleared)
        val routeWatchdog = timeoutStop.indexOf("stopRouteWatchdog()", coreWatchdog)
        val externalWatchdog = timeoutStop.indexOf("stopExternalVpnWatchdog()", routeWatchdog)
        assertTrue(
            "descriptor-less terminal timeout must unregister its dynamic receiver and stop core, route, and external-owner watchdogs before final self-stop",
            receiverRegistered > cancelStarts && unregisterReceiver > receiverRegistered && receiverCleared > unregisterReceiver &&
                coreWatchdog > receiverCleared && routeWatchdog > coreWatchdog && externalWatchdog > routeWatchdog &&
                finalClaim > externalWatchdog,
        )

        val supersededAdmission = timeoutStop.indexOf("if (!terminalStopAdmitted)")
        val supersededReturn = timeoutStop.indexOf("return", supersededAdmission)
        val finalClaimCurrent = timeoutStop.indexOf("if (terminalStopStillCurrent) return@withContext")
        val deferredConnect = timeoutStop.indexOf("consumeDeferredConnectAfterStop()", finalClaimCurrent)
        val currentUserSession = timeoutStop.indexOf("Settings.startedByUser", deferredConnect)
        assertTrue(
            "a superseded timeout must return before stale cancellation, then resume a deferred or already-current newer Connect instead of self-stopping it",
            supersededAdmission >= 0 && supersededReturn > supersededAdmission &&
                supersededReturn < cancelStarts && finalClaimCurrent > stopSelf && deferredConnect > finalClaimCurrent &&
                currentUserSession > deferredConnect,
        )
    }

    @Test
    fun `credential-encrypted VPN startup is never declared direct-boot aware`() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        val vpnStart = manifest.indexOf("android:name=\".bg.VPNService\"")
        val vpnEnd = manifest.indexOf("</service>", vpnStart)
        val tileStart = manifest.indexOf("android:name=\".bg.TileService\"")
        val tileEnd = manifest.indexOf("</service>", tileStart)
        val bootStart = manifest.indexOf("android:name=\".bg.BootReceiver\"")
        val bootEnd = manifest.indexOf("</receiver>", bootStart)
        val firebaseStart = manifest.indexOf("android:name=\"com.google.firebase.messaging.FirebaseMessagingService\"")
        val firebaseEnd = manifest.indexOf("/>", firebaseStart)
        check(vpnStart >= 0 && vpnEnd > vpnStart) { "missing VPNService manifest declaration" }
        check(tileStart >= 0 && tileEnd > tileStart) { "missing TileService manifest declaration" }
        check(bootStart >= 0 && bootEnd > bootStart) { "missing BootReceiver manifest declaration" }
        check(firebaseStart >= 0 && firebaseEnd > firebaseStart) { "missing Firebase service manifest declaration" }
        val vpnDeclaration = manifest.substring(vpnStart, vpnEnd)
        val tileDeclaration = manifest.substring(tileStart, tileEnd)
        val bootDeclaration = manifest.substring(bootStart, bootEnd)
        val firebaseDeclaration = manifest.substring(firebaseStart, firebaseEnd)
        assertFalse(
            "VPNService uses credential-encrypted Settings and must not be launched before unlock",
            vpnDeclaration.contains("android:directBootAware=\"true\""),
        )
        assertFalse(
            "TileService can reach CE-backed service state and must not run before unlock either",
            tileDeclaration.contains("android:directBootAware=\"true\""),
        )
        assertTrue(
            "BootReceiver must also stay out of device-encrypted direct boot so it cannot revive a CE session before unlock",
            bootDeclaration.contains("android:directBootAware=\"false\""),
        )
        assertTrue(
            "Firebase's service must remain non-direct-boot so diagnostics cannot initialize before the verified route",
            firebaseDeclaration.contains("android:directBootAware=\"false\""),
        )

        val vpn = sourceFile("VPNService.kt")
        val statusLog = functionBody(vpn, "logSystemLockdownStatus")
        assertTrue(
            "pre-unlock fail-closed behavior remains lock-bridge-only diagnostics",
            statusLog.contains("optional=true") && statusLog.contains("isAlwaysOn") && statusLog.contains("isLockdownEnabled") &&
                statusLog.contains("system kill-switch bridge"),
        )
    }

    @Test
    fun `Android VPN user-session validator requires both durable intent and the exact current epoch`() {
        val methodHandler = mainSourceFile("MethodHandler.kt")
        val validator = sourceSection(
            methodHandler,
            "Trigger.ValidateVpnUserSession.method -> {",
            "Trigger.EndFlutterRestart.method -> {",
        )

        val epoch = validator.indexOf("val epoch = (call.arguments as? Number)?.toLong()")
        val result = validator.indexOf("result.success(", epoch)
        val durableIntent = validator.indexOf("Settings.startedByUser", result)
        val exactOwnership = validator.indexOf("ServiceLifecycleOwnership.isUserSessionEpochCurrent(epoch)", durableIntent)
        assertTrue(
            "validate_vpn_user_session must fail closed unless Android still owns the exact epoch and durable user intent",
            epoch >= 0 && result > epoch && durableIntent > result && exactOwnership > durableIntent,
        )
        assertFalse(
            "the validator must not treat any generic started service status as an equivalent user-session epoch",
            validator.contains("Status.Started") || validator.contains("readPlatformServiceStatus"),
        )
    }

    private fun sourceFile(name: String): String {
        val source = File("src/main/kotlin/app/marten/client/bg/$name")
        check(source.isFile) { "missing production source ${source.path}" }
        return source.readText()
    }

    private fun mainSourceFile(name: String): String {
        val source = File("src/main/kotlin/app/marten/client/$name")
        check(source.isFile) { "missing production source ${source.path}" }
        return source.readText()
    }

    private fun sourceSection(source: String, startMarker: String, endMarker: String): String {
        val start = source.indexOf(startMarker)
        check(start >= 0) { "source marker not found: $startMarker" }
        val end = source.indexOf(endMarker, start + startMarker.length)
        check(end > start) { "source end marker not found after $startMarker: $endMarker" }
        return source.substring(start, end)
    }

    private fun functionBody(source: String, name: String): String {
        val declaration = source.indexOf("fun $name")
        check(declaration >= 0) { "function $name not found" }
        val start = source.indexOf('{', declaration)
        check(start >= 0) { "function $name has no body" }
        var depth = 0
        for (index in start until source.length) {
            when (source[index]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return source.substring(start, index + 1)
            }
        }
        error("function $name body does not close")
    }
}
