package app.marten.client.bg

import app.marten.client.constant.Status
import app.marten.core.api.v2.hcore.CoreStates
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.yield
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class ServiceRecoveryPolicyTest {
    @Test
    fun `untracked own Android VPN deferral is limited to a fresh VPN process without a descriptor`() {
        assertTrue(
            "a known Marten-owned Android Network without its retained PFD defers independently of later foreign-owner arbitration",
            shouldDeferVpnStartForUntrackedOwnNetwork(
                vpnMode = true,
                retainedDescriptorValid = false,
                vpnOwnershipKnown = true,
                ownVpnNetworkActive = true,
            ),
        )

        val cases = listOf(
            "non-VPN mode" to arrayOf(false, false, true, true),
            "retained descriptor proves the exact generation" to arrayOf(true, true, true, true),
            "unknown ownership visibility" to arrayOf(true, false, false, true),
            "no own Android VPN Network" to arrayOf(true, false, true, false),
        )
        for ((description, inputs) in cases) {
            assertFalse(
                description,
                shouldDeferVpnStartForUntrackedOwnNetwork(
                    vpnMode = inputs[0],
                    retainedDescriptorValid = inputs[1],
                    vpnOwnershipKnown = inputs[2],
                    ownVpnNetworkActive = inputs[3],
                ),
            )
        }
    }

    @Test
    fun `fail closed VPN barrier requires an exact unique marker and healthy TUN`() {
        val startupGeneration = FailClosedVpnGeneration(
            kind = FailClosedVpnKind.STARTUP,
            markerAddress = "2001:db8::100",
        )
        val otherStartupGeneration = FailClosedVpnGeneration(
            kind = FailClosedVpnKind.STARTUP,
            markerAddress = "2001:db8::101",
        )
        val retirementGeneration = FailClosedVpnGeneration(
            kind = FailClosedVpnKind.RETIREMENT,
            markerAddress = "2001:db8::200",
        )
        assertTrue(
            isFailClosedVpnBarrierReady(
                retainedGeneration = startupGeneration,
                publishedMarkerAddresses = setOf(startupGeneration.markerAddress),
                tunRuntimeHealthy = true,
            ),
        )
        assertTrue(
            isFailClosedVpnBarrierReady(
                retainedGeneration = retirementGeneration,
                publishedMarkerAddresses = setOf(retirementGeneration.markerAddress),
                tunRuntimeHealthy = true,
            ),
        )

        assertFalse(
            "the same STARTUP kind with another marker must not authorize a retained descriptor",
            isFailClosedVpnBarrierReady(
                retainedGeneration = startupGeneration,
                publishedMarkerAddresses = setOf(otherStartupGeneration.markerAddress),
                tunRuntimeHealthy = true,
            ),
        )
        assertFalse(
            "a RETIREMENT marker cannot authorize a STARTUP descriptor",
            isFailClosedVpnBarrierReady(
                retainedGeneration = startupGeneration,
                publishedMarkerAddresses = setOf(retirementGeneration.markerAddress),
                tunRuntimeHealthy = true,
            ),
        )
        assertFalse(
            isFailClosedVpnBarrierReady(
                retainedGeneration = null,
                publishedMarkerAddresses = setOf(startupGeneration.markerAddress),
                tunRuntimeHealthy = true,
            ),
        )
        assertFalse(
            isFailClosedVpnBarrierReady(
                retainedGeneration = startupGeneration,
                publishedMarkerAddresses = emptySet(),
                tunRuntimeHealthy = true,
            ),
        )
        assertFalse(
            isFailClosedVpnBarrierReady(
                retainedGeneration = startupGeneration,
                publishedMarkerAddresses = setOf(startupGeneration.markerAddress),
                tunRuntimeHealthy = false,
            ),
        )
    }

    @Test
    fun `cleanup claim followed by native user Stop marks only its exact predecessor epoch`() {
        val predecessor = checkNotNull(
            ServiceLifecycleOwnership.admitExplicitUserSession(explicitStartLease = null) { },
        )

        ServiceLifecycleOwnership.invalidateFlutterRestartForTerminalStop(explicitUserStop = false)
        assertFalse(
            "failed-start cleanup alone must not manufacture explicit user Stop ownership",
            ServiceLifecycleOwnership.wasUserSessionExplicitlyStopped(predecessor),
        )

        ServiceLifecycleOwnership.invalidateFlutterRestartForTerminalStop(explicitUserStop = true)
        assertTrue(
            "a later native user Stop must retain the predecessor claimed by its active cleanup transaction",
            ServiceLifecycleOwnership.wasUserSessionExplicitlyStopped(predecessor),
        )

        val newerEpoch = checkNotNull(
            ServiceLifecycleOwnership.admitExplicitUserSession(explicitStartLease = null) { },
        )
        assertFalse(
            "a new admitted Connect must not inherit an older session's explicit Stop marker",
            ServiceLifecycleOwnership.wasUserSessionExplicitlyStopped(newerEpoch),
        )
    }

    @Test
    fun `terminal Stop and revoke durably cancel native connect before asynchronous cleanup`() {
        val service = sourceFile("BoxService.kt")
        val terminalIntent = sourceSection(
            service,
            "private fun persistTerminalStopIntent(",
            "private fun hasPendingStickyTunHandoff",
        )
        val cancelHandoff = terminalIntent.indexOf("preclaimedTerminalStop ?: NativeConnectRequestBridge.cancelPendingFlutterConnect(")
        val epochClaim = terminalIntent.indexOf("ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(", cancelHandoff)
        val sealNetwork = terminalIntent.indexOf("NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)", epochClaim)
        val persistStopped = terminalIntent.indexOf("Settings.persistStoppedState()")
        val failedPersist = terminalIntent.indexOf("if (!persisted)")
        assertTrue("terminal Stop must atomically claim the native handoff and exact terminal epoch first", cancelHandoff >= 0 && epochClaim > cancelHandoff)
        assertTrue("terminal Stop must seal native networking under its exact terminal epoch claim", sealNetwork > epochClaim)
        assertTrue("terminal Stop must persist stopped state before cleanup", persistStopped > sealNetwork)
        assertTrue("failed preference persistence must retain an in-process fail-closed fallback", failedPersist > persistStopped)
        assertTrue(terminalIntent.contains("Settings.startedByUser = false"))
        assertTrue(terminalIntent.contains("Settings.startCoreAfterStartingService = false"))

        val settings = sourceAt("src/main/kotlin/app/marten/client/Settings.kt")
        val persistence = sourceSection(settings, "fun persistStoppedState(): Boolean", "\n\n}")
        val authoritativeMarker = persistence.indexOf("val markerPersisted =")
        val markerPersist = persistence.indexOf("hasTerminalStopMarkerLocked() || persistTerminalStopMarkerLocked()", authoritativeMarker)
        val boundedCommits = persistence.indexOf("for (attempt in 0 until 3)", markerPersist)
        val commit = persistence.indexOf(".commit()", boundedCommits)
        val markerOnlyFailure = persistence.indexOf("if (!preferencesPersisted && markerPersisted)", commit)
        val undurableFailure = persistence.indexOf("if (!markerPersisted)", markerOnlyFailure)
        val authoritativeReturn = persistence.indexOf("return markerPersisted", undurableFailure)
        assertTrue(
            "terminal Stop must establish the no-backup marker before bounded preference-cache commits",
            authoritativeMarker >= 0 && markerPersist > authoritativeMarker && boundedCommits > markerPersist && commit > boundedCommits,
        )
        assertTrue(
            "preference commits alone must never report terminal Stop durable; only the authoritative marker decides success",
            markerOnlyFailure > commit && undurableFailure > markerOnlyFailure && authoritativeReturn > undurableFailure,
        )

        val stop = sourceSection(service, "fun stop(quickSettingsRequestId: Long = 0L)", "suspend fun acknowledgeVerifiedRoute")
        val stopPersist = stop.indexOf(
            """persistTerminalStopIntent(
                reason = "explicit native user stop",
                explicitUserStop = true,""",
        )
        val stopDispatch = stop.indexOf("dispatchTerminalStopIntent(terminalIntent, quickSettingsRequestId)", stopPersist)
        val activeInstance = stop.indexOf("val instance = activeInstance")
        assertTrue(
            "native explicit Stop must atomically persist its exact ownership before dispatching or looking up an owner",
            stopPersist >= 0 && stopDispatch > stopPersist && activeInstance > stopDispatch,
        )

        val serviceStop = sourceSection(service, "private fun stopService(", "fun replaceTunFileDescriptor")
        val terminalIntentSelection = serviceStop.indexOf("val terminalIntent = if (terminalStopAlreadyClaimed)")
        val fallbackPersist = serviceStop.indexOf("persistTerminalStopIntent(", terminalIntentSelection)
        val durableState = serviceStop.indexOf("val terminalStateDurable = terminalIntent.persisted", fallbackPersist)
        val durableGate = serviceStop.indexOf("if (!terminalStateDurable && !vpnRevoked)", durableState)
        val revoke = serviceStop.indexOf("if (vpnRevoked)", durableGate)
        val cleanupLaunch = serviceStop.indexOf("serviceScope.launch(")
        assertTrue(
            "revoke through the instance path must derive durable terminal state before cleanup",
            terminalIntentSelection >= 0 && fallbackPersist > terminalIntentSelection && durableState > fallbackPersist &&
                durableGate > durableState && revoke > durableGate && cleanupLaunch > revoke,
        )
        val onRevoke = sourceSection(service, "fun onRevoke()", "\n}")
        assertTrue("framework revocation must enter the authoritative terminal stop path", onRevoke.contains("stopService(vpnRevoked = true)"))
    }

    @Test
    fun `native Connect leases and Flutter restart waits are exact epoch-owned transactions`() {
        val lifecycle = sourceFile("ServiceLifecyclePolicy.kt")
        val issueLease = sourceSection(lifecycle, "fun issueExplicitStartLease(): Long", "fun isExplicitStartLeaseCurrent")
        val validateLease = sourceSection(lifecycle, "fun isExplicitStartLeaseCurrent", "fun releaseExplicitStartLease")
        val explicitSession = sourceSection(lifecycle, "fun admitExplicitUserSession(", "fun currentUserSessionEpoch")
        val terminalInvalidation = sourceSection(
            lifecycle,
            "private fun invalidateForTerminalStopLocked(",
            "private fun expireFlutterRestartLeaseIfNeeded",
        )
        val restartWait = sourceSection(lifecycle, "suspend fun awaitFlutterRestartLease", "fun isFlutterRestartLeaseCurrent")

        assertTrue(
            "an explicit native Connect lease must capture its terminal session epoch when issued",
            issueLease.contains("explicitStartLeaseToken = token") &&
                issueLease.contains("explicitStartLeaseSessionEpoch = terminalSessionEpoch"),
        )
        assertTrue(
            "a claimed lease must match both token and session epoch before it can admit user intent",
                validateLease.contains("explicitStartLeaseToken == token") &&
                validateLease.contains("explicitStartLeaseSessionEpoch == terminalSessionEpoch") &&
                explicitSession.contains("explicitStartLeaseToken != explicitStartLease") &&
                explicitSession.contains("explicitStartLeaseSessionEpoch != terminalSessionEpoch") &&
                explicitSession.contains("return@synchronized null"),
        )
        assertTrue(
            "terminal Stop must atomically advance the epoch and invalidate both restart and explicit-start leases",
            terminalInvalidation.indexOf("terminalSessionEpoch++") >= 0 &&
                terminalInvalidation.contains("flutterRestartLeaseToken = null") &&
                terminalInvalidation.contains("explicitStartLeaseToken = null") &&
                terminalInvalidation.contains("signalOperationChangedLocked()"),
        )
        assertTrue(
            "Flutter restart wait must sleep on the lifecycle change signal, not poll for ownership",
            restartWait.contains("val change = synchronized(operationLock)") &&
                restartWait.contains("change.await()") &&
                !restartWait.contains("delay("),
        )

        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val restartHandler = sourceSection(
            methodHandler,
            "Trigger.TryBeginFlutterRestart.method -> {",
            "Trigger.ValidateFlutterRestart.method -> {",
        )
        assertTrue(
            "the platform restart request must await the event-driven lifecycle lease and revalidate status, durable intent, and epoch",
            restartHandler.contains("ServiceLifecycleOwnership.awaitFlutterRestartLease(") &&
                restartHandler.contains("ServiceLifecycleOwnership.isFlutterRestartLeaseCurrent(token)") &&
                restartHandler.contains("ServiceLifecycleOwnership.releaseFlutterRestart(token)"),
        )
    }

    @Test
    fun `contended native recovery waits for lifecycle events with sparse fallback and stops for terminal owners`() {
        val service = sourceFile("BoxService.kt")
        val lifecycle = sourceFile("ServiceLifecyclePolicy.kt")
        val request = sourceSection(
            service,
            "private fun requestCoreRecovery(",
            "private suspend fun recoverMobileCore",
        )
        val wait = sourceSection(
            lifecycle,
            "suspend fun awaitNativeRecoveryAdmissionChange(",
            "fun tryAcquireFlutterRestart",
        )
        val ownerAcquire = sourceSection(lifecycle, "fun acquire(): Long", "fun isCurrent")
        val terminalInvalidation = sourceSection(
            lifecycle,
            "private fun invalidateForTerminalStopLocked(",
            "private fun expireFlutterRestartLeaseIfNeeded",
        )

        val retryDelay = request.indexOf("val retryDelayMs = coreRecoveryAdmissionRetryDelayMs(")
        val waitForChange = request.indexOf("ServiceLifecycleOwnership.awaitNativeRecoveryAdmissionChange(", retryDelay)
        val timeout = request.indexOf("timeoutMs = retryDelayMs", waitForChange)
        val rejection = request.indexOf("if (\n                        !ServiceLifecycleOwnership.awaitNativeRecoveryAdmissionChange", retryDelay)
        val stopRetry = request.indexOf("return@launch", rejection)
        val retryLaunch = request.indexOf("if (launchCoreRecovery(reason, generation))", stopRetry)
        assertTrue(
            "a rejected recovery admission must wait for the lifecycle event before retrying native recovery",
            retryDelay >= 0 && waitForChange > retryDelay && timeout > waitForChange &&
                rejection > retryDelay && stopRetry > rejection && retryLaunch > stopRetry,
        )
        assertFalse(
            "the contended-admission loop must not use the old fixed two-second delay",
            request.contains("delay(CORE_RECOVERY_BACKOFF_MS)"),
        )
        assertFalse(
            "the admission wait section must not embed any timer delay; its timeout belongs to lifecycle await",
            request.contains("delay("),
        )
        assertFalse(
            "the fixed admission cooldown is only valid inside launchCoreRecovery, never requestCoreRecovery's wait path",
            request.contains("CORE_RECOVERY_BACKOFF_MS"),
        )

        assertTrue(
            "the lifecycle wait must park on its operation-change signal with a bounded fallback",
            wait.contains("val change = synchronized(operationLock)") &&
                wait.contains("withTimeoutOrNull(timeoutMs.coerceAtLeast(1L))") &&
                wait.contains("change.await()"),
        )
        assertTrue(
            "owner replacement or terminal Stop must make a stale recovery waiter stop rather than launch again",
            wait.contains("if (!isCurrent(ownerToken) || terminalStopActive) return false") &&
                wait.contains("isCurrent(ownerToken) && !terminalStopActive"),
        )
        assertTrue(
            "acquiring a replacement owner and terminal invalidation must wake lifecycle waiters",
            ownerAcquire.contains("signalOperationChangedLocked()") &&
                terminalInvalidation.contains("terminalStopActive = true") &&
                terminalInvalidation.contains("signalOperationChangedLocked()"),
        )
    }

    @Test
    fun `route monitor parks during exact admission retry and re-arms after it completes`() {
        val service = sourceFile("BoxService.kt")
        val schedule = functionBody(service, "routeWatchdogPollDelayMs")
        val routeCheck = functionBody(service, "runRouteWatchdogCheck")
        val recoveryRequest = functionBody(service, "requestCoreRecovery")

        val scheduleAdmissionGate = schedule.indexOf("coreRecoveryAdmissionRetryJob?.isActive == true")
        val parkedSchedule = schedule.indexOf("return Long.MAX_VALUE", scheduleAdmissionGate)
        assertTrue(
            "stable route supervision must park while lifecycle admission already owns a bounded retry",
            scheduleAdmissionGate >= 0 && parkedSchedule > scheduleAdmissionGate,
        )

        val checkAdmissionGate = routeCheck.indexOf("if (coreRecoveryAdmissionRetryJob?.isActive == true)")
        val parkedCheck = routeCheck.indexOf("return", checkAdmissionGate)
        val coreSnapshot = routeCheck.indexOf("readCoreStateSnapshot(")
        assertTrue(
            "a queued or stale wake must not start route work while recovery admission is pending",
            checkAdmissionGate >= 0 && parkedCheck > checkAdmissionGate && (coreSnapshot < 0 || parkedCheck < coreSnapshot),
        )

        val completion = recoveryRequest.indexOf("scheduled.invokeOnCompletion")
        val identityGuard = recoveryRequest.indexOf("if (coreRecoveryAdmissionRetryJob === scheduled)", completion)
        val clearJob = recoveryRequest.indexOf("coreRecoveryAdmissionRetryJob = null", identityGuard)
        val rearm = recoveryRequest.indexOf("routeHealthMonitor?.rearm()", clearJob)
        assertTrue(
            "only the exact retry job may clear itself, then wake the parked route monitor",
            completion >= 0 && identityGuard > completion && clearJob > identityGuard && rearm > clearJob,
        )
        assertTrue(
            "the route monitor should re-arm only for a still-current user session",
            recoveryRequest.substring(clearJob, rearm).contains("shouldWatchCore(generation)"),
        )
    }

    @Test
    fun `valid exact lease joins an existing process admission while only native handoff claims consume bridge ownership`() {
        val service = sourceFile("BoxService.kt")
        val admission = sourceSection(
            service,
            "suspend fun beginVpnStartAdmission(",
            "fun abortVpnStartAdmission",
        )
        val exactSession = admission.indexOf("val sessionEpoch = if (!resumeSession)")
        val lifecycleAdmission = admission.indexOf(
            "ServiceLifecycleOwnership.admitExplicitUserSession(",
            exactSession,
        )
        val active = admission.indexOf("val currentAdmissionReady = current?.hasProcessNetworkAdmission() == true")
        val coalescing = admission.indexOf("val (admission, shouldStart) = synchronized(vpnStartAdmissionLock)", active)
        val nativeClaimRequirement = admission.indexOf("require(!nativeHandoffClaim || explicitStartLease != null)")
        val nativeClaimComplete = admission.indexOf("nativeHandoffClaim &&", nativeClaimRequirement)
        val completeExactClaim = admission.indexOf(
            "NativeConnectRequestBridge.completeFlutterConnectClaim(checkNotNull(explicitStartLease))",
            nativeClaimComplete,
        )
        val join = admission.indexOf("if (currentAdmissionReady)", completeExactClaim)
        val epochCheck = admission.indexOf("ServiceLifecycleOwnership.isUserSessionEpochCurrent(sessionEpoch)", join)
        val success = admission.indexOf("return sessionEpoch", epochCheck)
        assertTrue(
            "an exact user-session lease must be admitted before an existing process admission can be joined",
            exactSession >= 0 && lifecycleAdmission > exactSession && active > lifecycleAdmission && coalescing > active,
        )
        assertTrue(
            "normal UI leases must not consume a bridge request; only nativeHandoffClaim may complete its exact bridge ownership",
            nativeClaimRequirement >= 0 && nativeClaimComplete > nativeClaimRequirement && completeExactClaim > nativeClaimComplete,
        )
        assertTrue(
            "an already admitted VPN must revalidate the epoch and return its exact epoch without tearing down recovery",
            join > completeExactClaim && epochCheck > join && success > epochCheck,
        )
        val joinPath = admission.substring(join, coalescing)
        assertFalse("joining an already admitted VPN must not abort the active recovery", joinPath.contains("abortVpnStartAdmission("))
        assertFalse("joining an already admitted VPN must not disconnect its active core", joinPath.contains("BoxService.stop(") || joinPath.contains("stopAndAlert("))
    }

    @Test
    fun `non terminal cleanup retains the full route blocker and resumes only on completion events`() {
        val service = sourceFile("BoxService.kt")
        val hold = sourceSection(
            service,
            "private suspend fun holdActiveSessionFailClosed(",
            "private fun scheduleFailClosedSessionHoldContinuation",
        )
        val continuation = sourceSection(
            service,
            "private fun scheduleFailClosedSessionHoldContinuation",
            "private fun resumeFailClosedSession",
        )
        val cleanup = functionBody(service, "closeMobileCoreAndAwaitTunQuiescence")
        val alert = functionBody(service, "stopAndAlert")

        val seal = hold.indexOf("tunDescriptorAdmissionClosed = true")
        val blocker = hold.indexOf("ensurePhysicalFailClosedVpn(", seal)
        val close = hold.indexOf("MobileCoreCloser.closeAsync(", blocker)
        val scheduled = hold.indexOf("scheduleFailClosedSessionHoldContinuation(hold)", close)
        assertTrue(
            "a recoverable failure must seal descriptor admission, install a physical blocker, then join the one native close",
            seal >= 0 && blocker > seal && close > blocker && scheduled > close,
        )
        assertTrue(
            "a passive hold must keep user intent and visible recovery state rather than terminally stopping",
            hold.contains("Settings.startCoreAfterStartingService = hold.resumeRequested") &&
                hold.contains("status.value = Status.Starting"),
        )
        assertFalse("a non-terminal hold must not clear durable user intent", hold.contains("Settings.startedByUser = false"))
        assertFalse("a non-terminal hold must not retire the retained Android TUN", hold.contains("closeTunFileDescriptor()"))
        assertFalse("a non-terminal hold must not retire the platform VPN", hold.contains("retirePlatformVpnSessionAfterCoreStop"))
        assertTrue(
            "core cleanup keeps the framework VPN as a full-route packet sink while the exact session remains active",
            cleanup.contains("fun retainVpnForActiveSession(): Boolean") &&
                cleanup.contains("val retirementOutcome = when") &&
                cleanup.contains("val platformVpnRetained = retirementOutcome == PlatformVpnRetirementOutcome.RETAINED") &&
                cleanup.contains("failClosedVpnInstalled && isFailClosedTunBarrierActive()"),
        )

        listOf(
            "ServiceLifecycleOwnership.awaitPendingCleanupCompletion(serviceOwnerToken)",
            "MobileCoreCloser.awaitCloseToFinish(",
            "ServiceLifecycleOwnership.awaitNativeRecoveryRelease(serviceOwnerToken)",
        ).forEach { required ->
            assertTrue("passive hold continuation must wait for `$required`", continuation.contains(required))
        }
        assertFalse("passive hold continuation must not wake on a retry timer", continuation.contains("delay("))
        assertTrue(
            "terminal stopAndAlert must first offer the fail-closed hold before it clears user intent",
            alert.indexOf("holdActiveSessionFailClosed(") >= 0 &&
                alert.indexOf("holdActiveSessionFailClosed(") < alert.indexOf("Settings.startedByUser = false"),
        )
    }

    @Test
    fun `incomplete recovery cleanup stays fail closed retries to the online deadline and records safe lifecycle outcomes`() {
        val service = sourceFile("BoxService.kt")
        val recovery = functionBody(service, "recoverMobileCore")

        val cleanup = recovery.indexOf("val cleanupReady = closeFailedRecoveryRuntime(")
        val pending = recovery.indexOf("outcome = \"cleanup_pending\"", cleanup)
        val retry = recovery.indexOf("delay(retryDelayMs)", pending)

        assertTrue("each failed recovery attempt must close its predecessor before retry", cleanup >= 0)
        assertTrue("an incomplete close must retain fail-closed recovery rather than return terminally", pending > cleanup)
        assertTrue("cleanup-pending recovery must continue through the common retry delay", retry > pending)
        assertTrue("the recovery lifecycle must report a start", recovery.contains("event = \"core_recovery\"") && recovery.contains("outcome = \"started\""))
        assertTrue("the recovery lifecycle must report a successful recovery", recovery.contains("outcome = \"recovered\""))
        assertTrue("unexpected loop failure must be diagnosable", recovery.contains("outcome = \"loop_failed\""))
        assertTrue("an ownerless exit must be diagnosable", recovery.contains("outcome = \"unexpected_exit\""))
    }

    @Test
    fun `newest exact Connect and prepare survive Stopping then replay behind the stop barrier`() {
        val service = sourceFile("BoxService.kt")
        val command = sourceSection(service, "internal fun onStartCommand", "\n    fun onDestroy")
        val queue = functionBody(service, "queueConnectBehindStop")
        val consume = functionBody(service, "consumeDeferredConnectAfterStop")
        val stop = sourceSection(service, "private fun stopService(", "fun replaceTunFileDescriptor")

        assertTrue(
            "the current pending request must be atomically replaced by the newest exact intent and epoch",
            queue.contains("synchronized(lifecycleLock)") &&
                queue.contains("deferredConnectAfterStop = DeferredConnectAfterStop(") &&
                queue.contains("intent = Intent(intent)") &&
                queue.contains("userSessionEpoch = userSessionEpoch"),
        )
        assertFalse("queueing a newer request must not retain an older request as the winner", queue.contains("if (deferredConnectAfterStop"))
        assertTrue(
            "draining must validate the queued epoch and synthesize a recovery request only from durable current intent",
            consume.contains("deferredConnectAfterStop = null") &&
                consume.contains("ServiceLifecycleOwnership.isUserSessionEpochCurrent(it.userSessionEpoch)") &&
                consume.contains("Settings.startCoreAfterStartingService") &&
                consume.contains("Action.EXTRA_USER_SESSION_EPOCH, epoch"),
        )

        val prepare = command.indexOf("if (intent?.action == Action.SERVICE_PREPARE_VPN)")
        val connect = command.indexOf("val connectFromNotification", prepare)
        val prepareSection = command.substring(prepare, connect)
        assertTrue(
            "an exact SERVICE_PREPARE received during Stopping must be queued behind the same stop barrier",
            prepare >= 0 && prepareSection.contains("if (status.value == Status.Stopping)") &&
                prepareSection.contains("queueConnectBehindStop(") &&
                prepareSection.contains("userSessionEpoch = checkNotNull(suppliedUserSessionEpoch)"),
        )
        val prepareQueue = prepareSection.indexOf("queueConnectBehindStop(")
        val prepareReturn = prepareSection.indexOf("return Service.START_STICKY", prepareQueue)
        val prepareAdmission = prepareSection.indexOf("prepareVpnStartAdmission(", prepareReturn)
        assertTrue(
            "SERVICE_PREPARE_VPN must return immediately after queueing behind Stopping, before any VPN admission can run in parallel",
            prepareQueue >= 0 && prepareReturn > prepareQueue && prepareAdmission > prepareReturn,
        )
        val stoppingConnect = command.substring(command.indexOf("status.value == Status.Stopping", connect))
        assertTrue(
            "an exact Stop-to-Connect must preserve start intent, queue the newest request, and return without parallel native start",
            stoppingConnect.contains("Settings.startCoreAfterStartingService = true") &&
                stoppingConnect.contains("queueConnectBehindStop(") &&
                stoppingConnect.contains("return Service.START_STICKY"),
        )

        val stopped = stop.indexOf("status.value = Status.Stopped")
        val drain = stop.indexOf("val deferredConnect = consumeDeferredConnectAfterStop()", stopped)
        val replay = stop.indexOf("onStartCommand(deferredConnect.intent, deferredConnect.flags)", drain)
        assertTrue(
            "the stop owner must drain and replay the exact newest request only after the platform barrier reaches Stopped",
            stopped >= 0 && drain > stopped && replay > drain,
        )
    }

    @Test
    fun `KR-057 foreign VPN terminal cleanup is bounded by exact barriers rather than historical ownership or recurring work`() {
        val service = sourceFile("BoxService.kt")
        val stopForExternalVpn = functionBody(service, "stopForExternalVpn")
        val stopService = sourceSection(
            service,
            "private fun stopService(",
            "private fun holdFailClosedAfterUndurableTerminalStop",
        )
        val terminalFailure = functionBody(service, "finishCoreCleanupFailure")
        val tunBarrier = functionBody(service, "awaitTunRuntimeQuiescence")

        assertTrue(
            "foreign-VPN takeover must enter the authoritative revoke stop coordinator",
            stopForExternalVpn.contains("stopService(vpnRevoked = true)"),
        )
        assertFalse(
            "terminal cleanup must use current exact VPN/TUN release facts, not historical ownership as a blocker proof",
            stopService.contains("vpnOwnershipWasEstablished") || terminalFailure.contains("vpnOwnershipWasEstablished"),
        )
        val stopWatchdogs = stopService.indexOf("stopExternalVpnWatchdog()")
        val terminalJob = stopService.indexOf("val newStopJob = serviceScope.launch", stopWatchdogs)
        val platformBarrier = stopService.indexOf("platformShutdownCompleted = vpnAndTunReleased", terminalJob)
        val stopped = stopService.indexOf("status.value = Status.Stopped", platformBarrier)
        assertTrue(
            "takeover must stop watchdog work, await one exact platform/TUN barrier, then leave Stopping as Stopped",
            stopWatchdogs >= 0 && terminalJob > stopWatchdogs && platformBarrier > terminalJob && stopped > platformBarrier,
        )
        assertFalse(
            "terminal takeover cleanup must not create recurring timer, alarm, wake-lock, or unbounded polling work",
            stopService.contains("Timer") || stopService.contains("AlarmManager") || stopService.contains("WakeLock") ||
                stopService.contains("while (true)"),
        )
        assertTrue(
            "the only TUN polling is bounded by the exact terminal release deadline",
            tunBarrier.contains("SystemClock.elapsedRealtime() < releaseDeadlineElapsedRealtimeMs") &&
                tunBarrier.contains("delay(TUN_RELEASE_POLL_MS)"),
        )
        assertTrue(
            "a terminal barrier ignores lingering foreign/OEM candidates once Marten's descriptor is released",
            isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 2, serviceStopping = true),
        )
    }

    @Test
    fun `late terminal probe reopening is event driven and waits for cleanup and recovery leases`() {
        val service = sourceFile("BoxService.kt")
        val lifecycle = sourceFile("ServiceLifecyclePolicy.kt")
        val release = sourceSection(
            service,
            "private fun releaseLocalProbesWhenTerminalOwnerIsReady(",
            "private val vpnStartAdmissionLock",
        )
        val terminalContinuation = sourceSection(
            lifecycle,
            "fun runWhenTerminalNetworkingReleaseOwned(action: () -> Unit)",
            "suspend fun awaitPendingCleanup",
        )

        assertTrue(
            "a failed immediate terminal-probe reopen must register the lifecycle-owned continuation",
            release.contains("ServiceLifecycleOwnership.runWhenTerminalNetworkingReleaseOwned") &&
                release.contains("tryAllowLocalProbesForCurrentState(blockEpoch)"),
        )
        assertTrue(
            "the terminal continuation must wait for lifecycle change events before the final exact probe allow",
            terminalContinuation.contains("operationChanged") &&
                terminalContinuation.contains("change.await()") &&
                terminalContinuation.contains("explicitStartLeaseToken == null") &&
                terminalContinuation.contains("nativeRecoveryOwnerToken == null") &&
                terminalContinuation.contains("!cleanupPending") &&
                terminalContinuation.contains("action()"),
        )
        assertFalse("late terminal reopen must not use a stopped-state polling delay", terminalContinuation.contains("delay("))
    }

    @Test
    fun `physical TLS DNS synchronous failure retires its exact signal and completes once`() {
        val probe = sourceFile("PhysicalTlsProbe.kt")
        val resolve = sourceSection(
            probe,
            "private suspend fun resolveCancellable(",
            "private suspend fun selectProbeNetwork",
        )

        val register = resolve.indexOf("activeDnsSignals.add(signal)")
        val finish = resolve.indexOf("fun finishSignal()", register)
        val remove = resolve.indexOf("activeDnsSignals.remove(signal)", finish)
        val completeOnce = resolve.indexOf("fun completeOnce(outcome: Result<List<InetAddress>>)", remove)
        val completeRetires = resolve.indexOf("finishSignal()", completeOnce)
        val onceGate = resolve.indexOf("completed.compareAndSet(false, true)", completeRetires)
        val synchronousCatch = resolve.indexOf("} catch (error: Throwable)", onceGate)
        val catchCompletion = resolve.indexOf("completeOnce(Result.failure(error))", synchronousCatch)
        assertTrue(
            "DNS registration must be removable before either callback or synchronous query rejection can complete",
            register >= 0 && finish > register && remove > finish && completeOnce > remove,
        )
        assertTrue(
            "the completion helper must remove the exact DNS signal before its atomic exactly-once continuation gate",
            completeRetires > completeOnce && onceGate > completeRetires,
        )
        assertTrue(
            "a synchronous DnsResolver.query throw must use the same exact removal and exactly-once completion path",
            synchronousCatch > onceGate && catchCompletion > synchronousCatch,
        )
    }

    @Test
    fun `undurable terminal Stop uses Stopping only for its bounded close then publishes a sealed Stopped hold`() {
        val service = sourceFile("BoxService.kt")
        val stopService = sourceSection(service, "private fun stopService(", "private fun holdFailClosedAfterUndurableTerminalStop")
        val hold = sourceSection(
            service,
            "private fun holdFailClosedAfterUndurableTerminalStop",
            "fun replaceTunFileDescriptor",
        )

        val durableStop = stopService.indexOf("val terminalStateDurable =")
        val undurableBranch = stopService.indexOf("if (!terminalStateDurable && !vpnRevoked)", durableStop)
        val holdCall = stopService.indexOf("holdFailClosedAfterUndurableTerminalStop(quickSettingsRequestId)", undurableBranch)
        val returnAfterHold = stopService.indexOf("return", holdCall)
        assertTrue(
            "only a durable marker admits terminal platform release; an undurable ordinary Stop must enter its retained fail-closed owner path",
            durableStop >= 0 && undurableBranch > durableStop && holdCall > undurableBranch && returnAfterHold > holdCall,
        )
        val stopping = hold.indexOf("status.value = Status.Stopping")
        val nativeClose = hold.indexOf("MobileCoreCloser.closeBlocking(")
        val stopped = hold.indexOf("status.value = Status.Stopped", nativeClose)
        val showStopped = hold.indexOf("notification.showStopped(activeProfileName)", stopped)
        assertTrue(
            "the undurable owner must retain native/probe and descriptor seals; Stopping is only the bounded close attempt before terminal Stopped publication",
            hold.contains("NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)") &&
                hold.contains("tunDescriptorAdmissionClosed = true") &&
                stopping >= 0 && nativeClose > stopping && stopped > nativeClose && showStopped > stopped,
        )
        assertTrue(
            "the retained owner must establish a full-route blocker before joining native close and must keep platform release incomplete",
            hold.contains("ensurePhysicalFailClosedVpn(") &&
                hold.contains("MobileCoreCloser.closeBlocking(") &&
                hold.contains("platformShutdownCompleted = false"),
        )
        assertFalse(
            "the sealed terminal hold must preserve its foreground service owner rather than stopSelf, schedule retries, or run recurring wake work",
            hold.contains("service.stopSelf()") || hold.contains("Timer") || hold.contains("AlarmManager") ||
                hold.contains("WakeLock") || hold.contains("while (true)"),
        )
    }

    @Test
    fun `terminal local probe admission reopens only after durable confirmed platform release`() {
        val service = sourceFile("BoxService.kt")
        val localAdmission = sourceFile("LocalProbeAdmission.kt")
        val lifecycleOwnership = sourceFile("ServiceLifecyclePolicy.kt")
        val terminalStop = sourceSection(service, "fun stop(quickSettingsRequestId: Long = 0L)", "suspend fun acknowledgeVerifiedRoute")
        val noActiveOwner = sourceSection(terminalStop, "if (instance == null) {", "// TileService, ShortcutActivity")
        val stopService = sourceSection(service, "private fun stopService(", "private fun holdFailClosedAfterUndurableTerminalStop")
        val hold = sourceSection(
            service,
            "private fun holdFailClosedAfterUndurableTerminalStop",
            "fun replaceTunFileDescriptor",
        )

        val terminalIntentPersist = terminalStop.indexOf("val terminalIntent = persistTerminalStopIntent")
        val dispatch = terminalStop.indexOf("dispatchTerminalStopIntent(terminalIntent", terminalIntentPersist)
        val noOwner = terminalStop.indexOf("if (instance == null)", dispatch)
        val localProbeLock = noActiveOwner.indexOf("LocalProbeAdmission.allowIfCurrent(")
        val terminalEpochCheck = noActiveOwner.indexOf(
            "ServiceLifecycleOwnership.isTerminalStopEpochCurrent(",
            localProbeLock,
        )
        val rejectUndurable = noActiveOwner.indexOf("if (!terminalIntent.persisted)", terminalEpochCheck)
        val undurableReturn = noActiveOwner.indexOf("return@allow false", rejectUndurable)
        val releasePendingTun = noActiveOwner.indexOf("closePendingStickyTunForTerminalStop()", undurableReturn)
        val terminalReleasePredicate = noActiveOwner.indexOf("canReleaseLocalProbesForCurrentState()", releasePendingTun)
        val eventDrivenRelease = noActiveOwner.indexOf("releaseLocalProbesWhenTerminalOwnerIsReady(", terminalReleasePredicate)
        assertTrue(
            "the no-owner Stop must take the LocalProbe lock first, then only observe its exact terminal epoch without lifecycle-to-probe lock inversion",
            terminalIntentPersist >= 0 && dispatch > terminalIntentPersist && noOwner > dispatch &&
                localProbeLock >= 0 && terminalEpochCheck > localProbeLock &&
                !noActiveOwner.contains("runIfTerminalStopEpochCurrent("),
        )
        assertTrue(
            "an undurable no-owner Stop keeps probes blocked, while durable release closes the pending TUN before its LocalProbe predicate and event continuation",
            rejectUndurable > terminalEpochCheck && undurableReturn > rejectUndurable &&
                releasePendingTun > undurableReturn && terminalReleasePredicate > releasePendingTun &&
                eventDrivenRelease > terminalReleasePredicate,
        )

        val releaseState = stopService.indexOf("platformShutdownCompleted =")
        val rejectIncompleteRelease = stopService.indexOf("if (!platformShutdownCompleted)", releaseState)
        val incompleteReturn = stopService.indexOf("return@launch", rejectIncompleteRelease)
        val activeOwnerReopen = stopService.indexOf(
            "tryAllowLocalProbesForCurrentState(latestTerminalIntent.probeBlockEpoch)",
            incompleteReturn,
        )
        assertTrue(
            "an active terminal Stop must await Android VPN/TUN release before reopening local probes",
            releaseState >= 0 && rejectIncompleteRelease > releaseState && incompleteReturn > rejectIncompleteRelease && activeOwnerReopen > incompleteReturn,
        )
        assertFalse(
            "an undurable fail-closed Stopping owner must never reopen physical probes",
            hold.contains("tryAllowLocalProbesForCurrentState("),
        )

        val gate = sourceSection(
            service,
            "internal fun tryAllowLocalProbesForCurrentState(blockEpoch: Long): Boolean",
            "\n\n        private val vpnStartAdmissionLock",
        )
        val releasePredicate = sourceSection(
            service,
            "private fun canReleaseLocalProbesForCurrentState(): Boolean",
            "\n\n        private fun releaseLocalProbesWhenTerminalOwnerIsReady",
        )
        assertTrue(
            "only the exact latest block epoch may reopen native TLS/ICMP admission through the predicate evaluated under LocalProbeAdmission's lock",
            gate.contains("LocalProbeAdmission.allowIfCurrent(") &&
                gate.contains("blockEpoch,") &&
                gate.contains("::canReleaseLocalProbesForCurrentState"),
        )
        assertTrue(
            "a live verified route may reopen probes without treating a terminal release as active networking",
            releasePredicate.contains("current?.hasVerifiedRouteForOptionalBackgroundWork() == true") &&
                releasePredicate.contains("return true"),
        )
        listOf(
            "ServiceLifecycleOwnership.ownsTerminalNetworkingRelease()",
            "!Settings.startedByUser",
            "!NativeCrashDiagnostics.isNetworkAdmissionAllowed()",
            "!ServiceLifecycleOwnership.hasPendingCleanup()",
            "!hasPendingStickyTunHandoff()",
            "current?.hasRetainedVpnDescriptor() != true",
            "!isOwnVpnActive(Application.application)",
        ).forEach { required ->
            assertTrue("terminal probe release must require `$required`", releasePredicate.contains(required))
        }

        val allowIfCurrent = sourceSection(localAdmission, "fun allowIfCurrent(", "\n}")
        assertTrue(
            "a stale block epoch must remain blocked rather than reopening a newer transition",
            allowIfCurrent.contains("if (blockEpoch != expectedBlockEpoch || !admission())") &&
                allowIfCurrent.contains("return@synchronized false"),
        )
        val terminalReleaseOwner = sourceSection(
            lifecycleOwnership,
            "fun ownsTerminalNetworkingRelease(): Boolean",
            "\n\n    suspend fun awaitPendingCleanup",
        )
        listOf(
            "terminalStopActive",
            "explicitStartLeaseToken == null",
            "flutterRestartLeaseToken == null",
            "nativeRecoveryOwnerToken == null",
        ).forEach { required ->
            assertTrue("terminal probe release must reject an active start/restart lease: $required", terminalReleaseOwner.contains(required))
        }
    }

    @Test
    fun `terminal platform barrier is exact framework-TUN and does not rely on stale process-unbind helpers`() {
        val service = sourceFile("BoxService.kt")
        val stopService = sourceSection(
            service,
            "private fun stopService(",
            "private fun holdFailClosedAfterUndurableTerminalStop",
        )
        val cleanupFailure = functionBody(service, "finishCoreCleanupFailure")
        val releasePredicate = sourceSection(
            service,
            "private fun canReleaseLocalProbesForCurrentState(): Boolean",
            "\n\n        private fun releaseLocalProbesWhenTerminalOwnerIsReady",
        )
        val normalVpnAndTunBarrier = stopService.indexOf(
            "val vpnAndTunReleased =\n                coreClosed.platformVpnRetired && coreClosed.tunQuiescent",
        )
        val normalPlatformBarrier = stopService.indexOf(
            "platformShutdownCompleted = vpnAndTunReleased",
            normalVpnAndTunBarrier,
        )
        val normalIncompleteBarrier = stopService.indexOf(
            "if (!platformShutdownCompleted)",
            normalPlatformBarrier,
        )
        val normalIncompleteReturn = stopService.indexOf("return@launch", normalIncompleteBarrier)
        val normalNativeAdmissionClosed = stopService.indexOf(
            "NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)",
            normalIncompleteReturn,
        )
        val normalLocalProbeReopen = stopService.indexOf(
            "tryAllowLocalProbesForCurrentState(latestTerminalIntent.probeBlockEpoch)",
            normalNativeAdmissionClosed,
        )
        assertTrue(
            "normal terminal Stop must wait for exact platform-vpn and TUN release before closing native admission and reopening probes",
            normalVpnAndTunBarrier >= 0 && normalPlatformBarrier > normalVpnAndTunBarrier &&
                normalIncompleteBarrier > normalPlatformBarrier &&
                normalIncompleteReturn > normalIncompleteBarrier &&
                normalNativeAdmissionClosed > normalIncompleteReturn &&
                normalLocalProbeReopen > normalNativeAdmissionClosed,
        )

        val failedVpnAndTunBarrier = cleanupFailure.indexOf(
            "val vpnAndTunReleased = platformReleased && tunReleased",
        )
        val failedPlatformBarrier = cleanupFailure.indexOf(
            "platformShutdownCompleted = vpnAndTunReleased",
            failedVpnAndTunBarrier,
        )
        val failedNativeAdmissionClosed = cleanupFailure.indexOf(
            "NativeCrashDiagnostics.setNetworkAdmissionAllowed(false)",
            failedPlatformBarrier,
        )
        val failedLocalProbeReopen = cleanupFailure.indexOf(
            "tryAllowLocalProbesForCurrentState(blockEpoch)",
            failedNativeAdmissionClosed,
        )
        assertTrue(
            "terminal cleanup failure may reopen probes only after exact framework VPN/TUN retirement and TUN quiescence",
            failedVpnAndTunBarrier >= 0 && failedPlatformBarrier > failedVpnAndTunBarrier &&
                failedNativeAdmissionClosed > failedPlatformBarrier &&
                failedLocalProbeReopen > failedNativeAdmissionClosed,
        )

        val terminalSafetyGate = releasePredicate.indexOf("val terminalPlatformReleaseOwned =")
        val platformNetworkingReleased = releasePredicate.indexOf("val platformNetworkingReleased =")
        val tunReleased = releasePredicate.indexOf("val currentTunReleased = current?.hasRetainedVpnDescriptor() != true", platformNetworkingReleased)
        val finalRelease = releasePredicate.indexOf("val released = terminalPlatformReleaseOwned", tunReleased)
        assertTrue(
            "terminal local-probe release must require exact framework/TUN platform retirement and no sticky retained descriptor",
            platformNetworkingReleased >= 0 &&
                tunReleased > platformNetworkingReleased &&
                terminalSafetyGate > tunReleased &&
                finalRelease > terminalSafetyGate,
        )
        assertTrue(
            "terminal platform-release gates must be process-binding independent",
            !releasePredicate.contains("bindProcessToNetwork") &&
                !releasePredicate.contains("boundNetworkForProcess") &&
                !releasePredicate.contains("bindProcessToOwnedVpnNetwork") &&
                !releasePredicate.contains("processVpnBindingReleased") &&
                releasePredicate.contains("current?.platformShutdownCompleted == true") &&
                releasePredicate.contains("!isOwnVpnActive(Application.application)") &&
                releasePredicate.contains("terminalOwner = ServiceLifecycleOwnership.ownsTerminalNetworkingRelease()"),
        )
    }

    @Test
    fun `get service status is owned by the live BoxService instance rather than Activity caches`() {
        val boxService = sourceFile("BoxService.kt")
        val platformStatus = sourceSection(
            boxService,
            "fun currentPlatformStatus(): Status",
            "fun isExternalVpnActive",
        )
        assertTrue(platformStatus.contains("activeInstance?.status?.value"))
        assertTrue(platformStatus.contains("hasPendingStickyTunHandoff()) Status.Starting else Status.Stopped"))

        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val getServiceStatus = sourceSection(
            methodHandler,
            "Trigger.GetServiceStatus.method -> {",
            "Trigger.TryBeginFlutterRestart.method -> {",
        )
        assertTrue(getServiceStatus.contains("result.success(BoxService.currentPlatformStatus().name)"))
        assertFalse(getServiceStatus.contains("MainActivity.instance"))
        assertFalse(getServiceStatus.contains("boundServiceStatus"))
        assertFalse(getServiceStatus.contains("serviceStatus.value"))
    }

    @Test
    fun `MethodHandler exposes tls_ping trigger and routes to PhysicalTlsProbe`() {
        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")

        assertTrue(methodHandler.contains("TLSPing(\"tls_ping\")"))

        val tlsPingSection = sourceSection(
            methodHandler,
            "Trigger.TLSPing.method -> {",
            "Trigger.GetStableDeviceID.method -> {",
        )

        assertTrue(tlsPingSection.contains("launchLocalProbe(result) {"))
        assertTrue(tlsPingSection.contains("PhysicalTlsProbe.measure("))
        assertTrue(methodHandler.contains("replyOnce { success(value) }"))
        assertTrue(tlsPingSection.contains("val args = call.arguments as? Map<*, *>"))
        assertTrue(tlsPingSection.contains("val host = args[\"host\"] as? String"))
        assertTrue(tlsPingSection.contains("val port = (args[\"port\"] as? Number)"))
        assertTrue(tlsPingSection.contains("val serverName = args[\"serverName\"] as? String"))
        assertTrue(tlsPingSection.contains("val allowUntrusted = args[\"allowUntrusted\"] as? Boolean ?: false"))
        assertTrue(tlsPingSection.contains("val timeoutMs = (args[\"timeoutMs\"] as? Number)"))
    }

    @Test
    fun `strict egress serializes local probe registration and native TLS ICMP gate transitions`() {
        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val localAdmission = sourceFile("LocalProbeAdmission.kt")
        val tlsProbe = sourceFile("PhysicalTlsProbe.kt")
        val launch = sourceSection(
            methodHandler,
            "private fun launchLocalProbe(",
            "private suspend fun cancelLocalProbes",
        )
        val cancel = sourceSection(
            methodHandler,
            "private suspend fun cancelLocalProbes(keepBlocked: Boolean)",
            "private suspend fun allowLocalProbes",
        )
        val allow = sourceSection(
            methodHandler,
            "private suspend fun allowLocalProbes(blockEpoch: Long): Boolean",
            "private fun releaseStoppedPlatformService",
        )
        val blockAndCancel = sourceSection(
            localAdmission,
            "private fun blockAndCancel(advanceEpoch: Boolean): BlockTransition",
            "suspend fun beginBlockTransitionAndDrain",
        )
        val registerAdmission = sourceSection(
            localAdmission,
            "fun register(job: Job): Boolean",
            "fun unregister(job: Job)",
        )
        val localAllow = sourceSection(localAdmission, "fun allowIfCurrent(", "\n}")
        val tlsBlock = sourceSection(tlsProbe, "fun blockAndCancel()", "fun allow()")
        val dns = sourceSection(tlsProbe, "private suspend fun resolveCancellable(", "private suspend fun selectProbeNetwork")

        val lazyLaunch = launch.indexOf("start = CoroutineStart.LAZY")
        val completion = launch.indexOf("job.invokeOnCompletion")
        val register = launch.indexOf("val admitted = LocalProbeAdmission.register(job)")
        val rejected = launch.indexOf("if (!admitted)", register)
        val rejectedCancel = launch.indexOf("job.cancel(CancellationException", rejected)
        val rejectedReply = launch.indexOf("replyOnce {", rejectedCancel)
        val rejectedReturn = launch.indexOf("return", rejectedReply)
        val start = launch.indexOf("job.start()", rejected)
        assertTrue(
            "completion must be installed before process-wide registration, so cancellation cannot strand a LAZY child",
            lazyLaunch >= 0 && completion > lazyLaunch && register > completion,
        )
        assertTrue(
            "register=false must cancel the unstarted LAZY child, reply, and return before job.start can execute",
            rejected > register && rejectedCancel > rejected && rejectedReply > rejectedCancel &&
                rejectedReturn > rejectedReply && start > rejectedReturn,
        )
        assertTrue("blocked probes must return an explicit platform error", launch.contains("\"local_probe_blocked\""))
        assertTrue(
            "completion and registration-rejection races must produce at most one MethodChannel reply",
            launch.contains("val replyStarted = AtomicBoolean(false)") &&
                launch.contains("replyStarted.compareAndSet(false, true)") &&
                launch.substring(completion).contains("replyOnce {") &&
                launch.substring(rejected).contains("replyOnce {"),
        )

        val drain = cancel.indexOf("LocalProbeAdmission.beginBlockTransitionAndDrain()")
        val conditionalReopen = cancel.indexOf("if (!keepBlocked)", drain)
        val reopen = cancel.indexOf("allowLocalProbes(blockEpoch)", conditionalReopen)
        val returnEpoch = cancel.indexOf("return blockEpoch", reopen)
        assertTrue(
            "strict transitions must close and join existing probes before any optional profile-clear reopen",
            drain >= 0 && conditionalReopen > drain && reopen > conditionalReopen && returnEpoch > reopen,
        )
        assertTrue(
            "cancel_local_probes must return the exact native block epoch after its drain",
            cancel.contains("private suspend fun cancelLocalProbes(keepBlocked: Boolean): Long"),
        )
        assertTrue(
            "allow_local_probes must suspend into the lifecycle-owned terminal-release gate rather than reopening directly",
            allow.contains("BoxService.awaitLocalProbesForCurrentState(blockEpoch)") &&
                !allow.contains("LocalProbeAdmission.allow()"),
        )

        val registerLock = registerAdmission.indexOf("synchronized(lock)")
        val blockLock = blockAndCancel.indexOf("synchronized(lock)")
        val block = blockAndCancel.indexOf("blocked = true", blockLock)
        val tlsCancel = blockAndCancel.indexOf("PhysicalTlsProbe.blockAndCancel()", block)
        val icmpCancel = blockAndCancel.indexOf("Libbox.blockICMPPings()", tlsCancel)
        val snapshot = blockAndCancel.indexOf("jobs.toList()", icmpCancel)
        val jobCancel = blockAndCancel.indexOf("transition.jobs.forEach { it.cancel", snapshot)
        assertTrue(
            "one process-wide lock must serialize registration with closing both native gates and snapshotting jobs",
            registerLock >= 0 && blockLock >= 0 && block > blockLock && tlsCancel > block &&
                icmpCancel > tlsCancel && snapshot > icmpCancel && jobCancel > snapshot,
        )
        val drainTransition = sourceSection(
            localAdmission,
            "suspend fun beginBlockTransitionAndDrain(): Long",
            "fun allowIfCurrent(",
        )
        assertTrue(
            "draining must join every cancelled local probe before native VPN admission",
            drainTransition.contains("transition.jobs.joinAll()"),
        )
        val allowLock = localAllow.indexOf("synchronized(lock)")
        val tlsAllow = localAllow.indexOf("PhysicalTlsProbe.allow()", allowLock)
        val icmpAllow = localAllow.indexOf("Libbox.allowICMPPings()", tlsAllow)
        val unblockJobs = localAllow.indexOf("blocked = false", icmpAllow)
        assertTrue(
            "the same process-wide lock cannot reopen job admission until both native TLS and ICMP gates reopen",
            allowLock >= 0 && tlsAllow > allowLock && icmpAllow > tlsAllow && unblockJobs > icmpAllow,
        )

        assertTrue("TLS blocker must synchronize blocked state and snapshot live sockets/DNS cancellation signals", tlsBlock.contains("synchronized(probeLock)") && tlsBlock.contains("activeSockets.toList() to activeDnsSignals.toList()"))
        assertTrue("TLS blocker must cancel DNS before closing live sockets", tlsBlock.indexOf("dnsSignals.forEach(CancellationSignal::cancel)") < tlsBlock.indexOf("sockets.forEach"))
        assertTrue("TLS probes must reject old Android uncancellable DNS", dns.contains("Build.VERSION.SDK_INT < Build.VERSION_CODES.Q"))
        assertTrue("TLS DNS cancellation must own a CancellationSignal under the probe lock", dns.contains("val signal = CancellationSignal()") && dns.contains("activeDnsSignals.add(signal)") && dns.contains("continuation.invokeOnCancellation"))
    }

    @Test
    fun `PhysicalTlsProbe prefers active VPN network then physical fallback`() {
        val source = sourceFile("PhysicalTlsProbe.kt")
        val selectSection = sourceSection(
            source,
            "private suspend fun selectProbeNetwork(): Network {",
            "private fun String.isIpLiteral(): Boolean",
        )

        val hasActiveVpnSelection =
            selectSection.contains("val activeNetwork = Application.connectivity.activeNetwork") &&
                selectSection.contains("val activeCapabilities = activeNetwork?.let(Application.connectivity::getNetworkCapabilities)") &&
                selectSection.contains("activeCapabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true") &&
                selectSection.contains("return activeNetwork")
        assertTrue(
            "PhysicalTlsProbe must check active network transport VPN and return it before physical fallback",
            hasActiveVpnSelection,
        )

        val activeNetworkLog = selectSection.indexOf("TLS probe route=active_vpn")
        val physicalNetworkLog = selectSection.indexOf("TLS probe route=physical")
        assertTrue(activeNetworkLog >= 0)
        assertTrue(physicalNetworkLog >= 0)
        assertTrue(activeNetworkLog < physicalNetworkLog)
        assertTrue(selectSection.contains("return DefaultNetworkMonitor.require()"))
    }

    @Test
    fun `PhysicalTlsProbe enforces bounded timeout and waits for TLS handshake with SNI`() {
        val source = sourceFile("PhysicalTlsProbe.kt")
        val measureSection = sourceSection(
            source,
            "withTimeout(boundedTimeoutMs) {",
            "private suspend fun selectProbeNetwork(): Network {",
        )

        assertTrue(source.contains("private const val MIN_TIMEOUT_MS ="))
        assertTrue(source.contains("private const val MAX_TIMEOUT_MS ="))
        assertTrue(source.contains("val boundedTimeoutMs = timeoutMs.coerceIn(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)"))
        assertTrue(source.contains("withTimeout(boundedTimeoutMs)"))
        assertTrue(measureSection.contains("val network = selectProbeNetwork()"))
        assertTrue(measureSection.contains("val addresses = resolveCancellable(network, endpointHost, probeGeneration)"))
        assertFalse("strict VPN transitions must not leave TLS probing on uncancellable Network.getAllByName", measureSection.contains("network.getAllByName(endpointHost)"))
        assertTrue(measureSection.contains("val plainSocket = network.socketFactory.createSocket()"))
        assertTrue(source.contains("val tlsFactory = if (allowUntrusted) {"))
        assertTrue(source.contains("realityFallbackTlsFactory"))
        assertTrue(source.contains("} else {"))
        assertTrue(source.contains("SSLSocketFactory.getDefault() as SSLSocketFactory"))
        assertTrue(source.contains("val tlsSocket = (tlsFactory.createSocket("))
        assertTrue(source.contains("plainSocket,"))
        assertTrue(source.contains("peerName,"))
        assertTrue(source.contains("true"))
        assertTrue(source.contains("val peerName = serverName?.trim()"))
        assertTrue(source.contains("parameters.endpointIdentificationAlgorithm = if (allowUntrusted) null else \"HTTPS\""))
        assertTrue(source.contains("if (!peerName.isIpLiteral())"))
        assertTrue(source.contains("parameters.serverNames = listOf(SNIHostName(peerName))"))
        assertTrue(source.contains("it.startHandshake()"))
        assertTrue(
            "healthy result should be returned only after handshake",
            source.indexOf("return@withTimeout") > source.indexOf("it.startHandshake()"),
        )
    }

    @Test
    fun `platform release waits for cleanup before polling VPN and accepts a release after 750ms`() = runBlocking {
        var nowNanos = 0L
        val events = mutableListOf<String>()
        val cleanupTimeouts = mutableListOf<Long>()

        val state = awaitPlatformStopRelease(
            coreStopped = true,
            timeoutMs = 5_000L,
            isQuiescentBoundOwner = { false },
            awaitCleanupAfterStop = { timeoutMs ->
                events += "cleanup"
                cleanupTimeouts += timeoutMs
                nowNanos += 200_000_000L
                true
            },
            isOwnVpnActive = {
                events += "vpn"
                nowNanos < 900_000_000L
            },
            pollIntervalMs = 250L,
            nowNanos = { nowNanos },
            pause = { delayMs ->
                events += "pause:$delayMs"
                nowNanos += delayMs * 1_000_000L
            },
        )

        assertEquals(listOf(5_000L), cleanupTimeouts)
        assertEquals("cleanup", events.first())
        assertTrue(events.indexOf("vpn") > events.indexOf("cleanup"))
        assertTrue(nowNanos >= 900_000_000L)
        assertTrue(state.cleanupFinished)
        assertTrue(state.vpnReleased)
    }

    @Test
    fun `quiescent bound owner skips cleanup and returns once VPN is absent`() = runBlocking {
        var cleanupCalls = 0

        val state = awaitPlatformStopRelease(
            coreStopped = true,
            timeoutMs = 5_000L,
            isQuiescentBoundOwner = { true },
            awaitCleanupAfterStop = {
                cleanupCalls++
                false
            },
            isOwnVpnActive = { false },
            pollIntervalMs = 50L,
        )

        assertEquals(0, cleanupCalls)
        assertTrue(state.quiescentBoundOwner)
        assertTrue(state.cleanupFinished)
        assertTrue(state.vpnReleased)
    }

    @Test
    fun `platform release shares one deadline across cleanup and VPN polling`() = runBlocking {
        var nowNanos = 0L
        val pauses = mutableListOf<Long>()
        val cleanupTimeouts = mutableListOf<Long>()

        val state = awaitPlatformStopRelease(
            coreStopped = true,
            timeoutMs = 5_000L,
            isQuiescentBoundOwner = { false },
            awaitCleanupAfterStop = { timeoutMs ->
                cleanupTimeouts += timeoutMs
                nowNanos += 4_200_000_000L
                true
            },
            isOwnVpnActive = { true },
            pollIntervalMs = 1_000L,
            nowNanos = { nowNanos },
            pause = { delayMs ->
                pauses += delayMs
                nowNanos += delayMs * 1_000_000L
            },
        )

        assertEquals(listOf(5_000L), cleanupTimeouts)
        assertEquals(listOf(800L), pauses)
        assertEquals(5_000_000_000L, nowNanos)
        assertTrue(state.cleanupFinished)
        assertFalse(state.vpnReleased)
    }

    @Test
    fun `confirmed Android VPN release permits user stopped while exact native close remains deferred`() {
        assertTrue(isPlatformStopSafeForUser(coreStopped = true, vpnReleased = true))
        assertFalse(isPlatformStopSafeForUser(coreStopped = false, vpnReleased = true))
        assertFalse(isPlatformStopSafeForUser(coreStopped = true, vpnReleased = false))

        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val stoppedRelease = sourceSection(
            methodHandler,
            "private suspend fun awaitStoppedPlatformServiceRelease",
            "private fun stableDeviceId",
        )
        val strictRelease = stoppedRelease.indexOf("isPlatformStopReleaseComplete(")
        val userSafeRelease = stoppedRelease.indexOf("isPlatformStopSafeForUser(")
        val deferredLog = stoppedRelease.indexOf("exact native cleanup remains deferred")
        val userSuccess = stoppedRelease.indexOf("return true", userSafeRelease)

        assertTrue(strictRelease >= 0)
        assertTrue(userSafeRelease > strictRelease)
        assertTrue(deferredLog > userSafeRelease)
        assertTrue("a service-only framework delay must not surface as a user disconnect failure", userSuccess > deferredLog)

        val boxService = sourceFile("BoxService.kt")
        val stop = sourceSection(
            boxService,
            "private fun stopService(",
            "fun replaceTunFileDescriptor",
        )
        val platformReleased = stop.indexOf("coreClosed.platformVpnRetired && coreClosed.tunQuiescent")
        val nativeCloseFinished = stop.indexOf("coreShutdownCompleted = coreClosed.completed")
        val stopped = stop.indexOf("status.value = Status.Stopped")
        assertTrue("manual stop must track Android release separately from exact native close", platformReleased > nativeCloseFinished)
        assertTrue("confirmed Android release must publish Stopped even when the native close remains pending", stopped > platformReleased)
        assertTrue(stop.contains("manual service stop handed the unfinished exact native close to its process-wide owner"))

        val start = sourceSection(
            boxService,
            "private suspend fun startService(",
            "suspend fun serviceReload0()",
        )
        val closeBarrier = start.indexOf("MobileCoreCloser.waitForCloseToFinish(")
        val setup = start.indexOf("Mobile.setup(")
        assertTrue("the next start must wait for the process-wide exact close", closeBarrier >= 0 && setup > closeBarrier)
    }

    @Test
    fun `bound stopped service is considered safe only without an active stop operation`() {
        assertEquals(true, isQuiescentBoundServiceState(Status.Stopped, coreShutdownCompleted = true, stopOperationActive = false))
        assertEquals(false, isQuiescentBoundServiceState(Status.Stopped, coreShutdownCompleted = true, stopOperationActive = true))
        assertEquals(false, isQuiescentBoundServiceState(Status.Started, coreShutdownCompleted = true, stopOperationActive = false))

        val quiescentOwner = isQuiescentBoundServiceState(
            status = Status.Stopped,
            coreShutdownCompleted = true,
            stopOperationActive = false,
        )
        assertTrue(quiescentOwner)
    }

    @Test
    fun `completed retained stop job is quiescent but active stop job is not`() {
        val completedRetainedJob = isQuiescentBoundServiceState(
            status = Status.Stopped,
            coreShutdownCompleted = true,
            stopOperationActive = false,
        )
        val activeRetainedJob = isQuiescentBoundServiceState(
            status = Status.Stopped,
            coreShutdownCompleted = true,
            stopOperationActive = true,
        )

        assertTrue(completedRetainedJob)
        assertFalse(activeRetainedJob)

        val boxServiceSource = sourceFile("BoxService.kt")
        val quiescentOwner = sourceSection(
            boxServiceSource,
            "fun isQuiescentBoundOwner(ownerToken: Long)",
            "\n        }\n\n\n    }",
        )
        assertTrue(quiescentOwner.contains("stopOperationActive = instance.serviceStopJob?.isActive == true"))
        assertFalse(quiescentOwner.contains("stopOperationActive = instance.serviceStopJob != null"))
    }

    @Test
    fun `platform stop uses bound-owner quiescence to skip extra cleanup wait when already stopped`() {
        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val stoppedRelease = sourceSection(
            methodHandler,
            "private suspend fun awaitStoppedPlatformServiceRelease",
            "private fun stableDeviceId",
        )

        assertTrue(stoppedRelease.contains("val releaseState = awaitPlatformStopRelease("))
        assertTrue(stoppedRelease.contains("isQuiescentBoundOwner = { BoxService.isQuiescentBoundOwner(ownerToken) }"))
        assertTrue(stoppedRelease.contains("ServiceLifecycleOwnership.awaitCleanupAfterStop(ownerToken, timeoutMs)"))
        assertTrue(stoppedRelease.contains("releaseState.quiescentBoundOwner"))
        assertTrue(stoppedRelease.contains("bound Android service is already quiescent; skipping destroy-only cleanup wait"))
    }

    @Test
    fun `manual stop captures stop owner token from active BoxService instance`() {
        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val stopSection = sourceSection(
            methodHandler,
            "Trigger.Stop.method -> {",
            "Trigger.MarkStarted.method -> {",
        )
        val stoppedOwnerLine = stopSection.lineSequence().firstOrNull { it.contains("val stoppedOwnerToken") }

        assertNotNull("manual stop should declare stoppedOwnerToken from active service owner lookup", stoppedOwnerLine)
        assertFalse(
            "manual stop should not use global lifecycle token",
            stopSection.contains("ServiceLifecycleOwnership.currentToken()"),
        )
        assertTrue(
            "manual stop should use BoxService-owned token source",
            stoppedOwnerLine!!.contains("BoxService"),
        )
    }

    @Test
    fun `platform release stays in the ordinary app process without a cold-reset helper`() {
        val manifest = sourceAt("src/main/AndroidManifest.xml")
        val lifecycleSources = listOf(
            manifest,
            sourceAt("src/main/kotlin/app/marten/client/MainActivity.kt"),
            sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt"),
            sourceFile("BoxService.kt"),
        )

        assertTrue(manifest.contains("android:name=\".MainActivity\""))
        lifecycleSources.forEach { source ->
            assertFalse(source.contains("DisconnectRestartActivity"))
            assertFalse(source.contains("DisconnectProcessRestart"))
            assertFalse(source.contains("Process.killProcess"))
            assertFalse(source.contains("exitProcess("))
        }

        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val stoppedRelease = sourceSection(
            methodHandler,
            "private suspend fun awaitStoppedPlatformServiceRelease",
            "private fun stableDeviceId",
        )
        assertFalse(stoppedRelease.contains("shouldResetProcessAfterPlatformStop"))
        assertFalse(stoppedRelease.contains("startActivity("))
        assertFalse(stoppedRelease.contains("recreate("))
    }

    @Test
    fun `absent stop owner token is treated as already stopped cleanup-safe`() = runBlocking {
        assertTrue(ServiceLifecycleOwnership.awaitCleanupAfterStop(0L, timeoutMs = 20L))
    }

    @Test
    fun `owner-known TUN checks ignore foreign global interfaces but preserve own generation barriers`() {
        assertTrue(
            isOwnedTunRuntimeQuiescent(
                descriptorValid = false,
                ownVpnActive = false,
                ownershipKnown = true,
                globalCandidateCount = 2,
            ),
        )
        assertTrue(
            isOwnedTunReleaseCompleteForCleanup(
                descriptorValid = false,
                ownVpnActive = false,
                ownershipKnown = true,
                globalCandidateCount = 2,
                serviceStopping = false,
            ),
        )
        assertFalse(
            "own vpn ownership blocks re-entry unless replacement is explicitly allowed",
            isOwnedTunRuntimeQuiescent(
                descriptorValid = false,
                ownVpnActive = true,
                ownershipKnown = true,
                globalCandidateCount = 2,
                allowPlatformVpnReplacement = false,
            ),
        )
        assertTrue(
            "explicit user-start replacement should allow re-entry even if ownership is still active",
            isOwnedTunRuntimeQuiescent(
                descriptorValid = false,
                ownVpnActive = true,
                ownershipKnown = true,
                globalCandidateCount = 2,
                allowPlatformVpnReplacement = true,
            ),
        )
        assertFalse(isOwnedTunRuntimeQuiescent(true, false, true, 0))
        assertFalse(isOwnedTunRuntimeQuiescent(false, true, true, 0))
        assertFalse(
            isOwnedTunReleaseCompleteForCleanup(
                descriptorValid = false,
                ownVpnActive = true,
                ownershipKnown = true,
                globalCandidateCount = 0,
                serviceStopping = false,
            ),
        )

        assertFalse(isOwnedTunRuntimeQuiescent(false, false, false, 1))
        assertFalse(
            isOwnedTunReleaseCompleteForCleanup(
                descriptorValid = false,
                ownVpnActive = false,
                ownershipKnown = false,
                globalCandidateCount = 1,
                serviceStopping = false,
            ),
        )
    }

    @Test
    fun `Started accepts exactly one Marten-owned TUN and keeps pre-S fallback conservative`() {
        assertTrue(
            isOwnedTunRuntimeHealthy(
                descriptorValid = true,
                ownVpnActive = true,
                ownershipKnown = true,
                interfaceUp = true,
                ownedCandidateCount = 1,
                globalCandidateCount = 2,
            ),
        )
        assertFalse(isOwnedTunRuntimeHealthy(true, true, true, true, 0, 1))
        assertFalse(isOwnedTunRuntimeHealthy(true, true, true, true, 2, 2))
        assertFalse(isOwnedTunRuntimeHealthy(false, true, true, true, 1, 1))
        assertFalse(isOwnedTunRuntimeHealthy(true, false, true, true, 1, 1))
        assertFalse(isOwnedTunRuntimeHealthy(true, true, true, false, 1, 1))
        assertFalse(isOwnedTunRuntimeHealthy(true, true, false, true, 1, 2))
    }

    @Test
    fun `known missing own VPN requests recovery only after its confirmation threshold outside a service-owned transition`() {
        assertTrue(
            shouldRecoverMissingOwnVpn(
                ownershipKnown = true,
                ownVpnActive = false,
                serviceOwnedTransitionActive = false,
                consecutiveOwnVpnMisses = 2,
                requiredMisses = 2,
            ),
        )
        assertFalse(
            shouldRecoverMissingOwnVpn(
                ownershipKnown = true,
                ownVpnActive = false,
                serviceOwnedTransitionActive = false,
                consecutiveOwnVpnMisses = 1,
                requiredMisses = 2,
            ),
        )
        assertFalse(
            shouldRecoverMissingOwnVpn(
                ownershipKnown = false,
                ownVpnActive = false,
                serviceOwnedTransitionActive = false,
                consecutiveOwnVpnMisses = 2,
                requiredMisses = 2,
            ),
        )
        assertFalse(
            shouldRecoverMissingOwnVpn(
                ownershipKnown = true,
                ownVpnActive = true,
                serviceOwnedTransitionActive = false,
                consecutiveOwnVpnMisses = 2,
                requiredMisses = 2,
            ),
        )
        assertFalse(
            shouldRecoverMissingOwnVpn(
                ownershipKnown = true,
                ownVpnActive = false,
                serviceOwnedTransitionActive = true,
                consecutiveOwnVpnMisses = 0,
                requiredMisses = 2,
            ),
        )
    }

    @Test
    fun `TUN handoff keeps established framework descriptor as VPN lifetime owner`() {
        // ParcelFileDescriptor is final and backed by Android framework state, so this
        // resource-free JVM suite checks the production handoff contract directly.
        val vpnSource = sourceFile("VPNService.kt")
        val openTun = sourceSection(vpnSource, "override fun openTun", "override fun writePlatformLog")
        val builderDescriptor = openTun.indexOf("val pfd = builder.establish()")
        val retainFrameworkDescriptor = openTun.indexOf("service.replaceTunFileDescriptor(pfd)")
        val nativeDescriptor = openTun.indexOf("val nativeFd = pfd.fd")
        val returnNativeDescriptor = openTun.indexOf("return nativeFd")

        assertTrue(builderDescriptor >= 0)
        assertTrue(retainFrameworkDescriptor > builderDescriptor)
        assertTrue(nativeDescriptor > retainFrameworkDescriptor)
        assertTrue(returnNativeDescriptor > nativeDescriptor)
        assertFalse(openTun.contains("ParcelFileDescriptor.dup("))
        assertFalse(openTun.contains("detachFd()"))

        val rejection = openTun.indexOf("if (!service.replaceTunFileDescriptor(pfd))")
        val rejectedReturn = openTun.indexOf("error(\"android: VPN service stopped while creating TUN\")", rejection)
        assertTrue(rejection >= 0)
        assertTrue(rejectedReturn > rejection)

        val serviceSource = sourceFile("BoxService.kt")
        val stopService = sourceSection(serviceSource, "private fun stopService", "fun replaceTunFileDescriptor")
        val terminalClaim = stopService.indexOf("ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(")
        val stopAdmissionLock = stopService.indexOf("synchronized(fileDescriptorLock)")
        val stopAdmissionSeal = stopService.indexOf("tunDescriptorAdmissionClosed = true")
        val stopVisibleTransition = stopService.indexOf("status.value = Status.Stopping")
        assertTrue(terminalClaim >= 0)
        assertTrue(stopAdmissionLock >= 0)
        assertTrue(stopAdmissionSeal > stopAdmissionLock)
        assertTrue(
            "the exact terminal epoch must publish Stopping before descriptor cleanup seals the replacement TUN",
            stopVisibleTransition > terminalClaim && stopAdmissionSeal > stopVisibleTransition,
        )

        val replaceDescriptor = sourceSection(serviceSource, "fun replaceTunFileDescriptor", "private fun closeTunFileDescriptor")
        val replacementAdmissionLock = replaceDescriptor.indexOf("synchronized(fileDescriptorLock)")
        val replacementAdmissionSeal = replaceDescriptor.indexOf("!tunDescriptorAdmissionClosed")
        val frameworkDescriptorStored = replaceDescriptor.indexOf("fileDescriptor = pfd")
        val rejectedFrameworkClose = replaceDescriptor.indexOf("runCatching { pfd.close() }")
        val rejectedNativeCloseRequest = replaceDescriptor.indexOf("MobileCoreCloser.closeAsync(\"late tun after service stop\")")
        val rejectedReturnFalse = replaceDescriptor.indexOf("return false")
        assertTrue(replacementAdmissionLock >= 0)
        assertTrue(replacementAdmissionSeal > replacementAdmissionLock)
        assertTrue(frameworkDescriptorStored > replacementAdmissionSeal)
        assertTrue(rejectedFrameworkClose >= 0)
        assertTrue(rejectedNativeCloseRequest > rejectedFrameworkClose)
        assertTrue(rejectedReturnFalse > rejectedNativeCloseRequest)

        val onDestroy = sourceSection(serviceSource, "fun onDestroy", "fun onRevoke")
        val preserve = onDestroy.indexOf("val shouldPreserveUserSession =")
        val handoff = onDestroy.indexOf("handoffTunFileDescriptorForStickyRecovery()")
        val cleanupRegistration = onDestroy.indexOf("registerDestroyCleanup(", handoff)
        val preservedStarting = onDestroy.indexOf("status.value = Status.Starting", preserve)
        val stickyIntent = onDestroy.indexOf("Settings.startCoreAfterStartingService = preservePublishedSession")
        val successor = sourceSection(serviceSource, "internal fun onStartCommand", "\n    fun onDestroy")
        val adopt = successor.indexOf("adoptStickyTunHandoffIfAvailable()")
        assertTrue("unexpected destroy must hand off its full-route descriptor before registering shared cleanup", handoff > preserve && cleanupRegistration > handoff)
        assertTrue("the successor must adopt the shared descriptor before admitting its command", adopt >= 0)
        assertTrue("unexpected destroy must keep user-visible recovery status", preservedStarting > preserve)
        assertTrue("sticky user intent must be persisted after the handoff outcome is known", stickyIntent > preservedStarting)
    }

    @Test
    fun `authoritative platform stop awaits core acknowledgement before releasing framework service exactly once`() = runBlocking {
        val calls = mutableListOf<String>()
        var coreStopCalls = 0
        var frameworkReleaseCalls = 0
        val coreStopAcknowledged = CompletableDeferred<Boolean>()

        val stop = async(start = CoroutineStart.UNDISPATCHED) {
            requestAuthoritativePlatformStop(
            requestCoreStop = {
                coreStopCalls++
                calls += "core-stop"
            },
            awaitCoreStop = {
                calls += "core-stop-ack"
                coreStopAcknowledged.await()
            },
            releaseFrameworkService = {
                frameworkReleaseCalls++
                calls += "framework-release"
            },
            )
        }

        assertEquals(listOf("core-stop", "core-stop-ack"), calls)
        assertEquals(0, frameworkReleaseCalls)

        coreStopAcknowledged.complete(true)
        assertTrue(stop.await())

        assertEquals(listOf("core-stop", "core-stop-ack", "framework-release"), calls)
        assertEquals(1, coreStopCalls)
        assertEquals(1, frameworkReleaseCalls)
    }

    @Test
    fun `authoritative platform stop never releases framework service when core acknowledgement fails`() = runBlocking {
        var coreStopCalls = 0
        var frameworkReleaseCalls = 0

        val stopped = requestAuthoritativePlatformStop(
            requestCoreStop = { coreStopCalls++ },
            awaitCoreStop = { false },
            releaseFrameworkService = { frameworkReleaseCalls++ },
        )

        assertFalse(stopped)
        assertEquals(1, coreStopCalls)
        assertEquals("unconfirmed Android VPN/TUN release must leave the authoritative service owner alive", 0, frameworkReleaseCalls)
    }

    @Test
    fun `manual active stop awaits its pinned owner before framework release and passes computed core result to release barrier`() {
        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val stopSection = sourceSection(
            methodHandler,
            "Trigger.Stop.method -> {",
            "Trigger.MarkStarted.method -> {",
        )
        val activeStop = stopSection.indexOf("val coreStopped = requestAuthoritativePlatformStop(")
        val request = stopSection.substring(activeStop)
        val await = request.indexOf("BoxService.awaitAuthoritativeStop(")
        val release = request.indexOf("releaseFrameworkService = { releaseStoppedPlatformService(mainActivity) }")
        val releaseBarrier = request.indexOf("val platformReleased = awaitStoppedPlatformServiceRelease(")
        val coreStoppedArgument = request.indexOf("coreStopped = coreStopped,", releaseBarrier)

        assertTrue(activeStop >= 0)
        assertTrue("active stop must await the exact BoxService owner", await >= 0)
        assertTrue("framework release must stay inside the two-phase stop protocol", release > await)
        assertTrue("release barrier must run after framework release", releaseBarrier > release)
        assertTrue(
            "release barrier must receive the core result already computed by the authoritative wait",
            coreStoppedArgument > releaseBarrier,
        )
        val afterRequest = request.substring(releaseBarrier)
        assertFalse(
            "an incomplete authoritative stop must not force-stop the Android service from MethodHandler",
            afterRequest.contains("appContext.stopService("),
        )
        assertFalse(
            "an incomplete authoritative stop must not persist a fabricated Stopped state",
            afterRequest.contains("persistStoppedState"),
        )
    }

    @Test
    fun `mobile core lifecycle coordinator never overlaps foreground setup and close`() = runBlocking {
        val coordinator = MobileCoreLifecycleCoordinator()
        val setupEntered = CompletableDeferred<Unit>()
        val releaseSetup = CompletableDeferred<Unit>()
        val closeEntered = CompletableDeferred<Unit>()
        val operations = mutableListOf<String>()

        val setup = async(start = CoroutineStart.UNDISPATCHED) {
            coordinator.run {
                operations += "setup-entered"
                setupEntered.complete(Unit)
                releaseSetup.await()
                operations += "setup-finished"
            }
        }
        setupEntered.await()

        val close = async(start = CoroutineStart.UNDISPATCHED) {
            coordinator.run {
                operations += "close-entered"
                closeEntered.complete(Unit)
            }
        }

        assertFalse(closeEntered.isCompleted)

        releaseSetup.complete(Unit)
        setup.await()
        close.await()

        assertEquals(
            listOf("setup-entered", "setup-finished", "close-entered"),
            operations,
        )
    }

    @Test
    fun `late tun callback is accepted only by current active service owner`() {
        assertTrue(shouldAcceptTunFileDescriptor(true, true, Status.Starting))
        assertTrue(shouldAcceptTunFileDescriptor(true, true, Status.Started))

        assertFalse(shouldAcceptTunFileDescriptor(false, true, Status.Started))
        assertFalse(shouldAcceptTunFileDescriptor(true, false, Status.Started))
        assertFalse(shouldAcceptTunFileDescriptor(true, true, Status.Stopping))
        assertFalse(shouldAcceptTunFileDescriptor(true, true, Status.Stopped))
    }

    @Test
    fun `selects up interface when newer higher-index tun is up`() {
        val interfaces = listOf(
            TunInterfaceState("tun26", 26, up = false, mtu = 1400, addressCount = 0),
            TunInterfaceState("tun27", 27, up = true, mtu = 1500, addressCount = 1),
        )
        val selected = selectTunRuntimeInterface(interfaces)
        assertEquals(27, selected?.index)
        assertEquals(true, selected?.up)
    }

    @Test
    fun `selects highest index when multiple tun interfaces are up`() {
        val interfaces = listOf(
            TunInterfaceState("tun20", 20, up = true, mtu = 1400, addressCount = 1),
            TunInterfaceState("tun23", 23, up = true, mtu = 1400, addressCount = 2),
            TunInterfaceState("tun21", 21, up = false, mtu = 1400, addressCount = 3),
        )
        val selected = selectTunRuntimeInterface(interfaces)
        assertEquals(23, selected?.index)
        assertEquals(true, selected?.up)
    }

    @Test
    fun `selects highest index snapshot when no interfaces are up`() {
        val interfaces = listOf(
            TunInterfaceState("tun20", 20, up = false, mtu = 1400, addressCount = 1),
            TunInterfaceState("tun21", 21, up = false, mtu = 1500, addressCount = 0),
            TunInterfaceState("tun19", 19, up = false, mtu = 1300, addressCount = 2),
        )
        val selected = selectTunRuntimeInterface(interfaces)
        assertEquals(21, selected?.index)
        assertEquals(false, selected?.up)
    }

    @Test
    fun `returns null when no interfaces exist`() {
        assertNull(selectTunRuntimeInterface(emptyList()))
    }

    @Test
    fun `core recovery retry delay is exponential and capped to preserve battery`() {
        assertEquals(2_000L, coreRecoveryRetryDelayMs(-1))
        assertEquals(2_000L, coreRecoveryRetryDelayMs(0))
        assertEquals(2_000L, coreRecoveryRetryDelayMs(1))
        assertEquals(4_000L, coreRecoveryRetryDelayMs(2))
        assertEquals(8_000L, coreRecoveryRetryDelayMs(3))
        assertEquals(16_000L, coreRecoveryRetryDelayMs(4))
        assertEquals(32_000L, coreRecoveryRetryDelayMs(5))
        assertEquals(60_000L, coreRecoveryRetryDelayMs(6))
        assertEquals(60_000L, coreRecoveryRetryDelayMs(20))
    }

    @Test
    fun `current route proof requires healthy current generation and active user session`() {
        assertTrue(
            isCurrentNetworkRouteProof(
                proofGeneration = 12L,
                currentGeneration = 12L,
                routeHealthy = true,
                userSessionActive = true,
            ),
        )
    }

    @Test
    fun `terminal cleanup can complete when descriptor is released even with lingering TUN candidates`() {
        assertTrue(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 0, serviceStopping = true))
        assertTrue(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 1, serviceStopping = true))
        assertTrue(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 2, serviceStopping = true))
        assertTrue(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = -1, serviceStopping = true))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = true, candidateCount = 0, serviceStopping = true))
    }

    @Test
    fun `reconnect cleanup still requires strict zero-candidate TUN quiescence`() {
        assertTrue(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 0, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 1, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 2, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 3, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = -1, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = true, candidateCount = 0, serviceStopping = false))
    }

    @Test
    fun `reconnect and recovery cleanup must stay non-terminal`() {
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 1, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 2, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 3, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = true, candidateCount = 0, serviceStopping = false))
        assertTrue(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 1, serviceStopping = true))
    }

    @Test
    fun `core cleanup escalates unless native close and TUN quiescence both complete`() {
        assertFalse(requiresCoreCleanupEscalation(closeCompleted = true, tunQuiescent = true))
        assertTrue(requiresCoreCleanupEscalation(closeCompleted = false, tunQuiescent = true))
        assertTrue(requiresCoreCleanupEscalation(closeCompleted = true, tunQuiescent = false))
        assertTrue(requiresCoreCleanupEscalation(closeCompleted = false, tunQuiescent = false))
    }

    @Test
    fun `system and process recovery restore only an active configured user session`() {
        assertTrue(
            shouldRestoreUserSessionFromServiceCommand(
                restartedBySystem = true,
                processRecoveryRequested = false,
                connectFromNotification = false,
                userSessionActive = true,
                activeConfigAvailable = true,
            ),
        )
        assertTrue(
            shouldRestoreUserSessionFromServiceCommand(
                restartedBySystem = false,
                processRecoveryRequested = true,
                connectFromNotification = false,
                userSessionActive = true,
                activeConfigAvailable = true,
            ),
        )

        assertFalse(
            shouldRestoreUserSessionFromServiceCommand(
                restartedBySystem = false,
                processRecoveryRequested = false,
                connectFromNotification = false,
                userSessionActive = true,
                activeConfigAvailable = true,
            ),
        )
        assertFalse(
            shouldRestoreUserSessionFromServiceCommand(
                restartedBySystem = true,
                processRecoveryRequested = false,
                connectFromNotification = true,
                userSessionActive = true,
                activeConfigAvailable = true,
            ),
        )
        assertFalse(
            shouldRestoreUserSessionFromServiceCommand(
                restartedBySystem = false,
                processRecoveryRequested = true,
                connectFromNotification = false,
                userSessionActive = false,
                activeConfigAvailable = true,
            ),
        )
        assertFalse(
            shouldRestoreUserSessionFromServiceCommand(
                restartedBySystem = true,
                processRecoveryRequested = false,
                connectFromNotification = false,
                userSessionActive = true,
                activeConfigAvailable = false,
            ),
        )
    }

    @Test
    fun `TUN is quiescent only after descriptor and every candidate are gone`() {
        assertTrue(isTunRuntimeQuiescent(descriptorValid = false, candidateCount = 0))
        assertFalse(isTunRuntimeQuiescent(descriptorValid = true, candidateCount = 0))
        assertFalse(isTunRuntimeQuiescent(descriptorValid = false, candidateCount = 1))
        assertFalse(isTunRuntimeQuiescent(descriptorValid = false, candidateCount = -1))
        assertFalse(isTunRuntimeQuiescent(descriptorValid = true, candidateCount = 2))
    }

    @Test
    fun `TUN is healthy only with one up candidate and a valid descriptor`() {
        assertTrue(isTunRuntimeHealthy(descriptorValid = true, interfaceUp = true, candidateCount = 1))
        assertFalse(isTunRuntimeHealthy(descriptorValid = false, interfaceUp = true, candidateCount = 1))
        assertFalse(isTunRuntimeHealthy(descriptorValid = true, interfaceUp = false, candidateCount = 1))
        assertFalse(isTunRuntimeHealthy(descriptorValid = true, interfaceUp = true, candidateCount = 0))
        assertFalse(isTunRuntimeHealthy(descriptorValid = true, interfaceUp = true, candidateCount = -1))
        assertFalse(isTunRuntimeHealthy(descriptorValid = true, interfaceUp = true, candidateCount = 2))
    }

    @Test
    fun `route recovery stays in place below its bounded failure threshold`() {
        assertFalse(shouldEscalateRouteRecovery(failedChecks = 0, threshold = 3))
        assertFalse(shouldEscalateRouteRecovery(failedChecks = 2, threshold = 3))
    }

    @Test
    fun `ICMP uses the same bounded fallback at and after three consecutive failures`() {
        assertTrue(shouldEscalateRouteRecovery(failedChecks = 3, threshold = 3))
        assertTrue(shouldEscalateRouteRecovery(failedChecks = 4, threshold = 3))
    }

    @Test
    fun `live turncoat carrier requires both real backend RX and active sessions`() {
        assertTrue(isLiveTurncoatCarrier(rxProofCount = 1, activeSessions = 1))
        assertTrue(isLiveTurncoatCarrier(rxProofCount = 3, activeSessions = 10))
    }

    @Test
    fun `health-only or inactive turncoat evidence does not mask a dead backend`() {
        assertFalse(isLiveTurncoatCarrier(rxProofCount = 1, activeSessions = 0))
        assertFalse(isLiveTurncoatCarrier(rxProofCount = 0, activeSessions = 10))
        assertFalse(isLiveTurncoatCarrier(rxProofCount = 0, activeSessions = 0))
    }

    @Test
    fun `current route proof rejects stale failed or inactive evidence`() {
        assertFalse(
            isCurrentNetworkRouteProof(
                proofGeneration = 11L,
                currentGeneration = 12L,
                routeHealthy = true,
                userSessionActive = true,
            ),
        )
        assertFalse(
            isCurrentNetworkRouteProof(
                proofGeneration = 12L,
                currentGeneration = 12L,
                routeHealthy = false,
                userSessionActive = true,
            ),
        )
        assertFalse(
            isCurrentNetworkRouteProof(
                proofGeneration = 12L,
                currentGeneration = 12L,
                routeHealthy = true,
                userSessionActive = false,
            ),
        )
    }

    @Test
    fun `service cleanup survives cancellation of its caller`() = runBlocking {
        val jobReference = CompletableDeferred<Job>()
        var cleanupFinished = false
        val caller = launch {
            runNonCancellableServiceCleanup {
                jobReference.await().cancel()
                yield()
                cleanupFinished = true
            }
        }
        jobReference.complete(caller)

        caller.join()

        assertTrue(caller.isCancelled)
        assertTrue(cleanupFinished)
    }

    @Test
    fun `core runtime is healthy only when started`() {
        assertEquals(true, isCoreRuntimeHealthy(CoreStates.STARTED))
        assertEquals(false, isCoreRuntimeHealthy(CoreStates.STOPPED))
        assertEquals(false, isCoreRuntimeHealthy(CoreStates.STARTING))
        assertEquals(false, isCoreRuntimeHealthy(CoreStates.STOPPING))
        assertEquals(false, isCoreRuntimeHealthy(null))
    }

    @Test
    fun `online native recovery expires only for an active user session with a usable physical network`() {
        assertTrue(
            shouldTerminateExpiredCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = true,
                underlyingNetworkAvailable = true,
                elapsedMs = 1_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertTrue(
            shouldTerminateExpiredCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = true,
                underlyingNetworkAvailable = true,
                elapsedMs = 5_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertFalse(
            shouldTerminateExpiredCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = true,
                underlyingNetworkAvailable = false,
                elapsedMs = 5_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertFalse(
            shouldTerminateExpiredCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = true,
                underlyingNetworkAvailable = true,
                elapsedMs = 999L,
                timeoutMs = 1_000L,
            ),
        )
        assertFalse(
            shouldTerminateExpiredCoreRecovery(
                recoveryInProgress = false,
                userSessionActive = true,
                underlyingNetworkAvailable = true,
                elapsedMs = 5_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertFalse(
            shouldTerminateExpiredCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = false,
                underlyingNetworkAvailable = true,
                elapsedMs = 5_000L,
                timeoutMs = 1_000L,
            ),
        )
    }

    @Test
    fun `expired automatic recovery terminally ends its exact generation instead of remaining in Starting`() {
        val source = sourceFile("BoxService.kt")
        val terminal = sourceSection(
            source,
            "private suspend fun terminateExpiredCoreRecovery(",
            "private fun ownsActiveFailClosedVpnSession",
        )

        val ownership = terminal.indexOf("coreRecoveryOwnsVpnTransition(generation)")
        val session = terminal.indexOf("currentUserSessionEpoch()", ownership)
        val diagnostic = terminal.indexOf("outcome = \"online_deadline_expired\"", session)
        val cleanup = terminal.indexOf("stopAndAlert(", diagnostic)
        val exactEpoch = terminal.indexOf("expectedUserSessionEpoch = userSessionEpoch", cleanup)
        val exactGeneration = terminal.indexOf("expectedGeneration = generation", exactEpoch)

        assertTrue("only the exact active recovery generation may terminate on expiry", ownership >= 0)
        assertTrue("expiry requires the current user-session epoch", session > ownership)
        assertTrue("expiry must leave a privacy-safe diagnostic before cleanup", diagnostic > session)
        assertTrue("expiry must enter terminal cleanup instead of another retry", cleanup > diagnostic)
        assertTrue("terminal cleanup must retain exact session and generation guards", exactEpoch > cleanup && exactGeneration > exactEpoch)
        assertTrue("terminal recovery expiry must set the explicit terminal-failure path", terminal.contains("terminalFailure = true"))
    }

    @Test
    fun `unexpected own VPN disappearance on destroy preserves sticky user intent unless revoked or externally taken over`() {
        val destroy = sourceSection(
            sourceFile("BoxService.kt"),
            "fun onDestroy()",
            "fun onRevoke()",
        )
        val lostOwnership = destroy.indexOf("val establishedVpnOwnershipLost =")
        val preserve = destroy.indexOf("val shouldPreserveUserSession =", lostOwnership)
        val revokedGate = destroy.indexOf("!vpnOwnershipRevoked", preserve)
        val noLossGate = destroy.indexOf("!establishedVpnOwnershipLost", preserve)
        val preservationLog = destroy.indexOf("preserving user intent for sticky recovery", preserve)
        val persistedRestart = destroy.indexOf("Settings.startCoreAfterStartingService = preservePublishedSession", preservationLog)

        assertTrue(lostOwnership >= 0)
        assertTrue("sticky preservation must be decided after ownership observation", preserve > lostOwnership)
        assertTrue("revoke remains terminal for sticky restore", revokedGate > preserve)
        assertEquals("missing own VPN alone must not veto sticky restore", -1, noLossGate)
        assertTrue("unexpected own VPN loss should be explicitly preserved", preservationLog > preserve)
        assertTrue("the preserved decision must be persisted for sticky restart", persistedRestart > preservationLog)
    }

    @Test
    fun `network reset never executes under lifecycle ownership and fails into core recovery`() {
        val recovery = sourceSection(
            sourceFile("BoxService.kt"),
            "private suspend fun recoverNetworkRoute(",
            "private fun requestRouteWatchdogCheck",
        )
        val reset = recovery.indexOf("Mobile.resetNetwork")
        val failure = recovery.indexOf("if (resetResult.isFailure)", reset)
        val recoveryRequest = recovery.indexOf("requestCoreRecovery(", failure)

        assertTrue("network recovery must call the native reset", reset >= 0)
        assertFalse(
            "transport reset must not monopolize the lifecycle coordinator needed by Stop/Close",
            recovery.contains("MobileCoreLifecycle.run"),
        )
        assertFalse(
            "transport reset must not hold the lifecycle lock while crossing into native code",
            recovery.substring(maxOf(0, reset - 400), reset).contains("synchronized(lifecycleLock)"),
        )
        assertTrue("a bounded native reset failure must fail closed into core recovery", failure > reset)
        assertTrue("failed reset must request recovery instead of retrying the stuck transport", recoveryRequest > failure)
    }

    @Test
    fun `failed native startup should retry only when route failed, session is active, and start is current`() {
        assertTrue(shouldRetryFailedNativeStartup(false, true, true))
        assertFalse(shouldRetryFailedNativeStartup(true, true, true))
        assertFalse(shouldRetryFailedNativeStartup(false, false, true))
        assertFalse(shouldRetryFailedNativeStartup(false, true, false))
    }

    @Test
    fun `overlapping mobile close start and blocking waiter share one native close`() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closeCalls = AtomicInteger()
        val coordinator = MobileCloseCoordinator("test-mobile-close") {
            closeCalls.incrementAndGet()
            entered.countDown()
            release.await()
        }

        assertTrue(coordinator.start())
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        assertFalse(coordinator.start())

        val waiterResult = AtomicReference<MobileCloseResult>()
        val waiter = thread {
            waiterResult.set(coordinator.closeBlocking(1_000L))
        }
        Thread.sleep(20L)
        assertTrue(waiter.isAlive)

        release.countDown()
        waiter.join(1_000L)

        assertFalse(waiter.isAlive)
        assertEquals(1, closeCalls.get())
        assertTrue(waiterResult.get().finished)
        assertEquals(null, waiterResult.get().error)
    }

    @Test
    fun `mobile close wait is bounded while the coalesced native close continues`() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closeCalls = AtomicInteger()
        val coordinator = MobileCloseCoordinator("test-mobile-close-timeout") {
            closeCalls.incrementAndGet()
            entered.countDown()
            release.await()
        }

        assertTrue(coordinator.start())
        assertTrue(entered.await(1, TimeUnit.SECONDS))

        val timedOut = coordinator.closeBlocking(10L)
        assertFalse("caller must regain control at the bounded deadline", timedOut.finished)
        assertEquals(1, closeCalls.get())
        assertFalse("a waiter must join the existing close rather than start another", coordinator.start())

        release.countDown()
        val completed = coordinator.waitForClose(1_000L)
        assertTrue(completed.finished)
        assertEquals(1, closeCalls.get())
    }

    @Test
    fun `completed mobile close error remains visible until one later successful retry clears it`() {
        val closeCalls = AtomicInteger()
        val expectedFailure = IllegalStateException("first native close failed")
        val coordinator = MobileCloseCoordinator("test-mobile-close-retained-error") {
            if (closeCalls.incrementAndGet() == 1) throw expectedFailure
        }

        val failed = coordinator.closeBlocking(1_000L)
        assertTrue("first close must finish", failed.finished)
        assertEquals(expectedFailure, failed.error)
        assertEquals(1, closeCalls.get())

        val lateWaiter = coordinator.waitForClose(1_000L)
        assertTrue("late waiter must observe completed operation", lateWaiter.finished)
        assertEquals("completed close error must not disappear with active-operation cleanup", expectedFailure, lateWaiter.error)
        assertEquals(1, closeCalls.get())

        val retried = coordinator.closeBlocking(1_000L)
        assertTrue("the next closeBlocking call must admit one new retry", retried.finished)
        assertEquals(null, retried.error)
        assertEquals(2, closeCalls.get())

        val afterSuccess = coordinator.waitForClose(1_000L)
        assertTrue(afterSuccess.finished)
        assertEquals("successful retry must clear retained completed error", null, afterSuccess.error)
        assertEquals(2, closeCalls.get())
    }

    @Test
    fun `core lifecycle work only continues for its current active session`() {
        assertTrue(shouldContinueCoreLifecycleOperation(8L, 8L, true))
        assertFalse(shouldContinueCoreLifecycleOperation(7L, 8L, true))
        assertFalse(shouldContinueCoreLifecycleOperation(8L, 8L, false))
    }

    @Test
    fun `failed native startup route retries only for the current active user session`() {
        assertTrue(
            shouldRetryFailedNativeStartup(
                routeVerified = false,
                userSessionActive = true,
                startStillCurrent = true,
            ),
        )
        assertFalse(
            shouldRetryFailedNativeStartup(
                routeVerified = false,
                userSessionActive = true,
                startStillCurrent = false,
            ),
        )
        assertFalse(
            shouldRetryFailedNativeStartup(
                routeVerified = false,
                userSessionActive = false,
                startStillCurrent = true,
            ),
        )
        assertFalse(
            shouldRetryFailedNativeStartup(
                routeVerified = true,
                userSessionActive = true,
                startStillCurrent = true,
            ),
        )

        val request = sourceSection(
            sourceFile("BoxService.kt"),
            "private fun requestCoreRecovery(",
            "private suspend fun recoverMobileCore",
        )
        assertTrue(request.contains("shouldContinueCoreLifecycleOperation("))
        assertTrue(request.contains("while (currentCoroutineContext().isActive && shouldWatchCore(generation))"))
        assertTrue(request.contains("core recovery admission remains pending"))

        val nativeProof = sourceSection(
            sourceFile("BoxService.kt"),
            "private suspend fun verifyNativeStartupRoute(",
            "fun onBind(intent: Intent)",
        )
        assertTrue(nativeProof.contains("shouldRetryFailedNativeStartup("))
        assertTrue(nativeProof.contains("requestCoreRecovery("))
        assertTrue(nativeProof.contains("discarding failed native startup route for stale or inactive generation"))
    }

    @Test
    fun `Flutter restart and native recovery leases arbitrate ownership atomically`() {
        val owner = ServiceLifecycleOwnership.acquire()
        var flutterRestartLease: Long? = null
        var nativeRecoveryAcquired = false

        try {
            flutterRestartLease = ServiceLifecycleOwnership.tryAcquireFlutterRestart()
            assertNotNull(flutterRestartLease)
            assertFalse(ServiceLifecycleOwnership.tryAcquireNativeRecovery(owner))

            ServiceLifecycleOwnership.releaseFlutterRestart(flutterRestartLease!!)
            flutterRestartLease = null

            assertTrue(ServiceLifecycleOwnership.tryAcquireNativeRecovery(owner))
            nativeRecoveryAcquired = true
            assertNull(ServiceLifecycleOwnership.tryAcquireFlutterRestart())

            ServiceLifecycleOwnership.releaseNativeRecovery(owner)
            nativeRecoveryAcquired = false

            flutterRestartLease = ServiceLifecycleOwnership.tryAcquireFlutterRestart()
            assertNotNull(flutterRestartLease)
        } finally {
            flutterRestartLease?.let(ServiceLifecycleOwnership::releaseFlutterRestart)
            if (nativeRecoveryAcquired) {
                ServiceLifecycleOwnership.releaseNativeRecovery(owner)
            }
        }
    }

    @Test
    fun `replacement owner waits for admitted predecessor cleanup without cancelling it`() = runBlocking {
        val cleanupStarted = CompletableDeferred<Unit>()
        val releaseCleanup = CompletableDeferred<Unit>()
        val cleanupFinished = CompletableDeferred<Unit>()
        val originalOwner = ServiceLifecycleOwnership.acquire()
        var cleanupRegistered = false

        try {
            cleanupRegistered = ServiceLifecycleOwnership.beginCleanup(originalOwner) {
                cleanupStarted.complete(Unit)
                releaseCleanup.await()
                cleanupFinished.complete(Unit)
            }
            assertTrue(cleanupRegistered)
            cleanupStarted.await()

            val replacementOwner = ServiceLifecycleOwnership.acquire()
            assertFalse(ServiceLifecycleOwnership.awaitPendingCleanup(replacementOwner, timeoutMs = 20L))

            releaseCleanup.complete(Unit)
            cleanupFinished.await()
            assertTrue(ServiceLifecycleOwnership.awaitPendingCleanup(replacementOwner, timeoutMs = 1_000L))
        } finally {
            releaseCleanup.complete(Unit)
            if (cleanupRegistered) {
                cleanupFinished.await()
            }
        }
    }

    @Test
    fun `manual stop waits for onDestroy cleanup registration and completion`() = runBlocking {
        val cleanupStarted = CompletableDeferred<Unit>()
        val releaseCleanup = CompletableDeferred<Unit>()
        val owner = ServiceLifecycleOwnership.acquire()
        val waiter = async(start = CoroutineStart.UNDISPATCHED) {
            ServiceLifecycleOwnership.awaitCleanupAfterStop(owner, timeoutMs = 1_000L)
        }

        try {
            yield()
            assertFalse(waiter.isCompleted)

            assertTrue(
                ServiceLifecycleOwnership.beginCleanup(owner) {
                    cleanupStarted.complete(Unit)
                    releaseCleanup.await()
                },
            )
            cleanupStarted.await()
            yield()
            assertFalse(waiter.isCompleted)

            releaseCleanup.complete(Unit)
            assertTrue(waiter.await())
        } finally {
            releaseCleanup.complete(Unit)
            waiter.await()
        }
    }

    @Test
    fun `manual stop cleanup wait times out when onDestroy never registers cleanup`() = runBlocking {
        val owner = ServiceLifecycleOwnership.acquire()

        assertFalse(ServiceLifecycleOwnership.awaitCleanupAfterStop(owner, timeoutMs = 20L))
    }

    @Test
    fun `stale owner cannot mutate a shared resource after replacement acquire`() {
        val staleOwner = ServiceLifecycleOwnership.acquire()
        val replacementOwner = ServiceLifecycleOwnership.acquire()
        var resourceOwner: Long? = null

        assertFalse(
            ServiceLifecycleOwnership.runIfCurrent(staleOwner) {
                resourceOwner = staleOwner
            },
        )
        assertNull(resourceOwner)

        assertTrue(
            ServiceLifecycleOwnership.runIfCurrent(replacementOwner) {
                resourceOwner = replacementOwner
            },
        )
        assertEquals(replacementOwner, resourceOwner)
    }

    @Test
    fun `await pending cleanup rejects an owner that became stale`() = runBlocking {
        val staleOwner = ServiceLifecycleOwnership.acquire()
        ServiceLifecycleOwnership.acquire()

        assertFalse(ServiceLifecycleOwnership.awaitPendingCleanup(staleOwner, timeoutMs = 1_000L))
    }

    @Test
    fun `startup core remains waiting until route verification before recovery request`() {
        assertEquals(false, shouldRecoverUnverifiedStartedCore(sawStartedCore = false, coreState = null, userSessionActive = true))
        assertEquals(
            false,
            shouldRecoverUnverifiedStartedCore(
                sawStartedCore = true,
                coreState = CoreStates.STARTED,
                userSessionActive = true,
            ),
        )
    }

    @Test
    fun `startup recovery is requested after unverified core later stops while session is active`() {
        assertEquals(
            true,
            shouldRecoverUnverifiedStartedCore(
                sawStartedCore = true,
                coreState = CoreStates.STOPPED,
                userSessionActive = true,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedStartedCore(
                sawStartedCore = true,
                coreState = null,
                userSessionActive = true,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedStartedCore(
                sawStartedCore = true,
                coreState = CoreStates.STOPPED,
                userSessionActive = false,
            ),
        )
    }

    @Test
    fun `never-started core recovery is requested after 5s grace when session is active`() {
        assertEquals(
            true,
            shouldRecoverNeverStartedCore(
                sawStartedCore = false,
                coreState = CoreStates.STOPPED,
                userSessionActive = true,
                elapsedMs = 5_001L,
                timeoutMs = 5_000L,
            ),
        )
        assertEquals(
            true,
            shouldRecoverNeverStartedCore(
                sawStartedCore = false,
                coreState = null,
                userSessionActive = true,
                elapsedMs = 5_001L,
                timeoutMs = 5_000L,
            ),
        )
    }

    @Test
    fun `never-started core recovery is rejected before 5s for STARTING and STARTED inactive, or with prior STARTED`() {
        assertEquals(
            false,
            shouldRecoverNeverStartedCore(
                sawStartedCore = false,
                coreState = CoreStates.STOPPED,
                userSessionActive = true,
                elapsedMs = 4_999L,
                timeoutMs = 5_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverNeverStartedCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTING,
                userSessionActive = true,
                elapsedMs = 5_001L,
                timeoutMs = 5_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverNeverStartedCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTED,
                userSessionActive = true,
                elapsedMs = 5_001L,
                timeoutMs = 5_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverNeverStartedCore(
                sawStartedCore = false,
                coreState = CoreStates.STOPPED,
                userSessionActive = false,
                elapsedMs = 5_001L,
                timeoutMs = 5_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverNeverStartedCore(
                sawStartedCore = true,
                coreState = null,
                userSessionActive = true,
                elapsedMs = 5_001L,
                timeoutMs = 5_000L,
            ),
        )
    }

    @Test
    fun `stalled starting core recovery is requested after 45s only for STARTING when session is active`() {
        assertEquals(
            true,
            shouldRecoverStalledStartingCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTING,
                userSessionActive = true,
                elapsedMs = 45_001L,
                timeoutMs = 45_000L,
            ),
        )
    }

    @Test
    fun `stalled starting core recovery is rejected before 45s or for other states inactive and started core`() {
        assertEquals(
            false,
            shouldRecoverStalledStartingCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTING,
                userSessionActive = true,
                elapsedMs = 44_999L,
                timeoutMs = 45_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverStalledStartingCore(
                sawStartedCore = false,
                coreState = CoreStates.STOPPED,
                userSessionActive = true,
                elapsedMs = 45_001L,
                timeoutMs = 45_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverStalledStartingCore(
                sawStartedCore = false,
                coreState = null,
                userSessionActive = true,
                elapsedMs = 45_001L,
                timeoutMs = 45_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverStalledStartingCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTED,
                userSessionActive = true,
                elapsedMs = 45_001L,
                timeoutMs = 45_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverStalledStartingCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTING,
                userSessionActive = false,
                elapsedMs = 45_001L,
                timeoutMs = 45_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverStalledStartingCore(
                sawStartedCore = true,
                coreState = CoreStates.STARTING,
                userSessionActive = true,
                elapsedMs = 45_001L,
                timeoutMs = 45_000L,
            ),
        )
    }

    @Test
    fun `running core recovery runs after timeout only when still started and session is active`() {
        assertEquals(
            true,
            shouldRecoverUnverifiedRunningCore(
                sawStartedCore = true,
                coreState = CoreStates.STARTED,
                userSessionActive = true,
                elapsedMs = 1_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedRunningCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTED,
                userSessionActive = true,
                elapsedMs = 1_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedRunningCore(
                sawStartedCore = true,
                coreState = CoreStates.STOPPED,
                userSessionActive = true,
                elapsedMs = 1_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedRunningCore(
                sawStartedCore = true,
                coreState = CoreStates.STARTING,
                userSessionActive = true,
                elapsedMs = 1_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedRunningCore(
                sawStartedCore = true,
                coreState = CoreStates.STARTED,
                userSessionActive = false,
                elapsedMs = 1_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedRunningCore(
                sawStartedCore = true,
                coreState = CoreStates.STARTED,
                userSessionActive = true,
                elapsedMs = 999L,
                timeoutMs = 1_000L,
            ),
        )
    }

    @Test
    fun `identical foreground setup keys coalesce concurrent callers onto one result`() = runBlocking {
        val coordinator = MobileForegroundSetupCoordinator()
        val key = foregroundSetupKey(grpcPort = 17079)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val executions = AtomicInteger(0)

        val first = async(start = CoroutineStart.UNDISPATCHED) {
            coordinator.run(key) {
                executions.incrementAndGet()
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        val joined = async(start = CoroutineStart.UNDISPATCHED) {
            coordinator.run(key) { executions.incrementAndGet() }
        }

        assertEquals(1, executions.get())
        release.complete(Unit)

        val firstAdmission = first.await()
        val joinedAdmission = joined.await()
        assertFalse(firstAdmission.coalesced)
        assertTrue(joinedAdmission.coalesced)
        assertFalse(joinedAdmission.waitedForOtherSetup)
        assertEquals(1, executions.get())
    }

    @Test
    fun `different foreground setup keys serialize and each execute once`() = runBlocking {
        val coordinator = MobileForegroundSetupCoordinator()
        val firstKey = foregroundSetupKey(grpcPort = 17079)
        val secondKey = foregroundSetupKey(grpcPort = 17080)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val executions = AtomicInteger(0)
        val order = mutableListOf<String>()

        val first = async(start = CoroutineStart.UNDISPATCHED) {
            coordinator.run(firstKey) {
                executions.incrementAndGet()
                order += "first-start"
                entered.complete(Unit)
                release.await()
                order += "first-end"
            }
        }
        entered.await()
        val second = async(start = CoroutineStart.UNDISPATCHED) {
            coordinator.run(secondKey) {
                executions.incrementAndGet()
                order += "second"
            }
        }

        assertEquals(1, executions.get())
        release.complete(Unit)

        val firstAdmission = first.await()
        val secondAdmission = second.await()
        assertFalse(firstAdmission.coalesced)
        assertFalse(secondAdmission.coalesced)
        assertTrue(secondAdmission.waitedForOtherSetup)
        assertEquals(listOf("first-start", "first-end", "second"), order)
        assertEquals(2, executions.get())
    }

    @Test
    fun `failed foreground setup is shared by joiners and later retry can run`() = runBlocking {
        supervisorScope {
            val coordinator = MobileForegroundSetupCoordinator()
            val key = foregroundSetupKey(grpcPort = 17079)
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val executions = AtomicInteger(0)

            val first = async(start = CoroutineStart.UNDISPATCHED) {
                coordinator.run(key) {
                    executions.incrementAndGet()
                    entered.complete(Unit)
                    release.await()
                    throw IllegalStateException("fake setup failure")
                }
            }
            entered.await()
            val joined = async(start = CoroutineStart.UNDISPATCHED) {
                coordinator.run(key) { executions.incrementAndGet() }
            }
            release.complete(Unit)

            val firstFailure = try {
                first.await()
                null
            } catch (error: IllegalStateException) {
                error
            }
            val joinedFailure = try {
                joined.await()
                null
            } catch (error: IllegalStateException) {
                error
            }
            assertNotNull(firstFailure)
            assertNotNull(joinedFailure)
            assertEquals("fake setup failure", firstFailure?.message)
            assertEquals("fake setup failure", joinedFailure?.message)
            assertEquals(1, executions.get())

            val retry = coordinator.run(key) { executions.incrementAndGet() }
            assertFalse(retry.coalesced)
            assertFalse(retry.waitedForOtherSetup)
            assertEquals(2, executions.get())
        }
    }

    @Test
    fun `KR-046 terminal probe release joins the exact cleanup event without polling or stale reopen`() {
        val handler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val service = sourceFile("BoxService.kt")
        val lifecycle = sourceFile("ServiceLifecyclePolicy.kt")
        val localAdmission = sourceFile("LocalProbeAdmission.kt")
        val allowTrigger = sourceSection(
            handler,
            "Trigger.AllowLocalProbes.method -> {",
            "Trigger.GetStableDeviceID.method -> {",
        )
        val awaitRelease = sourceSection(
            service,
            "internal suspend fun awaitLocalProbesForCurrentState(blockEpoch: Long): Boolean",
            "\n\n        private fun canReleaseLocalProbesForCurrentState",
        )
        val releasePredicate = sourceSection(
            service,
            "private fun canReleaseLocalProbesForCurrentState(): Boolean",
            "\n\n        private fun releaseLocalProbesWhenTerminalOwnerIsReady",
        )
        val beginCleanup = functionBody(lifecycle, "beginCleanup")
        val awaitTerminalRelease = sourceSection(
            lifecycle,
            "suspend fun awaitTerminalNetworkingReleaseOwned(",
            "\n\n    suspend fun awaitPendingCleanup",
        )
        val admitExplicitStart = functionBody(lifecycle, "admitExplicitUserSession")
        val allowIfCurrent = sourceSection(localAdmission, "fun allowIfCurrent(", "\n}")

        assertTrue(
            "allow_local_probes must run its suspend terminal-release join on IO and under a finite caller-facing timeout",
            allowTrigger.contains("scope.launch(Dispatchers.IO)") &&
                allowTrigger.contains("withTimeoutOrNull(TERMINAL_PROBE_RELEASE_TIMEOUT_MS)") &&
                allowTrigger.contains("allowLocalProbes(blockEpoch)"),
        )
        assertTrue(
            "the BoxService release path must await active-service cleanup only as a fallback when its own platform retirement has not completed, then recheck the exact probe epoch after wakeup",
            awaitRelease.contains("val requiredCleanupOwnerToken = activeInstance") &&
                awaitRelease.contains("?.takeUnless { it.platformShutdownCompleted }") &&
                awaitRelease.contains("?.serviceOwnerToken") &&
                awaitRelease.contains("ServiceLifecycleOwnership.awaitTerminalNetworkingReleaseOwned(") &&
                awaitRelease.contains("requiredCleanupOwnerToken,") &&
                awaitRelease.contains("if (") &&
                awaitRelease.contains("!ServiceLifecycleOwnership.awaitTerminalNetworkingReleaseOwned(") &&
                awaitRelease.contains("return false") &&
                awaitRelease.indexOf("tryAllowLocalProbesForCurrentState(blockEpoch)") <
                    awaitRelease.lastIndexOf("tryAllowLocalProbesForCurrentState(blockEpoch)"),
        )
        assertTrue(
            "the exact retirement Network onLost plus TUN barrier must be authoritative when ConnectivityManager's global VPN snapshot lags",
            releasePredicate.contains("val platformNetworkingReleased =") &&
                releasePredicate.contains("current?.platformShutdownCompleted == true") &&
                releasePredicate.contains("!isOwnVpnActive(Application.application)") &&
                releasePredicate.contains("platformNetworkingReleased"),
        )
        assertTrue(
            "cleanup registration and completion must signal terminal waiters, closing the Status.Stopped-to-onDestroy race",
            beginCleanup.contains("pendingCleanup = it") &&
                beginCleanup.contains("lastCleanupOwnerToken = ownerToken") &&
                beginCleanup.contains("signalOperationChangedLocked()") &&
                beginCleanup.contains("operation.invokeOnCompletion") &&
                beginCleanup.contains("synchronized(operationLock)") &&
                beginCleanup.contains("signalOperationChangedLocked()"),
        )
        assertTrue(
            "terminal release must wait event-driven for registered cleanup no older than the captured service owner and for that cleanup to complete",
            awaitTerminalRelease.contains("lastCleanupOwnerToken >= requiredCleanupOwnerToken") &&
                awaitTerminalRelease.contains("val cleanupPending = pendingCleanup?.isCompleted == false") &&
                awaitTerminalRelease.contains("cleanupRegistered") &&
                awaitTerminalRelease.contains("!cleanupPending") &&
                awaitTerminalRelease.contains("change.await()") &&
                !awaitTerminalRelease.contains("delay(") &&
                !awaitTerminalRelease.contains("withTimeout"),
        )
        assertTrue(
            "a newer Connect must invalidate the terminal wait, while a newer terminal seal must fail the final exact-epoch admission recheck",
            awaitTerminalRelease.contains("if (!terminalStopActive) return false") &&
                admitExplicitStart.contains("terminalStopActive = false") &&
                admitExplicitStart.contains("signalOperationChangedLocked()") &&
                allowIfCurrent.contains("if (blockEpoch != expectedBlockEpoch || !admission())") &&
                allowIfCurrent.contains("return@synchronized false"),
        )
    }

    @Test
    fun `automatic terminal service alert and recovery deadline must reopen the exact local probe epoch`() {
        val source = sourceFile("BoxService.kt")
        val recover = functionBody(source, "terminateExpiredCoreRecovery")
        val stopAndAlert = functionBody(source, "stopAndAlert")

        val terminalFailure = recover.indexOf("terminalFailure = true")
        val terminalEpoch = recover.indexOf("expectedUserSessionEpoch = userSessionEpoch", terminalFailure)
        val expectedGeneration = recover.indexOf("expectedGeneration = generation", terminalFailure)
        assertTrue(
            "expired core-recovery deadlines must be handled as terminal alert failures",
            terminalFailure >= 0 && terminalEpoch > terminalFailure && expectedGeneration > terminalEpoch,
        )

        val terminalIntent = stopAndAlert.indexOf("val terminalIntent = persistTerminalStopIntent(")
        val alertReason = stopAndAlert.indexOf("reason = \"service alert type=${'$'}type\"", terminalIntent)
        val clearTakeover = stopAndAlert.indexOf("clearExplicitVpnTakeoverAllowance()", terminalIntent)
        val cleanupClose = stopAndAlert.indexOf("val coreClosed = closeMobileCoreAndAwaitTunQuiescence(", terminalIntent)
        val stopCoreRuntime = stopAndAlert.indexOf("stopCoreRuntimeMonitor()", clearTakeover)
        val publishStopped = stopAndAlert.indexOf("status.value = Status.Stopped", stopCoreRuntime)
        val releaseNativeRecovery = stopAndAlert.indexOf(
            "ServiceLifecycleOwnership.releaseNativeRecovery(serviceOwnerToken)",
        )
        val reopenedProbeAttempt = stopAndAlert.indexOf(
            "val localProbesReleased = terminalIntent.persisted",
            releaseNativeRecovery,
        )
        val reopenGuard = stopAndAlert.indexOf(
            "if (terminalIntent.persisted && !localProbesReleased)",
            reopenedProbeAttempt,
        )
        val eventRelease = stopAndAlert.indexOf("releaseLocalProbesWhenTerminalOwnerIsReady(", reopenGuard)
        assertTrue(
            "terminal alert must persist durable marker before touching stop state",
            terminalIntent >= 0 && alertReason > terminalIntent && clearTakeover > alertReason &&
                stopCoreRuntime > clearTakeover && stopCoreRuntime > terminalIntent,
        )
        assertTrue(
            "native cleanup and TUN quiescence must complete before Status.Stopped",
            stopCoreRuntime < cleanupClose && publishStopped > cleanupClose &&
                stopAndAlert.contains("val coreClosed = closeMobileCoreAndAwaitTunQuiescence(") &&
                stopAndAlert.contains("coreClosed.tunQuiescent"),
        )
        assertTrue(
            "terminal alert must release the native recovery lease and then attempt exact local-probe admission",
            releaseNativeRecovery > cleanupClose &&
                reopenedProbeAttempt > releaseNativeRecovery &&
                reopenGuard > reopenedProbeAttempt &&
                stopAndAlert.contains("tryAllowLocalProbesForCurrentState(terminalIntent.probeBlockEpoch)")
        )
        assertTrue(
            "terminal Stopped must reopen local probes only when terminal intent is persisted and fallback event-driven before status transition",
            stopAndAlert.contains("terminalIntent.persisted") &&
                stopAndAlert.contains("tryAllowLocalProbesForCurrentState(terminalIntent.probeBlockEpoch)") &&
                stopAndAlert.contains("if (terminalIntent.persisted && !localProbesReleased)") &&
                eventRelease > reopenGuard &&
                publishStopped > eventRelease &&
                stopAndAlert.contains("\"service alert terminal release\"")
        )
    }

    @Test
    fun `core recovery online deadline is inclusive and pauses while the physical network is absent`() {
        val timeoutMs = 45_000L

        assertFalse(
            shouldTerminateExpiredCoreRecovery(
                recoveryInProgress = false,
                userSessionActive = true,
                underlyingNetworkAvailable = true,
                elapsedMs = timeoutMs + 1,
                timeoutMs = timeoutMs,
            ),
        )
        assertFalse(
            shouldTerminateExpiredCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = false,
                underlyingNetworkAvailable = true,
                elapsedMs = timeoutMs + 1,
                timeoutMs = timeoutMs,
            ),
        )
        assertFalse(
            shouldTerminateExpiredCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = true,
                underlyingNetworkAvailable = false,
                elapsedMs = Long.MAX_VALUE,
                timeoutMs = timeoutMs,
            ),
        )
        assertFalse(
            shouldTerminateExpiredCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = true,
                underlyingNetworkAvailable = true,
                elapsedMs = timeoutMs - 1,
                timeoutMs = timeoutMs,
            ),
        )
        assertTrue(
            shouldTerminateExpiredCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = true,
                underlyingNetworkAvailable = true,
                elapsedMs = timeoutMs,
                timeoutMs = timeoutMs,
            ),
        )
        assertTrue(
            shouldTerminateExpiredCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = true,
                underlyingNetworkAvailable = true,
                elapsedMs = timeoutMs + 1,
                timeoutMs = timeoutMs,
            ),
        )
    }

    @Test
    fun `core recovery has one nonrenewable online deadline and terminally cleans up on expiry`() {
        val service = sourceFile("BoxService.kt")
        val launch = sourceSection(
            service,
            "private fun launchCoreRecovery(",
            "private fun requestCoreRecovery(",
        )
        val recovery = functionBody(service, "recoverMobileCore")
        val monitor = functionBody(service, "startCoreWatchdog")
        val updateWindow = functionBody(service, "updateCoreRecoveryOnlineWindow")
        val timeout = sourceSection(
            service,
            "private fun coreRecoveryOnlineTimeoutMs(): Long =",
            "private suspend fun terminateExpiredCoreRecovery(",
        )
        val terminal = functionBody(service, "terminateExpiredCoreRecovery")

        val onlineStart = launch.indexOf("coreRecoveryOnlineStartedAtElapsed =")
        val offlineStart = launch.indexOf("underlyingNetworkInitialized && observedUnderlyingNetwork == null", onlineStart)
        val initialClock = launch.indexOf("SystemClock.elapsedRealtime()", offlineStart)
        val completionReset = launch.indexOf("coreRecoveryOnlineStartedAtElapsed = 0L", initialClock)
        assertTrue(
            "one recovery generation must establish its online window at admission and clear it only on completion",
            onlineStart >= 0 && offlineStart > onlineStart && initialClock > offlineStart && completionReset > initialClock,
        )

        val offlinePark = recovery.indexOf("underlyingNetworkInitialized && observedUnderlyingNetwork == null")
        val require = recovery.indexOf("DefaultNetworkMonitor.require()", offlinePark)
        val resumeClock = recovery.indexOf("coreRecoveryOnlineStartedAtElapsed = SystemClock.elapsedRealtime()", require)
        val resume = recovery.indexOf("continue", resumeClock)
        assertTrue(
            "an offline recovery must park on Android's callback and start its online window only when that callback resumes it",
            offlinePark >= 0 && require > offlinePark && resumeClock > require && resume > resumeClock,
        )
        val parked = recovery.substring(offlinePark, resume)
        assertFalse("offline recovery must not consume its online budget through retry delay", parked.contains("delay("))
        assertTrue(
            "callback resumption may initialize a paused window once but must not renew an existing one",
            parked.contains("coreRecoveryOnlineStartedAtElapsed <= 0L"),
        )

        val deadline = recovery.indexOf("shouldTerminateExpiredCoreRecovery(", resume)
        val terminalCall = recovery.indexOf("terminateExpiredCoreRecovery(", deadline)
        val firstAttempt = recovery.indexOf("val attempt = failedAttempts + 1", terminalCall)
        assertTrue(
            "the recovery loop must test the shared online deadline before every next native attempt",
            deadline > resume && terminalCall > deadline && firstAttempt > terminalCall,
        )
        assertFalse(
            "individual attempt setup must not renew the recovery generation deadline",
            recovery.substring(firstAttempt).contains("coreRecoveryOnlineStartedAtElapsed = SystemClock.elapsedRealtime()"),
        )

        assertTrue(
            "network callbacks may pause on loss and set the start time only once on return",
            updateWindow.contains("if (network == null)") &&
                updateWindow.contains("0L") &&
                updateWindow.contains("coreRecoveryOnlineStartedAtElapsed <= 0L") &&
                updateWindow.contains("else {\n                coreRecoveryOnlineStartedAtElapsed"),
        )
        assertTrue(
            "the watchdog must enforce the same policy rather than letting Starting persist forever",
            monitor.contains("shouldTerminateExpiredCoreRecovery(") &&
                monitor.contains("terminateExpiredCoreRecovery(generation, readCoreStateSnapshot(coreClient), elapsedMs)"),
        )
        assertTrue(
            "the online budget must be selected once per live runtime class",
            timeout.contains("CORE_RECOVERY_TURNCOAT_ONLINE_TIMEOUT_MS") &&
                timeout.contains("CORE_RECOVERY_ONLINE_TIMEOUT_MS"),
        )
        assertTrue(
            "expiry must enter terminal cleanup instead of another recovery retry",
            terminal.contains("event = \"core_recovery\"") &&
                terminal.contains("outcome = \"online_deadline_expired\"") &&
                terminal.contains("stopAndAlert(") &&
                terminal.contains("terminalFailure = true"),
        )
    }

    @Test
    fun `recovery reason diagnostics use fixed privacy safe categories`() {
        val cases = mapOf(
            "runtime watchdog lost Marten VPN" to "vpn_ownership",
            "verified route did not produce a healthy Android TUN" to "tun_health",
            "network route recovery after callback" to "network_route",
            "native core reset request" to "native_reset",
            "native startup route failed" to "startup_route",
            "selected-route unavailable" to "startup_route",
            "route watchdog failure" to "route_watchdog",
            "local core runtime stopped" to "core_runtime",
            "core did not start" to "core_start",
            "credential=https://private.example/token" to "unknown",
        )

        for ((reason, expected) in cases) {
            assertEquals("reason must never leak into its diagnostic category", expected, coreRecoveryReasonCategory(reason))
        }
        assertTrue(cases.values.all { it.matches(Regex("[a-z_]+")) })
    }

    @Test
    fun `recovery lifecycle reuses the safe reason category and startup readiness waits for an observation before OEM fallback`() {
        val service = sourceFile("BoxService.kt")
        val recovery = functionBody(service, "recoverMobileCore")
        val startup = functionBody(service, "verifyNativeStartupRoute")

        assertTrue("recovery must classify the verbose reason once", recovery.contains("val recoveryReasonCategory = coreRecoveryReasonCategory(reason)"))
        for (outcome in listOf("started", "recovered", "cleanup_pending", "loop_failed", "unexpected_exit")) {
            val outcomeAt = recovery.indexOf("outcome = \"$outcome\"")
            val categoryAt = recovery.indexOf("category = recoveryReasonCategory", outcomeAt)
            assertTrue("$outcome diagnostics must use the fixed reason category", outcomeAt >= 0 && categoryAt > outcomeAt)
        }

        val pending = startup.indexOf("if (result.networkReadinessPending)")
        val fallbackBudget = startup.indexOf("val fallbackTimeoutMs = minOf(STARTUP_ROUTE_VERIFY_RETRY_MS, remainingMs)", pending)
        val observation = startup.indexOf("DefaultNetworkMonitor.awaitObservationAfter(", fallbackBudget)
        val owner = startup.indexOf("ownerToken = serviceOwnerToken", observation)
        val fallback = startup.indexOf("fallbackTimeoutMs = fallbackTimeoutMs", owner)
        val directDelay = startup.indexOf("delay(fallbackTimeoutMs)", fallback)
        assertTrue(
            "pending startup readiness must await the next monitor observation using the retry interval only as bounded OEM fallback",
            pending >= 0 && fallbackBudget > pending && observation > fallbackBudget && owner > observation && fallback > owner && directDelay > fallback,
        )
    }

    private fun foregroundSetupKey(grpcPort: Int) = MobileForegroundSetupKey(
        baseDir = "/tmp/marten-base",
        workingDir = "/tmp/marten-work",
        tempDir = "/tmp/marten-temp",
        mode = 4,
        grpcPort = grpcPort,
        debug = true,
    )

    private fun sourceFile(name: String): String {
        return sourceAt("src/main/kotlin/app/marten/client/bg/$name")
    }

    private fun sourceAt(path: String): String {
        val source = File(path)
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
