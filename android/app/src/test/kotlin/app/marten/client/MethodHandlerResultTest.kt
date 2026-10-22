package app.marten.client

import io.flutter.plugin.common.MethodChannel
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class MethodHandlerResultTest {
    @Test
    fun `respondCatching keeps successful platform replies unchanged`() {
        val result = RecordingResult()

        result.respondCatching {
            success("admitted")
        }

        assertEquals(listOf("admitted"), result.successes)
        assertTrue(result.errors.isEmpty())
        assertEquals(0, result.notImplementedCount)
    }

    @Test
    fun `respondCatching turns a thrown strict admission failure into one structured error reply`() {
        val result = RecordingResult()

        result.respondCatching {
            throw IllegalStateException("Android always-on lockdown is disabled")
        }

        assertTrue("a failed method call must never acknowledge success", result.successes.isEmpty())
        assertEquals("the waiting Dart caller needs exactly one terminal error reply", 1, result.errors.size)
        val error = result.errors.single()
        assertEquals("marten_platform_error", error.code)
        assertEquals("Android always-on lockdown is disabled", error.message)
        assertEquals("IllegalStateException", error.details)
        assertEquals(0, result.notImplementedCount)
    }

    @Test
    fun `respondCatching swallows a rejected error callback`() {
        val result = RecordingResult(rejectErrorReply = true)

        result.respondCatching {
            throw IllegalArgumentException("admission rejected")
        }

        assertEquals(1, result.errors.size)
        assertTrue(result.successes.isEmpty())
        assertEquals(0, result.notImplementedCount)
    }

    @Test
    fun `active method handler lifecycle calls use respondCatching instead of ignored result runCatching`() {
        val source = File("src/main/kotlin/app/marten/client/MethodHandler.kt").readText()
        val handler = sourceSection(source, "override fun onMethodCall", "\n    private fun")

        assertFalse(
            "runCatching on MethodChannel.Result captures the exception without resolving Dart's Future",
            handler.contains("result.runCatching"),
        )
        for (trigger in listOf("BeginVpnStartAdmission", "Setup", "Start", "Stop", "MarkStarted")) {
            val branch = handler.substring(
                handler.indexOf("Trigger.$trigger.method -> {").also {
                    assertTrue("missing active lifecycle branch $trigger", it >= 0)
                },
            )
            assertTrue(
                "$trigger must resolve any thrown lifecycle failure through respondCatching",
                branch.contains("result.respondCatching {"),
            )
        }
    }

    @Test
    fun `Flutter Stop invalidates the BoxService owner without manufacturing native explicit-stop evidence`() {
        val source = File("src/main/kotlin/app/marten/client/MethodHandler.kt").readText()
        val service = File("src/main/kotlin/app/marten/client/bg/BoxService.kt").readText()
        val lifecycle = File("src/main/kotlin/app/marten/client/bg/ServiceLifecyclePolicy.kt").readText()
        val stop = sourceSection(source, "Trigger.Stop.method -> {", "Trigger.MarkStarted.method -> {")
        val nativeStop = sourceSection(service, "fun stop(quickSettingsRequestId: Long = 0L)", "fun stopFromFlutter()")
        val flutterStop = sourceSection(service, "fun stopFromFlutter()", "private fun dispatchTerminalStopIntent")
        val terminalInvalidation = sourceSection(
            lifecycle,
            "private fun invalidateForTerminalStopLocked(",
            "private fun expireFlutterRestartLeaseIfNeeded",
        )

        val ownerSnapshot = stop.indexOf("val stoppedOwnerToken = BoxService.currentActiveOwnerToken()")
        val terminalStop = stop.indexOf("BoxService.stopFromFlutter()", ownerSnapshot)
        val presentationStatus = stop.indexOf("val initialStatus = mainActivity.serviceStatus.value", terminalStop)
        val boundPresentationStatus = stop.indexOf("val initialBoundStatus = mainActivity.boundServiceStatus", presentationStatus)
        val stoppedShortcut = stop.indexOf("if (initialStatus == Status.Stopped && initialBoundStatus == Status.Stopped)")
        val stopAdmission = stop.substring(ownerSnapshot, presentationStatus)

        assertTrue("Stop must pin the current owner before invalidating it", ownerSnapshot >= 0)
        assertTrue(
            "Flutter Stop must use its dedicated terminal path before a stale presentation can skip it",
            terminalStop > ownerSnapshot && presentationStatus > terminalStop && boundPresentationStatus > presentationStatus,
        )
        assertTrue("the presentation shortcut must remain after terminal invalidation", stoppedShortcut > boundPresentationStatus)
        assertFalse(
            "no status branch may bypass the Flutter Stop path between owner capture and invalidation",
            stopAdmission.contains("if ("),
        )

        assertFalse("Flutter cleanup must never call the native-user Stop entry", stop.contains("BoxService.stop()"))
        assertTrue(
            "only the native user entry may request explicit ownership evidence",
            nativeStop.contains("explicitUserStop = true") && flutterStop.contains("persistTerminalStopIntent(\"Flutter lifecycle stop\")"),
        )
        assertFalse("Flutter failed-start cleanup must not label its terminal claim as an explicit user stop", flutterStop.contains("explicitUserStop = true"))
        assertTrue(
            "the bounded history must record the active terminal transaction's exact predecessor only for an explicit native stop",
            terminalInvalidation.contains("val explicitlyStoppedEpoch = if (explicitUserStop)") &&
                terminalInvalidation.contains("terminalStopSupersededUserSessionEpoch") &&
                terminalInvalidation.contains("explicitlyStoppedUserSessionEpochs.addLast(explicitlyStoppedEpoch)") &&
                terminalInvalidation.contains("while (explicitlyStoppedUserSessionEpochs.size > EXPLICIT_USER_STOP_HISTORY_LIMIT)"),
        )

        val authoritativeWait = stop.substring(stop.indexOf("val coreStopped = requestAuthoritativePlatformStop("))
        assertTrue(
            "the later two-phase wait must not re-admit a second stop after BoxService.stop already invalidated leases",
            authoritativeWait.contains("requestCoreStop = {},"),
        )
        assertFalse(
            "the two-phase callback must not contain a hidden second BoxService.stop admission",
            authoritativeWait.contains("requestCoreStop = { BoxService.stop()"),
        )
    }

    @Test
    fun `exact explicit-stop query trigger returns only the queried epoch marker`() {
        val source = File("src/main/kotlin/app/marten/client/MethodHandler.kt").readText()
        val query = sourceSection(
            source,
            "Trigger.WasVpnUserSessionExplicitlyStopped.method -> {",
            "Trigger.EndFlutterRestart.method -> {",
        )

        assertTrue(query.contains("val epoch = (call.arguments as? Number)?.toLong()"))
        assertTrue(query.contains("epoch != null"))
        assertTrue(query.contains("ServiceLifecycleOwnership.wasUserSessionExplicitlyStopped(epoch)"))
        assertTrue(query.contains("result.success("))
        assertFalse("a missing epoch must be false rather than querying current/global state", query.contains("currentUserSessionEpoch"))
    }

    private fun sourceSection(source: String, startMarker: String, endMarker: String): String {
        val start = source.indexOf(startMarker)
        check(start >= 0) { "source marker not found: $startMarker" }
        val end = source.indexOf(endMarker, start + startMarker.length)
        check(end > start) { "source end marker not found: $endMarker" }
        return source.substring(start, end)
    }

    private data class ErrorReply(
        val code: String,
        val message: String?,
        val details: Any?,
    )

    private class RecordingResult(
        private val rejectErrorReply: Boolean = false,
    ) : MethodChannel.Result {
        val successes = mutableListOf<Any?>()
        val errors = mutableListOf<ErrorReply>()
        var notImplementedCount = 0

        override fun success(result: Any?) {
            successes += result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            errors += ErrorReply(errorCode, errorMessage, errorDetails)
            if (rejectErrorReply) throw IllegalStateException("Flutter engine already detached")
        }

        override fun notImplemented() {
            notImplementedCount += 1
        }
    }
}
