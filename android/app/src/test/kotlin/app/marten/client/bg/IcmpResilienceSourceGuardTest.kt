package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IcmpResilienceSourceGuardTest {
    @Test
    fun `route acknowledgement is volatile fail-closed and reaches the lifecycle guard`() {
        val source = sourceFile("BoxService.kt")
        assertTrue(
            "active BoxService publication must be visible across MethodHandler and service threads",
            Regex("@Volatile\\s+private var activeInstance: BoxService\\? = null").containsMatchIn(source),
        )

        val acknowledgement = functionBody(source, "acknowledgeVerifiedRoute")
        assertTrue(acknowledgement.contains("val instance = activeInstance"))
        assertTrue(acknowledgement.contains("if (instance == null)"))
        assertTrue(acknowledgement.contains("return false"))
        assertTrue(acknowledgement.contains("instance.markCoreRuntimeStarted(routeVerified = true)"))

        val started = functionBody(source, "markCoreRuntimeStarted")
        assertTrue(started.contains("shouldContinueStart(generation)"))
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
    fun `open tun passes and returns the same establisher descriptor with no dup or detach`() {
        val source = sourceFile("VPNService.kt")
        val openTun = functionBody(source, "openTun")

        val establishMatch = Regex("val (\\w+) = builder\\.establish\\(\\)\\s*\\?:").find(openTun)
        assertTrue("openTun must capture establisher descriptor from builder.establish()", establishMatch != null)
        val establisher = establishMatch?.groupValues?.get(1)
        assertTrue("unable to resolve establisher variable name", establisher != null)
        val establisherName = establisher ?: ""
        val replace = openTun.indexOf("service.replaceTunFileDescriptor($establisherName)")
        val establish = openTun.indexOf("val $establisherName = builder.establish()")
        val escapedEstablisher = Regex.escape(establisherName)
        val directReturn = Regex("""return\s+$escapedEstablisher\.fd\b""").find(openTun)
        val nativeFdAlias = Regex("""val\s+(\w+)\s*=\s*$escapedEstablisher\.fd\b""").find(openTun)
        val aliasReturn = nativeFdAlias?.let { alias ->
            Regex("""return\s+${Regex.escape(alias.groupValues[1])}\b""")
                .find(openTun, alias.range.last + 1)
        }
        val returnDescriptor = directReturn?.range?.first ?: aliasReturn?.range?.first ?: -1
        val establisherClose = openTun.indexOf("$establisherName.close()", establish)
        val establisherRelease = openTun.indexOf("$establisherName.detachFd()", establish)

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
    fun `SERVICE_RECOVER active path releases Activity binding and schedules delayed restart`() {
        val source = sourceFile("BoxService.kt")
        val onStart = functionBody(source, "onStartCommand")
        val activeStart = onStart.indexOf("if (status.value != Status.Stopped) {")
        val activeEnd = onStart.indexOf("status.value = Status.Starting")
        assertTrue(activeStart >= 0)
        assertTrue(activeEnd > activeStart)

        val activeService = onStart.substring(activeStart, activeEnd)
        val replacementCondition = activeService.indexOf("processRecoveryRequested &&")
        assertTrue(
            "SERVICE_RECOVER path should be guarded by processRecovery and replacement request",
            replacementCondition >= 0,
        )
        val replacementStart = activeService.lastIndexOf("if (", replacementCondition)
        assertTrue(replacementStart >= 0)

        val replacementEnd = activeService.indexOf(
            "if ((restartedBySystem || processRecoveryRequested) && !connectFromNotification)",
            replacementCondition,
        )
        assertTrue(replacementEnd > replacementStart)
        val replacement = activeService.substring(replacementStart, replacementEnd)

        assertTrue(replacement.contains("vpnServiceReplacementRequested &&"))
        assertTrue(replacement.contains("shouldRestoreUserSession"))
        assertTrue(replacement.contains("releaseActivityServiceBindingForRecovery()"))
        assertTrue(replacement.contains("scheduleProcessRecovery()"))
        assertTrue(replacement.contains("service.stopSelf()"))

        val releaseBinding = replacement.indexOf("releaseActivityServiceBindingForRecovery()")
        val scheduleRecovery = replacement.indexOf("scheduleProcessRecovery()")
        val stopSelf = replacement.indexOf("service.stopSelf()")
        assertTrue(releaseBinding >= 0)
        assertTrue(scheduleRecovery > releaseBinding)
        assertTrue(stopSelf > scheduleRecovery)
        assertTrue(
            "replacement path should launch and then return sticky",
            replacement.lastIndexOf("return Service.START_STICKY") >
                maxOf(releaseBinding, scheduleRecovery, stopSelf),
        )
        assertTrue(
            "active SERVICE_RECOVER replacement must not relaunch service in place",
            replacement.indexOf("startService(nextStartGeneration())") < 0,
        )
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
    fun `newly accepted start reopens TUN descriptor admission under the descriptor lock`() {
        val onStart = functionBody(sourceFile("BoxService.kt"), "onStartCommand")
        val stoppedOwnerBranch = onStart.indexOf("if (status.value != Status.Stopped) {")
        val admissionLock = onStart.indexOf("synchronized(fileDescriptorLock)", stoppedOwnerBranch)
        val reopenAdmission = onStart.indexOf("tunDescriptorAdmissionClosed = false", admissionLock)
        val starting = onStart.indexOf("status.value = Status.Starting", admissionLock)
        val restore = onStart.indexOf("if (shouldRestoreUserSession)", admissionLock)

        assertTrue(stoppedOwnerBranch >= 0)
        assertTrue("accepted start must re-open descriptor admission under fileDescriptorLock", admissionLock > stoppedOwnerBranch)
        assertTrue(reopenAdmission > admissionLock)
        assertTrue(starting > reopenAdmission)
        assertTrue("descriptor admission must open before restored/native start work", restore > starting)
    }

    @Test
    fun `ownership watchdog starts before native setup and counts loss only after own VPN was established`() {
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
        assertTrue(watchdog.contains("explicitVpnTakeoverPending = false"))
        assertTrue(watchdog.contains("if (!ownership.known || !vpnOwnershipWasEstablished)"))
        assertTrue(watchdog.contains("consecutiveOwnVpnMisses = 0"))
        assertTrue(watchdog.contains("consecutiveOwnVpnMisses += 1"))
        assertTrue(watchdog.contains("shouldStopForLostVpnOwnership("))
        assertTrue(watchdog.contains("requiredMisses = EXTERNAL_VPN_OWNERSHIP_LOSS_CONFIRMATIONS"))
        assertTrue(watchdog.contains("stopForExternalVpnOnMain("))
    }

    @Test
    fun `Quick Settings starts a user-initiated VPN takeover while boot restore does not`() {
        val tile = sourceFile("TileService.kt")
        val toggle = functionBody(tile, "toggleService")
        assertTrue(toggle.contains("BoxService.connect(userInitiated = true)"))

        val boot = sourceFile("BootReceiver.kt")
        val receive = functionBody(boot, "onReceive")
        assertTrue(receive.contains("BoxService.connect(userInitiated = false)"))
    }

    @Test
    fun `SERVICE_RECOVER binding release posts delayed reconnect and retries recovery from stale active service`() {
        val source = sourceFile("BoxService.kt")
        val releaseBinding = functionBody(source, "releaseActivityServiceBindingForRecovery")

        val activityAssignment = releaseBinding.indexOf("val activity = runCatching { MainActivity.instance }.getOrNull() ?: return")
        val instanceGuard = releaseBinding.indexOf("if (activity.isFinishing || activity.isDestroyed) return")
        val disconnect = releaseBinding.indexOf("activity.disconnectServiceBinding()")
        val postDelayed = releaseBinding.indexOf("mainHandler.postDelayed({")
        val reconnect = releaseBinding.indexOf("activity.reconnect()")
        val reconnectGuard = releaseBinding.indexOf("currentActivity === activity")
        val delayMs = releaseBinding.indexOf("PROCESS_RECOVERY_REBIND_DELAY_MS")

        assertTrue(activityAssignment >= 0)
        assertTrue(instanceGuard > activityAssignment)
        assertTrue(disconnect > instanceGuard)
        assertTrue(postDelayed > disconnect)
        assertTrue(reconnectGuard > postDelayed)
        assertTrue(reconnect > reconnectGuard)
        assertTrue(delayMs > postDelayed)
        assertTrue(reconnect < delayMs)
    }

    @Test
    fun `core cleanup closes descriptor propagates close result and waits for TUN release`() {
        val source = sourceFile("BoxService.kt")
        val cleanup = functionBody(source, "closeMobileCoreAndAwaitTunQuiescence")
        val descriptorClose = cleanup.indexOf("closeTunFileDescriptor()")
        val coreClose = cleanup.indexOf("MobileCoreCloser.closeBlocking(reason)")
        val tunWait = cleanup.indexOf("awaitTunRuntimeQuiescence(reason, serviceStopping)")
        val result = cleanup.indexOf("CoreCleanupResult(closeCompleted, tunQuiescent)")
        assertTrue(descriptorClose >= 0)
        assertTrue(coreClose > descriptorClose)
        assertTrue(tunWait > coreClose)
        assertTrue(result > tunWait)
        val closeFailed = functionBody(source, "closeFailedRecoveryRuntime")
        assertTrue(closeFailed.contains("val cleanupResult = closeMobileCoreAndAwaitTunQuiescence(reason)"))
        assertTrue(Regex("\\n\\s*cleanupResult\\.completed\\s*\\n\\s*}").containsMatchIn(closeFailed))
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
        val deadline = awaitTun.indexOf("val deadline = SystemClock.elapsedRealtime() + TUN_RELEASE_TIMEOUT_MS")
        val elapsedGuard = awaitTun.indexOf("SystemClock.elapsedRealtime() < deadline")
        val delayPoll = awaitTun.indexOf("delay(TUN_RELEASE_POLL_MS)")
        val returnResult = awaitTun.indexOf("return quiescent")
        assertTrue("awaitTunRuntimeQuiescence must use the bounded timeout constant", deadline >= 0)
        assertTrue("awaitTunRuntimeQuiescence must exit only after deadline", elapsedGuard > deadline)
        assertTrue("awaitTunRuntimeQuiescence must actively poll while waiting", delayPoll > elapsedGuard)
        assertTrue("awaitTunRuntimeQuiescence must return quiescence outcome", returnResult > delayPoll)

        val cleanup = functionBody(source, "closeMobileCoreAndAwaitTunQuiescence")
        assertTrue("cleaning mobile core must close descriptor first", cleanup.contains("closeTunFileDescriptor()"))
        assertTrue(
            "mobile core close must run before tun quiescence wait",
            cleanup.indexOf("MobileCoreCloser.closeBlocking(reason)") > cleanup.indexOf("closeTunFileDescriptor()"),
        )
        assertTrue(
            "TUN quiescence must be awaited after close",
            cleanup.indexOf("awaitTunRuntimeQuiescence(reason, serviceStopping)") > cleanup.indexOf(
                "MobileCoreCloser.closeBlocking(reason)",
            ),
        )

        val stopService = functionBody(source, "stopService")
        val stopQuiescence = stopService.indexOf("closeMobileCoreAndAwaitTunQuiescence")
        val stopGuard = findCleanupFailureGuard(stopService)
        val stopReplacement = stopService.indexOf("replaceVpnServiceAfterCoreCleanupFailure(", stopGuard)
        val stopStopped = stopService.indexOf("status.value = Status.Stopped", stopReplacement)
        assertTrue("disconnect/cancel flow must await cleanup before hard kill check", stopQuiescence >= 0)
        assertTrue("disconnect/cancel flow must evaluate termination requirement", stopGuard > stopQuiescence)
        assertTrue("replacement helper must be checked after cleanup result", stopReplacement > stopGuard)
        assertTrue("foreground stop should mark Stopped after replacement decision", stopStopped > stopReplacement)
        assertFalse("disconnect/cancel path must not bypass guard with direct kill", stopService.contains("android.os.Process.killProcess"))
        assertTrue(
            "service stop cleanup must use serviceStopping=true",
            Regex("closeMobileCoreAndAwaitTunQuiescence\\([\\s\\S]*\"service stop\"[\\s\\S]*serviceStopping\\s*=\\s*true[\\s\\S]*\\)").containsMatchIn(stopService),
        )
    }

    @Test
    fun `completed native stop retires Samsung framework VPN ownership with a local closed replacement TUN`() {
        val vpnService = sourceFile("VPNService.kt")
        val retire = functionBody(vpnService, "retirePlatformVpnSessionAfterCoreStop")
        val builder = retire.indexOf("Builder()")
        val session = retire.indexOf("setSession(\"marten-stop\")", builder)
        val establish = retire.indexOf("establish()", session)
        val close = retire.indexOf(".close()", establish)

        assertTrue(builder >= 0)
        assertTrue(session > builder)
        assertTrue(establish > session)
        assertTrue("local replacement TUN must be closed immediately", close > establish)
        assertFalse("teardown TUN must never be handed to the core owner", retire.contains("replaceTunFileDescriptor"))
        assertFalse("framework teardown must not restart or re-open the native core", retire.contains("Mobile."))

        val stop = functionBody(sourceFile("BoxService.kt"), "stopService")
        val completed = stop.indexOf("coreClosed.completed")
        val retireCall = stop.indexOf("retirePlatformVpnSessionAfterCoreStop()", completed)
        val stopped = stop.indexOf("status.value = Status.Stopped", completed)
        assertTrue(completed >= 0)
        assertTrue("framework teardown follows completed core and retained-TUN cleanup", retireCall > completed)
        assertTrue("manual disconnect still reaches Stopped after framework teardown", stopped > retireCall)
    }

    @Test
    fun `terminal cleanup paths use tolerant TUN release completion for service stop, cancel, alert, and destroy`() {
        val source = sourceFile("BoxService.kt")

        val finishCancelledStart = functionBody(source, "finishCancelledStart")
        assertTrue(finishCancelledStart.contains("closeMobileCoreAndAwaitTunQuiescence("))
        assertTrue(finishCancelledStart.contains("serviceStopping = true"))
        assertTrue(finishCancelledStart.contains("replaceVpnServiceAfterCoreCleanupFailure("))
        val stopService = functionBody(source, "stopService")
        assertTrue(stopService.contains("closeMobileCoreAndAwaitTunQuiescence("))
        assertTrue(stopService.contains("\"service stop\""))
        assertTrue(stopService.contains("serviceStopping = true"))
        assertTrue(stopService.contains("replaceVpnServiceAfterCoreCleanupFailure("))
        assertTrue(stopService.contains("service.stopSelf()"))
        val stopAndAlert = functionBody(source, "stopAndAlert")
        assertTrue(stopAndAlert.contains("closeMobileCoreAndAwaitTunQuiescence("))
        assertTrue(stopAndAlert.contains("\"service alert\""))
        assertTrue(stopAndAlert.contains("serviceStopping = true"))
        assertTrue(stopAndAlert.contains("replaceVpnServiceAfterCoreCleanupFailure("))
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
        assertTrue(recover.contains("closeMobileCoreAndAwaitTunQuiescence(\"core watchdog recovery attempt"))
        assertTrue(closeFailed.contains("closeMobileCoreAndAwaitTunQuiescence(reason)"))
    }

    @Test
    fun `awaitTunRuntimeQuiescence checks serviceStopping argument for terminal cleanup path`() {
        val source = sourceFile("BoxService.kt")
        assertTrue(
            "closeMobileCoreAndAwaitTunQuiescence must forward serviceStopping into awaitTunRuntimeQuiescence",
            Regex("awaitTunRuntimeQuiescence\\(reason,\\s*serviceStopping\\)").containsMatchIn(
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
        val replacement = recovery.indexOf("replaceVpnServiceAfterCoreCleanupFailure(", cleanupFailure)
        val replacementReturn = recovery.indexOf("return", replacement)
        val retry = recovery.indexOf("core watchdog recovery retry scheduled", replacement)
        assertTrue(cleanup >= 0)
        assertTrue(cleanupFailure > cleanup)
        assertTrue(setupBlocked > cleanupFailure)
        assertTrue(setup > setupBlocked)
        assertTrue(replacement > setup)
        assertTrue(replacementReturn > replacement)
        assertTrue(retry > replacementReturn)

        assertCleanupFailureTerminatesBeforeStopped(source, "stopService", "return@launch")
        assertCleanupFailureTerminatesBeforeStopped(source, "stopAndAlert", "return@runNonCancellableServiceCleanup")
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
            stopService.contains("if (serviceStopJob?.isActive == true && !vpnRevoked)"),
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
    fun `manual stop must cancel pending SERVICE_RECOVER alarm before terminal cleanup`() {
        val source = sourceFile("BoxService.kt")
        val stopService = functionBody(source, "stopService")

        val cancelCall = listOf(
            stopService.indexOf("cancelProcessRecovery("),
            stopService.indexOf("cancelProcessRecoveryAlarm("),
            stopService.indexOf("cancelPendingProcessRecovery("),
            stopService.indexOf("cancelRecoveryAlarm("),
        ).firstOrNull { it >= 0 } ?: -1

        assertTrue(
            "manual stop must cancel pending SERVICE_RECOVER alarm before cleanup",
            cancelCall >= 0 || stopService.contains("cancelServiceRecoveryAlarm("),
        )
        assertTrue(
            "manual stop must invoke cancel for SERVICE_RECOVER path",
            Regex("alarmManager\\.cancel\\s*\\(").containsMatchIn(source) ||
                stopService.contains("cancelProcessRecovery(") ||
                stopService.contains("cancelProcessRecoveryAlarm(") ||
                stopService.contains("cancelPendingProcessRecovery(") ||
                stopService.contains("cancelRecoveryAlarm(") ||
                stopService.contains("cancelServiceRecoveryAlarm("),
        )

        if (cancelCall >= 0) {
            assertTrue(
                "canceling recovery alarm should happen before stop generation is finalized",
                cancelCall < stopService.indexOf("val stopGeneration = cancelPendingStarts()"),
            )
        }
        assertTrue(
            "manual stop cancellation path should still move service to terminal cleanup",
            stopService.contains("serviceScope.launch("),
        )
    }

    @Test
    fun `processRecoveryRequested onStartCommand should foreground-ack before early stopSelf branches`() {
        val source = sourceFile("BoxService.kt")
        val onStart = functionBody(source, "onStartCommand")

        val processRecoveryMarker = onStart.indexOf("if (processRecoveryRequested) {")
        assertTrue("processRecoveryRequested branch should exist", processRecoveryMarker >= 0)
        val processRecoveryHeaderEnd = onStart.indexOf(
            "val restartedBySystem",
            processRecoveryMarker + 1,
        )
        assertTrue("processRecoveryRequested branch should be before command parsing", processRecoveryHeaderEnd >= 0)
        val activeRecoveryStart = Regex(
            "if\\s*\\(\\s*processRecoveryRequested\\s*&&\\s*vpnServiceReplacementRequested\\s*&&\\s*shouldRestoreUserSession\\s*\\)",
        ).find(onStart)?.range?.first ?: -1
        assertTrue("active replacement path should exist", activeRecoveryStart >= 0)
        val staleRecoveryStopBranchStart = Regex(
            "else if\\s*\\(\\(\\s*restartedBySystem\\s*\\|\\|\\s*processRecoveryRequested\\)\\s*&&\\s*!connectFromNotification\\)",
        ).find(onStart)?.range?.first ?: -1
        assertTrue("stale restart path should exist", staleRecoveryStopBranchStart >= 0)

        val recoveryAck = processRecoveryMarker + indexOfForegroundAcknowledgement(
            onStart.substring(processRecoveryMarker, processRecoveryHeaderEnd),
        )
        assertTrue(
            "processRecoveryRequested path should acknowledge foreground before early stopSelf/return",
            recoveryAck >= processRecoveryMarker,
        )

        val activeRecoveryBranch = onStart.substring(activeRecoveryStart, staleRecoveryStopBranchStart)
        val activeStop = activeRecoveryBranch.indexOf("service.stopSelf()")
        assertTrue("active processRecoveryRequested branch should stop itself", activeStop >= 0)
        val activeStopAbs = activeRecoveryStart + activeStop
        val activeReturn = activeRecoveryBranch.indexOf("return Service.START_STICKY", activeStop)
        assertTrue("active processRecoveryRequested branch should return sticky", activeReturn >= 0)
        val activeReturnAbs = activeRecoveryStart + activeReturn
        assertTrue(
            "active processRecoveryRequested branch must acknowledge foreground before stopSelf/return",
            recoveryAck >= processRecoveryMarker && recoveryAck < activeStopAbs && recoveryAck < activeReturnAbs,
        )

        val staleRecoveryBranch = onStart.substring(staleRecoveryStopBranchStart)
        val staleStop = staleRecoveryBranch.indexOf("service.stopSelf()")
        assertTrue("stale processRecoveryRequested branch should stop itself", staleStop >= 0)
        val staleStopAbs = staleRecoveryStopBranchStart + staleStop
        val staleReturn = staleRecoveryBranch.indexOf("return Service.START_NOT_STICKY", staleStop)
        assertTrue("stale processRecoveryRequested branch should return not sticky", staleReturn >= 0)
        val staleReturnAbs = staleRecoveryStopBranchStart + staleReturn
        assertTrue(
            "stale processRecoveryRequested branch must foreground-ack before stopSelf/return",
            recoveryAck >= processRecoveryMarker && recoveryAck < staleStopAbs && recoveryAck < staleReturnAbs,
        )
    }

    @Test
    fun `releaseStoppedPlatformService must unbind activity before stopping platform service`() {
        val source = File("src/main/kotlin/app/marten/client/MethodHandler.kt").readText()
        val releaseStoppedPlatformService = functionBody(source, "releaseStoppedPlatformService")

        val unbindIndex = releaseStoppedPlatformService.indexOf("mainActivity.disconnectServiceBinding()")
        val stopIndex = releaseStoppedPlatformService.indexOf(
            "appContext.stopService(Intent(appContext, Settings.serviceClass()))",
        )

        assertTrue(
            "releaseStoppedPlatformService must explicitly unbind MainActivity before stopping service",
            unbindIndex >= 0,
        )
        assertTrue(
            "releaseStoppedPlatformService must stop platform service using Settings.serviceClass intent",
            stopIndex >= 0,
        )
        assertTrue(
            "Activity binding must be released before stopService to avoid stale Samsung TUN ownership race",
            stopIndex > unbindIndex,
        )
    }

    @Test
    fun `failed cleanup schedules service recovery before conditional stop and retains sticky fallback`() {
        val source = sourceFile("BoxService.kt")
        val replacement = functionBody(source, "replaceVpnServiceAfterCoreCleanupFailure")
        assertFalse(
            "BoxService must not include a hard process kill fallback",
            replacement.contains("android.os.Process.killProcess"),
        )
        val recoveryScheduled = replacement.indexOf("val recoveryScheduled = restoreSession && scheduleProcessRecovery()")
        val conditionalStop = replacement.indexOf("if (!restoreSession || recoveryScheduled)")
        val stopSelf = replacement.indexOf("service.stopSelf()", conditionalStop)
        val stickyFallback = replacement.indexOf("preserving sticky service ownership", conditionalStop)
        val scheduler = replacement.indexOf("scheduleProcessRecovery()")

        assertTrue(recoveryScheduled >= 0)
        assertTrue(conditionalStop > recoveryScheduled)
        assertTrue(stopSelf > conditionalStop)
        assertTrue(stopSelf > scheduler)
        assertTrue(stickyFallback >= 0)
        assertTrue(stickyFallback > stopSelf)
        assertTrue(scheduler >= recoveryScheduled)
        val stickyBranch = replacement.substring(stickyFallback)
        assertFalse("service stopSelf must stay out of sticky fallback branch", stickyBranch.contains("service.stopSelf()"))

        val schedulerSource = functionBody(source, "scheduleProcessRecovery")
        val pendingSource = functionBody(source, "processRecoveryPendingIntent")
        val recoverAction = maxOf(
            schedulerSource.indexOf("Action.SERVICE_RECOVER"),
            pendingSource.indexOf("Action.SERVICE_RECOVER"),
        )
        val pendingIntentInSchedule = schedulerSource.indexOf("processRecoveryPendingIntent(")
        val pendingIntent = maxOf(
            schedulerSource.indexOf("PendingIntent.getForegroundService"),
            schedulerSource.indexOf("PendingIntent.getService"),
            pendingSource.indexOf("PendingIntent.getForegroundService"),
            pendingSource.indexOf("PendingIntent.getService"),
        )
        val alarmManager = schedulerSource.indexOf("AlarmManager::class.java")
        val alarm = schedulerSource.indexOf("alarmManager.setAndAllowWhileIdle")

        assertTrue(recoverAction >= 0)
        assertTrue("scheduleProcessRecovery should use the shared recovery PendingIntent helper", pendingIntentInSchedule >= 0)
        assertTrue(pendingIntent >= 0)
        assertTrue(pendingIntent > pendingIntentInSchedule)
        assertTrue(alarmManager > pendingIntentInSchedule)
        assertTrue(alarm > alarmManager)
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
    fun `external recovery sites delegate to request admission rather than launching directly`() {
        val source = sourceFile("BoxService.kt")
        val externalRecoverySites = listOf(
            "startService",
            "startCoreRuntimeMonitor",
            "markCoreRuntimeStarted",
            "startCoreWatchdog",
            "recoverRoute",
            "startStoredCoreFromNativeEntryPoint",
        )

        externalRecoverySites.forEach { name ->
            val body = functionBody(source, name)
            assertTrue("$name must request recovery through the admission gate", body.contains("requestCoreRecovery("))
            assertFalse("$name must not bypass the recovery admission gate", body.contains("launchCoreRecovery("))
        }

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

    private fun assertCleanupFailureTerminatesBeforeStopped(source: String, name: String, returnMarker: String) {
        val body = functionBody(source, name)
        val failureGuard = findCleanupFailureGuard(body)
        val replacement = body.indexOf("replaceVpnServiceAfterCoreCleanupFailure(", failureGuard)
        val failedReturn = body.indexOf(returnMarker, replacement)
        val stopped = body.indexOf("status.value = Status.Stopped", failureGuard)
        assertTrue("$name must check close and TUN cleanup", failureGuard >= 0)
        assertTrue("$name must invoke replacement helper on failed cleanup", replacement > failureGuard)
        assertTrue("$name must return after failed cleanup", failedReturn > replacement)
        assertTrue("$name must not publish Stopped before failed cleanup return", stopped > failedReturn)
    }

    private fun indexOfForegroundAcknowledgement(source: String): Int {
        val directIndices = listOf(
            source.indexOf("notification.show("),
            source.indexOf("notification.showStopped("),
            source.indexOf("notification.showStarted("),
            source.indexOf("notification.showReconnecting("),
            source.indexOf("notification.showRecovering("),
            source.indexOf("startForeground("),
            source.indexOf("startForegroundService("),
        ).filter { it >= 0 }

        if (directIndices.isNotEmpty()) {
            return directIndices.minOrNull()!!
        }
        val helperMatch = Regex("\\b\\w*acknowledge\\w*\\(").find(source)
        return helperMatch?.range?.first ?: -1
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
        val bodyStart = source.indexOf('{', declaration)
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
