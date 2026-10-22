package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnDataPlaneProbePolicyTest {
    @Test
    fun `probe runs for startup degraded or missing proof`() {
        assertTrue(shouldProbe(forced = true, degraded = false, lastProofMs = 1L))
        assertTrue(shouldProbe(forced = false, degraded = true, lastProofMs = 1L))
        assertTrue(shouldProbe(forced = false, degraded = false, lastProofMs = 0L))
    }

    @Test
    fun `only the first stable periodic proof failure preserves the verified route`() {
        assertTrue(
            shouldPreserveVerifiedRouteAfterTransientProbeFailure(
                platformStarted = true,
                routeAlreadyDegraded = false,
                priorFailedChecks = 0,
                currentProofAvailable = true,
                tunHealthy = true,
                tunTrafficAdvanced = true,
            ),
        )

        assertFalse(
            "a repeated failed watchdog check is an escalation candidate, not a retained-route sample",
            shouldPreserveVerifiedRouteAfterTransientProbeFailure(
                platformStarted = true,
                routeAlreadyDegraded = false,
                priorFailedChecks = 1,
                currentProofAvailable = true,
                tunHealthy = true,
                tunTrafficAdvanced = true,
            ),
        )
        assertFalse(
            "an already degraded route must not retain an older proof",
            shouldPreserveVerifiedRouteAfterTransientProbeFailure(
                platformStarted = true,
                routeAlreadyDegraded = true,
                priorFailedChecks = 0,
                currentProofAvailable = true,
                tunHealthy = true,
                tunTrafficAdvanced = true,
            ),
        )
        assertFalse(
            "startup has no established user-visible route to preserve",
            shouldPreserveVerifiedRouteAfterTransientProbeFailure(
                platformStarted = false,
                routeAlreadyDegraded = false,
                priorFailedChecks = 0,
                currentProofAvailable = true,
                tunHealthy = true,
                tunTrafficAdvanced = true,
            ),
        )
        assertFalse(
            "missing proof, unhealthy TUN, or idle TUN traffic remain fail-closed",
            shouldPreserveVerifiedRouteAfterTransientProbeFailure(true, false, 0, false, true, true) ||
                shouldPreserveVerifiedRouteAfterTransientProbeFailure(true, false, 0, true, false, true) ||
                shouldPreserveVerifiedRouteAfterTransientProbeFailure(true, false, 0, true, true, false),
        )
    }

    @Test
    fun `recovery status publishes immediately for hard failures but otherwise waits for confirmation`() {
        assertFalse(shouldPublishRouteRecoveryStatus(failedChecks = 1, recoveryThreshold = 2, hardFailure = false))
        assertTrue(shouldPublishRouteRecoveryStatus(failedChecks = 2, recoveryThreshold = 2, hardFailure = false))
        assertTrue(shouldPublishRouteRecoveryStatus(failedChecks = 1, recoveryThreshold = 3, hardFailure = true))
    }

    @Test
    fun `VPN route probe attempts prefer 4 seconds for direct route and 30 seconds for TURNcoat`() {
        assertEquals(STANDARD_VPN_DATA_PLANE_ATTEMPT_TIMEOUT_MS, vpnDataPlaneAttemptTimeoutMs(turncoatRoute = false))
        assertEquals(TURNCOAT_VPN_DATA_PLANE_ATTEMPT_TIMEOUT_MS, vpnDataPlaneAttemptTimeoutMs(turncoatRoute = true))

        assertEquals(3_000L, vpnDataPlaneAttemptTimeoutMs(turncoatRoute = false, remainingBudgetMs = 3_000L));
        assertEquals(3_000L, vpnDataPlaneAttemptTimeoutMs(turncoatRoute = true, remainingBudgetMs = 3_000L));
        assertEquals(1L, vpnDataPlaneAttemptTimeoutMs(turncoatRoute = false, remainingBudgetMs = 1L));
        assertEquals(1L, vpnDataPlaneAttemptTimeoutMs(turncoatRoute = true, remainingBudgetMs = 0L));
    }

    @Test
    fun `stable route proof interval is five minutes interactive and thirty minutes screen off`() {
        assertEquals(5 * 60_000L, stableRouteProbeIntervalMs(deviceInteractive = true))
        assertEquals(30 * 60_000L, stableRouteProbeIntervalMs(deviceInteractive = false))

        assertEquals(0L, vpnDataPlaneProbeDelayMs(true, lastProofElapsedRealtimeMs = 0L, nowElapsedRealtimeMs = 10_000L))
        assertEquals(100L, vpnDataPlaneProbeDelayMs(true, lastProofElapsedRealtimeMs = 100L, nowElapsedRealtimeMs = 300_000L))
        assertEquals(900_000L, vpnDataPlaneProbeDelayMs(false, lastProofElapsedRealtimeMs = 100L, nowElapsedRealtimeMs = 900_100L))
    }

    @Test
    fun `stable proof deadline is shared across protocols and ignores tun byte growth`() {
        for (interactive in listOf(true, false)) {
            val interval = stableRouteProbeIntervalMs(interactive)
            assertFalse(shouldProbe(deviceInteractive = interactive, lastProofMs = 100L, nowMs = 100L + interval - 1L))
            assertTrue(shouldProbe(deviceInteractive = interactive, lastProofMs = 100L, nowMs = 100L + interval))
        }
        assertFalse(shouldProbe(lastProofMs = 10_000L, nowMs = 9_999L))
    }

    @Test
    fun `screen transitions re-arm only the remaining age of the current proof`() {
        val lastProofMs = 100L

        assertEquals(
            180_000L,
            vpnDataPlaneProbeDelayMs(
                deviceInteractive = true,
                lastProofElapsedRealtimeMs = lastProofMs,
                nowElapsedRealtimeMs = 120_100L,
            ),
        )
        assertEquals(
            1_680_000L,
            vpnDataPlaneProbeDelayMs(
                deviceInteractive = false,
                lastProofElapsedRealtimeMs = lastProofMs,
                nowElapsedRealtimeMs = 120_100L,
            ),
        )
        assertEquals(
            100_000L,
            vpnDataPlaneProbeDelayMs(
                deviceInteractive = true,
                lastProofElapsedRealtimeMs = lastProofMs,
                nowElapsedRealtimeMs = 200_100L,
            ),
        )
    }

    @Test
    fun `clock rollback cannot force a stable or traffic-triggered probe`() {
        assertFalse(shouldProbe(lastProofMs = 10_000L, nowMs = 9_999L))
        assertFalse(shouldProbe(lastProofMs = 10_000L, nowMs = 9_999L))
    }

    @Test
    fun `tun traffic advances only for a counter increase or interface replacement`() {
        val previous = TunTrafficSnapshot("tun0", rxBytes = 100L, txBytes = 200L)

        assertFalse(hasTunTrafficAdvanced(null, previous))
        assertFalse(hasTunTrafficAdvanced(previous, null))
        assertFalse(hasTunTrafficAdvanced(previous, previous))
        assertFalse(hasTunTrafficAdvanced(previous, TunTrafficSnapshot("tun0", 99L, 199L)))
        assertTrue(hasTunTrafficAdvanced(previous, TunTrafficSnapshot("tun0", 101L, 200L)))
        assertTrue(hasTunTrafficAdvanced(previous, TunTrafficSnapshot("tun0", 100L, 201L)))
        assertTrue(hasTunTrafficAdvanced(previous, TunTrafficSnapshot("tun1", 0L, 0L)))
    }

    @Test
    fun `vpn source keeps Marten in its resolved TUN plan while allowing selected exclusions and admits started only with current proof`() {
        val vpnService = sourceFile("VPNService.kt")
        val openTun = functionBody(vpnService, "openTun")
        assertTrue(
            "openTun must build the authoritative app-routing plan from Settings and subscription options",
            openTun.contains("resolveVpnAppRoutingPlan(") &&
                openTun.contains("ownPackageName = packageName") &&
                openTun.contains("perAppProxyMode = Settings.perAppProxyMode") &&
                openTun.contains("perAppProxyPackages = Settings.perAppProxyList") &&
                openTun.contains("optionIncludePackages = optionIncludePackages") &&
                openTun.contains("optionExcludePackages = optionExcludePackages"),
        )
        assertTrue(
            "Marten remains in IncludeOnly while selected subscription/user exclusions use the explicit plan branches",
            openTun.contains("is VpnAppRoutingPlan.IncludeOnly") &&
                openTun.contains("addIncludePackage(builder, routedPackage)") &&
                openTun.contains("if (routedPackage != packageName)") &&
                openTun.contains("is VpnAppRoutingPlan.Exclude") &&
                openTun.contains("addExcludePackage(builder, bypassedPackage)") &&
                vpnService.contains("builder.addAllowedApplication(packageName)") &&
                vpnService.contains("builder.addDisallowedApplication(packageName)"),
        )
        assertFalse("strict VPN must not enable Android bypass", vpnService.contains("allowBypass("))
        assertFalse("strict VPN must not exclude an IP route from the TUN", vpnService.contains("excludeRoute("))
        assertTrue("strict VPN must install IPv4 default route", openTun.contains("builder.addRoute(\"0.0.0.0\", 0)"))
        assertTrue("strict VPN must install IPv6 default route", openTun.contains("builder.addRoute(\"::\", 0)"))

        val serviceSource = sourceFile("BoxService.kt")
        val currentProof = functionBody(serviceSource, "currentVpnDataPlaneProof")
        val recordProof = functionBody(serviceSource, "recordVpnDataPlaneProof")
        val markStartedStart = serviceSource.indexOf("private suspend fun markCoreRuntimeStarted(")
        val markStartedEnd = serviceSource.indexOf("\n    private suspend fun awaitTunRuntimeHealthForStarted()", markStartedStart)
        val markStarted = serviceSource.substring(markStartedStart, markStartedEnd)
        assertTrue("data-plane proof must bind to the active TUN generation", currentProof.contains("it.tunGeneration == tunGeneration"))
        val currentHandleLookup = "val currentVpnNetworkHandle = vpnDataPlaneProbe.currentVpnNetworkHandle()"
        val currentProofLock = currentProof.indexOf("synchronized(vpnDataPlaneProofLock)")
        val currentProofHandleComparison = currentProof.indexOf("it.vpnNetworkHandle == currentVpnNetworkHandle", currentProofLock)
        val recordProofLock = recordProof.indexOf("synchronized(vpnDataPlaneProofLock)")
        val recordProofHandleComparison = recordProof.indexOf("proofVpnNetworkHandle != currentVpnNetworkHandle", recordProofLock)
        assertTrue(
            "current-proof lookup must capture the exact Android VPN Network before taking the proof lock",
            currentProof.indexOf(currentHandleLookup) >= 0 && currentProofLock > currentProof.indexOf(currentHandleLookup),
        )
        assertTrue(
            "current proof must bind its stored handle to the captured exact Android VPN Network",
            currentProofHandleComparison > currentProofLock,
        )
        assertTrue(
            "proof recording must capture the exact Android VPN Network before taking the proof lock",
            recordProof.indexOf(currentHandleLookup) >= 0 && recordProofLock > recordProof.indexOf(currentHandleLookup),
        )
        assertTrue(
            "proof recording must compare the supplied handle with the captured exact Android VPN Network",
            recordProofHandleComparison > recordProofLock,
        )

        val freshProofGuards = Regex("hasReusableVpnDataPlaneProof\\(generation\\)")
            .findAll(markStarted)
            .map { it.range.first }
            .toList()
        val freshProofGuard = freshProofGuards.firstOrNull() ?: -1
        val started = markStarted.indexOf("status.value = Status.Started")
        assertEquals("Started must have an initial and final exact current-proof gate", 2, freshProofGuards.size)
        assertFalse("no route-verification caller may bypass the proof gate", markStarted.contains("routeVerified && !hasReusableVpnDataPlaneProof"))
        assertTrue("proof gate must execute before Started", started > freshProofGuard)
        assertTrue("missing proof must leave the service in Starting", markStarted.substring(freshProofGuard, started).contains("status.value = Status.Starting"))
        assertTrue("publishing Started may stop the deadline supervisor without stopping recovery", markStarted.contains("stopCoreRecoverySupervision()"))
        assertFalse("publishing Started must not cancel the recovery job", markStarted.contains("stopCoreWatchdog()"))
        val stopRecoverySupervision = functionBody(serviceSource, "stopCoreRecoverySupervision")
        assertTrue("Started must cancel only the recovery deadline supervisor", stopRecoverySupervision.contains("coreWatchdogJob?.cancel()"))
        assertFalse("Started must preserve the admitted recovery job", stopRecoverySupervision.contains("coreRecoveryJob = null"))
        assertFalse("Started must preserve recovery state and online deadline", stopRecoverySupervision.contains("coreRecoveryInProgress = false") || stopRecoverySupervision.contains("coreRecoveryOnlineStartedAtElapsed = 0L"))
    }

    @Test
    fun `route monitor drops stale start network and tun observations before recovery mutations`() {
        val source = sourceFile("BoxService.kt")
        val monitorStart = functionBody(source, "startRouteWatchdog")
        val check = functionBody(source, "runRouteWatchdogCheck")

        assertTrue("the monitor must capture the start generation that owns its checks", monitorStart.contains("val generation = currentStartGeneration()"))
        assertTrue("the check must receive the captured start generation", monitorStart.contains("runRouteWatchdogCheck(reason, healthClient, routeClient, generation)"))
        assertTrue("the check must bind observations to network and TUN generations", check.contains("val checkNetworkGeneration = networkGeneration") && check.contains("val checkTunGeneration = tunGeneration"))
        assertTrue("current-observation validation must include all three live generations", check.contains("shouldWatchCore(generation)") && check.contains("networkGeneration == checkNetworkGeneration") && check.contains("tunGeneration == checkTunGeneration"))

        val staleResult = check.indexOf("if (!isCurrentObservation())", check.indexOf("val result ="))
        val firstMutationAfterResult = listOf(
            check.indexOf("routeWatchdogFailures = 0", staleResult),
            check.indexOf("routeWatchdogDegraded = true", staleResult),
            check.indexOf("markRouteDegraded(", staleResult),
        ).filter { it >= 0 }.minOrNull() ?: -1
        assertTrue("stale route results must be discarded before state changes", staleResult >= 0 && firstMutationAfterResult > staleResult)

        val catchStart = check.indexOf("catch (e: Throwable)")
        val exceptionGuard = check.indexOf("if (!isCurrentObservation()) return", catchStart)
        val exceptionMutation = check.indexOf("routeWatchdogFailures += 1", catchStart)
        assertTrue("cancellation and stale exceptions must be rejected before failure counters change", catchStart >= 0 && exceptionGuard > catchStart && exceptionMutation > exceptionGuard)
    }

    @Test
    fun `Android startup gives the VPN probe the pre VPN default Network only for DNS bootstrap`() {
        val routeCheck = functionBody(sourceFile("BoxService.kt"), "checkVpnDataPlaneRoute")

        val runStart = routeCheck.indexOf("vpnDataPlaneProbe.run(")
        val defaultNetworkArg = routeCheck.indexOf("DefaultNetworkMonitor.defaultNetwork", runStart)
        assertTrue(
            "the route check must invoke the VPN probe through the pre-start active network",
            runStart >= 0 && defaultNetworkArg > runStart,
        )
    }

    @Test
    fun `stable VPN supervision never replaces a not due current proof with an outbound probe`() {
        val watchdog = functionBody(sourceFile("BoxService.kt"), "runRouteWatchdogCheck")
        val requireProof = watchdog.indexOf("val requireVpnDataPlane = Settings.serviceMode == ServiceMode.VPN")
        val shouldRun = watchdog.indexOf("shouldRunVpnDataPlaneProbe(", requireProof)
        val currentProof = watchdog.indexOf("else if (Settings.serviceMode == ServiceMode.VPN && currentProof != null)", shouldRun)
        val genericProbe = watchdog.indexOf("checkSelectedRoute(routeClient)", currentProof)

        assertTrue("the shared schedule must decide when the VPN data-plane proof is due", requireProof >= 0 && shouldRun > requireProof)
        assertTrue("a not-due VPN proof is retained as the route result", currentProof > shouldRun)
        assertTrue("the generic selected-route probe belongs after the VPN-specific proof branch", genericProbe > currentProof)
        assertTrue(
            "the selected-route monitor must not retain a TURNcoat-specific periodic proof shortcut",
            !watchdog.contains("turncoatCarrierNeedsProof") && !watchdog.contains("scheduledVpnDataPlaneProof"),
        )
    }

    @Test
    fun `cached VPN proof has a short bounded reuse window and still binds every live generation`() {
        val source = sourceFile("BoxService.kt")
        val reusable = functionBody(source, "hasReusableVpnDataPlaneProof")
        val current = functionBody(source, "currentVpnDataPlaneProof")

        assertTrue("a retained proof must have an explicit finite deadline", reusable.contains("proofAgeMs in 0..VPN_DATA_PLANE_PROOF_REUSE_MS"))
        assertTrue("a retained proof must be bound to the requested start generation", current.contains("it.startGeneration == generation"))
        assertTrue("a retained proof must be bound to the current network generation", current.contains("it.networkGeneration == networkGeneration"))
        assertTrue("a retained proof must be bound to the current TUN generation", current.contains("it.tunGeneration == tunGeneration"))
        assertTrue("proof reuse is deliberately short", sourceFile("VpnDataPlaneProbePolicy.kt").contains("VPN_DATA_PLANE_PROOF_REUSE_MS = 15_000L"))
    }

    @Test
    fun `Flutter acknowledgement uses the bounded native TURNcoat retry gate`() {
        val source = sourceFile("BoxService.kt")
        val acknowledgement = functionBody(source, "acknowledgeVerifiedRouteFromFlutter")
        val retry = acknowledgement.indexOf("awaitStartupRoutePublication(")
        val turncoatPlan = acknowledgement.indexOf("val usesTurncoat = currentRuntimeUsesTurncoat()")
        val deadline = source.indexOf("private const val STARTUP_ROUTE_VERIFY_TURNCOAT_TIMEOUT_MS = 75_000L")
        val retryDelay = source.indexOf("private const val STARTUP_ROUTE_VERIFY_RETRY_MS = 700L")

        assertTrue("Flutter acknowledgement must await bounded route publication", retry >= 0)
        assertTrue("retry must use the selected TURNcoat configuration", turncoatPlan >= 0 && turncoatPlan < retry)
        assertTrue("native route verification must share the acknowledgement deadline", acknowledgement.contains("operationDeadlineElapsedMs = deadline"))
        assertTrue("native retry must stay bounded", deadline >= 0 && retryDelay >= 0)
    }

    @Test
    fun `native startup proves the vpn data plane then hands current route failure to retry recovery`() {
        val source = sourceFile("BoxService.kt")
        val startupProbe = functionBody(source, "verifyNativeStartupRoute")
        assertTrue(
            "native startup must require the VPN data-plane request",
            Regex("checkSelectedRoute\\s*\\(\\s*routeClient\\s*,\\s*requireVpnDataPlane\\s*=\\s*true").containsMatchIn(startupProbe),
        )
        assertFalse("carrier telemetry cannot directly admit startup", startupProbe.contains("isLiveTurncoatCarrier"))
        assertFalse("TURNcoat RX evidence cannot directly admit startup", startupProbe.contains("rx_proof_count"))
        assertFalse("TURNcoat health reports cannot directly admit startup", startupProbe.contains("health_report_count"))
        val routeHealthy = startupProbe.indexOf("if (result.healthy)")
        val successfulReturn = startupProbe.indexOf("return true")
        assertTrue("startup may succeed only after the VPN GET is healthy", routeHealthy >= 0 && successfulReturn > routeHealthy)

        val retryFailedStart = startupProbe.indexOf("shouldRetryFailedNativeStartup(")
        val recoveryRequest = startupProbe.indexOf("requestCoreRecovery(", retryFailedStart)
        assertTrue(
            "a failed current user-owned VPN GET must be handed to recovery admission",
            retryFailedStart >= 0 && recoveryRequest > retryFailedStart,
        )
        assertTrue("failed current route must remain visibly fail-closed", startupProbe.contains("status.value = Status.Starting"))
        assertTrue("failed current route must publish recovery status", startupProbe.contains("R.string.status_recovering"))
        assertTrue("stale or inactive startup must be discarded without retry", startupProbe.contains("stale or inactive generation"))
        assertFalse("route failure must not terminally stop the service", startupProbe.contains("stopAndAlert(Alert.StartService"))
        assertFalse("route failure must not retain the old terminal-stop option", startupProbe.contains("stopServiceOnRouteFailure"))

        val watchdog = functionBody(source, "runRouteWatchdogCheck")
        assertTrue(
            "data-plane watchdog failures must use the two-attempt recovery threshold",
            Regex("val\\s+recoveryThreshold\\s*=\\s*if\\s*\\(\\s*result\\.requiresCoreRecovery\\s*\\)\\s*2\\s*else")
                .containsMatchIn(watchdog),
        )
        assertTrue("threshold escalation must enter route recovery", watchdog.contains("recoverRoute("))

        val establishedRecovery = functionBody(source, "recoverMobileCore")
        assertTrue(
            "established watchdog recovery keeps its bounded retry loop",
            establishedRecovery.contains("while (currentCoroutineContext().isActive && shouldWatchCore(generation))"),
        )

        val networkRecovery = functionBody(source, "recoverNetworkRoute")
        val coreEscalation = Regex("result\\.requiresCoreRecovery\\s*&&\\s*routeAttempt\\s*>=\\s*2")
            .find(networkRecovery)
            ?.range
            ?.first ?: -1
        assertTrue("network recovery must escalate only after two failed data-plane attempts", coreEscalation >= 0)
        assertTrue(
            "two failed data-plane attempts must request full core/TUN recovery",
            networkRecovery.indexOf("requestCoreRecovery(", coreEscalation) > coreEscalation,
        )
    }

    @Test
    fun `periodic stable proof failure defers user visible recovery while preserving the proof only for that probe`() {
        val source = sourceFile("BoxService.kt")
        val watchdog = functionBody(source, "runRouteWatchdogCheck")
        val routeCheck = functionBody(source, "checkSelectedRoute")
        val vpnProbe = functionBody(source, "checkVpnDataPlaneRoute")

        val preserveDecision = watchdog.indexOf("shouldPreserveVerifiedRouteAfterTransientProbeFailure(")
        val dataPlaneCheck = watchdog.indexOf("checkSelectedRoute(", preserveDecision)
        assertTrue(
            "a stable periodic watchdog check must decide whether its existing proof is transient before issuing the VPN GET",
            preserveDecision >= 0 && dataPlaneCheck > preserveDecision,
        )
        assertTrue(
            "only the VPN data-plane path may receive the transient-proof preservation flag",
            routeCheck.contains("preserveVpnDataPlaneProofOnFailure") &&
                vpnProbe.contains("preserveProofOnFailure"),
        )
        assertTrue(
            "the periodic VPN GET must forward its transient-proof decision into the route checker",
            watchdog.substring(preserveDecision, (dataPlaneCheck + 360).coerceAtMost(watchdog.length))
                .contains("preserveVpnDataPlaneProofOnFailure ="),
        )
        assertTrue(
            "a deliberately preserved transient proof must not be invalidated by the failed GET",
            vpnProbe.contains("if (preserveProofOnFailure && !result.networkReadinessPending)") &&
                vpnProbe.indexOf("invalidateVpnDataPlaneProof(result.summary)") >
                vpnProbe.indexOf("if (preserveProofOnFailure && !result.networkReadinessPending)"),
        )

        val publishDecision = watchdog.indexOf("shouldPublishRouteRecoveryStatus(")
        val degrade = watchdog.indexOf("markRouteDegraded(result.summary)", publishDecision)
        val recover = watchdog.indexOf("recoverRoute(\"selected route unavailable:", publishDecision)
        assertTrue(
            "the periodic watchdog must gate its visible recovery transition on the confirmation policy",
            publishDecision >= 0 && degrade > publishDecision && recover > degrade,
        )

        val networkChanged = functionBody(source, "onUnderlyingNetworkObserved")
        val networkRecovery = functionBody(source, "launchNetworkRouteRecovery")
        assertTrue("network generation changes must still enter their recovery owner", networkChanged.contains("launchNetworkRouteRecovery("))
        assertTrue(
            "network recovery remains immediately visible rather than borrowing the periodic transient-probe grace",
            networkRecovery.contains("status.value = Status.Starting") &&
                networkRecovery.contains("R.string.status_recovering"),
        )
    }

    @Test
    fun `route probe failure enters recovery while terminal alert cleanup remains ordered`() {
        val source = sourceFile("BoxService.kt")
        val startupProbe = functionBody(source, "verifyNativeStartupRoute")
        val stopAndAlert = functionBody(source, "stopAndAlert")

        assertTrue("failed current startup route must request recovery", startupProbe.contains("requestCoreRecovery("))
        assertTrue("stale or inactive startup route must be discarded", startupProbe.contains("stale or inactive generation"))
        assertFalse("route unavailability must not enter terminal alert cleanup", startupProbe.contains("stopAndAlert(Alert.StartService"))

        val closeAndTunWait = stopAndAlert.indexOf("closeMobileCoreAndAwaitTunQuiescence(")
        val alert = stopAndAlert.indexOf("callback.onServiceAlert(type.ordinal, message)")
        val stopped = stopAndAlert.indexOf("status.value = Status.Stopped")

        assertFalse("terminal alert cleanup must not bypass the shared MobileCoreCloser", stopAndAlert.contains("Mobile.stop()"))
        assertTrue("terminal alert cleanup must close the core and await TUN quiescence", closeAndTunWait >= 0)
        assertTrue("the dialog callback must be published after native cleanup", alert > closeAndTunWait)
        assertTrue("Stopped must be published after native cleanup", stopped > closeAndTunWait)
        assertTrue("Stopped must follow the terminal alert callback", stopped > alert)
        assertFalse(
            "cleanup must not wait for the UI dialog to be dismissed",
            stopAndAlert.substring(0, alert).contains("onServiceAlert"),
        )
    }

    @Test
    fun `route watchdog forces one TURNcoat carrier retirement while ordinary network updates keep probe reset`() {
        val source = sourceFile("BoxService.kt")
        val recoverRoute = functionBody(source, "recoverRoute")
        val recoverNetworkRoute = functionBody(source, "recoverNetworkRoute")
        val underlyingNetwork = functionBody(source, "onUnderlyingNetworkObserved")

        assertTrue(
            "TURNcoat watchdog recovery must request the stronger reset only for TURNcoat configs",
            recoverRoute.contains(
                "forceTurncoatCarrierRetirement = currentRuntimeUsesTurncoat()",
            ),
        )
        assertTrue(
            "only the first retry may retire the physical carrier; later retries retain normal reset semantics",
            recoverNetworkRoute.contains(
                "val forceTurncoatCarrier = forceTurncoatCarrierRetirement && !forcedTurncoatRetirementAttempted",
            ),
        )
        val forceCall = recoverNetworkRoute.indexOf("Mobile.resetNetworkForRouteRecovery()")
        val ordinaryCall = recoverNetworkRoute.indexOf("Mobile.resetNetwork()")
        val consumeForcedAttempt = recoverNetworkRoute.indexOf("forcedTurncoatRetirementAttempted = true")
        assertTrue("forced first attempt must call the route-recovery native API", forceCall >= 0)
        assertTrue("subsequent attempts must retain the normal network reset API", ordinaryCall > forceCall)
        assertTrue(
            "the forced reset must be consumed before the native call, even when that call partially fails",
            consumeForcedAttempt >= 0 && consumeForcedAttempt < forceCall,
        )
        assertTrue(
            "underlying-network changes must not force carrier retirement before their normal probe-and-keep reset",
            !underlyingNetwork.contains("forceTurncoatCarrierRetirement"),
        )
    }

    @Test
    fun `ordinary route watchdog escalation prefers bounded network recovery before core rebuild while TURNcoat failures may still escalate`() {
        val source = sourceFile("BoxService.kt")
        val recoverRoute = functionBody(source, "recoverRoute")
        val recoverNetworkRoute = functionBody(source, "recoverNetworkRoute")

        val launchRouteRecovery = recoverRoute.indexOf("launchNetworkRouteRecovery(")
        val routeReason = recoverRoute.indexOf("route watchdog recovery:")
        assertTrue(
            "route watchdog must still keep TURNcoat/ICMP branch in the same in-place recovery path",
            launchRouteRecovery >= 0 &&
                recoverRoute.contains("forceTurncoatCarrierRetirement = currentRuntimeUsesTurncoat()") &&
                recoverRoute.contains("replaceActive = false") &&
                routeReason >= 0,
        )
        assertTrue(
            "ordinary non-TURNcoat/non-ICMP escalation must use bounded route recovery rather than direct core request",
            !recoverRoute.contains("requestCoreRecovery("),
        )

        val resetFailed = recoverNetworkRoute.indexOf("if (resetResult.isFailure)")
        val networkResetCore = recoverNetworkRoute.indexOf("Mobile.resetNetworkForRouteRecovery()")
        val normalReset = recoverNetworkRoute.indexOf("Mobile.resetNetwork()")
        val resetFailureCoreRecovery = recoverNetworkRoute.indexOf(
            "requestCoreRecovery(\"native \$resetKind failed during \$reason\")",
        )
        assertTrue("forced TURNcoat path still requires a forced native reset", networkResetCore >= 0)
        assertTrue("non-forced reset still remains the in-place route recovery baseline", normalReset >= 0)
        assertTrue(
            "route reset failures must still escape to core recovery when recovery cannot be fixed in-place",
            resetFailureCoreRecovery > resetFailed,
        )

        val resultEscalation = recoverNetworkRoute.indexOf(
            "if (\n                (result.requiresCoreRecovery && routeAttempt >= 2) ||\n                routeAttempt >= NETWORK_ROUTE_RECOVERY_MAX_ATTEMPTS",
        )
        val fallbackCoreRecovery = recoverNetworkRoute.indexOf("requestCoreRecovery(", resultEscalation)
        assertTrue(
            "bounded network-route attempts must still escalate into core/TUN recovery",
            resultEscalation >= 0 && fallbackCoreRecovery > resultEscalation,
        )
    }

    @Test
    fun `source body scanner ignores braces in Kotlin literals and comments`() {
        val source =
            "fun sample() {\n" +
                "  val ordinary = \"{ ordinary }\"\n" +
                "  val triple = \"\"\"{ triple }\"\"\"\n" +
                "  val marker = '{'\n" +
                "  // } line comment\n" +
                "  /* { outer /* } nested */ outer } */\n" +
                "}\n" +
                "fun after() = Unit\n"

        val body = functionBody(source, "sample")
        assertTrue(body.contains("val triple"))
        assertFalse(body.contains("fun after"))
    }

    private fun shouldProbe(
        forced: Boolean = false,
        degraded: Boolean = false,
        deviceInteractive: Boolean = true,
        lastProofMs: Long = 1L,
        nowMs: Long = 1L,
    ): Boolean = shouldRunVpnDataPlaneProbe(
        forced = forced,
        degraded = degraded,
        deviceInteractive = deviceInteractive,
        lastProofElapsedRealtimeMs = lastProofMs,
        nowElapsedRealtimeMs = nowMs,
    )

    private fun sourceFile(name: String): String {
        val source = File("src/main/kotlin/app/marten/client/bg/$name")
        check(source.isFile) { "missing production source ${source.path}" }
        return source.readText()
    }

    private fun functionBody(source: String, name: String): String {
        val declaration = source.indexOf("fun $name")
        check(declaration >= 0) { "function $name not found" }
        val bodyStart = findCodeCharacter(source, declaration, '{')
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
                '{' -> depth += 1
                '}' -> {
                    depth -= 1
                    if (depth == 0) return source.substring(bodyStart, index + 1)
                }
            }
            index++
        }
        error("function $name body does not close")
    }

    private fun findCodeCharacter(source: String, start: Int, target: Char): Int {
        var index = start
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
                target -> return index
            }
            index++
        }
        return -1
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
