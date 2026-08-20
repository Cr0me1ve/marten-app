package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IcmpResilienceSourceGuardTest {
    @Test
    fun `route unavailability remains owned recovery work rather than a terminal Flutter acknowledgement failure`() {
        val source = sourceFile("BoxService.kt")
        assertTrue(
            "active BoxService publication must be visible across MethodHandler and service threads",
            Regex("@Volatile\\s+private var activeInstance: BoxService\\? = null").containsMatchIn(source),
        )

        val acknowledgement = functionBody(source, "acknowledgeVerifiedRoute")
        assertTrue(acknowledgement.contains("val instance = activeInstance"))
        assertTrue(acknowledgement.contains("if (instance == null)"))
        assertTrue(acknowledgement.contains("return false"))
        assertTrue(acknowledgement.contains("return instance.acknowledgeVerifiedRouteFromFlutter()"))
        assertFalse(
            "companion acknowledgement must not directly promote Started without native proof",
            acknowledgement.contains("markCoreRuntimeStarted("),
        )

        val flutterAcknowledgement = functionBody(source, "acknowledgeVerifiedRouteFromFlutter")
        assertTrue(flutterAcknowledgement.contains("shouldContinueStart(generation)"))
        assertTrue(flutterAcknowledgement.contains("!hasReusableVpnDataPlaneProof(generation)"))
        val delegateToOwner = flutterAcknowledgement.indexOf("nativeRouteRecoveryOwnsGeneration(generation)")
        val nativeRetry = flutterAcknowledgement.indexOf("val verified = verifyNativeStartupRoute(")
        val sameGeneration = flutterAcknowledgement.indexOf("generation = generation", nativeRetry)
        val failClosed = flutterAcknowledgement.indexOf("if (!verified) return false", nativeRetry)
        val markStarted = flutterAcknowledgement.indexOf("return markCoreRuntimeStarted(routeVerified = true, generation = generation)")
        val recoveryOwner = functionBody(source, "nativeRouteRecoveryOwnsGeneration")
        assertTrue("Flutter acknowledgement must delegate to bounded native VPN proof", nativeRetry >= 0)
        assertTrue("Flutter acknowledgement must yield immediately to the active native recovery owner", delegateToOwner >= 0)
        assertTrue("native proof must stay in the acknowledged lifecycle generation", sameGeneration > nativeRetry)
        assertTrue("an active core recovery owns the acknowledged generation", recoveryOwner.contains("coreRecoveryInProgress"))
        assertTrue("an active network recovery owns the acknowledged generation", recoveryOwner.contains("networkRecoveryJob?.isActive == true"))
        assertTrue("a degraded route watchdog owns the acknowledged generation", recoveryOwner.contains("routeWatchdogDegraded"))
        assertTrue("ownership must remain generation and user-session guarded", recoveryOwner.contains("shouldDelegateRouteVerificationToNativeRecovery("))
        assertTrue("failed acknowledgement proof must return before Started", failClosed > sameGeneration && markStarted > failClosed)
        assertFalse("Flutter acknowledgement must never terminally stop for route unavailability", flutterAcknowledgement.contains("stopServiceOnFailure = true"))
        assertFalse("Flutter acknowledgement must leave recovery notifications/status to the owner", flutterAcknowledgement.contains("stopAndAlert(Alert.StartService"))

        val nativeProof = functionBody(source, "verifyNativeStartupRoute")
        assertTrue("native proof must retry rather than trust one route snapshot", nativeProof.contains("while (SystemClock.elapsedRealtime() < deadline)"))
        assertTrue(
            "native proof must require the Android VPN data-plane GET",
            nativeProof.contains("checkSelectedRoute(") && nativeProof.contains("requireVpnDataPlane = true"),
        )
        assertTrue("native proof expiry must enter guarded core recovery", nativeProof.contains("requestCoreRecovery("))
        assertFalse("route unavailability must not terminally stop the foreground service", nativeProof.contains("stopAndAlert(Alert.StartService"))
        assertFalse("route verification must not retain a terminal-stop parameter", nativeProof.contains("stopServiceOnFailure"))

        assertFalse(
            "no route-verification caller may opt into terminal Stop/Close for route unavailability",
            source.contains("stopServiceOnRouteFailure = true"),
        )

        val started = functionBody(source, "markCoreRuntimeStarted")
        assertTrue(started.contains("shouldContinueStart(generation)"))
        val proofGate = "if (!hasReusableVpnDataPlaneProof(generation))"
        val firstProofGate = started.indexOf(proofGate)
        val tunHealth = started.indexOf("val tunHealth = awaitTunRuntimeHealthForStarted()")
        val secondProofGate = started.indexOf(proofGate, firstProofGate + proofGate.length)
        val startedPublication = started.indexOf("status.value = Status.Started")
        val failedPublication = started.indexOf("if (!marked)")
        val immediateWatchdog = started.indexOf(
            "requestRouteWatchdogCheck(\"VPN data-plane proof changed before Started\", delayMs = 0L)",
            failedPublication,
        )

        assertTrue("Started requires the first current-proof gate", firstProofGate >= 0)
        assertTrue("TUN health must settle after the first proof gate", tunHealth > firstProofGate)
        assertTrue("Started requires a second proof gate after TUN health settles", secondProofGate > tunHealth)
        assertTrue("the publication proof gate must run before Started", startedPublication > secondProofGate)
        assertTrue("failed publication must remain Starting", started.substring(secondProofGate, startedPublication).contains("status.value = Status.Starting"))
        assertTrue("failed publication must enter the immediate route watchdog", failedPublication > startedPublication)
        assertTrue("proof loss before publication must request an immediate watchdog check", immediateWatchdog > failedPublication)
        val continuationGuard = functionBody(source, "shouldContinueStart")
        assertTrue(continuationGuard.contains("ServiceLifecycleOwnership.isCurrent(serviceOwnerToken)"))
    }

    @Test
    fun `user stop is admitted directly to the active BoxService owner without a broadcast`() {
        val stop = functionBody(sourceFile("BoxService.kt"), "stop")

        val activeOwner = stop.indexOf("val instance = activeInstance")
        val directStop = stop.indexOf("instance.stopService()")
        val mainThreadPost = stop.indexOf("instance.mainHandler.post")
        val identityGuard = stop.indexOf("activeInstance === instance")

        assertTrue("user stop must snapshot the current in-process service owner", activeOwner >= 0)
        assertTrue("main-thread user stop must invoke that owner directly", directStop > activeOwner)
        assertTrue("off-main user stop must be posted to the snapped owner", mainThreadPost > activeOwner)
        assertTrue("posted stop must not target a replacement service instance", identityGuard > mainThreadPost)
        assertFalse("in-process user stop must not reopen the broadcast admission race", stop.contains("sendBroadcast"))
    }

    @Test
    fun `authoritative stop pins its initial owner instead of following a replacement`() {
        val await = functionBody(sourceFile("BoxService.kt"), "awaitAuthoritativeStop")

        val pinnedOwner = await.indexOf("val stoppedInstance = activeInstance ?: return true")
        val ownerCheck = await.indexOf("stoppedInstance.serviceOwnerToken != ownerToken")
        val stopJob = await.indexOf("val stopJob = stoppedInstance.serviceStopJob")
        val stoppedStatus = await.indexOf("stoppedInstance.status.value == Status.Stopped")
        val coreShutdown = await.indexOf("stoppedInstance.coreShutdownCompleted")

        assertTrue("await must capture the active owner exactly once", pinnedOwner >= 0)
        assertTrue("pinned owner token must reject a mismatched request", ownerCheck > pinnedOwner)
        assertTrue("await must join the pinned owner's stop job", stopJob > ownerCheck)
        assertTrue("completion must be read from the pinned owner", stoppedStatus > stopJob)
        assertTrue("completion must include pinned core shutdown", coreShutdown > stoppedStatus)
        assertFalse(
            "await must not follow activeInstance after taking its stoppedInstance snapshot",
            await.substring(pinnedOwner + "val stoppedInstance = activeInstance ?: return true".length).contains("activeInstance"),
        )
    }

    @Test
    fun `open tun always emits one secret-free structured outcome`() {
        val source = sourceFile("VPNService.kt")
        val openTun = functionBody(source, "openTun")

        assertTrue(openTun.contains("openTun request mtu="))
        assertTrue(openTun.contains("openTun outcome=success retained_fd_valid="))
        assertTrue(openTun.contains("openTun outcome=failure error_type="))
        assertTrue(openTun.contains("catch (error: Throwable)"))
    }

    @Test
    fun `VPN service constructs BoxService only after Android attaches its base context`() {
        val source = sourceFile("VPNService.kt")
        val onCreate = functionBody(source, "onCreate")
        val onDestroy = functionBody(source, "onDestroy")

        assertTrue(Regex("private\\s+lateinit\\s+var\\s+service\\s*:\\s*BoxService").containsMatchIn(source))
        assertFalse(
            "BoxService must not be created from a VPNService property initializer",
            Regex("private\\s+(?:[A-Za-z_][A-Za-z0-9_]*\\s+)*service(?:\\s*:\\s*BoxService)?\\s*=\\s*BoxService\\s*\\(")
                .containsMatchIn(source),
        )

        val superCreate = onCreate.indexOf("super.onCreate()")
        val serviceCreate = onCreate.indexOf("service = BoxService(this, this)")
        assertTrue("VPNService must call the Android lifecycle before resolving BoxService dependencies", superCreate >= 0)
        assertTrue("BoxService construction must follow super.onCreate", serviceCreate > superCreate)

        val destroyGuard = onDestroy.indexOf("if (::service.isInitialized)")
        val serviceDestroy = onDestroy.indexOf("service.onDestroy()")
        val superDestroy = onDestroy.indexOf("super.onDestroy()")
        assertTrue("destroy must tolerate a service that never reached onCreate", destroyGuard >= 0)
        assertTrue("BoxService destroy must remain inside the initialization guard", serviceDestroy > destroyGuard)
        assertTrue("VPNService must retain super.onDestroy in its finally path", Regex("}\\s*finally\\s*\\{").containsMatchIn(onDestroy))
        assertTrue("VPNService must always complete its Android destroy lifecycle", superDestroy > serviceDestroy)
    }

    @Test
    fun `proxy service constructs BoxService only after Android attaches its base context`() {
        val source = sourceFile("ProxyService.kt")
        val onCreate = functionBody(source, "onCreate")
        val onDestroy = functionBody(source, "onDestroy")

        assertTrue(Regex("private\\s+lateinit\\s+var\\s+service\\s*:\\s*BoxService").containsMatchIn(source))
        assertFalse(
            "BoxService must not be created from a ProxyService property initializer",
            Regex("private\\s+(?:[A-Za-z_][A-Za-z0-9_]*\\s+)*service(?:\\s*:\\s*BoxService)?\\s*=\\s*BoxService\\s*\\(")
                .containsMatchIn(source),
        )

        val superCreate = onCreate.indexOf("super.onCreate()")
        val serviceCreate = onCreate.indexOf("service = BoxService(this, this)")
        assertTrue("ProxyService must call the Android lifecycle before resolving BoxService dependencies", superCreate >= 0)
        assertTrue("BoxService construction must follow super.onCreate", serviceCreate > superCreate)

        val destroyGuard = onDestroy.indexOf("if (::service.isInitialized)")
        val serviceDestroy = onDestroy.indexOf("service.onDestroy()")
        val superDestroy = onDestroy.indexOf("super.onDestroy()")
        assertTrue("destroy must tolerate a service that never reached onCreate", destroyGuard >= 0)
        assertTrue("BoxService destroy must remain inside the initialization guard", serviceDestroy > destroyGuard)
        assertTrue("ProxyService must retain super.onDestroy in its finally path", Regex("}\\s*finally\\s*\\{").containsMatchIn(onDestroy))
        assertTrue("ProxyService must always complete its Android destroy lifecycle", superDestroy > serviceDestroy)
    }

    @Test
    fun `open tun passes and returns the same establisher descriptor with no dup or detach`() {
        val source = sourceFile("VPNService.kt")
        val openTun = functionBody(source, "openTun")

        val establish = openTun.indexOf("val pfd = builder.establish()")
        val replace = openTun.indexOf("service.replaceTunFileDescriptor(pfd)")
        val nativeFd = openTun.indexOf("val nativeFd = pfd.fd")
        val returnDescriptor = openTun.indexOf("return nativeFd")
        val establisherClose = openTun.indexOf("pfd.close()", establish)
        val establisherRelease = openTun.indexOf("pfd.detachFd()", establish)

        assertTrue(establish >= 0)
        assertTrue("openTun must keep descriptor ownership in ServiceLifecycle owner", replace >= 0)
        assertTrue("openTun must return the establisher fd directly or through a local alias", returnDescriptor >= 0)
        assertTrue(establish < replace)
        assertTrue(replace < returnDescriptor)
        assertFalse("dup() in descriptor handoff path leaks ownership model", openTun.substring(establish, returnDescriptor).contains("ParcelFileDescriptor.dup"))
        assertFalse("detachFd() in descriptor handoff path leaks ownership model", openTun.substring(establish, returnDescriptor).contains("detachFd()"))
        assertFalse(
            "descriptor must not be closed in handoff path",
            establisherClose in establish..returnDescriptor,
        )
        if (establisherRelease >= 0) {
            assertFalse(
                "detaching is not allowed when Kotlin owns the original descriptor",
                establisherRelease >= establish && establisherRelease < returnDescriptor,
            )
        }
    }

    @Test
    fun `stale service cleanup is rejected before it can reset a replacement owner`() {
        val staleOwner = ServiceLifecycleOwnership.acquire()
        ServiceLifecycleOwnership.acquire()

        assertFalse(
            ServiceLifecycleOwnership.beginCleanup(staleOwner) {
                throw AssertionError("stale cleanup must never run")
            },
        )

        val destroy = functionBody(sourceFile("BoxService.kt"), "onDestroy")
        val cleanupAccepted = destroy.indexOf("val cleanupAccepted = ServiceLifecycleOwnership.beginCleanup")
        val guardedReset = destroy.indexOf("if (cleanupAccepted)")
        val stoppedStatus = destroy.indexOf("status.value = Status.Stopped")
        assertTrue(cleanupAccepted >= 0)
        assertTrue(guardedReset > cleanupAccepted)
        assertTrue(stoppedStatus > guardedReset)
    }

    @Test
    fun `TUN creation and runtime health enforce a single Marten-owned generation`() {
        val vpnSource = sourceFile("VPNService.kt")
        assertTrue(Regex("@Synchronized\\s+override fun openTun").containsMatchIn(vpnSource))
        val openTun = functionBody(vpnSource, "openTun")
        val precondition = openTun.indexOf("service.requireTunCreationPrecondition()")
        val establish = openTun.indexOf("builder.establish()")
        assertTrue(precondition >= 0)
        assertTrue(establish > precondition)

        val health = functionBody(sourceFile("BoxService.kt"), "readTunRuntimeHealth")
        assertTrue(health.contains("val globalCandidateCount = if (tunnelsResult.isSuccess) tunnels.size else -1"))
        assertTrue(health.contains("val ownedCandidateCount = if (tunnelsResult.isSuccess) ownedTunnels.size else -1"))
        assertTrue(health.contains("ownedCandidateCount = ownedCandidateCount,"))
        assertTrue(health.contains("globalCandidateCount = globalCandidateCount,"))
        assertTrue(health.contains("inspection_ok=\${tunnelsResult.isSuccess}"))
        assertTrue(health.contains("isOwnedTunRuntimeHealthy("))
    }

    @Test
    fun `legacy SERVICE_RECOVER is consumed and never replaces the active service`() {
        val source = sourceFile("BoxService.kt")
        val onStart = functionBody(source, "onStartCommand")
        val legacyAction = onStart.indexOf("val processRecoveryRequested = intent?.action == Action.SERVICE_RECOVER")
        val cancel = onStart.indexOf("cancelLegacyProcessRecoveryAlarm()", legacyAction)
        val activeBranch = onStart.indexOf("if (status.value != Status.Stopped) {")
        val ignore = onStart.indexOf("ignoring system service restart while service is already active", activeBranch)

        assertTrue(legacyAction >= 0)
        assertTrue("the leftover PendingIntent must be cancelled immediately", cancel > legacyAction)
        assertTrue("active services only absorb legacy recovery commands", ignore > activeBranch)
        assertFalse("legacy recovery must not schedule another alarm", source.contains("scheduleProcessRecovery"))
        assertFalse("legacy recovery must not release an Activity binding", source.contains("releaseActivityServiceBindingForRecovery"))
        assertFalse("legacy recovery must not perform service replacement", source.contains("replaceVpnServiceAfterCoreCleanupFailure"))
    }

    @Test
    fun `TUN creation precondition waits only for an owned generation when ownership is known`() {
        val precondition = functionBody(sourceFile("BoxService.kt"), "requireTunCreationPrecondition")
        assertTrue(precondition.contains("isOwnedTunRuntimeQuiescent("))
        assertTrue(precondition.contains("ownVpnActive = health.ownVpnActive"))
        assertTrue(precondition.contains("ownershipKnown = health.ownershipKnown"))
        assertTrue(precondition.contains("globalCandidateCount = health.globalCandidateCount"))
        assertTrue(!precondition.contains("allowLingeringTunReplacement"))
        assertTrue(precondition.contains("Log.e(TAG, \"rejecting openTun while a previous generation is still active; \${health.summary}\")"))
        assertTrue(precondition.contains("error(\"android: previous TUN generation is still active\")"))
        assertTrue(precondition.contains("return"))
    }

    @Test
    fun `newly accepted start reopens TUN admission only after the prior close barrier`() {
        val start = functionBody(sourceFile("BoxService.kt"), "startService")
        val waitForPriorClose = start.indexOf("MobileCoreCloser.waitForCloseToFinish(\"service start\")")
        val admissionLock = start.indexOf("synchronized(fileDescriptorLock)", waitForPriorClose)
        val reopenAdmission = start.indexOf("tunDescriptorAdmissionClosed = false", admissionLock)
        val setup = start.indexOf("Mobile.setup(", reopenAdmission)

        assertTrue("start must wait for any in-flight native close", waitForPriorClose >= 0)
        assertTrue("accepted start must re-open descriptor admission under fileDescriptorLock", admissionLock > waitForPriorClose)
        assertTrue(reopenAdmission > admissionLock)
        assertTrue("descriptor admission must open before native setup", setup > reopenAdmission)
    }

    @Test
    fun `onStartCommand captures explicit user intent into VPN start marker`() {
        val onStart = functionBody(sourceFile("BoxService.kt"), "onStartCommand")
        val explicitRequest = onStart.indexOf("val explicitUserStartRequested =")
        val bypassMarker = onStart.indexOf("!restartedBySystem")
        val explicitExtra = onStart.indexOf("intent?.getBooleanExtra(Action.EXTRA_USER_INITIATED, false) == true")
        val explicitCapture = onStart.indexOf("explicitUserStartRequested && Settings.serviceMode == ServiceMode.VPN")
        val rejectedStart = onStart.indexOf("shouldRejectNewVpnStart(")
        val admissionOpen = onStart.indexOf("synchronized(fileDescriptorLock)")
        val markerStore = onStart.indexOf("explicitUserVpnStartPending =")

        assertTrue(explicitRequest >= 0)
        assertTrue(bypassMarker > explicitRequest)
        assertTrue(explicitExtra > explicitRequest)
        assertTrue("onStartCommand should pass user intent into rejection gate", onStart.contains("explicitUserStart = explicitUserStartRequested"))
        assertTrue(
            "onStartCommand should capture marker through service-mode-gated assignment",
            explicitCapture > explicitRequest,
        )
        val stoppedBranch = onStart.indexOf("if (status.value != Status.Stopped) {")
        assertTrue(stoppedBranch >= 0)
        assertTrue("capture should only happen after explicit rejected-start check", explicitCapture > rejectedStart)
        assertTrue("capture should only happen on accepted-start branch", explicitCapture > stoppedBranch)
        assertTrue(admissionOpen > rejectedStart)
        assertTrue("marker assignment should happen before descriptor admission reset", markerStore < admissionOpen)
    }

    @Test
    fun `explicit user-start marker resets on stop-path failure and descriptor replacement paths`() {
        val replace = functionBody(sourceFile("BoxService.kt"), "replaceTunFileDescriptor")
        val replaceReset = replace.indexOf("explicitUserVpnStartPending = false")
        val onTunCreationFailed = functionBody(sourceFile("BoxService.kt"), "onTunCreationFailed")
        val creationFailedReset = onTunCreationFailed.indexOf("explicitUserVpnStartPending = false")
        val stopService = functionBody(sourceFile("BoxService.kt"), "stopService")
        val stopReset = stopService.indexOf("explicitUserVpnStartPending = false")
        val stopAndAlert = functionBody(sourceFile("BoxService.kt"), "stopAndAlert")
        val stopAndAlertReset = stopAndAlert.indexOf("explicitUserVpnStartPending = false")
        val destroy = functionBody(sourceFile("BoxService.kt"), "onDestroy")
        val destroyReset = destroy.indexOf("explicitUserVpnStartPending = false")
        val onRevoke = functionBody(sourceFile("BoxService.kt"), "onRevoke")
        val revokeStopsService = onRevoke.indexOf("stopService(vpnRevoked = true)")

        assertTrue("replacement path should clear explicit marker", replaceReset >= 0)
        assertTrue("TUN creation failure should clear explicit marker", creationFailedReset >= 0)
        assertTrue("service stop entry should clear explicit marker", stopReset >= 0)
        assertTrue(
            "stop entry reset must happen before legacy cleanup cancellation",
            stopReset < stopService.indexOf("cancelLegacyProcessRecoveryAlarm()"),
        )
        assertTrue("service alert path should clear explicit marker", stopAndAlertReset >= 0)
        assertTrue("service destroy must clear explicit marker", destroyReset >= 0)
        assertTrue("revoke should clear marker through the shared stop path", revokeStopsService >= 0)
        assertFalse("onRevoke should not clear marker directly", onRevoke.contains("explicitUserVpnStartPending = false"))
    }

    @Test
    fun `ownership watchdog starts before native setup and retains ownership-loss checks without explicit takeover bypass`() {
        val source = sourceFile("BoxService.kt")
        val startService = functionBody(source, "startService")
        val resetOwnership = startService.indexOf("vpnOwnershipWasEstablished = false")
        val startWatchdog = startService.indexOf("startExternalVpnWatchdog()", resetOwnership)
        val nativeSetup = startService.indexOf("Mobile.setup(", startWatchdog)
        assertTrue(resetOwnership >= 0)
        assertTrue("watchdog must cover Builder.establish through route verification", startWatchdog > resetOwnership)
        assertTrue("watchdog must start before native Mobile.setup", nativeSetup > startWatchdog)

        val watchdog = functionBody(source, "startExternalVpnWatchdog")

        assertTrue(watchdog.contains("var consecutiveOwnVpnMisses = 0"))
        assertTrue(watchdog.contains("if (ownership.active)"))
        assertTrue(watchdog.contains("vpnOwnershipWasEstablished = true"))
        assertFalse(watchdog.contains("explicitVpnTakeoverPending"))
        assertTrue(watchdog.contains("if (!ownership.known || !vpnOwnershipWasEstablished)"))
        assertTrue(watchdog.contains("consecutiveOwnVpnMisses = 0"))
        assertTrue(watchdog.contains("consecutiveOwnVpnMisses += 1"))
        assertTrue(watchdog.contains("shouldStopForLostVpnOwnership("))
        assertTrue(watchdog.contains("requiredMisses = EXTERNAL_VPN_OWNERSHIP_LOSS_CONFIRMATIONS"))
        assertTrue(watchdog.contains("stopForExternalVpnOnMain("))
    }

    @Test
    fun `TUN precondition forwards explicit user-start marker as platform replacement allow and has no explicit bypass`() {
        val boxSource = sourceFile("BoxService.kt")
        val precondition = functionBody(boxSource, "requireTunCreationPrecondition")
        val onStart = functionBody(boxSource, "onStartCommand")

        assertTrue(
            "TUN precondition should derive platform-replacement allow from explicit marker",
            precondition.contains("val allowPlatformVpnReplacement = explicitUserVpnStartPending"),
        )
        assertTrue(
            "TUN precondition should pass marker into ownership rejection",
            precondition.contains("explicitUserStart = allowPlatformVpnReplacement"),
        )
        assertTrue(
            "TUN precondition should forward marker into runtime-owned quiescence gate",
            precondition.contains("allowPlatformVpnReplacement = allowPlatformVpnReplacement"),
        )
        assertTrue(onStart.contains("explicitUserStart = explicitUserStartRequested"))
        assertFalse(onStart.contains("explicitUserStart = true"))
        assertFalse(precondition.contains("explicitUserStart = true"))
    }

    @Test
    fun `TileService and boot restore use shared BoxService connect contract without explicit takeover bypass`() {
        val tile = sourceFile("TileService.kt")
        val toggle = functionBody(tile, "toggleService")
        val requestUserConnect = functionBody(tile, "requestUserConnect")
        assertFalse(toggle.contains("userInitiated ="))
        assertFalse(toggle.contains("EXTRA_USER_INITIATED"))
        assertFalse(toggle.contains("explicit takeover"))
        assertTrue(toggle.contains("requestUserConnect()"))
        assertTrue(requestUserConnect.contains("VpnPermissionActivity"))

        val boot = sourceFile("BootReceiver.kt")
        val receive = functionBody(boot, "onReceive")
        assertFalse(receive.contains("userInitiated ="))
        assertFalse(receive.contains("EXTRA_USER_INITIATED"))
        assertFalse(receive.contains("explicit takeover"))
        assertTrue(receive.contains("BoxService.connect()"))
    }

    @Test
    fun `legacy recovery has no Activity binding release or delayed reconnect path`() {
        val source = sourceFile("BoxService.kt")
        assertFalse(source.contains("releaseActivityServiceBindingForRecovery"))
        assertFalse(source.contains("PROCESS_RECOVERY_REBIND_DELAY_MS"))
        assertFalse(source.contains("MainActivity.instance"))
    }

    @Test
    fun `core cleanup closes descriptor retires platform VPN and waits for TUN release`() {
        val source = sourceFile("BoxService.kt")
        val cleanup = functionBody(source, "closeMobileCoreAndAwaitTunQuiescence")
        val descriptorClose = cleanup.indexOf("closeTunFileDescriptor()")
        val coreClose = cleanup.indexOf("MobileCoreCloser.closeBlocking(reason)")
        val releaseDeadline = Regex(
            "val\\s+releaseDeadlineElapsedRealtimeMs\\s*=\\s*SystemClock\\.elapsedRealtime\\s*\\(\\s*\\)\\s*\\+\\s*TUN_RELEASE_TIMEOUT_MS",
        ).find(cleanup)?.range?.first ?: -1
        val platformRetirement = cleanup.indexOf("val platformVpnRetired = if (")
        val platformRetirementCall = cleanup.indexOf(
            "retirePlatformVpnSessionAfterCoreStop(",
            platformRetirement,
        )
        val platformDeadlineArg = cleanup.indexOf(
            "releaseDeadlineElapsedRealtimeMs",
            platformRetirementCall + 1,
        )
        val tunWait = cleanup.indexOf("awaitTunRuntimeQuiescence(")
        val tunDeadlineArg = cleanup.indexOf("releaseDeadlineElapsedRealtimeMs", tunWait + 1)
        val result = cleanup.indexOf("CoreCleanupResult(closeCompleted && platformVpnRetired, tunQuiescent)")
        assertTrue(descriptorClose >= 0)
        assertTrue(coreClose > descriptorClose)
        assertTrue("platform VPN retirement must follow a completed native close", platformRetirement > coreClose)
        assertTrue(
            "release deadline must start before native close so a stuck close cannot add another TUN grace period",
            releaseDeadline >= 0 && releaseDeadline < descriptorClose,
        )
        assertTrue("platform retirement must use shared release deadline", platformRetirementCall > platformRetirement)
        assertTrue(
            "platform retirement and TUN release should share same computed deadline",
            platformDeadlineArg in (platformRetirementCall + 1 until tunWait) &&
                tunDeadlineArg > tunWait,
        )
        assertTrue(tunWait > platformRetirement)
        assertTrue(result > tunWait)
        val closeFailed = functionBody(source, "closeFailedRecoveryRuntime")
        assertTrue(closeFailed.contains("val cleanupResult = closeMobileCoreAndAwaitTunQuiescence(reason)"))
        assertTrue(closeFailed.contains("cleanupResult.completed"))
    }

    @Test
    fun `TUN cleanup waits 5000ms grace before fail-closed termination`() {
        val source = sourceFile("BoxService.kt")

        val timeout = Regex("private const val TUN_RELEASE_TIMEOUT_MS =\\s*([0-9_]+L)").find(source)
        assertTrue("TUN cleanup timeout constant must be defined", timeout != null)
        val timeoutMs = timeout!!.groupValues[1].replace("_", "").removeSuffix("L").toLong()
        assertTrue(
            "Android TUN cleanup must wait at least 5_000 ms before fail-closed termination",
            timeoutMs >= 5_000L,
        )

        val awaitTun = functionBody(source, "awaitTunRuntimeQuiescence")
        val elapsedGuard = awaitTun.indexOf(
            "SystemClock.elapsedRealtime() < releaseDeadlineElapsedRealtimeMs",
        )
        val releaseArg = awaitTun.indexOf("releaseDeadlineElapsedRealtimeMs")
        val delayPoll = awaitTun.indexOf("delay(TUN_RELEASE_POLL_MS)")
        val returnResult = awaitTun.indexOf("return quiescent")
        assertTrue(
            "awaitTunRuntimeQuiescence must accept shared deadline argument",
            releaseArg >= 0,
        )
        assertTrue("awaitTunRuntimeQuiescence must exit only after deadline", elapsedGuard >= 0)
        assertTrue(
            "awaitTunRuntimeQuiescence must actively poll while waiting",
            delayPoll > elapsedGuard,
        )
        assertTrue(
            "awaitTunRuntimeQuiescence must return quiescence outcome",
            returnResult > delayPoll,
        )

        val cleanup = functionBody(source, "closeMobileCoreAndAwaitTunQuiescence")
        assertTrue(
            "cleaning mobile core must close descriptor first",
            cleanup.contains("closeTunFileDescriptor()"),
        )
        assertTrue(
            "mobile core close must run before tun quiescence wait",
            cleanup.indexOf("MobileCoreCloser.closeBlocking(reason)") > cleanup.indexOf("closeTunFileDescriptor()"),
        )
        val tunDeadlineShared = Regex(
            "awaitTunRuntimeQuiescence\\s*\\(\\s*reason\\s*,\\s*serviceStopping\\s*,\\s*releaseDeadlineElapsedRealtimeMs\\s*,?\\s*\\)",
        ).find(cleanup)?.range?.first ?: -1
        assertTrue(
            "TUN quiescence must be awaited after close",
            tunDeadlineShared > cleanup.indexOf("MobileCoreCloser.closeBlocking(reason)"),
        )
        assertTrue(
            "shared deadline argument should be threaded into TUN quiescence",
            tunDeadlineShared > Regex(
                "val\\s+releaseDeadlineElapsedRealtimeMs\\s*=\\s*SystemClock\\.elapsedRealtime\\s*\\(\\s*\\)\\s*\\+\\s*TUN_RELEASE_TIMEOUT_MS",
            ).find(cleanup)?.range?.first.orEmptyIndex(),
        )

        val stopService = functionBody(source, "stopService")
        val stopQuiescence = stopService.indexOf("closeMobileCoreAndAwaitTunQuiescence")
        val stopGuard = findCleanupFailureGuard(stopService)
        val terminalFailure = stopService.indexOf("finishCoreCleanupFailure(", stopGuard)
        val terminalReturn = stopService.indexOf("return@launch", terminalFailure)
        assertTrue("disconnect/cancel flow must await cleanup before hard kill check", stopQuiescence >= 0)
        assertTrue("disconnect/cancel flow must evaluate termination requirement", stopGuard > stopQuiescence)
        assertTrue("failed cleanup must enter the one terminal fail-closed handler", terminalFailure > stopGuard)
        assertTrue("manual stop must not continue normal cleanup after terminal failure", terminalReturn > terminalFailure)
        assertFalse("disconnect/cancel path must not bypass guard with direct kill", stopService.contains("android.os.Process.killProcess"))
        assertTrue(
            "service stop cleanup must use serviceStopping=true",
            Regex("closeMobileCoreAndAwaitTunQuiescence\\([\\s\\S]*\"service stop\"[\\s\\S]*serviceStopping\\s*=\\s*true[\\s\\S]*\\)").containsMatchIn(stopService),
        )
    }

    @Test
    fun `completed native stop retires the exact marker VPN only after Android publishes it`() {
        val vpnService = sourceFile("VPNService.kt")
        val retire = functionBody(vpnService, "retirePlatformVpnSessionAfterCoreStop")
        val session = Regex("setSession\\s*\\(\\s*\"marten-stop\"\\s*\\)")
            .find(retire)?.range?.first ?: -1
        val establish = Regex("\\.establish\\s*\\(").find(retire)?.range?.first ?: -1
        val awaitPublication = retire.indexOf("awaitPlatformVpnRetirementNetwork(")
        val close = Regex("retirementDescriptor\\s*\\.\\s*close\\s*\\(").find(retire)?.range?.first ?: -1
        val awaitRelease = retire.indexOf("awaitPlatformVpnRetirementRelease(")

        assertTrue("retirement must create the local marker session", session >= 0)
        assertTrue("marker session must be established before it is observed", establish > session)
        assertTrue(
            "descriptor must stay open until the marker Network is discovered",
            awaitPublication > establish,
        )
        assertTrue(
            "descriptor must close only after marker Network discovery",
            close > awaitPublication,
        )
        assertTrue("retirement must await release after closing the descriptor", awaitRelease > close)
        assertFalse(
            "teardown TUN must never be handed to the core owner",
            retire.contains("replaceTunFileDescriptor"),
        )
        assertFalse(
            "framework teardown must not restart or re-open the native core",
            retire.contains("Mobile."),
        )
        assertFalse("retirement must not call activity-based VPN flows", retire.contains("prepare("))
        assertFalse("retirement must not route through helper or generic marker channels", retire.contains("MobileCoreLifecycle"))

        val awaitPublicationBody = functionBody(
            vpnService,
            "awaitPlatformVpnRetirementNetwork",
        )
        assertTrue(
            "marker wait must search for the retirement Network",
            awaitPublicationBody.contains("findPlatformVpnRetirementNetwork(connectivity)"),
        )
        assertTrue(
            "marker wait must use the caller's release deadline",
            awaitPublicationBody.contains("releaseDeadlineElapsedRealtimeMs"),
        )
        assertFalse(
            "marker publication wait must not start a separate retirement timeout",
            Regex("SystemClock\\.elapsedRealtime\\s*\\(\\s*\\)\\s*\\+\\s*PLATFORM_VPN_RETIREMENT_TIMEOUT_MS")
                .containsMatchIn(awaitPublicationBody),
        )

        val awaitReleaseBody = functionBody(vpnService, "awaitPlatformVpnRetirementRelease")
        assertTrue(
            "release wait must observe the exact Network returned by marker discovery",
            Regex("allNetworks\\s*\\.any\\s*\\{\\s*it\\s*==\\s*retirementNetwork\\s*}")
                .containsMatchIn(awaitReleaseBody),
        )
        assertTrue(
            "release wait must use the same caller-provided deadline",
            awaitReleaseBody.contains("releaseDeadlineElapsedRealtimeMs"),
        )
        assertFalse(
            "release wait must not start a second independent retirement timeout",
            Regex("SystemClock\\.elapsedRealtime\\s*\\(\\s*\\)\\s*\\+\\s*PLATFORM_VPN_RETIREMENT_TIMEOUT_MS")
                .containsMatchIn(awaitReleaseBody),
        )

        val markerFinder = functionBody(vpnService, "findPlatformVpnRetirementNetwork")
        assertTrue(
            "marker discovery must restrict candidates to VPN transport",
            markerFinder.contains("TRANSPORT_VPN"),
        )
        assertTrue(
            "marker discovery must inspect the configured marker address",
            markerFinder.contains("PLATFORM_VPN_RETIREMENT_ADDRESS"),
        )
        assertTrue(
            "marker discovery must delegate ownership and marker validation to the pure policy",
            markerFinder.contains("isMartenRetirementNetworkCandidate("),
        )

        val stop = functionBody(sourceFile("BoxService.kt"), "stopService")
        val completed = stop.indexOf("coreClosed.completed")
        val shouldRetireCall = stop.indexOf("if (shouldRetirePlatformVpnAfterCoreStop(", completed)
        val retireCall = stop.indexOf("retirePlatformVpnSessionAfterCoreStop", completed)
        val cleanupGuard = stop.indexOf("requiresCoreCleanupEscalation(", shouldRetireCall)
        val retirementGateStart = if (retireCall >= 0) retireCall else shouldRetireCall
        val retirementGateEnd = if (cleanupGuard >= 0) cleanupGuard else stop.length
        val ownershipRevokedGate = stop.indexOf("!vpnOwnershipRevoked &&", retirementGateStart)
        val externalGate = stop.indexOf(
            "!isExternalVpnActive(service, \"platform VPN retirement final gate\")",
            retirementGateStart,
        )
        val stopped = stop.indexOf("status.value = Status.Stopped", completed)
        assertTrue(completed >= 0)
        assertTrue("retirement decision should guard legacy core stop completion path", shouldRetireCall > completed)
        assertTrue("framework teardown follows completed core and retained-TUN cleanup", retireCall > completed)
        assertTrue(
            "retirement should run only while ownership is intact and no external VPN is active",
            ownershipRevokedGate in (retireCall + 1 until retirementGateEnd),
        )
        assertTrue(
            "retirement should pass the same external VPN gate before executing replacement TUN",
            externalGate in (ownershipRevokedGate + 1 until retirementGateEnd),
        )
        assertTrue("lambda gates must execute before cleanup replacement decision", cleanupGuard > ownershipRevokedGate)
        assertTrue("lambda gates must execute before cleanup replacement decision", cleanupGuard > externalGate)
        assertTrue("manual disconnect still reaches Stopped after framework teardown", stopped > retireCall)
    }

    @Test
    fun `terminal cleanup paths use tolerant TUN release completion for service stop, cancel, alert, and destroy`() {
        val source = sourceFile("BoxService.kt")

        val finishCancelledStart = functionBody(source, "finishCancelledStart")
        assertTrue(finishCancelledStart.contains("closeMobileCoreAndAwaitTunQuiescence("))
        assertTrue(finishCancelledStart.contains("serviceStopping = true"))
        assertTrue(finishCancelledStart.contains("finishCoreCleanupFailure("))
        val stopService = functionBody(source, "stopService")
        assertTrue(stopService.contains("closeMobileCoreAndAwaitTunQuiescence("))
        assertTrue(stopService.contains("\"service stop\""))
        assertTrue(stopService.contains("serviceStopping = true"))
        assertTrue(stopService.contains("finishCoreCleanupFailure("))
        assertTrue(stopService.contains("service.stopSelf()"))
        val stopAndAlert = functionBody(source, "stopAndAlert")
        assertTrue(stopAndAlert.contains("closeMobileCoreAndAwaitTunQuiescence("))
        assertTrue(stopAndAlert.contains("\"service alert\""))
        assertTrue(stopAndAlert.contains("serviceStopping = true"))
        assertTrue(stopAndAlert.contains("finishCoreCleanupFailure("))
        assertTrue(stopAndAlert.contains("service.stopSelf()"))
        val onDestroy = functionBody(source, "onDestroy")
        assertTrue(onDestroy.contains("closeMobileCoreAndAwaitTunQuiescence("))
        assertTrue(onDestroy.contains("\"service destroy\""))
        assertTrue(onDestroy.contains("serviceStopping = true"))
    }

    @Test
    fun `reconnect cleanup must stay strict about zero-candidate TUN quiescence`() {
        val source = sourceFile("BoxService.kt")
        val reload = functionBody(source, "serviceReload0")
        val recover = functionBody(source, "recoverMobileCore")
        val closeFailed = functionBody(source, "closeFailedRecoveryRuntime")

        assertFalse(
            "service reload recovery flow should not pass serviceStopping=true",
            reload.contains("serviceStopping = true"),
        )
        assertFalse(
            "core watchdog recovery flow should not pass serviceStopping=true",
            recover.contains("serviceStopping = true"),
        )
        assertFalse(
            "closeFailedRecoveryRuntime should keep reconnect mode",
            closeFailed.contains("serviceStopping = true"),
        )
        assertTrue(reload.contains("closeMobileCoreAndAwaitTunQuiescence(\"service reload\")"))
        assertTrue(
            recover.contains("closeMobileCoreAndAwaitTunQuiescence(") &&
                recover.contains("\"core watchdog recovery attempt ${'$'}attempt\""),
        )
        assertTrue(closeFailed.contains("closeMobileCoreAndAwaitTunQuiescence(reason)"))
    }

    @Test
    fun `awaitTunRuntimeQuiescence checks serviceStopping argument for terminal cleanup path`() {
        val source = sourceFile("BoxService.kt")
        assertTrue(
            "closeMobileCoreAndAwaitTunQuiescence must forward serviceStopping into awaitTunRuntimeQuiescence",
            Regex(
                "awaitTunRuntimeQuiescence\\s*\\(\\s*reason\\s*,\\s*serviceStopping\\s*,\\s*releaseDeadlineElapsedRealtimeMs\\s*,?\\s*\\)",
            ).containsMatchIn(
                functionBody(source, "closeMobileCoreAndAwaitTunQuiescence"),
            ),
        )
        val stopService = functionBody(source, "stopService")
        assertTrue(
            Regex("closeMobileCoreAndAwaitTunQuiescence\\([\\s\\S]*\"service stop\"[\\s\\S]*serviceStopping\\s*=\\s*true[\\s\\S]*\\)").containsMatchIn(
                stopService,
            ),
        )
    }

    @Test
    fun `recovery and stop paths terminate before setup retry or terminal stopped on failed cleanup`() {
        val source = sourceFile("BoxService.kt")
        val recovery = functionBody(source, "recoverMobileCore")
        val cleanup = recovery.indexOf("closeMobileCoreAndAwaitTunQuiescence(")
        val cleanupFailure = recovery.indexOf("preparationCleanupFailed = true", cleanup)
        val setupBlocked = recovery.indexOf("return@run false", cleanupFailure)
        val setup = recovery.indexOf("Mobile.setup(", cleanup)
        val terminalFailure = recovery.indexOf("finishCoreCleanupFailure(", cleanupFailure)
        val terminalReturn = recovery.indexOf("return", terminalFailure)
        val retry = recovery.indexOf("core watchdog recovery retry scheduled", terminalFailure)
        assertTrue(cleanup >= 0)
        assertTrue(cleanupFailure > cleanup)
        assertTrue(setupBlocked > cleanupFailure)
        assertTrue(setup > setupBlocked)
        assertTrue(terminalFailure > setup)
        assertTrue(terminalReturn > terminalFailure)
        assertTrue("terminal cleanup failure must return before any later retry branch", retry > terminalReturn)

        assertCleanupFailureTerminatesThroughTerminalHandler(source, "stopService", "return@launch")
        assertCleanupFailureTerminatesThroughTerminalHandler(source, "stopAndAlert", "return@runNonCancellableServiceCleanup")
    }

    @Test
    fun `service stop must coalesce terminal cleanup instead of short-circuiting at stopping state`() {
        val source = sourceFile("BoxService.kt")
        val stopService = functionBody(source, "stopService")
        assertTrue(
            "service stop should use the concrete Job-based coalescing guard",
            source.contains("private var serviceStopJob: Job? = null"),
        )
        assertTrue(
            "service stop should gate duplicate stop requests with serviceStopJob?.isActive",
            stopService.contains("if (serviceStopJob?.isActive == true)"),
        )
        assertTrue(
            "service stop should create a lazy stop coroutine job",
            stopService.contains("val newStopJob = serviceScope.launch(") &&
                stopService.contains("start = CoroutineStart.LAZY"),
        )
        assertTrue(
            "service stop should assign and start the new stop job",
            stopService.contains("serviceStopJob = newStopJob") &&
                stopService.contains("newStopJob.start()"),
        )

        assertFalse(
            "manual service stop must no longer return directly while status==Stopping",
            stopService.contains("if (status.value == Status.Stopping && !vpnRevoked) return"),
        )
        assertTrue(
            "manual service stop should invoke terminal TUN/core cleanup with serviceStopping=true",
            Regex("closeMobileCoreAndAwaitTunQuiescence\\([\\s\\S]*\"service stop\"[\\s\\S]*serviceStopping\\s*=\\s*true[\\s\\S]*\\)").containsMatchIn(
                stopService,
            ),
        )
        assertTrue(
            "manual service stop should still stop foreground service after closedown",
            stopService.contains("service.stopSelf()"),
        )
    }

    @Test
    fun `manual stop cancels the one possible legacy SERVICE_RECOVER PendingIntent`() {
        val source = sourceFile("BoxService.kt")
        val stopService = functionBody(source, "stopService")
        val cancel = stopService.indexOf("cancelLegacyProcessRecoveryAlarm()")
        val stopGeneration = stopService.indexOf("val stopGeneration = cancelPendingStarts()")

        assertTrue("manual stop must cancel an old leftover alarm", cancel >= 0)
        assertTrue("legacy cancellation belongs before stop generation teardown", cancel < stopGeneration)
        assertFalse("manual stop must never schedule recovery alarms", stopService.contains("scheduleProcessRecovery"))
    }

    @Test
    fun `legacy SERVICE_RECOVER is cancellation-only and cannot cause replacement scheduling`() {
        val source = sourceFile("BoxService.kt")
        val onStart = functionBody(source, "onStartCommand")
        val marker = onStart.indexOf("if (processRecoveryRequested) {")
        val cancellation = onStart.indexOf("cancelLegacyProcessRecoveryAlarm()", marker)
        assertTrue(marker >= 0)
        assertTrue(cancellation > marker)
        assertFalse(onStart.contains("scheduleProcessRecovery"))
        assertFalse(onStart.contains("startActivity("))
        assertFalse(onStart.contains("disconnectServiceBinding"))
    }

    @Test
    fun `releaseStoppedPlatformService must unbind activity before stopping platform service`() {
        val source = File("src/main/kotlin/app/marten/client/MethodHandler.kt").readText()
        val releaseStoppedPlatformService = functionBody(source, "releaseStoppedPlatformService")
        val unbindIndex = releaseStoppedPlatformService.indexOf("mainActivity.disconnectServiceBinding()")
        val stopIndex = releaseStoppedPlatformService.indexOf(
            "appContext.stopService(Intent(appContext, Settings.serviceClass()))",
        )

        assertTrue("release must explicitly unbind the activity", unbindIndex >= 0)
        assertTrue("release must stop the configured platform service", stopIndex >= 0)
        assertTrue("activity binding must be released before service teardown", unbindIndex < stopIndex)
    }

    @Test
    fun `failed cleanup enters exactly one fail-closed terminal transition without alarm or process kill`() {
        val source = sourceFile("BoxService.kt")
        val terminal = functionBody(source, "finishCoreCleanupFailure")
        assertTrue(terminal.contains("terminalCoreCleanupFailurePublished"))
        assertTrue(terminal.contains("Settings.startedByUser = false"))
        assertTrue(terminal.contains("cancelLegacyProcessRecoveryAlarm()"))
        assertTrue(terminal.contains("MobileCoreCloser.closeAsync(\"terminal core cleanup failure\")"))
        assertTrue(terminal.contains("status.value = Status.Stopping"))
        assertTrue(terminal.contains("retirePlatformVpnSessionAfterFailedCoreCleanup"))
        assertTrue(terminal.contains("status.value = Status.Stopped"))
        assertTrue(terminal.contains("notification.showStopped(activeProfileName)"))
        assertTrue(terminal.contains("callback.onServiceAlert(Alert.StartService.ordinal, userMessage)"))
        assertTrue(terminal.contains("service.stopSelf()"))
        assertFalse(terminal.contains("scheduleProcessRecovery"))
        assertFalse(terminal.contains("disconnectServiceBinding"))
        assertFalse(source.contains("android.os.Process.killProcess"))
    }

    @Test
    fun `BoxService production code never hard-kills app process for cleanup fallback`() {
        val source = sourceFile("BoxService.kt")
        assertFalse("killProcess should not be used in BoxService production path", source.contains("android.os.Process.killProcess"))
    }

    @Test
    fun `both native startup paths arm monitor and watchdog before starting mobile core`() {
        val source = sourceFile("BoxService.kt")
        val serviceStart = functionBody(source, "startService")
        val serviceNativeStart = serviceStart.indexOf("val startCoreInService = Settings.startCoreAfterStartingService")
        val serviceMonitor = serviceStart.indexOf("startCoreRuntimeMonitor(nativeStartup = true)", serviceNativeStart)
        val serviceWatchdog = serviceStart.indexOf("startCoreWatchdog()", serviceMonitor)
        val serviceMobileStart = serviceStart.indexOf("startMobileCoreFromNativePath(", serviceWatchdog)

        assertTrue(serviceNativeStart >= 0)
        assertTrue(serviceMonitor > serviceNativeStart)
        assertTrue(serviceWatchdog > serviceMonitor)
        assertTrue(serviceMobileStart > serviceWatchdog)

        val nativeEntry = functionBody(source, "startStoredCoreFromNativeEntryPoint")
        val entryMonitor = nativeEntry.indexOf("startCoreRuntimeMonitor(nativeStartup = true)")
        val entryWatchdog = nativeEntry.indexOf("startCoreWatchdog()")
        val entryMobileStart = nativeEntry.indexOf("startMobileCoreFromNativePath(")

        assertTrue(entryMonitor >= 0)
        assertTrue(entryWatchdog > entryMonitor)
        assertTrue(entryMobileStart > entryWatchdog)
    }

    @Test
    fun `native startup monitor uses its own bounded thresholds and wider route verification timeout`() {
        val source = sourceFile("BoxService.kt")
        val monitor = functionBody(source, "startCoreRuntimeMonitor")
        val nativeTimeoutStart = source.indexOf("private fun nativeUnverifiedStartupRecoveryTimeoutMs")
        val nativeTimeoutEnd = source.indexOf("private fun stopCoreRuntimeMonitor", nativeTimeoutStart)
        val nativeTimeout = source.substring(nativeTimeoutStart, nativeTimeoutEnd)

        assertTrue(source.contains("private const val CORE_NATIVE_START_GRACE_MS"))
        assertTrue(source.contains("private const val CORE_NATIVE_STARTING_STALL_MS"))
        assertTrue(source.contains("private const val CORE_FLUTTER_START_GRACE_MS"))
        assertTrue(source.contains("private const val CORE_FLUTTER_STARTING_STALL_MS"))
        assertTrue(monitor.contains("if (nativeStartup) CORE_NATIVE_START_GRACE_MS else CORE_FLUTTER_START_GRACE_MS"))
        assertTrue(monitor.contains("if (nativeStartup) CORE_NATIVE_STARTING_STALL_MS else CORE_FLUTTER_STARTING_STALL_MS"))
        assertTrue(
            monitor.contains(
                "if (nativeStartup) nativeUnverifiedStartupRecoveryTimeoutMs() else unverifiedStartupRecoveryTimeoutMs()",
            ),
        )
        assertTrue(nativeTimeoutStart >= 0)
        assertTrue(nativeTimeoutEnd > nativeTimeoutStart)
        assertTrue(nativeTimeout.contains("unverifiedStartupRecoveryTimeoutMs() + ROUTE_WATCHDOG_GRPC_TIMEOUT_MS"))
    }

    @Test
    fun `route unavailability from every startup signal enters recovery admission rather than terminal Stop Close`() {
        val source = sourceFile("BoxService.kt")
        val routeVerificationSignals = listOf(
            "startService",
            "startStoredCoreFromNativeEntryPoint",
            "verifyAndMarkCoreRuntimeStarted",
            "acknowledgeVerifiedRouteFromFlutter",
        )
        routeVerificationSignals.forEach { name ->
            val body = functionBody(source, name)
            assertFalse(
                "$name must not convert transient route unavailability into terminal service stop",
                body.contains("stopServiceOnRouteFailure = true"),
            )
        }

        val runtimeRecoverySites = listOf(
            "startCoreRuntimeMonitor",
            "markCoreRuntimeStarted",
            "startCoreWatchdog",
            "recoverRoute",
        )
        runtimeRecoverySites.forEach { name ->
            val body = functionBody(source, name)
            assertTrue("$name must request recovery through the admission gate", body.contains("requestCoreRecovery("))
            assertFalse("$name must not bypass the recovery admission gate", body.contains("launchCoreRecovery("))
        }

        val nativeProof = functionBody(source, "verifyNativeStartupRoute")
        assertTrue("failed native route proof must use recovery admission", nativeProof.contains("requestCoreRecovery("))
        assertFalse("native route proof must not bypass recovery admission", nativeProof.contains("launchCoreRecovery("))
        val request = functionBody(source, "requestCoreRecovery")
        assertTrue(request.contains("if (launchCoreRecovery(reason, generation)) return true"))
        assertTrue(request.contains("if (launchCoreRecovery(reason, generation)) {"))
    }

    @Test
    fun `recovery admission retries one guarded job until cancelled or admitted`() {
        val source = sourceFile("BoxService.kt")
        val request = functionBody(source, "requestCoreRecovery")
        val retryAssignment = Regex("coreRecoveryAdmissionRetryJob\\s*=\\s*scheduled").findAll(request).count()
        val loop = request.indexOf("while (currentCoroutineContext().isActive && shouldWatchCore(generation))")
        val delay = request.indexOf("delay(CORE_RECOVERY_BACKOFF_MS)", loop)
        val retryLaunch = request.indexOf("if (launchCoreRecovery(reason, generation))", delay)

        assertTrue(request.contains("if (coreRecoveryAdmissionRetryJob?.isActive == true)"))
        assertTrue(retryAssignment == 1)
        assertTrue(loop >= 0)
        assertTrue(delay > loop)
        assertTrue(retryLaunch > delay)
        assertTrue(request.contains("core recovery admitted after"))
        assertTrue(request.contains("core recovery admission remains pending"))
        assertTrue(request.contains("core recovery admission retry scheduled"))

        val stopWatchdog = functionBody(source, "stopCoreWatchdog")
        val markStarted = functionBody(source, "markCoreRuntimeStarted")
        assertTrue(stopWatchdog.contains("cancelCoreRecoveryAdmissionRetry()"))
        assertTrue(markStarted.contains("cancelCoreRecoveryAdmissionRetry()"))
        assertTrue(markStarted.indexOf("cancelCoreRecoveryAdmissionRetry()") < markStarted.indexOf("status.value = Status.Started"))
    }

    @Test
    fun `Android teardown has one MobileCoreCloser ownership path with no direct native stop`() {
        val service = sourceFile("BoxService.kt")
        val serviceWithoutLineComments = service
            .lines()
            .filter { !it.trimStart().startsWith("//") && !it.trimStart().startsWith("*") }
            .joinToString("\n")
        val closer = File("src/main/kotlin/app/marten/client/bg/MobileCoreCloser.kt").readText()

        assertFalse(
            "BoxService cleanup must not issue an uncoordinated Mobile.stop",
            Regex("\\bMobile\\s*\\.\\s*stop\\s*\\(").containsMatchIn(serviceWithoutLineComments),
        )
        assertFalse(
            "BoxService cleanup must not bypass the shared closer with Mobile.close",
            Regex("\\bMobile\\s*\\.\\s*close\\s*\\(").containsMatchIn(serviceWithoutLineComments),
        )
        assertTrue(
            "the one native close worker must be lifecycle-exclusive",
            closer.contains("MobileCoreLifecycle.run") &&
                closer.contains("Mobile.close(4L)"),
        )
        assertTrue(
            "the close worker must own the blocking lifecycle bridge rather than callers",
            closer.contains("runBlocking") &&
                closer.indexOf("runBlocking") < closer.indexOf("MobileCoreLifecycle.run"),
        )

        listOf(
            "finishCancelledStart",
            "serviceReload0",
            "closeFailedRecoveryRuntime",
            "stopService",
            "stopAndAlert",
            "onDestroy",
        ).forEach { cleanupPath ->
            val body = functionBody(service, cleanupPath)
            assertFalse(
                "$cleanupPath must not hold MobileCoreLifecycle while awaiting native cleanup",
                body.contains("MobileCoreLifecycle.run") &&
                    body.contains("closeMobileCoreAndAwaitTunQuiescence("),
            )
        }
    }

    @Test
    fun `manual stop seals and closes TUN before duplicate or revoke coalescing`() {
        val stop = functionBody(sourceFile("BoxService.kt"), "stopService")
        val seal = stop.indexOf("tunDescriptorAdmissionClosed = true")
        val closeDescriptor = stop.indexOf("closeTunFileDescriptor()", seal)
        val duplicateGuard = stop.indexOf("if (serviceStopJob?.isActive == true)")
        val nativeCloseWait = stop.indexOf("closeMobileCoreAndAwaitTunQuiescence(")

        assertTrue("stop must atomically seal TUN descriptor admission", seal >= 0)
        assertTrue("manual stop must close the retained Android TUN descriptor eagerly", closeDescriptor > seal)
        assertTrue("duplicate stop requests must join the service stop job", duplicateGuard > closeDescriptor)
        assertTrue("TUN teardown must precede the eventual native close wait", nativeCloseWait > duplicateGuard)
        assertFalse(
            "VPN revoke must coalesce with the same stop job instead of spawning another teardown",
            stop.contains("if (serviceStopJob?.isActive == true &&"),
        )

        val revoke = functionBody(sourceFile("BoxService.kt"), "onRevoke")
        assertTrue("Android revoke must enter the common stop coordinator", revoke.contains("stopService(vpnRevoked = true)"))
        assertFalse("revoke must not close native core directly", Regex("\\bMobile\\s*\\.").containsMatchIn(revoke))
    }

    @Test
    fun `recovery joins bounded close before setup and never starts a second cleanup`() {
        val service = sourceFile("BoxService.kt")
        val recovery = functionBody(service, "recoverMobileCore")
        val cleanupHelper = functionBody(service, "closeMobileCoreAndAwaitTunQuiescence")
        val cleanup = recovery.indexOf("closeMobileCoreAndAwaitTunQuiescence(")
        val closeWait = cleanupHelper.indexOf("MobileCoreCloser.closeBlocking")
        val setup = recovery.indexOf("Mobile.setup(", cleanup)
        val blockedSetup = recovery.indexOf("return@run false", cleanup)

        assertTrue("recovery must wait on the shared close before starting setup", cleanup >= 0)
        assertTrue("recovery cleanup must use the shared MobileCoreCloser", closeWait >= 0)
        assertTrue("a failed or timed-out cleanup must block setup", blockedSetup > cleanup)
        assertTrue("setup must remain after its cleanup admission gate", setup > blockedSetup)
        assertEquals(
            "one recovery attempt must have one ordered close/TUN cleanup barrier",
            cleanup,
            recovery.lastIndexOf("closeMobileCoreAndAwaitTunQuiescence(", setup),
        )
    }

    @Test
    fun `start close timeout publishes still stopping failure without a second close wait`() {
        val start = functionBody(sourceFile("BoxService.kt"), "startService")
        val wait = start.indexOf("MobileCoreCloser.waitForCloseToFinish(\"service start\")")
        val failure = start.indexOf("finishCoreCleanupFailure(", wait)
        val stillStopping = start.indexOf("R.string.error_connection_still_stopping", failure)
        val returnAfterFailure = start.indexOf("return", stillStopping)

        assertTrue("Connect must make one bounded wait for a prior native close", wait >= 0)
        assertTrue("timeout must enter the terminal cleanup failure owner", failure > wait)
        assertTrue("timeout must report that the connection is still stopping", stillStopping > failure)
        assertTrue("timeout branch must return immediately after reporting failure", returnAfterFailure > stillStopping)

        val timeoutBranch = start.substring(wait, returnAfterFailure)
        assertFalse("timeout branch must not invoke a second alert cleanup", timeoutBranch.contains("stopAndAlert("))
        assertFalse("timeout branch must not join another native close", timeoutBranch.contains("MobileCoreCloser.closeBlocking"))
    }

    @Test
    fun `pending service cleanup timeout publishes still stopping failure without a second close`() {
        val start = functionBody(sourceFile("BoxService.kt"), "startService")
        val wait = start.indexOf("ServiceLifecycleOwnership.awaitPendingCleanup(serviceOwnerToken)")
        val failure = start.indexOf("finishCoreCleanupFailure(", wait)
        val stillStopping = start.indexOf("R.string.error_connection_still_stopping", failure)
        val returnAfterFailure = start.indexOf("return", stillStopping)

        assertTrue("Connect must use the ownership cleanup barrier", wait >= 0)
        assertTrue("pending cleanup timeout must enter the terminal cleanup failure owner", failure > wait)
        assertTrue("pending cleanup timeout must report that the connection is still stopping", stillStopping > failure)
        assertTrue("pending cleanup timeout branch must return after reporting failure", returnAfterFailure > stillStopping)

        val timeoutBranch = start.substring(wait, returnAfterFailure)
        assertFalse("pending cleanup timeout must not invoke a second alert cleanup", timeoutBranch.contains("stopAndAlert("))
        assertFalse("pending cleanup timeout must not join another native close", timeoutBranch.contains("MobileCoreCloser.closeBlocking"))
    }

    @Test
    fun `function body parser ignores braces in Kotlin lexical literals and comments`() {
        val source =
            "fun sample() {\n" +
                "  val ordinary = \"{ ordinary }\"\n" +
                "  val triple = \"\"\"{ triple }\"\"\"\n" +
                "  val marker = '{'\n" +
                "  // } line comment\n" +
                "  /* { outer /* } nested */ outer } */\n" +
                "  if (true) { return }\n" +
                "}\n" +
                "fun after() { error(\"not part of sample\") }\n"

        val body = functionBody(source, "sample")

        assertTrue(body.contains("if (true) { return }"))
        assertTrue(!body.contains("fun after"))
        assertTrue(body.trimEnd().endsWith("}"))
    }

    private fun sourceFile(name: String): String {
        val source = File("src/main/kotlin/app/marten/client/bg/$name")
        check(source.isFile) { "missing production source ${source.path}" }
        return source.readText()
    }

    private fun assertCleanupFailureTerminatesThroughTerminalHandler(source: String, name: String, returnMarker: String) {
        val body = functionBody(source, name)
        val failureGuard = findCleanupFailureGuard(body)
        val terminalFailure = body.indexOf("finishCoreCleanupFailure(", failureGuard)
        val failedReturn = body.indexOf(returnMarker, terminalFailure)
        assertTrue("$name must check close and TUN cleanup", failureGuard >= 0)
        assertTrue("$name must invoke terminal fail-closed cleanup", terminalFailure > failureGuard)
        assertTrue("$name must return after terminal cleanup admission", failedReturn > terminalFailure)
    }

    private fun findCleanupFailureGuard(body: String): Int {
        return listOf(
            body.indexOf("if (requiresCoreCleanupEscalation("),
            body.indexOf("if (isTunReleaseCompleteForCleanup("),
            body.indexOf("if (isOwnedTunReleaseCompleteForCleanup("),
        ).firstOrNull { it >= 0 } ?: -1
    }

    private fun functionBody(source: String, name: String): String {
        val declaration = source.indexOf("fun $name")
        check(declaration >= 0) { "function $name not found" }
        val bodyStart = functionBodyStart(source, declaration)
        check(bodyStart >= 0) { "function $name has no body" }
        var depth = 0
        var index = bodyStart
        while (index < source.length) {
            when (source[index]) {
                '/' -> {
                    if (source.startsWith("//", index)) {
                        index = source.indexOf('\n', index + 2).let { if (it < 0) source.length else it }
                        continue
                    }
                    if (source.startsWith("/*", index)) {
                        index = skipBlockComment(source, index)
                        continue
                    }
                }
                '"' -> {
                    index = if (source.startsWith("\"\"\"", index)) {
                        skipTripleQuotedString(source, index)
                    } else {
                        skipQuotedLiteral(source, index, '"')
                    }
                    continue
                }
                '\'' -> {
                    index = skipQuotedLiteral(source, index, '\'')
                    continue
                }
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return source.substring(declaration, index + 1)
                }
            }
            index++
        }
        error("function $name has an unterminated body")
    }

    private fun functionBodyStart(source: String, declaration: Int): Int {
        var parenthesisDepth = 0
        var index = declaration
        while (index < source.length) {
            when (source[index]) {
                '/' -> {
                    if (source.startsWith("//", index)) {
                        index = source.indexOf('\n', index + 2).let { if (it < 0) source.length else it }
                        continue
                    }
                    if (source.startsWith("/*", index)) {
                        index = skipBlockComment(source, index)
                        continue
                    }
                }
                '"' -> {
                    index = if (source.startsWith("\"\"\"", index)) {
                        skipTripleQuotedString(source, index)
                    } else {
                        skipQuotedLiteral(source, index, '"')
                    }
                    continue
                }
                '\'' -> {
                    index = skipQuotedLiteral(source, index, '\'')
                    continue
                }
                '(' -> parenthesisDepth++
                ')' -> parenthesisDepth--
                '{' -> if (parenthesisDepth == 0) return index
            }
            index++
        }
        error("function declaration has no body")
    }

    private fun Int?.orEmptyIndex(): Int = this ?: -1

    private fun skipQuotedLiteral(source: String, start: Int, quote: Char): Int {
        var index = start + 1
        while (index < source.length) {
            if (source[index] == '\\') {
                index += 2
                continue
            }
            if (source[index] == quote) return index + 1
            index++
        }
        error("unterminated Kotlin literal")
    }

    private fun skipTripleQuotedString(source: String, start: Int): Int {
        val end = source.indexOf("\"\"\"", start + 3)
        check(end >= 0) { "unterminated Kotlin triple-quoted string" }
        return end + 3
    }

    private fun skipBlockComment(source: String, start: Int): Int {
        var depth = 1
        var index = start + 2
        while (index < source.length - 1) {
            when {
                source.startsWith("/*", index) -> {
                    depth++
                    index += 2
                }
                source.startsWith("*/", index) -> {
                    depth--
                    index += 2
                    if (depth == 0) return index
                }
                else -> index++
            }
        }
        error("unterminated Kotlin block comment")
    }
}
