package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ServiceEnergyPolicyTest {
    @Test
    fun `core watchdog returns recovery and stable intervals`() {
        assertEquals(2_000L, coreWatchdogPollDelayMs(recoveryInProgress = true))
        assertEquals(15_000L, coreWatchdogPollDelayMs(recoveryInProgress = false))
    }

    @Test
    fun `vpn ownership watchdog shortens interval on interactive device`() {
        assertEquals(5_000L, vpnOwnershipWatchdogPollDelayMs(deviceInteractive = true))
        assertEquals(15_000L, vpnOwnershipWatchdogPollDelayMs(deviceInteractive = false))
    }

    @Test
    fun `selected route watchdog prioritizes degraded and preserves expected stable intervals`() {
        assertEquals(500L, selectedRouteWatchdogPollDelayMs(degraded = true, icmpRoute = false, deviceInteractive = true))
        assertEquals(500L, selectedRouteWatchdogPollDelayMs(degraded = true, icmpRoute = false, deviceInteractive = false))
        assertEquals(500L, selectedRouteWatchdogPollDelayMs(degraded = true, icmpRoute = true, deviceInteractive = true))
        assertEquals(500L, selectedRouteWatchdogPollDelayMs(degraded = true, icmpRoute = true, deviceInteractive = false))

        assertEquals(30_000L, selectedRouteWatchdogPollDelayMs(degraded = false, icmpRoute = false, deviceInteractive = true))
        assertEquals(60_000L, selectedRouteWatchdogPollDelayMs(degraded = false, icmpRoute = false, deviceInteractive = false))
    }

    @Test
    fun `selected route watchdog switches by icmp interactive or background mode`() {
        assertEquals(3_000L, selectedRouteWatchdogPollDelayMs(degraded = false, icmpRoute = true, deviceInteractive = true))
        assertEquals(10_000L, selectedRouteWatchdogPollDelayMs(degraded = false, icmpRoute = true, deviceInteractive = false))
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
}
