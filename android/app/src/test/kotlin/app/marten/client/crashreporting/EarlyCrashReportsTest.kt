package app.marten.client.crashreporting

import android.content.Context
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.shadows.ShadowActivityManager
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class EarlyCrashReportsTest {
    @Test
    fun `captures locally without message text and retains sdk-covered evidence without remote duplication`() {
        val context = RuntimeEnvironment.getApplication()
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit().putBoolean("flutter.enable_analytics", true).commit()

        val originalHandler = Thread.getDefaultUncaughtExceptionHandler()
        try {
            // The test process must not delegate an intentionally simulated crash to JUnit.
            Thread.setDefaultUncaughtExceptionHandler { _, _ -> }
            EarlyCrashReports.install(context)
            val installedHandler = checkNotNull(Thread.getDefaultUncaughtExceptionHandler())
            val reportFile = File(EarlyCrashReports.directory(context), "app.json")
            reportFile.delete()

            installedHandler.uncaughtException(
                Thread.currentThread(),
                IllegalStateException("person@example.com secret-value"),
            )
            assertTrue("early uncaught failure should be persisted", reportFile.isFile)
            val saved = reportFile.readText()
            assertTrue(saved.contains("android_early_uncaught"))
            assertFalse("raw exception messages must not enter the local report", saved.contains("person@example.com"))
            assertFalse(saved.contains("secret-value"))

            EarlyCrashReports.setCollectionEnabled(context, false)
            assertTrue(EarlyCrashReports.read(context).isEmpty())
            assertFalse("opt-out must purge pending native reports", reportFile.exists())

            installedHandler.uncaughtException(
                Thread.currentThread(),
                IllegalStateException("must not be captured after opt out"),
            )
            assertFalse("process-local opt-out must prevent new writes immediately", reportFile.exists())

            EarlyCrashReports.setCollectionEnabled(context, true)
            installedHandler.uncaughtException(
                Thread.currentThread(),
                IllegalArgumentException("failure before SDK readiness"),
            )
            val secondSaved = reportFile.readText()
            EarlyCrashReports.markSdkReady(context)
            installedHandler.uncaughtException(
                Thread.currentThread(),
                IllegalArgumentException("failure after SDK readiness"),
            )
            val afterSdkReady = reportFile.readText()
            assertTrue("post-readiness local evidence should be retained", afterSdkReady != secondSaved)
            assertTrue(afterSdkReady.contains("\"sdk_covered\":true"))
            assertTrue(afterSdkReady.contains("\"timestamp_ms\":"))
            assertTrue("SDK-covered crash must not be backfilled as a duplicate", EarlyCrashReports.read(context).isEmpty())
            val snapshot = EarlyCrashReports.snapshot(context)
            assertTrue(snapshot.contains("MARTEN_LOCAL_EXCEPTION process_role=app"))
            assertTrue(snapshot.contains("sdk_covered=true"))
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(originalHandler)
        }
    }

    @Test
    fun `snapshot exports bounded exit facts without process identifiers or private strings`() {
        val context = RuntimeEnvironment.getApplication()
        EarlyCrashReports.setCollectionEnabled(context, true)
        val info = exitInfo(
            context,
            processName = "${context.packageName}:private-endpoint.example",
            reason = ApplicationExitInfo.REASON_CRASH_NATIVE,
            timestamp = System.currentTimeMillis(),
            description = "secret description private-endpoint.example",
            trace = "secret trace private-endpoint.example",
        )

        val summary = EarlyCrashReports.summarizeExit(context, info)
        assertEquals("other", summary["process_role"])
        assertEquals("native_crash", summary["category"])
        assertEquals(info.timestamp, summary["timestamp_ms"])
        assertEquals(info.status, summary["status"])
        assertEquals(info.importance, summary["importance"])
        assertEquals(info.pss, summary["pss_kb"])
        assertEquals(info.rss, summary["rss_kb"])
        assertEquals(
            setOf("timestamp_ms", "process_role", "category", "status", "importance", "pss_kb", "rss_kb", "expected"),
            summary.keys,
        )

        Shadows.shadowOf(context.getSystemService(ActivityManager::class.java)!!).addApplicationExitInfo(info)
        val snapshot = EarlyCrashReports.snapshot(context)
        assertTrue(snapshot.startsWith("MARTEN_CRASH_DIAGNOSTICS schema=1 collection=enabled"))
        assertTrue(snapshot.contains("history_status=available count=1"))
        assertTrue(snapshot.contains("category=native_crash"))
        assertTrue(snapshot.contains("process_role=other"))
        assertFalse(snapshot.contains("${info.pid}"))
        assertFalse(snapshot.contains("private-endpoint.example"))
        assertFalse(snapshot.contains("secret description"))
        assertFalse(snapshot.contains("secret trace"))
    }

    @Test
    fun `historical abnormal exits are nonfatal remote events while clean exits are ignored`() {
        val context = RuntimeEnvironment.getApplication()
        EarlyCrashReports.setCollectionEnabled(context, true)
        val manager = Shadows.shadowOf(context.getSystemService(ActivityManager::class.java)!!)
        val now = System.currentTimeMillis()
        manager.addApplicationExitInfo(
            exitInfo(context, "${context.packageName}:core", ApplicationExitInfo.REASON_CRASH, now + 2),
        )
        manager.addApplicationExitInfo(
            exitInfo(context, context.packageName, ApplicationExitInfo.REASON_EXIT_SELF, now + 1),
        )

        val reports = EarlyCrashReports.read(context)

        assertEquals(1, reports.size)
        assertEquals("android_process_exit_core_java_crash", reports.single()["type"])
        assertEquals("android_process_exit_core_java_crash", reports.single()["reason"])
        assertEquals(false, reports.single()["fatal"])
        assertTrue(reports.single()["stack"] == "")
    }

    @Test
    fun `expected core shutdown marker suppresses only the matching recent signal exit`() {
        val context = RuntimeEnvironment.getApplication()
        EarlyCrashReports.setCollectionEnabled(context, true)
        val now = System.currentTimeMillis()
        val expectedPid = 48271
        EarlyCrashReports.markExpectedCoreExit(context, expectedPid)
        val manager = Shadows.shadowOf(context.getSystemService(ActivityManager::class.java)!!)
        manager.addApplicationExitInfo(
            exitInfo(
                context,
                "${context.packageName}:core",
                ApplicationExitInfo.REASON_SIGNALED,
                now + 2,
                pid = expectedPid,
            ),
        )
        manager.addApplicationExitInfo(
            exitInfo(
                context,
                "${context.packageName}:core",
                ApplicationExitInfo.REASON_SIGNALED,
                now + 1,
                pid = expectedPid + 1,
            ),
        )

        val reports = EarlyCrashReports.read(context)
        val snapshot = EarlyCrashReports.snapshot(context)

        assertEquals("only the unexpected core signal remains reportable", 1, reports.size)
        assertEquals("android_process_exit_core_signaled", reports.single()["type"])
        assertTrue(snapshot.contains("process_role=core category=signaled"))
        assertTrue(snapshot.contains("expected=true"))
        assertTrue(snapshot.contains("expected=false"))
    }

    @Test
    @Config(sdk = [28])
    fun `snapshot explicitly reports unsupported historical exit API`() {
        val context = RuntimeEnvironment.getApplication()
        EarlyCrashReports.setCollectionEnabled(context, true)

        assertTrue(EarlyCrashReports.snapshot(context).contains("history_status=unsupported"))
    }

    @Test
    fun `snapshot reports query failure without exposing exception text`() {
        val base = RuntimeEnvironment.getApplication()
        EarlyCrashReports.setCollectionEnabled(base, true)
        val context = object : android.content.ContextWrapper(base) {
            override fun getSystemService(name: String): Any? {
                if (name == Context.ACTIVITY_SERVICE) {
                    throw IllegalStateException("private-endpoint.example secret")
                }
                return super.getSystemService(name)
            }
        }

        val snapshot = EarlyCrashReports.snapshot(context)

        assertTrue(snapshot.contains("history_status=query_failed count=0"))
        assertFalse(snapshot.contains("private-endpoint.example"))
        assertFalse(snapshot.contains("secret"))
    }

    @Test
    fun `acknowledgement removes only the exact report snapshot that was read`() {
        val context = RuntimeEnvironment.getApplication()
        EarlyCrashReports.setCollectionEnabled(context, true)
        val reportFile = File(EarlyCrashReports.directory(context), "app.json")
        reportFile.parentFile?.mkdirs()
        reportFile.writeText(
            """{"type":"java.lang.IllegalStateException","stack":"frame-old","reason":"android_early_uncaught","fatal":true}""",
        )

        val first = EarlyCrashReports.read(context).first { (it["id"] as String).startsWith("app.json:") }
        val firstId = first["id"] as String
        reportFile.writeText(
            """{"type":"java.lang.IllegalArgumentException","stack":"frame-new","reason":"android_early_uncaught","fatal":true}""",
        )
        EarlyCrashReports.acknowledge(context, listOf(firstId))

        assertTrue("an event written after read must survive the stale acknowledgement", reportFile.isFile)
        val second = EarlyCrashReports.read(context).first { (it["id"] as String).startsWith("app.json:") }
        assertEquals("frame-new", second["stack"])
        EarlyCrashReports.acknowledge(context, listOf(second["id"] as String))
        assertFalse("matching acknowledgement should remove the delivered snapshot", reportFile.exists())
        val retainedFile = File(reportFile.parentFile, "app-last.json")
        assertTrue("accepted local evidence remains available for export", retainedFile.isFile)
        assertTrue(EarlyCrashReports.snapshot(context).contains("MARTEN_LOCAL_EXCEPTION process_role=app"))
        EarlyCrashReports.setCollectionEnabled(context, false)
        assertFalse("opt-out purges retained local evidence", retainedFile.exists())
        assertTrue(EarlyCrashReports.snapshot(context).contains("history_status=disabled"))
    }

    private fun exitInfo(
        @Suppress("UNUSED_PARAMETER") context: Context,
        processName: String,
        reason: Int,
        timestamp: Long,
        description: String = "",
        trace: String = "",
        pid: Int = 48271,
    ): ApplicationExitInfo = ShadowActivityManager.ApplicationExitInfoBuilder.newBuilder()
        .setProcessName(processName)
        .setPid(pid)
        .setReason(reason)
        .setStatus(9)
        .setImportance(100)
        .setPss(2048)
        .setRss(4096)
        .setTimestamp(timestamp)
        .setDescription(description)
        .setTraceInputStream(trace.byteInputStream())
        .build()
}
