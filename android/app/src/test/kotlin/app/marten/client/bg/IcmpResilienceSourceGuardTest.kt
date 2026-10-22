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
        val delegateToOwner = flutterAcknowledgement.indexOf("nativeRouteRecoveryOwnsGeneration(generation)")
        val publication = flutterAcknowledgement.indexOf("return awaitStartupRoutePublication(")
        val recoveryOwner = functionBody(source, "nativeRouteRecoveryOwnsGeneration")
        val helper = sourceFile("StartupRoutePublication.kt")
        assertTrue("Flutter acknowledgement must use bounded same-owner publication", publication >= 0)
        assertTrue("Flutter acknowledgement must yield immediately to the active native recovery owner", delegateToOwner >= 0)
        assertTrue("publication retries must stay in the exact acknowledged lifecycle generation", flutterAcknowledgement.contains("isCurrent = { shouldContinueStart(generation) }"))
        assertTrue("publication retries must yield to an active native recovery owner", flutterAcknowledgement.contains("recoveryActive = { nativeRouteRecoveryOwnsGeneration(generation) }"))
        assertTrue("publication retries must recheck the exact current VPN proof", flutterAcknowledgement.contains("hasCurrentProof = { hasReusableVpnDataPlaneProof(generation) }"))
        assertTrue("native verification receives the operation's shared deadline", flutterAcknowledgement.contains("operationDeadlineElapsedMs = deadline"))
        assertTrue("only a publication explicitly rejected for proof change may retry", helper.contains("StartupRoutePublicationResult.PROOF_CHANGED -> Unit"))
        assertTrue("each proof-change retry requires a fresh native verification even if topology restores the old proof", helper.contains("attempt > 0 || !hasCurrentProof()"))
        assertTrue("health and proof-verification failures remain terminal for this acknowledgement", helper.contains("StartupRoutePublicationResult.FAILED -> return@withTimeoutOrNull false"))
        assertTrue("the publication retry count is bounded", helper.contains("repeat(3)"))
        assertTrue("acknowledgement suppresses the ordinary watchdog recovery on a proof race", flutterAcknowledgement.contains("recoverOnProofChange = false"))
        assertTrue("an active core recovery owns the acknowledged generation", recoveryOwner.contains("coreRecoveryInProgress"))
        assertTrue("an active network recovery owns the acknowledged generation", recoveryOwner.contains("networkRecoveryJob?.isActive == true"))
        assertTrue("a degraded route watchdog owns the acknowledged generation", recoveryOwner.contains("routeWatchdogDegraded"))
        assertTrue("ownership must remain generation and user-session guarded", recoveryOwner.contains("shouldDelegateRouteVerificationToNativeRecovery("))
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
    fun `user stop persists its epoch tombstone before dispatching to the current BoxService owner without a broadcast`() {
        val boxService = sourceFile("BoxService.kt")
        val stop = functionBody(boxService, "stop")
        val dispatch = functionBody(boxService, "dispatchTerminalStopIntent")

        val durableIntent = stop.indexOf("val terminalIntent = persistTerminalStopIntent(")
        val explicitReason = stop.indexOf("reason = \"explicit native user stop\"", durableIntent)
        val explicitOwnership = stop.indexOf("explicitUserStop = true", explicitReason)
        val dispatchIntent = stop.indexOf("dispatchTerminalStopIntent(terminalIntent, quickSettingsRequestId)", durableIntent)
        val activeOwner = dispatch.indexOf("val instance = activeInstance")
        val mainThread = dispatch.indexOf("Looper.myLooper() == Looper.getMainLooper()", activeOwner)
        val directStop = dispatch.indexOf("instance.stopService(", mainThread)
        val directDurableState = dispatch.indexOf("terminalStateAlreadyPersisted = terminalIntent.persisted", directStop)
        val mainThreadPost = dispatch.indexOf("instance.mainHandler.post", directDurableState)
        val replacementOwner = dispatch.indexOf("val currentInstance = activeInstance", mainThreadPost)
        val replacementDispatch = dispatch.indexOf("dispatchTerminalStopIntent(terminalIntent, quickSettingsRequestId)", replacementOwner)
        val replacementStop = dispatch.indexOf("currentInstance.stopService(", replacementDispatch)
        val replacementDurableState = dispatch.indexOf("terminalStateAlreadyPersisted = terminalIntent.persisted", replacementStop)

        assertTrue(
            "ordinary stops must retain a zero-valued Quick Settings correlation default",
            boxService.contains("fun stop(quickSettingsRequestId: Long = 0L)"),
        )
        assertTrue(
            "native explicit Stop must atomically claim its exact epoch marker before dispatching it",
            durableIntent >= 0 && explicitReason > durableIntent && explicitOwnership > explicitReason && dispatchIntent > explicitOwnership,
        )
        assertTrue(
            "terminal dispatch must own current active-instance selection, main-thread delivery, and persisted-state handoff",
            activeOwner >= 0 && mainThread > activeOwner && directStop > mainThread && directDurableState > directStop,
        )
        assertTrue(
            "off-main dispatch must resolve a replacement owner or re-dispatch the same terminal intent, preserving its persisted result",
            mainThreadPost > directDurableState && replacementOwner > mainThreadPost && replacementDispatch > replacementOwner &&
                replacementStop > replacementDispatch && replacementDurableState > replacementStop,
        )
        assertFalse("stop() must not select an owner itself before its terminal intent dispatch", stop.contains("activeInstance"))
        assertFalse("in-process user stop must not reopen the broadcast admission race", stop.contains("sendBroadcast") || dispatch.contains("sendBroadcast"))
    }

    @Test
    fun `authoritative stop pins its initial owner until Android VPN release is confirmed`() {
        val await = functionBody(sourceFile("BoxService.kt"), "awaitAuthoritativeStop")

        val pinnedOwner = await.indexOf("val stoppedInstance = activeInstance")
        val ownerCheck = await.indexOf("stoppedInstance.serviceOwnerToken != ownerToken")
        val stopJob = await.indexOf("val stopJob = stoppedInstance.serviceStopJob")
        val stoppedStatus = await.indexOf("stoppedInstance.status.value == Status.Stopped")
        val platformShutdown = await.indexOf("stoppedInstance.platformShutdownCompleted")

        assertTrue("await must capture the active owner exactly once", pinnedOwner >= 0)
        assertTrue("pinned owner token must reject a mismatched request", ownerCheck > pinnedOwner)
        assertTrue("await must join the pinned owner's stop job", stopJob > ownerCheck)
        assertTrue("completion must be read from the pinned owner", stoppedStatus > stopJob)
        assertTrue("completion must require pinned Android VPN/TUN release", platformShutdown > stoppedStatus)
        assertFalse(
            "await must not follow activeInstance after taking its stoppedInstance snapshot",
            await.substring(pinnedOwner + "val stoppedInstance = activeInstance ?: return true".length).contains("activeInstance"),
        )
    }

    @Test
    fun `open tun always emits one secret-free structured outcome`() {
        val source = sourceFile("VPNService.kt")
        val openTun = functionBody(source, "openRemoteTun")

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
    fun `VPN service retains the platform TUN while passing only a CoreTunSpec over Binder`() {
        val source = sourceFile("VPNService.kt")
        val openTun = functionBody(source, "openTun")
        val openRemoteTun = functionBody(source, "openRemoteTun")

        assertTrue(openTun.contains("openRemoteTun(CoreTunSpec.from(options))"))
        val establish = openRemoteTun.indexOf("val pfd = builder.establish()")
        val replace = openRemoteTun.indexOf("service.replaceTunFileDescriptor(pfd)")
        val nativeFd = openRemoteTun.indexOf("val nativeFd = pfd.fd")
        val returnDescriptor = openRemoteTun.indexOf("return nativeFd")
        val establisherClose = openRemoteTun.indexOf("pfd.close()", establish)
        val establisherRelease = openRemoteTun.indexOf("pfd.detachFd()", establish)

        assertTrue(establish >= 0)
        assertTrue("VpnService must keep descriptor ownership in its lifecycle owner", replace >= 0)
        assertTrue("VpnService must return the retained establisher fd to libbox", returnDescriptor >= 0)
        assertTrue(establish < replace)
        assertTrue(replace < returnDescriptor)
        assertTrue(nativeFd > replace && returnDescriptor > nativeFd)
        assertFalse("the service-owned platform descriptor must not be duplicated in its handoff", openRemoteTun.substring(establish, returnDescriptor).contains("ParcelFileDescriptor.dup"))
        assertFalse("the service-owned platform descriptor must not be detached", openRemoteTun.substring(establish, returnDescriptor).contains("detachFd()"))
        assertFalse(
            "the service-owned platform descriptor must not be closed in handoff path",
            establisherClose >= establish && establisherClose < returnDescriptor,
        )
        if (establisherRelease >= 0) {
            assertFalse(
                "detaching is not allowed when VPNService owns the original descriptor",
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
        val cleanupAccepted = destroy.indexOf("val (stickyTunHandedOff, cleanupAccepted) = synchronized(serviceReplacementLock)")
        val guardedReset = destroy.indexOf("if (cleanupAccepted &&")
        val stickyDecision = destroy.indexOf("val preservePublishedSession =", guardedReset)
        assertTrue(cleanupAccepted >= 0)
        assertTrue(guardedReset > cleanupAccepted)
        assertTrue("only the owner that registered destroy cleanup may publish its sticky/terminal outcome", stickyDecision > guardedReset)
    }

    @Test
    fun `TUN creation and runtime health enforce a single Marten-owned generation`() {
        val vpnSource = sourceFile("VPNService.kt")
        assertTrue(vpnSource.contains("override fun openTun(options: TunOptions): Int = openRemoteTun(CoreTunSpec.from(options))"))
        val openTun = functionBody(vpnSource, "openRemoteTun")
        assertTrue("TUN builder transaction remains serialized", openTun.contains("synchronized(vpnBuilderTransactionLock)"))
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
        val waitForPriorClose = start.indexOf("MobileCoreCloser.waitForCloseToFinish(")
        val admissionLock = start.indexOf("synchronized(fileDescriptorLock)", waitForPriorClose)
        val reopenAdmission = start.indexOf("tunDescriptorAdmissionClosed = false", admissionLock)
        val setup = start.indexOf("Mobile.setup(", reopenAdmission)

        assertTrue("start must wait for any in-flight native close", waitForPriorClose >= 0)
        val closeBarrier = start.substring(waitForPriorClose, admissionLock)
        assertTrue("start close barrier must identify its current generation", closeBarrier.contains("reason = \"service start generation=\$generation\""))
        assertTrue("start close barrier must use the explicit 60s admission timeout", closeBarrier.contains("timeoutMs = CORE_START_ADMISSION_TIMEOUT_MS"))
        assertTrue("accepted start must re-open descriptor admission under fileDescriptorLock", admissionLock > waitForPriorClose)
        assertTrue(reopenAdmission > admissionLock)
        assertTrue("descriptor admission must open before native setup", setup > reopenAdmission)
    }

    @Test
    fun `onStartCommand captures explicit user intent into VPN start marker`() {
        val onStart = functionBody(sourceFile("BoxService.kt"), "onStartCommand")
        val epochRequired = onStart.indexOf("val userSessionEpochRequired =")
        val suppliedEpoch = onStart.indexOf("val suppliedUserSessionEpoch =", epochRequired)
        val staleEpochReject = onStart.indexOf("!ServiceLifecycleOwnership.isUserSessionEpochCurrent(suppliedUserSessionEpoch)", suppliedEpoch)
        val rejectedEpochReturn = onStart.indexOf("return Service.START_NOT_STICKY", staleEpochReject)
        val explicitRequest = onStart.indexOf("val explicitUserStartRequested =")
        val bypassMarker = onStart.indexOf("!restartedBySystem")
        val explicitExtra = onStart.indexOf("intent?.getBooleanExtra(Action.EXTRA_USER_INITIATED, false) == true", explicitRequest)
        val explicitCapture = onStart.indexOf("explicitUserStartRequested && Settings.serviceMode == ServiceMode.VPN")
        val explicitCaptureStart = onStart.indexOf("if (explicitUserStartRequested && Settings.serviceMode == ServiceMode.VPN)")
        val rejectedStart = onStart.indexOf("shouldRejectNewVpnStart(")
        val admissionOpen = onStart.indexOf("synchronized(fileDescriptorLock)")
        val markerSet = onStart.indexOf("markExplicitVpnTakeoverAllowance()", explicitCaptureStart)
        val markerClear = onStart.indexOf("clearExplicitVpnTakeoverAllowance()", explicitCaptureStart)
        val explicitElse = onStart.indexOf("} else {", explicitCaptureStart)

        assertTrue(
            "every explicit SERVICE_PREPARE_VPN/SERVICE_CONNECT/UI command must reject a missing or stale epoch before any start marker is captured",
            epochRequired >= 0 && suppliedEpoch > epochRequired && staleEpochReject > suppliedEpoch &&
                rejectedEpochReturn > staleEpochReject && explicitRequest > rejectedEpochReturn,
        )
        assertTrue(explicitRequest >= 0)
        assertTrue(bypassMarker > explicitRequest)
        assertTrue(explicitExtra > explicitRequest)
        assertTrue("onStartCommand should pass user intent into rejection gate", onStart.contains("explicitUserStart = explicitUserStartRequested"))
        assertTrue(
            "onStartCommand should capture marker through service-mode-gated assignment",
            explicitCapture > explicitRequest,
        )
        assertTrue(
            "onStartCommand should use explicit marker helper calls rather than direct assignment",
            onStart.contains("markExplicitVpnTakeoverAllowance()") && onStart.contains("clearExplicitVpnTakeoverAllowance()") &&
                !onStart.contains("explicitUserVpnStartPending ="),
        )
        val stoppedBranch = onStart.indexOf("if (status.value != Status.Stopped) {")
        assertTrue(stoppedBranch >= 0)
        assertTrue("capture should only happen after explicit rejected-start check", explicitCapture > rejectedStart)
        assertTrue("capture should only happen on accepted-start branch", explicitCapture > stoppedBranch)
        assertTrue(admissionOpen > rejectedStart)
        assertTrue("explicit branch helper call should happen before descriptor admission reset", markerSet > explicitCaptureStart && markerSet < admissionOpen)
        assertTrue("non-explicit branch helper call should happen before descriptor admission reset", markerClear > explicitCaptureStart && markerClear < admissionOpen)
        assertTrue("explicit branch helper call should occur before non-explicit helper call", markerSet < explicitElse && markerClear > explicitElse)
    }

    @Test
    fun `explicit user-start marker is cleared only by terminal stop paths and never becomes an app-routing bypass`() {
        val stopService = functionBody(sourceFile("BoxService.kt"), "stopService")
        val stopReset = stopService.indexOf("clearExplicitVpnTakeoverAllowance()")
        val cancelledStart = functionBody(sourceFile("BoxService.kt"), "finishCancelledStart")
        val cancelledReset = cancelledStart.indexOf("clearExplicitVpnTakeoverAllowance()")
        val automaticRecovery = functionBody(sourceFile("BoxService.kt"), "awaitRecoverableCoreCleanup")
        val onRevoke = functionBody(sourceFile("BoxService.kt"), "onRevoke")
        val revokeStopsService = onRevoke.indexOf("stopService(vpnRevoked = true)")

        assertTrue("service stop entry should clear explicit marker", stopReset >= 0)
        assertTrue(
            "stop entry reset must happen before legacy cleanup cancellation",
            stopReset < stopService.indexOf("cancelLegacyProcessRecoveryAlarm()"),
        )
        assertTrue("cancelled start must clear its one-shot marker", cancelledReset >= 0)
        assertFalse("automatic recovery must not obtain a fresh explicit-start allowance", automaticRecovery.contains("explicitUserVpnStartPending = true"))
        assertTrue("revoke should clear marker through the shared stop path", revokeStopsService >= 0)
        assertFalse("onRevoke should not clear marker directly", onRevoke.contains("explicitUserVpnStartPending = false"))
    }

    @Test
    fun `ownership observer is callback driven and recovers only confirmed missing own VPN`() {
        val source = sourceFile("BoxService.kt")
        val startService = functionBody(source, "startService")
        val resetOwnership = startService.indexOf("vpnOwnershipWasEstablished = false")
        val startWatchdog = startService.indexOf("startExternalVpnWatchdog()", resetOwnership)
        val nativeSetup = startService.indexOf("Mobile.setup(", startWatchdog)
        assertTrue(resetOwnership >= 0)
        assertTrue("watchdog must cover Builder.establish through route verification", startWatchdog > resetOwnership)
        assertTrue("watchdog must start before native Mobile.setup", nativeSetup > startWatchdog)

        val watchdog = functionBody(source, "startExternalVpnWatchdog")
        val callback = watchdog.indexOf("val callback = object : ConnectivityManager.NetworkCallback()")
        val register = watchdog.indexOf("connectivity.registerNetworkCallback(request, callback)", callback)
        val initialWake = watchdog.indexOf("changes.trySend(Unit) // Register before the first snapshot", register)
        val waitForChange = watchdog.indexOf("changes.receive()", initialWake)
        val ownershipRead = watchdog.indexOf("readVpnOwnership(service)", waitForChange)
        val activeOwnership = watchdog.indexOf("if (ownership.active)", ownershipRead)
        val activeOwnershipExit = watchdog.indexOf("break", activeOwnership)
        val unknownOwnership = watchdog.indexOf("if (!ownership.known || !vpnOwnershipWasEstablished)", activeOwnership)
        val unknownOwnershipExit = watchdog.indexOf("break", unknownOwnership)
        val recoveryOwnership = watchdog.indexOf("coreRecoveryOwnsVpnTransition(generation)", unknownOwnership)
        val recoveryOwnershipExit = watchdog.indexOf("break", recoveryOwnership)
        val externalTakeover = watchdog.indexOf("shouldYieldToExternalVpn(\"VPN ownership event\")", waitForChange)
        val externalStop = watchdog.indexOf("stopForExternalVpnOnMain(\"VPN ownership event\")", externalTakeover)
        val recoveryPolicy = watchdog.indexOf("shouldRecoverMissingOwnVpn(", recoveryOwnership)
        val degraded = watchdog.indexOf("markRouteDegraded(reason)", recoveryPolicy)
        val recoveryRequest = watchdog.indexOf("requestCoreRecovery(reason, generation)", degraded)

        assertTrue("the ownership observer must register a filtered Android VPN callback", callback >= 0 && register > callback)
        assertTrue("the first ownership snapshot must follow callback registration", initialWake > register && waitForChange > initialWake)
        assertTrue("network callback events must trigger the ownership read", ownershipRead > waitForChange)
        assertTrue("an active Marten VPN must be remembered as established", activeOwnership > ownershipRead && watchdog.contains("vpnOwnershipWasEstablished = true"))
        assertTrue("an active own network must end the bounded confirmation batch", activeOwnershipExit > activeOwnership && activeOwnershipExit < unknownOwnership)
        assertFalse("ownership supervision must not rely on future explicit-takeover intent", watchdog.contains("explicitVpnTakeoverPending"))
        assertTrue("real external VPN takeover must use the shared terminal stop", externalTakeover >= 0 && externalStop > externalTakeover)
        assertTrue("unknown or unestablished ownership must end confirmation without recovery", unknownOwnershipExit > unknownOwnership && unknownOwnershipExit < recoveryOwnership)
        assertTrue("recovery-owned transitions must bypass ownership-loss recovery", recoveryOwnershipExit > recoveryOwnership)
        assertTrue("missing-own-VPN recovery must use its bounded policy", recoveryPolicy > recoveryOwnership)
        assertTrue("the policy must reject unknown or active ownership", watchdog.contains("ownershipKnown = ownership.known") && watchdog.contains("ownVpnActive = ownership.active"))
        assertTrue("confirmed own-VPN loss must keep user intent and mark recovery", degraded > recoveryPolicy)
        assertTrue("confirmed own-VPN loss must request generation-scoped recovery", recoveryRequest > degraded)
        assertTrue("only suspected loss may use bounded confirmation", watchdog.contains("delay(CORE_WATCHDOG_CONFIRM_MS)"))
        assertFalse("stable ownership must not use screen-aware polling", watchdog.contains("vpnOwnershipWatchdogPollDelayMs"))
    }

    @Test
    fun `TUN precondition allows only service-owned retained descriptor replacement and has no app bypass`() {
        val boxSource = sourceFile("BoxService.kt")
        val precondition = functionBody(boxSource, "requireTunCreationPrecondition")
        val onStart = functionBody(boxSource, "onStartCommand")

        assertTrue(
            "TUN precondition must identify an existing service-owned descriptor before replacement",
            precondition.contains("val retainedDescriptorReplacement = synchronized(fileDescriptorLock)") &&
                precondition.contains("tunDescriptorMode != TunDescriptorMode.NONE"),
        )
        assertTrue(
            "TUN precondition must allow replacement only through its retained descriptor predicate",
            precondition.contains("explicitUserVpnStartPending || retainedDescriptorReplacement"),
        )
        assertTrue(
            "TUN precondition should forward the ownership-controlled replacement predicate into runtime quiescence",
            precondition.contains("allowPlatformVpnReplacement = allowPlatformVpnReplacement"),
        )
        assertFalse(precondition.contains("allowBypass("))
        assertFalse(onStart.contains("allowBypass("))
    }

    @Test
    fun `TileService directly connects with granted VPN permission and opens an Activity only for a real prompt`() {
        val tile = sourceFile("TileService.kt")
        val toggle = functionBody(tile, "toggleService")
        val requestUserConnect = functionBody(tile, "requestUserConnect")
        assertFalse(toggle.contains("userInitiated ="))
        assertFalse(toggle.contains("EXTRA_USER_INITIATED"))
        assertFalse(toggle.contains("explicit takeover"))
        assertTrue("Quick Settings must retain its trace ID through the permission path", toggle.contains("requestUserConnect(requestId)"))
        assertTrue(
            "Quick Settings stop must still use the direct active-owner admission path",
            toggle.contains("BoxService.stop(quickSettingsRequestId = requestId)"),
        )
        val connectBranch = toggle.indexOf("Status.Stopped ->")
        val connectUnavailable = toggle.indexOf("state = Tile.STATE_UNAVAILABLE", connectBranch)
        val connectDispatch = toggle.indexOf("requestUserConnect(requestId)", connectBranch)
        val stopBranch = toggle.indexOf("Status.Started ->")
        val stopUnavailable = toggle.indexOf("state = Tile.STATE_UNAVAILABLE", stopBranch)
        val stopDispatch = toggle.indexOf("BoxService.stop(quickSettingsRequestId = requestId)", stopBranch)
        assertTrue(
            "Connect must disable the tile before dispatching a new lifecycle command",
            connectBranch >= 0 && connectUnavailable > connectBranch && connectDispatch > connectUnavailable,
        )
        assertTrue(
            "Stop must disable the tile before dispatching a new lifecycle command",
            stopBranch >= 0 && stopUnavailable > stopBranch && stopDispatch > stopUnavailable,
        )

        val vpnMode = requestUserConnect.indexOf("if (Settings.serviceMode == ServiceMode.VPN)")
        val prepare = requestUserConnect.indexOf("VpnService.prepare(applicationContext)", vpnMode)
        val prepareFailure = requestUserConnect.indexOf("if (prepareResult.isFailure)", prepare)
        val prepareFailureInactive = requestUserConnect.indexOf("state = Tile.STATE_INACTIVE", prepareFailure)
        val prepareFailureReturn = requestUserConnect.indexOf("return", prepareFailure)
        val directPermissionBranch = requestUserConnect.indexOf("if (permissionIntent == null)", prepareFailureReturn)
        val directConnect = requestUserConnect.indexOf("BoxService.connect(", directPermissionBranch)
        val directUserInitiated = requestUserConnect.indexOf("userInitiated = true", directConnect)
        val directRequestId = requestUserConnect.indexOf("quickSettingsRequestId = requestId", directUserInitiated)
        val directSource = requestUserConnect.indexOf(
            "entrySource = VpnPermissionActivity.SOURCE_QUICK_SETTINGS",
            directRequestId,
        )
        val directReturn = requestUserConnect.indexOf("return", directSource)
        val promptRequired = requestUserConnect.indexOf("outcome = \"prompt_required\"", directReturn)
        val collapse = requestUserConnect.indexOf("startActivityAndCollapse(", promptRequired)
        val directBranch = requestUserConnect.substring(directPermissionBranch, promptRequired)
        val prepareFailureBranch = requestUserConnect.substring(prepareFailure, directPermissionBranch)

        assertTrue(
            "Quick Settings must ask the Android VPN authority before deciding whether any UI is required",
            vpnMode >= 0 && prepare > vpnMode,
        )
        assertTrue(
            "a VpnService.prepare failure must return fail-closed before either direct service admission or permission UI",
            prepareFailure > prepare && prepareFailureReturn > prepareFailure && directPermissionBranch > prepareFailureReturn &&
                !prepareFailureBranch.contains("BoxService.connect(") &&
                !prepareFailureBranch.contains("startActivityAndCollapse("),
        )
        assertTrue(
            "a VpnService.prepare failure must restore the temporarily disabled tile to INACTIVE before returning",
            prepareFailureInactive > prepareFailure && prepareFailureReturn > prepareFailureInactive &&
                !requestUserConnect.substring(prepareFailure, prepareFailureReturn).contains("Tile.STATE_UNAVAILABLE"),
        )
        assertTrue(
            "already granted VPN permission must directly preserve the Quick Settings user intent, request ID, and entry source",
            directConnect > directPermissionBranch && directUserInitiated > directConnect && directRequestId > directUserInitiated &&
                directSource > directRequestId && directReturn > directSource,
        )
        assertFalse(
            "the direct-service branch must not unconditionally create an Activity, PendingIntent, or collapse the tile",
            directBranch.contains("VpnPermissionActivity.pendingIntent(") ||
                directBranch.contains("VpnPermissionActivity.createIntent(") ||
                directBranch.contains("startActivityAndCollapse("),
        )
        assertTrue(
            "permission UI is allowed only after a non-null prepare result bypasses the direct-service return",
            promptRequired > directReturn && collapse > promptRequired,
        )
        assertFalse(
            "permission handling must not add lifecycle retry timing or optimistic tile activation",
            requestUserConnect.contains("Timer(") || requestUserConnect.contains("delay(") ||
                requestUserConnect.contains("Tile.STATE_ACTIVE"),
        )

        val boot = sourceFile("BootReceiver.kt")
        val receive = functionBody(boot, "onReceive")
        val codeOnly = receive.lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")
        assertTrue(
            "only system boot and package-replacement broadcasts may issue a recovery hint",
            receive.contains("Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED") &&
                receive.contains("else -> return"),
        )
        assertTrue(
            "boot recovery must send SERVICE_RECOVER to let BoxService re-read authoritative persisted intent",
            receive.contains(".setAction(Action.SERVICE_RECOVER)") &&
                receive.contains("ContextCompat.startForegroundService(context, recoveryIntent)"),
        )
        assertFalse("boot must not manufacture a user Connect that can beat Disconnect", codeOnly.contains("BoxService.connect("))
        assertFalse("boot must not create started-by-user state outside BoxService admission", codeOnly.contains("Settings.startedByUser ="))
        assertFalse("boot must not enqueue a native core start outside BoxService admission", codeOnly.contains("Settings.startCoreAfterStartingService ="))
        assertFalse(receive.contains("userInitiated ="))
        assertFalse(receive.contains("EXTRA_USER_INITIATED"))
        assertFalse(receive.contains("explicit takeover"))
    }

    @Test
    fun `cold Quick Settings click retains its exact request until a replayed status can toggle it once`() {
        val tile = sourceFile("TileService.kt")
        val click = functionBody(tile, "onClick")
        val toggleWhenKnown = functionBody(tile, "toggleWhenStatusKnown")
        val statusChanged = functionBody(tile, "onServiceStatusChanged")
        val binder = sourceFile("ServiceBinder.kt")
        val manifest = File("src/main/AndroidManifest.xml").readText()
        val tileDeclaration = Regex(
            "<service\\s+android:name=\\\"\\.bg\\.TileService\\\"[\\s\\S]*?</service>",
        ).find(manifest)?.value.orEmpty()

        assertTrue(
            "the TileService declaration must opt into Android's active-tile status callbacks",
            tileDeclaration.contains("android.service.quicksettings.ACTIVE_TILE") &&
                tileDeclaration.contains("android:value=\"true\""),
        )
        assertTrue(
            "cold tile state needs a nullable stored request identity",
            Regex("private var pending[A-Za-z]*RequestId: Long\\? = null").containsMatchIn(tile),
        )
        assertTrue(
            "a click must inspect the nullable binder status rather than treating an unbound tile as Stopped",
            Regex("val\\s+\\w+\\s*=\\s*connection\\.currentStatus").containsMatchIn(toggleWhenKnown),
        )
        assertTrue("onClick must route the newly allocated ID into the nullable-status decision", click.contains("toggleWhenStatusKnown(requestId)"))
        val immediateToggle = toggleWhenKnown.indexOf("toggleService(requestId", 0)
        val storePending = Regex("pending[A-Za-z]*RequestId\\s*=\\s*requestId").find(toggleWhenKnown)?.range?.first ?: -1
        val connect = toggleWhenKnown.indexOf("connection.connect()", storePending)
        assertTrue("an unknown status must preserve this exact click identity", storePending >= 0)
        assertTrue("an unknown status must bind before any later status replay", connect > storePending)
        assertTrue(
            "the deferred branch must leave a privacy-safe diagnostic breadcrumb",
            toggleWhenKnown.contains("status_pending"),
        )
        assertTrue(
            "a known status must retain the immediate toggle path",
            immediateToggle >= 0 && immediateToggle < storePending,
        )
        assertTrue(
            "a second click while waiting for the same replay must not create a second deferred toggle",
            toggleWhenKnown.contains("if (pendingToggleRequestId != null)") &&
                toggleWhenKnown.contains("duplicate_pending"),
        )

        val pendingRead = statusChanged.indexOf("pending")
        val clearPending = statusChanged.indexOf("= null", pendingRead)
        val replayToggle = statusChanged.indexOf("toggleService(", clearPending)
        assertTrue("replayed service status must consume the pending click", pendingRead >= 0)
        assertTrue("the pending click must be cleared before its replay toggle", clearPending > pendingRead)
        assertTrue("only replayed status may execute the deferred toggle", replayToggle > clearPending)
        assertEquals(
            "one replayed status must have at most one deferred toggle site",
            1,
            statusChanged.split("toggleService(").size - 1,
        )

        val observedStatus = binder.indexOf("status.observeForever")
        val tileUpdate = binder.indexOf("TileService.requestStateUpdate(", observedStatus)
        assertTrue("each service status update must request a safe active-tile refresh", tileUpdate > observedStatus)
        assertTrue("TileService must own the safe active-tile refresh entry point", tile.contains("fun requestStateUpdate("))

        val stateUpdate = functionBody(tile, "requestStateUpdate")
        val companion = tile.substring(tile.indexOf("companion object"), tile.indexOf("private val connection"))
        assertTrue(
            "state refresh must be deduplicated by the status that caused it",
            Regex("fun\\s+requestStateUpdate\\s*\\(\\s*context:\\s*Context\\s*,\\s*status:\\s*Status").containsMatchIn(tile),
        )
        assertTrue("deduplication state must be process-wide with the TileService companion", companion.contains("lastRequestedStatus"))
        val lockName = Regex("private val (\\w*Lock) = Any\\(\\)").find(companion)?.groupValues?.get(1).orEmpty()
        assertTrue("deduplication must be serialized by a companion-level lock", lockName.isNotEmpty())
        val lock = stateUpdate.indexOf("synchronized($lockName)")
        val duplicate = stateUpdate.indexOf("lastRequestedStatus == status", lock)
        val requestListening = stateUpdate.indexOf("AndroidTileService.requestListeningState", duplicate)
        assertTrue("deduplication must run under the process-wide lock", lock >= 0)
        assertTrue("an identical status must return before requesting another tile listener", duplicate > lock && requestListening > duplicate)
        assertTrue("the same status must skip the platform refresh request", stateUpdate.contains("if (!shouldRequest) return"))
        assertTrue(
            "a failed platform request must clear deduplication so a later update can retry",
            stateUpdate.indexOf("lastRequestedStatus = null", requestListening) > requestListening,
        )
        val observerToUpdate = binder.substring(observedStatus, tileUpdate + 300)
        assertTrue("ServiceBinder must forward its observed status into tile deduplication", Regex("requestStateUpdate\\s*\\([\\s\\S]*\\bit\\b").containsMatchIn(observerToUpdate))
    }

    @Test
    fun `Android 14+ Quick Settings pending intent is per-request one-shot while notification intent stays reusable`() {
        val tileSource = sourceFile("TileService.kt")
        val requestCode = functionBody(tileSource, "quickSettingsPendingIntentRequestCode")
        val requestConnect = functionBody(tileSource, "requestUserConnect")
        val notificationSource = sourceFile("ServiceNotification.kt")
        val notificationConnect = functionBody(notificationSource, "connectIntent")
        val flagsDefinition = notificationSource.substring(
            notificationSource.indexOf("val flags ="),
            notificationSource.indexOf("private fun runningBuilder", notificationSource.indexOf("val flags =")),
        )

        assertTrue(
            "QS requestCode must be derived from the requestId",
            requestCode.contains("requestId and 0x3fff_ffffL"),
        )
        assertTrue(
            "the true permission-prompt branch, not the already-granted direct-service branch, must use a per-request requestCode",
            requestConnect.contains("outcome = \"prompt_required\"") &&
                requestConnect.indexOf("VpnPermissionActivity.pendingIntent(") > requestConnect.indexOf("outcome = \"prompt_required\"") &&
                requestConnect.contains("requestCode = quickSettingsPendingIntentRequestCode(requestId)"),
        )
        assertTrue(
            "the true permission-prompt Android 14 branch must use one-shot pending intent after direct service has returned",
            requestConnect.indexOf("oneShot = true") > requestConnect.indexOf("if (permissionIntent == null)") &&
                requestConnect.indexOf("startActivityAndCollapse(") > requestConnect.indexOf("outcome = \"prompt_required\""),
        )

        assertTrue(
            "notification intent flags must be reusable",
            flagsDefinition.contains("PendingIntent.FLAG_UPDATE_CURRENT"),
        )
        assertFalse(
            "notification flags must not include one-shot",
            flagsDefinition.contains("PendingIntent.FLAG_ONE_SHOT"),
        )
        val fixedRequestCode = Regex("VpnPermissionActivity\\.pendingIntent\\(\\s*service\\s*,\\s*3\\s*,")
            .containsMatchIn(notificationConnect)
        assertTrue(
            "notification connect must stay on fixed requestCode 3",
            fixedRequestCode,
        )
        assertFalse(
            "notification connect must not force one-shot",
            notificationConnect.contains("oneShot = true"),
        )
    }

    @Test
    fun `transition tile states are unavailable and never enqueue a competing lifecycle command`() {
        val tileSource = sourceFile("TileService.kt")
        val statusBranch = functionBody(tileSource, "onServiceStatusChanged")
        val toggle = functionBody(tileSource, "toggleService")

        assertTrue(
            "tile must expose Started as ACTIVE and Stopped as INACTIVE",
            statusBranch.contains("Status.Started -> Tile.STATE_ACTIVE") &&
                statusBranch.contains("Status.Stopped -> Tile.STATE_INACTIVE"),
        )
        assertTrue(
            "transition states must be unavailable while the existing lifecycle owner settles",
            statusBranch.contains("Status.Starting, Status.Stopping -> Tile.STATE_UNAVAILABLE"),
        )
        val stopBranch = toggle.indexOf("Status.Started ->")
        assertTrue(
            "only a fully Started tile click may request stop",
            stopBranch >= 0 && toggle.indexOf("BoxService.stop(quickSettingsRequestId = requestId)", stopBranch) > stopBranch,
        )
        val connectBranch = toggle.indexOf("Status.Stopped ->")
        assertTrue(
            "only a fully Stopped tile click may request connect",
            connectBranch >= 0 &&
                toggle.indexOf("requestUserConnect(requestId)", connectBranch) > connectBranch,
        )
        val transitionBranch = toggle.indexOf("Status.Starting, Status.Stopping ->")
        val ignoredTransition = toggle.indexOf("ignored_transition", transitionBranch)
        assertTrue(
            "a transition click must be recorded and ignored instead of issuing Connect or Stop",
            transitionBranch >= 0 && ignoredTransition > transitionBranch,
        )
        val transitionBody = toggle.substring(transitionBranch)
        assertFalse("transition clicks must not stop the active lifecycle", transitionBody.contains("BoxService.stop("))
        assertFalse("transition clicks must not start a competing lifecycle", transitionBody.contains("requestUserConnect("))
    }

    @Test
    fun `legacy recovery has no Activity binding release or delayed reconnect path`() {
        val source = sourceFile("BoxService.kt")
        assertFalse(source.contains("releaseActivityServiceBindingForRecovery"))
        assertFalse(source.contains("PROCESS_RECOVERY_REBIND_DELAY_MS"))
        assertFalse(source.contains("MainActivity.instance"))
    }

    @Test
    fun `core cleanup retains packet sink for recovery and retires it only on terminal paths`() {
        val source = sourceFile("BoxService.kt")
        val cleanup = functionBody(source, "closeMobileCoreAndAwaitTunQuiescence")
        val admissionSeal = cleanup.indexOf("tunDescriptorAdmissionClosed = true")
        val retain = cleanup.indexOf("val failClosedVpnInstalled = ensurePhysicalFailClosedVpn(reason)")
        val coreClose = cleanup.indexOf("MobileCoreCloser.closeBlocking(reason)")
        val platformRetirement = cleanup.indexOf("val platformVpnRetired = when {")
        val recoveryBarrier = cleanup.indexOf("failClosedVpnInstalled && isFailClosedTunBarrierActive()")
        val platformRetirementCall = cleanup.indexOf("retirePlatformVpnSessionAfterCoreStop(", platformRetirement)
        val descriptorClose = cleanup.indexOf("closeTunFileDescriptor()", platformRetirementCall)
        val tunWait = cleanup.indexOf("awaitTunRuntimeQuiescence(", descriptorClose)
        val result = cleanup.indexOf("CoreCleanupResult(closeCompleted, platformVpnRetired, tunQuiescent)")
        assertTrue("cleanup must seal descriptor admission", admissionSeal >= 0)
        assertTrue("existing full-route descriptor is replaced by the physical packet sink before native close", retain > admissionSeal && coreClose > retain)
        assertTrue("automatic recovery must keep the retained descriptor as barrier", recoveryBarrier > platformRetirement)
        assertTrue("platform retirement must use shared release deadline", platformRetirementCall > platformRetirement)
        assertTrue("terminal cleanup retires the framework VPN before releasing the descriptor", descriptorClose > platformRetirementCall)
        assertTrue("terminal cleanup waits for Android release after closing descriptor", tunWait > descriptorClose)
        assertTrue(result > tunWait)
        val closeFailed = functionBody(source, "closeFailedRecoveryRuntime")
        val initialCleanup = closeFailed.indexOf("val initialCleanupResult = closeMobileCoreAndAwaitTunQuiescence(reason)")
        val recoverableWait = closeFailed.indexOf(
            "awaitRecoverableCoreCleanup(reason, generation, initialCleanupResult)",
            initialCleanup,
        )
        assertTrue("failed recovery must start with the regular close/TUN barrier", initialCleanup >= 0)
        assertTrue("a pending close must stay with the recovery owner rather than terminate", recoverableWait > initialCleanup)
        assertTrue(closeFailed.contains("cleanupResult?.completed == true"))
    }

    @Test
    fun `terminal TUN release is bounded while recovery keeps the full-route sink`() {
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
            "recovery branch must retain the full-route sink under the current active-session predicate",
            cleanup.contains("fun retainVpnForActiveSession(): Boolean") &&
                cleanup.contains("val retirementOutcome = when") &&
                cleanup.contains("val platformVpnRetained = retirementOutcome == PlatformVpnRetirementOutcome.RETAINED") &&
                cleanup.contains("PlatformVpnRetirementOutcome.RETAINED ->\n                failClosedVpnInstalled && isFailClosedTunBarrierActive()"),
        )
        assertTrue(
            "only the non-retained terminal branch may close the descriptor",
            cleanup.contains("if (platformVpnRetained) {") &&
                cleanup.contains("} else {\n            closeTunFileDescriptor()"),
        )

        val stopService = functionBody(source, "stopService")
        val stopQuiescence = stopService.indexOf("closeMobileCoreAndAwaitTunQuiescence")
        assertTrue("disconnect/cancel flow must await cleanup before hard kill check", stopQuiescence >= 0)
        assertFalse("disconnect/cancel path must not bypass guard with direct kill", stopService.contains("android.os.Process.killProcess"))
        assertTrue(
            "service stop cleanup must use serviceStopping=true",
            Regex("closeMobileCoreAndAwaitTunQuiescence\\([\\s\\S]*\"service stop\"[\\s\\S]*serviceStopping\\s*=\\s*true[\\s\\S]*\\)").containsMatchIn(stopService),
        )
    }

    @Test
    fun `terminal stop retires the exact marker VPN only after Android publishes it`() {
        val vpnService = sourceFile("VPNService.kt")
        val retire = functionBody(vpnService, "retirePlatformVpnSession")
        val session = Regex("session\\s*=\\s*\"marten-stop\"")
            .find(retire)?.range?.first ?: -1
        val establish = Regex("\\.establish\\s*\\(").find(retire)?.range?.first ?: -1
        val awaitPublication = retire.indexOf("awaitPlatformVpnRetirementNetwork(")
        val terminalEpochClaim = retire.indexOf("ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(")
        val close = retire.indexOf("service.closeTunFileDescriptorIfCurrent(retirementDescriptor)")
        val awaitRelease = retire.indexOf("awaitPlatformVpnRetirementRelease(")

        assertTrue("retirement must create the local marker session", session >= 0)
        assertTrue("marker session must be established before it is observed", establish > session)
        assertTrue(
            "descriptor must stay open until the marker Network is discovered",
            awaitPublication > establish,
        )
        assertTrue(
            "only the current terminal Stop epoch may close the tracked descriptor after marker Network discovery",
            terminalEpochClaim > awaitPublication && close > terminalEpochClaim,
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
            "marker wait must search for the exact unique retirement Network generation",
            awaitPublicationBody.contains("findPlatformVpnRetirementNetwork(connectivity, generation)"),
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
            "marker discovery must inspect the exact unique generation marker address",
            markerFinder.contains("generation.markerAddress"),
        )
        assertTrue(
            "marker discovery must delegate ownership and marker validation to the pure policy",
            markerFinder.contains("isMartenRetirementNetworkCandidate("),
        )

        val cleanup = functionBody(sourceFile("BoxService.kt"), "closeMobileCoreAndAwaitTunQuiescence")
        val terminalRetire = cleanup.indexOf("retirePlatformVpnSessionAfterCoreStop(")
        val terminalClose = cleanup.indexOf("closeTunFileDescriptor()", terminalRetire)
        assertTrue("only terminal cleanup may invoke framework retirement", terminalRetire >= 0)
        assertTrue("retirement marker is kept until its framework descriptor is released", terminalClose > terminalRetire)

        val stop = functionBody(sourceFile("BoxService.kt"), "stopService")
        val platformReleased = stop.indexOf("coreClosed.platformVpnRetired && coreClosed.tunQuiescent")
        val stopped = stop.indexOf("status.value = Status.Stopped", platformReleased)
        assertTrue("manual disconnect reaches Stopped after Android VPN release", stopped > platformReleased)
    }

    @Test
    fun `terminal cleanup paths retire their own platform owner while sticky destroy hands off the full-route descriptor`() {
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
        val preserve = onDestroy.indexOf("val shouldPreserveUserSession =")
        val handoff = onDestroy.indexOf("handoffTunFileDescriptorForStickyRecovery()")
        val cleanupRegistration = onDestroy.indexOf("registerDestroyCleanup(", handoff)
        val preservedStarting = onDestroy.indexOf("status.value = Status.Starting", preserve)
        val terminalStopped = onDestroy.indexOf("status.value = Status.Stopped", preserve)
        val stickyIntent = onDestroy.indexOf("Settings.startCoreAfterStartingService = preservePublishedSession")
        val detachNotification = onDestroy.indexOf("notification.close(", stickyIntent)
        val successorAdoption = functionBody(source, "onStartCommand").indexOf("adoptStickyTunHandoffIfAvailable()")
        assertTrue("sticky destroy must publish the descriptor before shared cleanup registration", handoff > preserve && cleanupRegistration > handoff)
        assertTrue("sticky destroy must publish recovery rather than Stopped", preservedStarting > preserve)
        assertTrue("terminal Stopped must remain guarded by the non-sticky branch", terminalStopped > preservedStarting)
        assertTrue("sticky user intent must survive through the next service admission", stickyIntent > terminalStopped)
        assertTrue("destroy must detach its notification after recording sticky state", detachNotification > stickyIntent)
        assertTrue("the replacement service must adopt the shared full-route handoff before command admission", successorAdoption >= 0)
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
    fun `terminal cleanup forwards serviceStopping to bounded Android TUN release`() {
        val source = sourceFile("BoxService.kt")
        val cleanup = functionBody(source, "closeMobileCoreAndAwaitTunQuiescence")
        assertTrue(
            "closeMobileCoreAndAwaitTunQuiescence must forward serviceStopping into awaitTunRuntimeQuiescence",
            cleanup.contains("awaitTunRuntimeQuiescence(\n                reason,\n                serviceStopping,"),
        )
        val stopService = functionBody(source, "stopService")
        assertTrue(
            Regex("closeMobileCoreAndAwaitTunQuiescence\\([\\s\\S]*\"service stop\"[\\s\\S]*serviceStopping\\s*=\\s*true[\\s\\S]*\\)").containsMatchIn(
                stopService,
            ),
        )
    }

    @Test
    fun `automatic recovery keeps cleanup fail-closed without terminally stopping the user session`() {
        val source = sourceFile("BoxService.kt")
        val recovery = functionBody(source, "recoverMobileCore")
        val cleanup = recovery.indexOf("closeMobileCoreAndAwaitTunQuiescence(")
        val recoverableCleanup = recovery.indexOf("awaitRecoverableCoreCleanup(", cleanup)
        val setup = recovery.indexOf("Mobile.setup(", cleanup)
        assertTrue(cleanup >= 0)
        assertTrue("automatic recovery must await the exact pending cleanup barrier", recoverableCleanup > cleanup)
        assertTrue("a new core/TUN setup stays behind cleanup completion", setup > recoverableCleanup)
        assertFalse(
            "automatic cleanup timeout must not publish a terminal cleanup failure",
            recovery.contains("finishCoreCleanupFailure("),
        )

        val awaitCleanup = functionBody(source, "awaitRecoverableCoreCleanup")
        val admissionSeal = awaitCleanup.indexOf("tunDescriptorAdmissionClosed = true")
        val retain = awaitCleanup.indexOf("ensurePhysicalFailClosedVpn(", admissionSeal)
        val closeAsync = awaitCleanup.indexOf("MobileCoreCloser.closeAsync(", retain)
        val exactCloseWait = awaitCleanup.indexOf("MobileCoreCloser.awaitCloseToFinish(", closeAsync)
        assertTrue("automatic cleanup must keep descriptor admission sealed", admissionSeal >= 0)
        assertTrue("automatic cleanup must retain its full-route descriptor as packet sink", retain > admissionSeal)
        assertTrue(
            "automatic cleanup may request exactly one asynchronous close only when the initial close is incomplete, then await that exact completion event",
            closeAsync > retain && exactCloseWait > closeAsync &&
                awaitCleanup.substring(retain, closeAsync).contains("if (!initialResult.nativeCloseCompleted)") &&
                Regex("MobileCoreCloser\\.closeAsync\\(").findAll(awaitCleanup).count() == 1,
        )
        assertFalse("automatic cleanup must not start a second native close", awaitCleanup.contains("MobileCoreCloser.closeBlocking("))
        assertFalse("automatic cleanup must never close the retained descriptor", awaitCleanup.contains("closeTunFileDescriptor()"))
        assertFalse("automatic cleanup must never retire the framework VPN", awaitCleanup.contains("retirePlatformVpnSession"))
        assertFalse("automatic cleanup must not terminally clear user intent", awaitCleanup.contains("Settings.startedByUser = false"))

        val stop = functionBody(source, "stopService")
        val platformFailure = stop.indexOf("if (!platformShutdownCompleted)")
        val terminalFailure = stop.indexOf("finishCoreCleanupFailure(", platformFailure)
        assertTrue("manual stop escalates only when Android VPN/TUN release is unconfirmed", platformFailure >= 0)
        assertTrue("manual platform-release failure enters the terminal fail-closed path", terminalFailure > platformFailure)

        val alertStop = functionBody(source, "stopAndAlert")
        val alertCleanupFailure = alertStop.indexOf("if (requiresCoreCleanupEscalation(")
        val alertTerminalFailure = alertStop.indexOf("finishCoreCleanupFailure(", alertCleanupFailure)
        assertTrue("alert stop must guard an incomplete core/TUN cleanup", alertCleanupFailure >= 0)
        assertTrue("alert cleanup failure must use the shared terminal handler", alertTerminalFailure > alertCleanupFailure)
    }

    @Test
    fun `active regular cleanup retains newest exact terminal Stop instead of coalescing it away`() {
        val source = sourceFile("BoxService.kt")
        val stopService = functionBody(source, "stopService")
        val deferStop = functionBody(source, "deferTerminalStopUntilCleanupCompletes")
        val completion = functionBody(source, "onServiceStopCleanupCompleted")
        assertTrue(
            "service stop must retain the concrete Job ownership used to serialize terminal cleanup",
            source.contains("private var serviceStopJob: Job? = null"),
        )
        val terminalIntent = stopService.indexOf("val terminalIntent = if (terminalStopAlreadyClaimed)")
        val predecessor = stopService.indexOf("val predecessorStopJob = serviceStopJob", terminalIntent)
        val activePredecessor = stopService.indexOf("predecessorStopJob?.isActive == true", predecessor)
        val seal = stopService.indexOf("tunDescriptorAdmissionClosed = true", activePredecessor)
        val cancelGeneration = stopService.indexOf("val deferredStopGeneration = cancelPendingStarts()", seal)
        val defer = stopService.indexOf("deferTerminalStopUntilCleanupCompletes(", cancelGeneration)
        val activeBranch = stopService.substring(activePredecessor, defer)

        assertTrue(
            "a newer terminal Stop must immediately seal descriptor admission and invalidate its current start generation while a regular predecessor cleanup remains active",
            terminalIntent >= 0 && predecessor > terminalIntent && activePredecessor > predecessor &&
                seal > activePredecessor && cancelGeneration > seal && defer > cancelGeneration,
        )
        assertFalse(
            "an active regular serviceStopJob must not coalesce/return before retaining the newest terminal Stop",
            activeBranch.contains("if (serviceStopJob?.isActive == true) return") ||
                activeBranch.contains("if (predecessorStopJob?.isActive == true) return"),
        )
        assertTrue(
            "the deferred terminal Stop must retain the exact predecessor Job and terminal intent rather than a boolean retry flag",
            deferStop.contains("DeferredTerminalStopAfterCleanup(") &&
                deferStop.contains("predecessorJob = predecessorJob") &&
                deferStop.contains("terminalIntent = terminalIntent"),
        )

        val matchingPredecessor = completion.indexOf("it.predecessorJob === completedJob")
        val currentEpoch = completion.indexOf("isTerminalStopEpochCurrent(", matchingPredecessor)
        val staleReturn = completion.indexOf("return@post", currentEpoch)
        val replay = completion.indexOf("target.stopService(", staleReturn)
        assertTrue(
            "only the predecessor completion event may replay the still-current deferred Stop; a superseded terminal epoch returns first",
            matchingPredecessor >= 0 && currentEpoch > matchingPredecessor && staleReturn > currentEpoch && replay > staleReturn,
        )
        assertFalse(
            "the exact deferred Stop handoff must not introduce a timer, delay, or polling workaround",
            deferStop.contains("Timer(") || deferStop.contains("delay(") ||
                completion.contains("Timer(") || completion.contains("delay("),
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
        val retainSink = terminal.indexOf("ensurePhysicalFailClosedVpn(\"terminal core cleanup failure\")")
        val nativeClose = terminal.indexOf("MobileCoreCloser.closeAsync(\"terminal core cleanup failure\")")
        val platformRetirement = terminal.indexOf("retirePlatformVpnSessionAfterFailedCoreCleanup")
        val descriptorClose = terminal.indexOf("closeTunFileDescriptor()")
        val stoppedDecision = terminal.indexOf("status.value = Status.Stopped", descriptorClose)

        assertTrue(terminal.contains("terminalCoreCleanupFailurePublished"))
        assertTrue(terminal.contains("Settings.startedByUser = false"))
        assertTrue(terminal.contains("cancelLegacyProcessRecoveryAlarm()"))
        assertTrue("terminal failure must preserve the full-route sink while native close is pending", retainSink >= 0)
        assertTrue("terminal failure must start one shared native close", nativeClose > retainSink)
        assertTrue(terminal.contains("status.value = Status.Stopping"))
        assertTrue("only terminal failure can retire the platform VPN", platformRetirement > nativeClose)
        assertTrue("descriptor release follows retirement", descriptorClose > platformRetirement)
        assertTrue(
            "after its bounded Android VPN/TUN attempt, terminal failure must leave Stopping as Stopped even when the exact retained owner cannot yet be released",
            stoppedDecision > descriptorClose,
        )
        assertFalse(
            "a terminal failure must not leave the UI in Stopping by branching on incomplete platform release",
            terminal.contains("status.value = if (platformShutdownCompleted)"),
        )
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
    fun `both native startup paths arm bounded startup supervision before starting mobile core`() {
        val source = sourceFile("BoxService.kt")
        val serviceStart = functionBody(source, "startService")
        val serviceNativeStart = serviceStart.indexOf("val startCoreInService = synchronized(lifecycleLock)")
        val serviceMonitor = serviceStart.indexOf("startCoreRuntimeMonitor(nativeStartup = true)", serviceNativeStart)
        val serviceMobileStart = serviceStart.indexOf("startMobileCoreFromNativePath(", serviceMonitor)

        assertTrue("service-start native work must atomically claim the coalesced request", serviceNativeStart >= 0)
        assertTrue(serviceMonitor > serviceNativeStart)
        assertTrue("startup monitor must be armed before native start", serviceMobileStart > serviceMonitor)
        assertFalse("the recovery deadline supervisor must not start before recovery is admitted", serviceStart.contains("startCoreWatchdog()"))

        val nativeEntry = functionBody(source, "startStoredCoreFromNativeEntryPoint")
        val entryMonitor = nativeEntry.indexOf("startCoreRuntimeMonitor(nativeStartup = true)")
        val entryMobileStart = nativeEntry.indexOf("startMobileCoreFromNativePath(", entryMonitor)

        assertTrue(entryMonitor >= 0)
        assertTrue(entryMobileStart > entryMonitor)
        assertFalse("native startup must not start the recovery-only deadline supervisor", nativeEntry.contains("startCoreWatchdog()"))
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
        assertFalse(
            "the native startup runtime monitor must not retain the legacy 250 ms poll constant",
            source.contains("CORE_RUNTIME_MONITOR_POLL_MS"),
        )
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
        assertTrue(
            "runtime monitor must share the sparse screen-aware watchdog schedule",
            monitor.contains("coreWatchdogPollDelayMs(") &&
                monitor.contains("recoveryInProgress = true") &&
                monitor.contains("deviceInteractive = Application.powerManager.isInteractive"),
        )
        assertFalse("runtime monitor must not hard-code a 250 ms delay", monitor.contains("delay(250L)"))
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
        )
        runtimeRecoverySites.forEach { name ->
            val body = functionBody(source, name)
            assertTrue("$name must request recovery through the admission gate", body.contains("requestCoreRecovery("))
            assertFalse("$name must not bypass the recovery admission gate", body.contains("launchCoreRecovery("))
        }

        val deadlineSupervisor = functionBody(source, "startCoreWatchdog")
        assertTrue("the recovery-only watchdog must enforce the shared online deadline", deadlineSupervisor.contains("shouldTerminateExpiredCoreRecovery("))
        assertTrue("deadline expiry must use terminal cleanup", deadlineSupervisor.contains("terminateExpiredCoreRecovery("))
        assertFalse("the recovery-only deadline watchdog must not admit a second recovery", deadlineSupervisor.contains("requestCoreRecovery("))

        val routeRecovery = functionBody(source, "recoverRoute")
        assertTrue("route watchdog must attempt bounded in-place route recovery", routeRecovery.contains("launchNetworkRouteRecovery("))
        assertFalse("recoverRoute must not call core recovery directly", routeRecovery.contains("requestCoreRecovery("))
        assertFalse("recoverRoute must not rebuild core and TUN directly", routeRecovery.contains("launchCoreRecovery("))

        val nativeProof = functionBody(source, "verifyNativeStartupRoute")
        assertTrue("failed native route proof must use recovery admission", nativeProof.contains("requestCoreRecovery("))
        assertFalse("native route proof must not bypass recovery admission", nativeProof.contains("launchCoreRecovery("))
        val networkRouteRecovery = functionBody(source, "recoverNetworkRoute")
        val networkRouteUnhealthy = networkRouteRecovery.indexOf("if (!isCoreRuntimeHealthy(coreState))")
        val requestFromCoreUnhealthy = networkRouteRecovery.indexOf(
            "requestCoreRecovery(\"network route recovery found an unhealthy core:",
            networkRouteUnhealthy,
        )
        val networkReset = networkRouteRecovery.indexOf("Mobile.resetNetwork()")
        val resetFailure = networkRouteRecovery.indexOf("if (resetResult.isFailure)", networkReset)
        val requestFromResetFailure = networkRouteRecovery.indexOf(
            "requestCoreRecovery(\"native ${'$'}resetKind failed during ${'$'}reason\")",
            resetFailure,
        )
        val routeAttempt = networkRouteRecovery.indexOf("routeAttempt += 1")
        val requestFromFallback = networkRouteRecovery.indexOf("requestCoreRecovery(", routeAttempt)
        val boundedFallback = networkRouteRecovery.indexOf("result.requiresCoreRecovery && routeAttempt >= 2", routeAttempt)
        val boundedMax = networkRouteRecovery.indexOf("routeAttempt >= NETWORK_ROUTE_RECOVERY_MAX_ATTEMPTS", boundedFallback)
        assertTrue(
            "recoverNetworkRoute must escalate unhealthy core to core recovery",
            networkRouteUnhealthy >= 0 && requestFromCoreUnhealthy > networkRouteUnhealthy,
        )
        assertTrue(
            "recoverNetworkRoute must escalate a failed in-place network reset through recovery admission",
            networkReset >= 0 && resetFailure > networkReset && requestFromResetFailure > resetFailure,
        )
        assertTrue(
            "recoverNetworkRoute must use bounded fresh-proof failures before requesting core recovery",
            routeAttempt >= 0 &&
                boundedFallback > routeAttempt && boundedMax > boundedFallback &&
                requestFromFallback > boundedMax &&
                requestFromFallback > requestFromCoreUnhealthy,
        )
        assertFalse("recoverNetworkRoute must not launch core recovery directly", networkRouteRecovery.contains("launchCoreRecovery("))
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
        val retryDelay = request.indexOf("val retryDelayMs = coreRecoveryAdmissionRetryDelayMs(", loop)
        val interactivePolicy = request.indexOf("deviceInteractive = Application.powerManager.isInteractive", retryDelay)
        val eventWait = request.indexOf("ServiceLifecycleOwnership.awaitNativeRecoveryAdmissionChange(", interactivePolicy)
        val retryLaunch = request.indexOf("if (launchCoreRecovery(reason, generation))", eventWait)
        val retryStart = request.indexOf("scheduled.start()", retryLaunch)

        assertTrue(request.contains("if (coreRecoveryAdmissionRetryJob?.isActive == true)"))
        assertTrue(retryAssignment == 1)
        assertTrue(loop >= 0)
        assertTrue(retryDelay > loop)
        assertTrue("retry fallback must stay screen-aware", interactivePolicy > retryDelay)
        assertTrue("retry must await lifecycle ownership changes instead of issuing a direct delay", eventWait > interactivePolicy && !request.contains("delay("))
        assertTrue(retryLaunch > eventWait)
        assertTrue("the sole retry Job must be started after its cancellation cleanup and sparse-fallback log are installed", retryStart > retryLaunch)
        assertTrue(request.contains("core recovery admitted after"))
        assertTrue(request.contains("core recovery admission remains pending"))
        assertTrue(request.contains("core recovery admission waiting for lifecycle release with sparse fallback"))
        assertTrue(request.contains("scheduled.invokeOnCompletion"))

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
    fun `manual Stop keeps TUN sealed through event-driven terminal handoff and preserves revoke`() {
        val stop = functionBody(sourceFile("BoxService.kt"), "stopService")
        val defer = functionBody(sourceFile("BoxService.kt"), "deferTerminalStopUntilCleanupCompletes")
        val completion = functionBody(sourceFile("BoxService.kt"), "onServiceStopCleanupCompleted")
        val predecessor = stop.indexOf("val predecessorStopJob = serviceStopJob")
        val activePredecessor = stop.indexOf("predecessorStopJob?.isActive == true", predecessor)
        val seal = stop.indexOf("tunDescriptorAdmissionClosed = true", activePredecessor)
        val retainProof = stop.indexOf("invalidateVpnDataPlaneProof(\"terminal Stop queued behind older service cleanup\")", seal)
        val deferCall = stop.indexOf("deferTerminalStopUntilCleanupCompletes(", retainProof)
        val activeBranch = stop.substring(activePredecessor, deferCall)
        val currentEpoch = completion.indexOf("isTerminalStopEpochCurrent(")
        val staleReturn = completion.indexOf("return@post", currentEpoch)
        val replay = completion.indexOf("target.stopService(", staleReturn)

        assertTrue("stop must atomically seal TUN descriptor admission", seal >= 0)
        assertTrue(
            "a newer terminal Stop must retain the fail-closed TUN/proof barrier while it waits for the active predecessor cleanup",
            retainProof > seal && deferCall > retainProof,
        )
        assertFalse(
            "the waiting branch must not close or reopen the TUN itself before predecessor completion drives the exact handoff",
            activeBranch.contains("closeTunFileDescriptor()") ||
                activeBranch.contains("closeMobileCoreAndAwaitTunQuiescence(") ||
                activeBranch.contains("tunDescriptorAdmissionClosed = false"),
        )
        assertTrue(
            "the event-driven handoff must discard stale terminal epochs before replaying the current Stop",
            currentEpoch >= 0 && staleReturn > currentEpoch && replay > staleReturn,
        )
        assertTrue(
            "VPN revoke must remain part of the exact deferred Stop and be forwarded when predecessor cleanup completes",
            defer.contains("vpnRevoked = vpnRevoked") &&
                completion.substring(replay).contains("vpnRevoked = deferredStop.vpnRevoked"),
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
        val wait = start.indexOf("MobileCoreCloser.waitForCloseToFinish(")
        val failure = start.indexOf("finishCoreCleanupFailure(", wait)
        val stillStopping = start.indexOf("R.string.error_connection_still_stopping", failure)
        val returnAfterFailure = start.indexOf("return", stillStopping)

        assertTrue("Connect must make one bounded wait for a prior native close", wait >= 0)
        val closeBarrier = start.substring(wait, failure)
        assertTrue("close wait must carry the service generation", closeBarrier.contains("reason = \"service start generation=\$generation\""))
        assertTrue("close wait must use the explicit 60s admission timeout", closeBarrier.contains("timeoutMs = CORE_START_ADMISSION_TIMEOUT_MS"))
        assertTrue("timeout must enter the terminal cleanup failure owner", failure > wait)
        assertTrue("timeout must report that the connection is still stopping", stillStopping > failure)
        assertTrue("timeout branch must return immediately after reporting failure", returnAfterFailure > stillStopping)

        val timeoutBranch = start.substring(wait, returnAfterFailure)
        assertFalse("timeout branch must not invoke a second alert cleanup", timeoutBranch.contains("stopAndAlert("))
        assertFalse("timeout branch must not join another native close", timeoutBranch.contains("MobileCoreCloser.closeBlocking"))
        assertEquals("timeout branch must have exactly one native-close wait", 1, timeoutBranch.split("MobileCoreCloser.waitForCloseToFinish(").size - 1)
    }

    @Test
    fun `pending service cleanup timeout publishes still stopping failure without a second close`() {
        val start = functionBody(sourceFile("BoxService.kt"), "startService")
        val wait = start.indexOf("ServiceLifecycleOwnership.awaitPendingCleanup(")
        val failure = start.indexOf("finishCoreCleanupFailure(", wait)
        val stillStopping = start.indexOf("R.string.error_connection_still_stopping", failure)
        val returnAfterFailure = start.indexOf("return", stillStopping)

        assertTrue("Connect must use the ownership cleanup barrier", wait >= 0)
        val cleanupBarrier = start.substring(wait, failure)
        assertTrue("cleanup barrier must await the current service owner", cleanupBarrier.contains("serviceOwnerToken"))
        assertTrue("cleanup barrier must use the explicit 60s admission timeout", cleanupBarrier.contains("timeoutMs = CORE_START_ADMISSION_TIMEOUT_MS"))
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
