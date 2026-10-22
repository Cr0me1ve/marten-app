package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ServiceNotificationEnergyPolicyTest {
    @Test
    fun `should stream dynamic updates only when all conditions are true`() {
        val all = listOf(
            shouldStreamDynamicNotificationUpdates(false, false, false) to false,
            shouldStreamDynamicNotificationUpdates(false, false, true) to false,
            shouldStreamDynamicNotificationUpdates(false, true, false) to false,
            shouldStreamDynamicNotificationUpdates(false, true, true) to false,
            shouldStreamDynamicNotificationUpdates(true, false, false) to false,
            shouldStreamDynamicNotificationUpdates(true, false, true) to false,
            shouldStreamDynamicNotificationUpdates(true, true, false) to false,
            shouldStreamDynamicNotificationUpdates(true, true, true) to true,
        )

        all.forEach { (actual, expected) ->
            assertEquals(expected, actual)
        }
    }

    @Test
    fun `service notification starts UID traffic updates only while interactive and stops them on screen-off`() {
        val serviceNotification = sourceFile("ServiceNotification.kt")

        val start = functionBody(serviceNotification, "start")
        assertTrue(start.contains("if (Settings.dynamicNotification && permissionGranted)"))
        assertTrue(start.contains("Application.powerManager.isInteractive"))
        assertTrue(start.contains("shouldStreamDynamicNotificationUpdates("))
        assertTrue(start.contains("startTrafficUpdates()"))
        assertTrue(start.contains("stopTrafficUpdates()"))
        assertTrue(start.indexOf("startTrafficUpdates()") > start.indexOf("shouldStreamDynamicNotificationUpdates("))
        assertTrue(start.indexOf("stopTrafficUpdates()") > start.indexOf("shouldStreamDynamicNotificationUpdates("))

        val onReceive = functionBody(serviceNotification, "onReceive")
        assertTrue(onReceive.contains("Intent.ACTION_SCREEN_OFF ->"))
        assertTrue(onReceive.contains("stopTrafficUpdates()"))
        val offBranch = onReceive.indexOf("Intent.ACTION_SCREEN_OFF ->")
        assertTrue(offBranch >= 0)
        val offBranchEnd = onReceive.indexOf("}", offBranch)
        assertTrue(offBranchEnd > offBranch)
        assertFalse(
            "screen-off branch must not start traffic polling",
            onReceive.substring(offBranch, offBranchEnd + 1).contains("startTrafficUpdates()"),
        )

        val serviceNotificationClass = serviceNotification.substring(serviceNotification.indexOf("class ServiceNotification"))
        val closeForeground = functionBody(serviceNotificationClass, "closeForeground")
        assertTrue(
            "foreground teardown must cancel the UI-only traffic coroutine",
            closeForeground.contains("stopTrafficUpdates()"),
        )
    }

    @Test
    fun `dynamic notifications poll only process UID traffic rather than opening a core system info stream`() {
        val serviceNotification = sourceFile("ServiceNotification.kt")
        val stream = functionBody(serviceNotification, "streamUidTraffic")
        val sample = functionBody(serviceNotification, "readUidTrafficSample")

        listOf("GrpcClient", "GetSystemInfo", "SystemInfo", "streamSystemInfo", "startListenSystemInfo").forEach { legacyCoreStream ->
            assertFalse(
                "dynamic notification polling must not retain the legacy core system-info stream: $legacyCoreStream",
                serviceNotification.contains(legacyCoreStream),
            )
        }
        assertTrue(sample.contains("TrafficStats.getUidTxBytes(Process.myUid())"))
        assertTrue(sample.contains("TrafficStats.getUidRxBytes(Process.myUid())"))
        assertTrue(sample.contains("SystemClock.elapsedRealtime()"))
        assertTrue(stream.contains("delay(DYNAMIC_NOTIFICATION_MIN_UPDATE_INTERVAL_MS)"))
        assertTrue(stream.contains("currentCoroutineContext().isActive"))
        val initialSample = stream.indexOf("var previous = readUidTrafficSample()")
        val wait = stream.indexOf("delay(DYNAMIC_NOTIFICATION_MIN_UPDATE_INTERVAL_MS)")
        val currentSample = stream.indexOf("val current = readUidTrafficSample()")
        assertTrue(
            "traffic polling must capture an initial baseline, wait five seconds, then capture the current sample",
            initialSample >= 0 && wait >= 0 && currentSample >= 0 && initialSample < wait && wait < currentSample,
        )
    }

    @Test
    fun `notification content is published only after a permitted changing UID traffic sample`() {
        val serviceNotification = sourceFile("ServiceNotification.kt")
        val stream = functionBody(serviceNotification, "streamUidTraffic")
        val updateStatus = functionBody(serviceNotification, "updateStatus")

        val permissionGate = stream.indexOf("shouldPublishDynamicNotificationUpdate(")
        val update = stream.indexOf("updateStatus(previous, current)")
        assertTrue("traffic samples must consult lifecycle, status, and generation gate", permissionGate >= 0)
        assertTrue(stream.contains("platformStatus = status.value"))
        assertTrue(stream.contains("gatePermitsUpdate = notificationUpdateGate.permitsUpdate(streamGeneration)"))
        assertTrue("traffic notification can update only after the gate permits it", update > permissionGate)

        val unchangedContent = updateStatus.indexOf("if (lastDynamicContent == speed) return")
        val notify = updateStatus.indexOf("Application.notificationManager.notify(")
        assertTrue("unchanged traffic speeds must not wake NotificationManager", unchangedContent >= 0 && notify > unchangedContent)
    }

    private fun sourceFile(name: String): String = sourceFromCandidates(
        listOf(
            "src/main/kotlin/app/marten/client/bg/$name",
            "android/src/main/kotlin/app/marten/client/bg/$name",
            "../android/src/main/kotlin/app/marten/client/bg/$name",
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
            if (source[index] == quote) {
                return index + 1
            }
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
