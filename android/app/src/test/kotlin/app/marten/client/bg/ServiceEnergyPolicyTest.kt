package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ServiceEnergyPolicyTest {
    @Test
    fun `core watchdog keeps recovery supervision sparse in interactive and background states`() {
        assertEquals(5_000L, coreWatchdogPollDelayMs(recoveryInProgress = true, deviceInteractive = true))
        assertEquals(15_000L, coreWatchdogPollDelayMs(recoveryInProgress = true, deviceInteractive = false))
        assertEquals(15_000L, coreWatchdogPollDelayMs(recoveryInProgress = false, deviceInteractive = true))
        assertEquals(15_000L, coreWatchdogPollDelayMs(recoveryInProgress = false, deviceInteractive = false))
    }

    @Test
    fun `contended native recovery admission uses sparse screen-aware exponential fallbacks`() {
        assertEquals(5_000L, coreRecoveryAdmissionRetryDelayMs(rejectedAttempts = 0, deviceInteractive = true))
        assertEquals(5_000L, coreRecoveryAdmissionRetryDelayMs(rejectedAttempts = 1, deviceInteractive = true))
        assertEquals(8_000L, coreRecoveryAdmissionRetryDelayMs(rejectedAttempts = 2, deviceInteractive = true))
        assertEquals(16_000L, coreRecoveryAdmissionRetryDelayMs(rejectedAttempts = 3, deviceInteractive = true))
        assertEquals(32_000L, coreRecoveryAdmissionRetryDelayMs(rejectedAttempts = 4, deviceInteractive = true))
        assertEquals(60_000L, coreRecoveryAdmissionRetryDelayMs(rejectedAttempts = 5, deviceInteractive = true))
        assertEquals(60_000L, coreRecoveryAdmissionRetryDelayMs(rejectedAttempts = 99, deviceInteractive = true))

        assertEquals(15_000L, coreRecoveryAdmissionRetryDelayMs(rejectedAttempts = 0, deviceInteractive = false))
        assertEquals(15_000L, coreRecoveryAdmissionRetryDelayMs(rejectedAttempts = 2, deviceInteractive = false))
        assertEquals(16_000L, coreRecoveryAdmissionRetryDelayMs(rejectedAttempts = 3, deviceInteractive = false))
        assertEquals(60_000L, coreRecoveryAdmissionRetryDelayMs(rejectedAttempts = 99, deviceInteractive = false))
    }

    @Test
    fun `startup runtime monitor uses the shared sparse screen-aware watchdog cadence`() {
        val boxService = sourceFile("BoxService.kt")
        val runtimeMonitor = functionBody(boxService, "startCoreRuntimeMonitor")

        assertFalse(
            "the removed 250 ms runtime-monitor constant must not be reintroduced",
            boxService.contains("CORE_RUNTIME_MONITOR_POLL_MS"),
        )
        assertTrue(
            "startup recovery must delegate its delay to the common 5 s interactive / 15 s background policy",
            runtimeMonitor.contains("coreWatchdogPollDelayMs(") &&
                runtimeMonitor.contains("recoveryInProgress = true") &&
                runtimeMonitor.contains("deviceInteractive = Application.powerManager.isInteractive"),
        )
        assertFalse(
            "startup recovery must not keep a hard-coded tight polling delay",
            runtimeMonitor.contains("delay(250L)"),
        )
    }

    @Test
    fun `vpn ownership supervision is event driven with bounded confirmation`() {
        val boxService = sourceFile("BoxService.kt")
        val ownershipMonitor = functionBody(boxService, "startExternalVpnWatchdog")

        assertFalse("ownership checks must not poll on a fixed screen-aware timer", ownershipMonitor.contains("vpnOwnershipWatchdogPollDelayMs"))
        assertTrue("only a suspected ownership loss may wait for bounded confirmation", ownershipMonitor.contains("delay(CORE_WATCHDOG_CONFIRM_MS)"))
        assertTrue("stable ownership must park for a network callback", ownershipMonitor.contains("changes.receive()"))
        assertTrue("ownership loss must retain its bounded miss confirmation policy", ownershipMonitor.contains("EXTERNAL_VPN_OWNERSHIP_LOSS_CONFIRMATIONS"))
    }

    @Test
    fun `selected route monitor uses immediate bounded degraded checks and shared stable proof cadence`() {
        assertEquals(5_000L, selectedRouteWatchdogPollDelayMs(degraded = true, deviceInteractive = true))
        assertEquals(15_000L, selectedRouteWatchdogPollDelayMs(degraded = true, deviceInteractive = false))

        assertEquals(5 * 60_000L, selectedRouteWatchdogPollDelayMs(degraded = false, deviceInteractive = true))
        assertEquals(30 * 60_000L, selectedRouteWatchdogPollDelayMs(degraded = false, deviceInteractive = false))
    }

    @Test
    fun `screen and doze transitions rearm the current route proof deadline`() {
        val boxService = sourceFile("BoxService.kt")
        val receiverStart = boxService.indexOf("private val receiver = object : BroadcastReceiver")
        val receiverEnd = boxService.indexOf("private fun registerServiceReceiverIfNeeded()", receiverStart)
        assertTrue("service receiver must be present", receiverStart >= 0 && receiverEnd > receiverStart)
        val receiver = boxService.substring(receiverStart, receiverEnd)

        listOf(
            "PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED ->",
            "Intent.ACTION_SCREEN_ON ->",
            "Intent.ACTION_SCREEN_OFF ->",
            "Intent.ACTION_USER_PRESENT ->",
        ).forEach { event ->
            val eventStart = receiver.indexOf(event)
            assertTrue("$event must wake schedule recalculation", eventStart >= 0)
            val branchEnd = receiver.indexOf("\n                }", eventStart).let { if (it < 0) receiver.length else it }
            val branch = receiver.substring(eventStart, branchEnd)
            assertTrue("$event must re-arm the existing monitor", branch.contains("routeHealthMonitor?.rearm()"))
            assertFalse("$event must not start an immediate second route-check lane", branch.contains("requestRouteWatchdogCheck("))
        }
    }

    @Test
    fun `service CAPTCHA control retry is exponential with a screen-off floor and one-minute cap`() {
        assertEquals(2_000L, serviceCaptchaControlRetryDelayMs(consecutiveFailures = 0, deviceInteractive = true))
        assertEquals(4_000L, serviceCaptchaControlRetryDelayMs(consecutiveFailures = 1, deviceInteractive = true))
        assertEquals(8_000L, serviceCaptchaControlRetryDelayMs(consecutiveFailures = 2, deviceInteractive = true))
        assertEquals(16_000L, serviceCaptchaControlRetryDelayMs(consecutiveFailures = 3, deviceInteractive = true))
        assertEquals(32_000L, serviceCaptchaControlRetryDelayMs(consecutiveFailures = 4, deviceInteractive = true))
        assertEquals(60_000L, serviceCaptchaControlRetryDelayMs(consecutiveFailures = 5, deviceInteractive = true))
        assertEquals(60_000L, serviceCaptchaControlRetryDelayMs(consecutiveFailures = 99, deviceInteractive = true))

        assertEquals(15_000L, serviceCaptchaControlRetryDelayMs(consecutiveFailures = 0, deviceInteractive = false))
        assertEquals(15_000L, serviceCaptchaControlRetryDelayMs(consecutiveFailures = 2, deviceInteractive = false))
        assertEquals(16_000L, serviceCaptchaControlRetryDelayMs(consecutiveFailures = 3, deviceInteractive = false))
        assertEquals(60_000L, serviceCaptchaControlRetryDelayMs(consecutiveFailures = 99, deviceInteractive = false))
    }

    @Test
    fun `vpn service and manifest avoid wake-lock usage and permissions`() {
        val boxService = sourceFile("BoxService.kt")
        val manifest = sourceFileFromRoot("src/main/AndroidManifest.xml")

        assertFalse(boxService.contains("newWakeLock"))
        assertFalse(boxService.contains("PARTIAL_WAKE_LOCK"))
        assertFalse(manifest.contains("Marten:VpnService"))
        assertFalse(manifest.contains("android.permission.WAKE_LOCK"))
    }

    @Test
    fun `network recovery waits for a physical callback and bounds expensive route work`() {
        val boxService = sourceFile("BoxService.kt")
        val recovery = functionBody(boxService, "recoverNetworkRoute(")
        val startupVerification = functionBody(boxService, "verifyNativeStartupRoute(")

        val noNetwork = recovery.indexOf("underlyingNetworkInitialized && observedUnderlyingNetwork == null")
        val requireNetwork = recovery.indexOf("DefaultNetworkMonitor.require()", noNetwork)
        val waitReturns = recovery.indexOf("return", requireNetwork)
        val reset = recovery.indexOf("val resetResult", waitReturns)
        assertTrue(
            "without an underlying network, route recovery must park on the connectivity callback before resetting the core",
            noNetwork >= 0 && requireNetwork > noNetwork && waitReturns > requireNetwork && reset > waitReturns,
        )
        val noNetworkBranch = recovery.substring(noNetwork, reset)
        assertFalse(
            "a missing network must not use the route retry timer as a polling source",
            noNetworkBranch.contains("delay(NETWORK_ROUTE_RECOVERY_RETRY_MS)"),
        )
        assertTrue(
            "an active core recovery owns recovery instead of competing with a route reset",
            recovery.indexOf("if (coreRecoveryInProgress)") in 0 until reset,
        )
        assertTrue(
            "an active route check owns verification instead of a parallel probe",
            recovery.contains("if (!beginRouteWatchdogCheck())") && recovery.contains("endRouteWatchdogCheck()"),
        )
        assertTrue(
            "network route recovery must cap expensive reset/probe attempts at three",
            boxService.contains("private const val NETWORK_ROUTE_RECOVERY_MAX_ATTEMPTS = 3") &&
                recovery.contains("routeAttempt >= NETWORK_ROUTE_RECOVERY_MAX_ATTEMPTS"),
        )

        val startupNoNetwork = startupVerification.indexOf("underlyingNetworkInitialized && observedUnderlyingNetwork == null")
        val startupRequire = startupVerification.indexOf("DefaultNetworkMonitor.require()", startupNoNetwork)
        val startupContinue = startupVerification.indexOf("continue", startupRequire)
        val startupProbe = startupVerification.indexOf("attempt += 1", startupContinue)
        assertTrue(
            "startup route verification must wait for the connectivity callback rather than polling every 700 ms",
            startupNoNetwork >= 0 && startupRequire > startupNoNetwork &&
                startupContinue > startupRequire && startupProbe > startupContinue,
        )
        assertFalse(
            startupVerification.substring(startupNoNetwork, startupProbe).contains("delay(STARTUP_ROUTE_VERIFY_RETRY_MS)"),
        )
    }

    private fun sourceFile(name: String): String = sourceFromCandidates(
        listOf(
            "src/main/kotlin/app/marten/client/bg/$name",
            "android/src/main/kotlin/app/marten/client/bg/$name",
            "../android/src/main/kotlin/app/marten/client/bg/$name",
        ),
    )

    private fun sourceFileFromRoot(relative: String): String = sourceFromCandidates(
        listOf(
            relative,
            "android/$relative",
            "../android/$relative",
        ),
    )

    private fun sourceFromCandidates(candidates: List<String>): String {
        val source = candidates
            .asSequence()
            .map { File(it) }
            .firstOrNull { it.isFile }

        check(source != null) { "missing production source among: ${candidates.joinToString()}" }
        return source.readText()
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
