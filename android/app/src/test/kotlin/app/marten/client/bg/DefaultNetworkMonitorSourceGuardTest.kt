package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DefaultNetworkMonitorSourceGuardTest {
    @Test
    fun `start uses timeout-or-null for initial network wait and does not absorb cancellation`() {
        val source = sourceFile("DefaultNetworkMonitor.kt")
        val start = functionBody(source, "start(ownerToken: Long, onNetworkChanged: ((Network?) -> Unit)? = null): Boolean")

        assertTrue(
            "start() must use withTimeoutOrNull for the initial network confirmation",
            start.contains("withTimeoutOrNull(MISSING_INTERFACE_CONFIRMATION_DELAY_MS)"),
        )
        assertFalse(
            "start() must not use cancellable timeout branch to determine nullness",
            start.contains("withTimeout(MISSING_INTERFACE_CONFIRMATION_DELAY_MS)"),
        )
        assertTrue(
            "start() should still call DefaultNetworkListener.get in the initial probe",
            start.contains("DefaultNetworkListener.get()"),
        )
        assertFalse(
            "start() must not mask outer cancellation through a getOrElse branch",
            start.contains("getOrElse"),
        )
        assertFalse(
            "start() must not explicitly swallow CancellationException as recoverable timeout",
            start.contains("if (it is CancellationException) throw it"),
        )
    }

    private fun sourceFile(name: String): String {
        val source = File("src/main/kotlin/app/marten/client/bg/$name")
        check(source.isFile) { "missing production source ${source.path}" }
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
