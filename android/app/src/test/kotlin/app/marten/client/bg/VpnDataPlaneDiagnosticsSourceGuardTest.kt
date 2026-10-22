package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnDataPlaneDiagnosticsSourceGuardTest {
    @Test
    fun `probe exposes only the stable safe stage vocabulary and sanitizes throwable categories`() {
        val probe = sourceFile("VpnDataPlaneProbe.kt")
        val result = sourceSection(probe, "internal data class VpnDataPlaneProbeResult", "private data class NetworkDnsResult")
        val stages = sourceSection(probe, "internal enum class VpnDataPlaneProbeStage", "internal fun vpnDataPlaneExceptionCategory")
        val endpoints = sourceSection(probe, "private val PROBE_ENDPOINTS = listOf(", "private const val PROBE_PORT")
        val exceptionCategory = functionBody(probe, "vpnDataPlaneExceptionCategory")

        assertTrue("probe result must carry a stable stage", result.contains("val stage: VpnDataPlaneProbeStage"))
        assertTrue("probe result must carry a safe failure category", result.contains("val failure: String?"))
        assertEquals(
            listOf(
                "vpn_network",
                "underlying_network",
                "underlying_dns",
                "http_connect",
                "tls_handshake",
                "http_write",
                "http_read",
                "vpn_dns",
                "complete",
            ),
            Regex("\\\"([a-z_]+)\\\"").findAll(stages).map { it.groupValues[1] }.toList(),
        )
        assertTrue("successful probes must terminate at complete", probe.contains("stage = VpnDataPlaneProbeStage.COMPLETE"))
        val endpointHosts = Regex("HttpsProbeEndpoint\\(\\\"([^\\\"]+)\\\"")
            .findAll(endpoints)
            .map { it.groupValues[1] }
            .toList()
        assertTrue("endpoint rotation must retain at least three independent HTTPS hosts", endpointHosts.distinct().size >= 3)
        assertFalse("probe summaries must not expose the selected endpoint", result.contains("endpoint") || result.contains(".host"))
        assertTrue("IO throwable names must be derived from class tokens", exceptionCategory.contains("value.javaClass.simpleName"))
        assertTrue("IO throwable names must be normalized into a bounded lowercase token", exceptionCategory.contains("replace(Regex(\"[^A-Za-z0-9]+\"), \"_\")"))
        assertTrue("each class token must be bounded before composing a category", exceptionCategory.contains(".take(24)"))
        assertTrue("exception categories must remain within the diagnostics safe-token limit", exceptionCategory.contains(".take(48).trimEnd('_')"))
        assertTrue("the terminal cause walk must be bounded even for a cyclic cause graph", exceptionCategory.contains("generateSequence(error)") && exceptionCategory.contains(".takeUnless { it === current }") && exceptionCategory.contains(".take(6).last()"))
        assertFalse("diagnostic categories must never serialize throwable messages", exceptionCategory.contains(".message"))
        assertFalse("diagnostic categories must never serialize throwable text", exceptionCategory.contains("toString()"))
    }

    @Test
    fun `exception categories retain only bounded top and root class tokens`() {
        val privateMessage = "https://cp.cloudflare.com:443/generate_204 address=203.0.113.7 credential=private"
        val root = RootProbeFailure(privateMessage)
        val top = TopProbeFailure(privateMessage).apply { initCause(root) }

        val category = vpnDataPlaneExceptionCategory(top, unexpected = false)

        assertEquals("io_topprobefailure_rootprobefailure", category)
        assertTrue("diagnostic categories must be safe tokens", category.matches(Regex("[a-z0-9_]{1,48}")))
        assertTrue("diagnostic categories must stay within the ConnectionDiagnostics limit", category.length <= 48)
        assertFalse("exception messages must not be included", category.contains(privateMessage))
        assertFalse("hosts must not be included", category.contains("cloudflare"))
        assertFalse("addresses must not be included", category.contains("203_0_113_7"))
        assertFalse("credentials must not be included", category.contains("credential"))

        val unexpected = vpnDataPlaneExceptionCategory(top, unexpected = true)
        assertEquals("unexpected_topprobefailure_rootprobefailure", unexpected)
        assertTrue("unexpected category must also remain within the safe-token limit", unexpected.length <= 48)
    }

    @Test
    fun `exception category cause traversal terminates for a cycle`() {
        val first = TopProbeFailure("first")
        val second = RootProbeFailure("second")
        first.initCause(second)
        second.initCause(first)

        val category = vpnDataPlaneExceptionCategory(first, unexpected = false)

        assertEquals("io_topprobefailure_rootprobefailure", category)
        assertTrue("cyclic cause diagnostics must still be bounded", category.length <= 48)
    }

    @Test
    fun `connection diagnostics persist only safe VPN fields including both generations`() {
        val diagnostics = sourceFile("ConnectionDiagnostics.kt")
        val record = sourceSection(diagnostics, "fun record(", "private fun readNetworkSnapshot")

        assertTrue("diagnostics record must accept the probe stage", record.contains("stage: String"))
        assertTrue("diagnostics record must accept the probe category", record.contains("category: String"))
        assertTrue("diagnostics record must accept the network generation", record.contains("networkGeneration: Long"))
        assertTrue("diagnostics record must accept the TUN generation", record.contains("tunGeneration: Long"))
        assertTrue("probe stage must be filtered by the diagnostics safe-token policy", record.contains("safeStage = stage.takeIf(safeToken::matches)"))
        assertTrue("probe category must be filtered by the diagnostics safe-token policy", record.contains("safeCategory = category.takeIf(safeToken::matches)"))
        for (field in listOf("stage=", "category=", "network_generation=", "tun_generation=")) {
            assertTrue("persisted diagnostics must retain $field", record.contains(field))
        }
        assertFalse("persisted diagnostics must never contain Android Network handles", record.contains("networkHandle"))
        assertFalse("persisted diagnostics must never contain an endpoint", record.contains("endpoint"))
        assertFalse("persisted diagnostics must never contain an URL", record.contains("url"))
        assertFalse("persisted diagnostics must never contain exception messages", record.contains(".message"))
    }

    @Test
    fun `connection and Quick Settings diagnostics queue all slow environment and file work after caller timestamps`() {
        val connection = sourceFile("ConnectionDiagnostics.kt")
        val quickSettings = sourceFile("QuickSettingsDiagnostics.kt")

        listOf(
            "ConnectionDiagnostics" to connection,
            "QuickSettingsDiagnostics" to quickSettings,
        ).forEach { (name, source) ->
            val record = sourceSection(source, "fun record(", "private fun readNetworkSnapshot")
            val writer = record.indexOf("writer.execute {")
            assertTrue("$name must retain a single serial writer", writer >= 0)

            val callerPath = record.substring(0, writer)
            val writerPath = record.substring(writer)
            assertTrue("$name must capture wall time before enqueueing", callerPath.contains("System.currentTimeMillis()"))
            assertTrue("$name must capture monotonic time before enqueueing", callerPath.contains("SystemClock.elapsedRealtime()"))
            listOf(
                "readNetworkSnapshot(",
                "getSystemService(",
                "ConnectivityManager",
                "Settings.Global",
                "getExternalFilesDir(",
                ".filesDir",
                ".appendBytes(",
                ".mkdirs(",
                "rotate(",
            ).forEach { slowOperation ->
                assertFalse("$name caller path must not perform $slowOperation", callerPath.contains(slowOperation))
            }
            assertTrue("$name writer must gather its network snapshot after enqueueing", writerPath.contains("readNetworkSnapshot("))
            assertTrue("$name writer must retain file persistence", writerPath.contains("appendBytes("))
            assertTrue("$name must emit diagnostics from the ordered writer", writerPath.contains("Log.i(TAG, line)"))

            val capturedScalars = if (name == "ConnectionDiagnostics") {
                listOf(
                    "safeComponent",
                    "safeEvent",
                    "safeOutcome",
                    "safeStage",
                    "safeCategory",
                    "safeRequestId",
                    "safeGeneration",
                    "safeAttempt",
                    "safeDurationMs",
                    "safeNetworkGeneration",
                    "safeTunGeneration",
                )
            } else {
                listOf("safeComponent", "safeEvent", "safeOutcome", "safeStatus", "safeRequestId", "safeGeneration", "safeRevision")
            }
            capturedScalars.forEach { scalar ->
                assertTrue("$name must capture $scalar before enqueueing", callerPath.contains("val $scalar"))
                assertTrue("$name writer must serialize captured $scalar", writerPath.contains("\$$scalar"))
            }
        }
    }

    @Test
    fun `successful VPN proof publication stays on the minimal revalidated startup path`() {
        val service = sourceFile("BoxService.kt")
        val proof = functionBody(service, "recordVpnDataPlaneProof")
        val watchdog = functionBody(service, "runRouteWatchdogCheck")

        assertFalse("proof publication must not synchronously read TUN runtime health", proof.contains("readTunRuntimeHealth("))
        assertFalse("proof publication must not synchronously read TUN traffic", proof.contains("readTunTrafficSnapshot("))
        assertTrue("proof publication must retain start-generation revalidation", proof.contains("proofStartGeneration != startGeneration"))
        assertTrue("proof publication must retain network-generation revalidation", proof.contains("proofNetworkGeneration != networkGeneration"))
        assertTrue("proof publication must retain TUN-generation revalidation", proof.contains("proofTunGeneration != tunGeneration"))
        val currentHandle = proof.indexOf("val currentVpnNetworkHandle = vpnDataPlaneProbe.currentVpnNetworkHandle()")
        val proofLock = proof.indexOf("synchronized(vpnDataPlaneProofLock)")
        val exactHandleComparison = proof.indexOf("proofVpnNetworkHandle != currentVpnNetworkHandle", proofLock)
        assertTrue("proof publication must read the exact current VPN network handle before its lock", currentHandle >= 0 && proofLock > currentHandle)
        assertTrue("proof publication must compare the proof against that exact current VPN network handle", exactHandleComparison > proofLock)

        assertTrue("the route watchdog must still read TUN traffic for activity-aware recovery", watchdog.contains("readTunTrafficSnapshot("))
        assertTrue("the route watchdog must restore the traffic baseline after startup publication", watchdog.contains("lastTunTrafficSnapshot ="))
    }

    @Test
    fun `VPN data plane route records started and every terminal outcome with safe context`() {
        val probe = sourceFile("VpnDataPlaneProbe.kt")
        val routeCheck = functionBody(sourceFile("BoxService.kt"), "checkVpnDataPlaneRoute")
        val recordHelper = sourceSection(routeCheck, "fun recordProbeDiagnostic(", "recordProbeDiagnostic(\n            outcome = \"started\"")
        val cancelled = sourceSection(routeCheck, "val result = try", "if (\n            proofStartGeneration")
        val staleGeneration = sourceSection(routeCheck, "if (\n            proofStartGeneration", "if (!result.healthy)")
        val probeFailure = sourceSection(routeCheck, "if (!result.healthy)", "val proofVpnNetworkHandle")
        val missingVpnNetwork = sourceSection(routeCheck, "val proofVpnNetworkHandle", "if (\n            !recordVpnDataPlaneProof")
        val stalePublication = sourceSection(routeCheck, "if (\n            !recordVpnDataPlaneProof", "return RouteHealth(true")
        val verified = routeCheck.substring(routeCheck.indexOf("return RouteHealth(true"))

        assertTrue("one local helper must own the privacy-safe data-plane serialization", recordHelper.contains("ConnectionDiagnostics.record("))
        assertTrue("data-plane helper must use the dedicated event", recordHelper.contains("event = \"vpn_data_plane\""))
        assertTrue("data-plane helper must retain network generation", recordHelper.contains("networkGeneration = proofNetworkGeneration"))
        assertTrue("data-plane helper must retain TUN generation", recordHelper.contains("tunGeneration = proofTunGeneration"))
        assertOutcome(routeCheck, outcome = "started")
        assertDiagnostic(cancelled, outcome = "cancelled", category = "coroutine_cancelled")
        assertTrue("cancellation must use the lifecycle stage", cancelled.contains("stage = \"lifecycle\""))
        assertTrue(
            "cancellation diagnostics must retain elapsed time from the started record",
            cancelled.contains("durationMs = (SystemClock.elapsedRealtime() - diagnosticStartedAt).coerceAtLeast(0L)"),
        )
        assertTrue(
            "cancellation must remain authoritative after diagnostics are recorded",
            cancelled.contains("catch (error: CancellationException)") && cancelled.contains("throw error"),
        )
        assertDiagnostic(staleGeneration, outcome = "stale", category = "stale_generation")
        assertDiagnostic(probeFailure, outcome = "failed", category = "result.failure")
        assertTrue("probe failure diagnostics must identify the exact completed probe stage", probeFailure.contains("stage = result.stage.token"))
        assertDiagnostic(missingVpnNetwork, outcome = "failed", category = "missing_vpn_network")
        assertDiagnostic(stalePublication, outcome = "stale", category = "stale_publication")
        assertDiagnostic(verified, outcome = "verified", category = "none")
        assertTrue("verified diagnostics must retain the completed probe stage", verified.contains("stage = result.stage.token"))

        listOf(
            "stale-generation" to staleGeneration,
            "probe failure" to probeFailure,
            "missing VPN network" to missingVpnNetwork,
            "stale publication" to stalePublication,
            "verified publication" to verified,
        ).forEach { (name, terminal) ->
            assertTrue(
                "$name terminal diagnostic duration must cover probe through terminal publication",
                terminal.contains("durationMs = (SystemClock.elapsedRealtime() - diagnosticStartedAt).coerceAtLeast(0L)"),
            )
            assertFalse("$name terminal diagnostic must not report only raw probe latency", terminal.contains("durationMs = result.latencyMs"))
        }

        val postProbeTelemetry = routeCheck.substringSequence("ConnectionDiagnostics.record(")
            .firstOrNull { it.contains("event = \"vpn_data_plane_publication\"") }
        checkNotNull(postProbeTelemetry) { "missing vpn_data_plane_publication telemetry" }
        assertTrue(
            "successful proof must emit separate elapsed publication telemetry",
            postProbeTelemetry.contains("durationMs = (SystemClock.elapsedRealtime() - publicationStartedAt).coerceAtLeast(0L)"),
        )
        assertTrue("publication telemetry must identify its safe publication stage", postProbeTelemetry.contains("stage = \"publication\""))
        assertTrue("publication telemetry must retain a safe static category", postProbeTelemetry.contains("category = \"none\""))
        assertFalse("publication telemetry must not serialize an Android network handle", postProbeTelemetry.contains("NetworkHandle") || postProbeTelemetry.contains("networkHandle"))
        assertFalse("publication telemetry must not serialize endpoint/URL data", postProbeTelemetry.contains("endpoint") || postProbeTelemetry.contains("url") || postProbeTelemetry.contains("PROBE_"))
        assertFalse("publication telemetry must not serialize exception messages or route summaries", postProbeTelemetry.contains(".message") || postProbeTelemetry.contains(".summary"))

        assertFalse("data-plane records must not expose network handles", recordHelper.contains("NetworkHandle") || recordHelper.contains("networkHandle"))
        assertFalse("data-plane records must not expose endpoint/URL data", recordHelper.contains("endpoint") || recordHelper.contains("url") || recordHelper.contains("PROBE_"))
        assertFalse("data-plane records must not expose exception messages", recordHelper.contains(".message") || recordHelper.contains(".summary"))
        val endpointHosts = Regex("HttpsProbeEndpoint\\(\\\"([^\\\"]+)\\\"")
            .findAll(sourceSection(probe, "private val PROBE_ENDPOINTS = listOf(", "private const val PROBE_PORT"))
            .map { it.groupValues[1] }
            .toList()
        assertTrue("the test must inspect every configured rotated endpoint", endpointHosts.size >= 3)
        assertTrue(
            "rotated endpoint hostnames must never be serialized by data-plane diagnostics",
            endpointHosts.none(recordHelper::contains) && endpointHosts.none(routeCheck::contains),
        )
    }

    @Test
    fun `redundant startup and recovery probes race independent endpoints and retain the most advanced failure`() {
        val probe = sourceFile("VpnDataPlaneProbe.kt")
        val run = functionBody(probe, "run")
        val service = sourceFile("BoxService.kt")

        assertTrue("routine callers must keep a single endpoint by default", probe.contains("redundantEndpoints: Boolean = false"))
        assertTrue("redundant mode must schedule every independent endpoint", run.contains("nextProbeEndpoints(if (redundantEndpoints) PROBE_ENDPOINTS.size else 1)"))
        assertTrue("each redundant endpoint must start in its own child job", run.contains("val jobs = endpoints.map") && run.contains("launch {"))
        assertTrue("the first complete proof must win", run.contains("if (result.healthy) return@coroutineScope result"))
        assertTrue("a total failure must preserve the farthest completed stage", run.contains("selectMostAdvancedVpnDataPlaneFailure(failures)"))
        assertTrue("losing work must be structured-cancelled", run.contains("finally {") && run.contains("jobs.forEach { it.cancel() }") && run.contains("completed.close()"))
        assertTrue("the check boundary must pass redundant mode only when requested", service.contains("redundantDataPlaneEndpoints: Boolean = false") && service.contains("redundantEndpoints = redundantDataPlaneEndpoints"))
        assertTrue("native startup must opt into redundant proof", service.contains("dataPlaneAttemptTimeoutMs = attemptTimeoutMs,") && service.contains("redundantDataPlaneEndpoints = true"))
        assertTrue("network recovery must opt into redundant proof", service.contains("reason = reason,") && service.contains("redundantDataPlaneEndpoints = true"))
    }

    @Test
    fun `underlying readiness failures park recovery instead of launching a core restart`() {
        val probe = sourceFile("VpnDataPlaneProbe.kt")
        val service = sourceFile("BoxService.kt")
        val routeCheck = functionBody(service, "checkVpnDataPlaneRoute")
        val routeRecovery = functionBody(service, "recoverNetworkRoute")
        val listener = sourceFile("DefaultNetworkListener.kt")

        assertTrue("probe results must preserve readiness ownership separately from route failure", probe.contains("val networkReadinessPending: Boolean = false"))
        assertTrue("missing underlying network must be marked pending", probe.contains("underlying_network_unavailable") && probe.contains("networkReadinessPending = true"))
        assertTrue("underlying DNS unavailability must be marked pending", probe.contains("underlying_dns_unavailable") && probe.contains("networkReadinessPending = true"))
        assertTrue("route health must suppress core recovery for pending physical readiness", routeCheck.contains("requiresCoreRecovery = !result.networkReadinessPending"))
        assertTrue("route recovery must return to callback-driven observation for pending readiness", routeRecovery.contains("result.networkReadinessPending") && routeRecovery.contains("return"))
        assertTrue("link-property changes must publish a same-network readiness edge", listener.contains("override fun onLinkPropertiesChanged") && listener.contains("NetworkMessage.Update(network)"))
    }

    private fun assertDiagnostic(source: String, outcome: String, category: String) {
        val matching = diagnosticCall(source, outcome)
        assertTrue("$outcome diagnostic must record category=$category", matching.contains("category = $category") || matching.contains("category = \"$category\""))
    }

    private fun assertOutcome(source: String, outcome: String) {
        diagnosticCall(source, outcome)
    }

    private fun diagnosticCall(source: String, outcome: String): String {
        val call = "recordProbeDiagnostic("
        val matching = source.substringSequence(call).firstOrNull { it.contains("outcome = \"$outcome\"") }
        checkNotNull(matching) { "missing vpn_data_plane diagnostic outcome=$outcome" }
        return matching
    }

    private fun String.substringSequence(marker: String): Sequence<String> = sequence {
        var offset = 0
        while (true) {
            val start = indexOf(marker, offset)
            if (start < 0) return@sequence
            val open = start + marker.length - 1
            var depth = 0
            var index = open
            while (index < length) {
                when (this@substringSequence[index]) {
                    '(' -> depth++
                    ')' -> if (--depth == 0) {
                        yield(substring(start, index + 1))
                        offset = index + 1
                        break
                    }
                }
                index++
            }
            check(depth == 0) { "call does not close: $marker" }
        }
    }

    private fun sourceFile(name: String): String {
        val source = File("src/main/kotlin/app/marten/client/bg/$name")
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

    private class TopProbeFailure(message: String) : Exception(message)

    private class RootProbeFailure(message: String) : Exception(message)
}
