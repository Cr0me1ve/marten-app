package app.marten.client.crashreporting

import android.app.ActivityManager
import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeTrue
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CrashDiagnosticsIntegrationTest {
    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun snapshotUsesRealAndroidExitHistoryAndExportsOnlySafeFields() {
        val manager = context.getSystemService(ActivityManager::class.java)
        assertTrue("Android 11+ exit history API should be available", manager != null)
        val history = manager!!.getHistoricalProcessExitReasons(null, 0, 32)
        val snapshot = EarlyCrashReports.snapshot(context)

        assertTrue(snapshot.startsWith("MARTEN_CRASH_DIAGNOSTICS schema=1"))
        assertTrue(snapshot.contains("history_status=available count="))
        assertTrue(snapshot.contains("history_scope=system_retained"))
        assertTrue(snapshot.contains("incomplete_possible=true"))
        val exportedExitLines = snapshot.lineSequence().filter { it.startsWith("MARTEN_PROCESS_EXIT ") }.toList()
        for (exit in history) {
            val processName = exit.processName.orEmpty()
            val description = exit.description.orEmpty()
            for (line in exportedExitLines) {
                assertFalse("raw process names must not be exported", processName.isNotEmpty() && line.contains(processName))
                assertFalse("exit descriptions must not be exported", description.isNotEmpty() && line.contains(description))
                assertFalse("PID labels must not be exported", line.contains("pid=${exit.pid}"))
            }
        }
    }

    @Test
    fun snapshotContainsHistoricalJavaCrash() {
        val args = InstrumentationRegistry.getArguments()
        val cutoffValue = args.getString("cutoff_ms")
        assumeTrue(
            "Pass cutoff_ms after inducing the app crash to require a real historical Java crash",
            cutoffValue != null,
        )
        val cutoffMs = cutoffValue!!.toLongOrNull()
            ?: throw AssertionError("cutoff_ms must be a Unix timestamp in milliseconds")
        val snapshot = EarlyCrashReports.snapshot(context)

        assertTrue(snapshot.contains("MARTEN_PROCESS_EXIT"))
        assertTrue(snapshot.lineSequence().any { line ->
            line.startsWith("MARTEN_PROCESS_EXIT ") &&
                line.contains("process_role=app") &&
                line.contains("category=java_crash") &&
                (Regex("(?:^| )timestamp_ms=([0-9]+)(?: |$)").find(line)?.groupValues?.get(1)?.toLongOrNull() ?: 0L) >= cutoffMs
        })
    }
}
