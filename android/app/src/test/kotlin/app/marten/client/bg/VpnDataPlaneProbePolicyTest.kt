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
    fun `VPN route probe attempts prefer 4 seconds for direct route and 30 seconds for TURNcoat`() {
        assertEquals(STANDARD_VPN_DATA_PLANE_ATTEMPT_TIMEOUT_MS, vpnDataPlaneAttemptTimeoutMs(turncoatRoute = false))
        assertEquals(TURNCOAT_VPN_DATA_PLANE_ATTEMPT_TIMEOUT_MS, vpnDataPlaneAttemptTimeoutMs(turncoatRoute = true))

        assertEquals(3_000L, vpnDataPlaneAttemptTimeoutMs(turncoatRoute = false, remainingBudgetMs = 3_000L));
        assertEquals(3_000L, vpnDataPlaneAttemptTimeoutMs(turncoatRoute = true, remainingBudgetMs = 3_000L));
        assertEquals(1L, vpnDataPlaneAttemptTimeoutMs(turncoatRoute = false, remainingBudgetMs = 1L));
        assertEquals(1L, vpnDataPlaneAttemptTimeoutMs(turncoatRoute = true, remainingBudgetMs = 0L));
    }

    @Test
    fun `ordinary busy tun waits five minutes before probing`() {
        assertFalse(shouldProbe(tunTrafficAdvanced = true, lastProofMs = 100L, nowMs = 300_099L))
        assertTrue(shouldProbe(tunTrafficAdvanced = true, lastProofMs = 100L, nowMs = 300_100L))
    }

    @Test
    fun `stable tun probe interval follows interactive state`() {
        assertFalse(shouldProbe(deviceInteractive = true, lastProofMs = 100L, nowMs = 300_099L))
        assertTrue(shouldProbe(deviceInteractive = true, lastProofMs = 100L, nowMs = 300_100L))

        assertFalse(shouldProbe(deviceInteractive = false, lastProofMs = 100L, nowMs = 1_800_099L))
        assertTrue(shouldProbe(deviceInteractive = false, lastProofMs = 100L, nowMs = 1_800_100L))
    }

    @Test
    fun `TURNcoat always requires a fresh authoritative VPN proof within sixty seconds including background`() {
        for (interactive in listOf(true, false)) {
            assertFalse(
                "TURNcoat should not probe before its sixty-second proof deadline",
                shouldProbe(
                    turncoatRoute = true,
                    deviceInteractive = interactive,
                    lastProofMs = 100L,
                    nowMs = 60_099L,
                ),
            )
            assertTrue(
                "TURNcoat must not inherit the ordinary interactive/background interval",
                shouldProbe(
                    turncoatRoute = true,
                    deviceInteractive = interactive,
                    lastProofMs = 100L,
                    nowMs = 60_100L,
                ),
            )
        }
    }

    @Test
    fun `TURNcoat watchdog starts at sixty seconds and passes its route type into the full VPN proof policy`() {
        val source = sourceFile("BoxService.kt")
        val watchdog = functionBody(source, "runRouteWatchdogCheck")
        val initialDelay = functionBody(source, "routeWatchdogInitialDelayMs")

        assertTrue(
            "TURNcoat must not defer its first watchdog proof beyond one minute",
            source.contains("private const val ROUTE_WATCHDOG_TURNCOAT_INITIAL_DELAY_MS = 60_000L"),
        )
        assertTrue(
            "TURNcoat initial delay must select the dedicated one-minute constant from the live generation owner",
            initialDelay.contains("currentRuntimeUsesTurncoat() -> ROUTE_WATCHDOG_TURNCOAT_INITIAL_DELAY_MS"),
        )
        val runtimeHelperStart = source.indexOf("private fun currentRuntimeUsesTurncoat(): Boolean")
        val runtimeHelperEnd = source.indexOf("\n    private fun", runtimeHelperStart + 1)
        val runtimeUsesTurncoat = if (runtimeHelperStart < 0 || runtimeHelperEnd < 0) {
            ""
        } else {
            source.substring(runtimeHelperStart, runtimeHelperEnd)
        }
        assertTrue(
            "live route policy must read TURNcoat capability from immutable runtime ownership",
            runtimeUsesTurncoat.contains("runtimeConfigOwnership.usesTurncoat(currentStartGeneration())"),
        )
        assertFalse(
            "live route policy must not read future resume intent from Settings",
            runtimeUsesTurncoat.contains("Settings.activeConfig"),
        )
        assertTrue("the watchdog must use the full VPN data-plane proof policy", watchdog.contains("shouldRunVpnDataPlaneProbe("))
        assertTrue("the full proof policy must know that the selected route is TURNcoat", watchdog.contains("turncoatRoute = usesTurncoat"))
    }

    @Test
    fun `clock rollback cannot force a stable or traffic-triggered probe`() {
        assertFalse(shouldProbe(lastProofMs = 10_000L, nowMs = 9_999L))
        assertFalse(shouldProbe(tunTrafficAdvanced = true, lastProofMs = 10_000L, nowMs = 9_999L))
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
    fun `vpn source keeps Marten UID in the VPN and admits started only with current tun proof`() {
        val openTun = functionBody(sourceFile("VPNService.kt"), "openTun")
        val routingPolicy = sourceFile("VpnAppRoutingPolicy.kt")
        assertTrue(
            "VPNService must resolve routing with its own package name",
            Regex("resolveVpnAppRoutingPlan\\([\\s\\S]*ownPackageName\\s*=\\s*packageName").containsMatchIn(openTun),
        )
        assertTrue(
            "include-only policy must retain Marten's package",
            routingPolicy.contains("it == ownPackageName || it !in bypassPackages"),
        )
        assertTrue(
            "exclude policy must remove Marten's package",
            routingPolicy.contains(".filter { it != ownPackageName }"),
        )

        val serviceSource = sourceFile("BoxService.kt")
        val currentProof = functionBody(serviceSource, "currentVpnDataPlaneProof")
        val markStarted = functionBody(serviceSource, "markCoreRuntimeStarted")
        assertTrue("data-plane proof must bind to the active TUN generation", currentProof.contains("it.tunGeneration == tunGeneration"))
        assertTrue(
            "data-plane proof must bind to the exact active Android VPN Network",
            currentProof.contains("it.vpnNetworkHandle == vpnDataPlaneProbe.currentVpnNetworkHandle()"),
        )

        val freshProofGuard = markStarted.indexOf("if (!hasReusableVpnDataPlaneProof(generation))")
        val started = markStarted.indexOf("status.value = Status.Started")
        assertTrue("Started must unconditionally be gated by a fresh VPN data-plane proof", freshProofGuard >= 0)
        assertFalse("no route-verification caller may bypass the proof gate", markStarted.contains("routeVerified && !hasReusableVpnDataPlaneProof"))
        assertTrue("proof gate must execute before Started", started > freshProofGuard)
        assertTrue("missing proof must leave the service in Starting", markStarted.substring(freshProofGuard, started).contains("status.value = Status.Starting"))
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
    fun `TURNcoat watchdog accepts carrier telemetry only alongside a current Android VPN proof`() {
        val watchdog = functionBody(sourceFile("BoxService.kt"), "runRouteWatchdogCheck")

        val evidence = watchdog.indexOf("val turncoatEvidence")
        val liveCarrier = watchdog.indexOf("isLiveTurncoatCarrier(", evidence)
        val requireProof = watchdog.indexOf("val requireVpnDataPlane = scheduledVpnDataPlaneProof || turncoatCarrierNeedsProof")
        val retainedProof = watchdog.indexOf("usesTurncoat && currentProof != null")
        val missingProof = watchdog.indexOf("TURNcoat route has no current VPN data-plane proof")
        assertTrue("carrier telemetry remains diagnostic", evidence >= 0 && liveCarrier > evidence)
        assertTrue("missing real RX must force an authoritative data-plane GET", requireProof > liveCarrier)
        assertTrue("a healthy TURNcoat watchdog result may retain only a current native proof", retainedProof > requireProof)
        assertTrue("telemetry alone must fail closed when no proof exists", missingProof > retainedProof)
        assertFalse(
            "health/probe counters may not directly return a successful route",
            watchdog.substring(evidence, retainedProof).contains("RouteHealth(\n                    true"),
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
        val retry = acknowledgement.indexOf("verifyNativeStartupRoute(")
        val turncoatPlan = acknowledgement.indexOf("usesTurncoat = currentRuntimeUsesTurncoat()", retry)
        val deadline = source.indexOf("private const val STARTUP_ROUTE_VERIFY_TURNCOAT_TIMEOUT_MS = 75_000L")
        val retryDelay = source.indexOf("private const val STARTUP_ROUTE_VERIFY_RETRY_MS = 700L")

        assertTrue("Flutter acknowledgement must await native data-plane retry", retry >= 0)
        assertTrue("retry must use the selected TURNcoat configuration", turncoatPlan > retry)
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
        turncoatRoute: Boolean = false,
        tunTrafficAdvanced: Boolean = false,
        lastProofMs: Long = 1L,
        nowMs: Long = 1L,
    ): Boolean = shouldRunVpnDataPlaneProbe(
        forced = forced,
        degraded = degraded,
        turncoatRoute = turncoatRoute,
        deviceInteractive = deviceInteractive,
        tunTrafficAdvanced = tunTrafficAdvanced,
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
