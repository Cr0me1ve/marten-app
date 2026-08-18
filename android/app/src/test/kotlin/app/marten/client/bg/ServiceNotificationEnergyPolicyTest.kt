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
    fun `service notification start and screen-off restore respect interactive gate and stop stream`() {
        val serviceNotification = sourceFile("ServiceNotification.kt")

        val start = functionBody(serviceNotification, "start")
        assertTrue(start.contains("if (Settings.dynamicNotification && permissionGranted)"))
        assertTrue(start.contains("Application.powerManager.isInteractive"))
        assertTrue(start.contains("shouldStreamDynamicNotificationUpdates("))
        assertTrue(start.contains("startListenSystemInfo()"))
        assertTrue(start.contains("stopListenSystemInfo()"))
        assertTrue(start.indexOf("startListenSystemInfo()") > start.indexOf("shouldStreamDynamicNotificationUpdates("))
        assertTrue(start.indexOf("stopListenSystemInfo()") > start.indexOf("shouldStreamDynamicNotificationUpdates("))

        val onReceive = functionBody(serviceNotification, "onReceive")
        assertTrue(onReceive.contains("Intent.ACTION_SCREEN_OFF ->"))
        assertTrue(onReceive.contains("stopListenSystemInfo()"))
        val offBranch = onReceive.indexOf("Intent.ACTION_SCREEN_OFF ->")
        assertTrue(offBranch >= 0)
        val offBranchEnd = onReceive.indexOf("}", offBranch)
        assertTrue(offBranchEnd > offBranch)
        assertFalse(
            "screen-off branch must not call startListenSystemInfo",
            onReceive.substring(offBranch, offBranchEnd + 1).contains("startListenSystemInfo()"),
        )
    }

    @Test
    fun `system info stream must use single executeBlocking stream call without legacy polling fallback`() {
        val streamSystemInfo = functionBody(sourceFile("ServiceNotification.kt"), "streamSystemInfo")
        val calls = Regex("coreClient\\.GetSystemInfo\\(\\)\\.executeBlocking\\(\\)").findAll(streamSystemInfo).toList()
        assertEquals(1, calls.size)
        assertEquals(-1, streamSystemInfo.indexOf("delay(1_000)"))
        assertEquals(-1, streamSystemInfo.indexOf("readSystemInfo(coreClient)"))
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
