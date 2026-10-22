package app.marten.client.bg

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Process
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.marten.client.BuildConfig
import java.io.File
import java.util.zip.GZIPInputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EnergyProfilingIntegrationTest {
    @Test(timeout = 200_000)
    fun bindingCoreStartsAutomaticProfilerAndDiagnosticsProcessWritesSelfCheckAndProfile() {
        assertTrue("run this integration test with -PmartenEnergyDiagnostics=true", BuildConfig.ENERGY_DIAGNOSTICS)

        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val connected = CountDownLatch(1)
        var binder: IBinder? = null
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                binder = service
                connected.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName) = Unit
        }
        val intent = Intent(context, CoreProcessService::class.java)
        assertTrue("CoreProcessService bind must start the :core process", context.bindService(intent, connection, Context.BIND_AUTO_CREATE))
        try {
            assertTrue("core binder should become available", connected.await(15, TimeUnit.SECONDS))
            val core = ICoreProcess.Stub.asInterface(checkNotNull(binder))
            val corePid = core.pid()
            assertTrue("CoreProcessService must run in its dedicated process", corePid > 0 && corePid != Process.myPid())

            val base = checkNotNull(context.getExternalFilesDir(null))
            val directory = File(base, "energy-profiles-v3")
            val selfCheck = File(directory, "core-self-check.txt")
            val cpuProfile = File(directory, "core-cpu-0.pprof")
            val report = File(directory, "core-report-0.txt")
            val artStatus = File(directory, "art-status.txt")
            val artHistory = File(directory, "art-history.txt.gz")
            val testStartWallMs = System.currentTimeMillis()
            val deadline = SystemClock.elapsedRealtime() + 180_000L
            while (SystemClock.elapsedRealtime() < deadline &&
                !(artStatus.isFile && artStatus.readText().contains("outcome=recording") &&
                    artStatus.readText().contains("format=jvmti_kernel_cpu"))
            ) {
                SystemClock.sleep(500L)
            }

            assertTrue("the app process must publish active JVMTI kernel CPU recording", artStatus.isFile &&
                artStatus.readText().contains("outcome=recording") && artStatus.readText().contains("format=jvmti_kernel_cpu"))

            // Let the first CPU-counter baseline settle, then make one durable
            // Java frame hot long enough to cross multiple 100 ms polls.
            SystemClock.sleep(300L)
            val hotWorker = Thread({ artProfilerCpuWork(2_500L) }, "marten-art-hot-worker")
            hotWorker.start()
            hotWorker.join(10_000L)
            assertFalse("the bounded hot-worker workload should finish", hotWorker.isAlive)

            // Exercise ThreadStart/TLS registration and thread exit bookkeeping
            // without keeping a large number of test threads alive.
            val churn = (0 until 50).map { index ->
                Thread({ artProfilerCpuWork(15L) }, "marten-art-churn-$index")
            }
            churn.forEach(Thread::start)
            churn.forEach { it.join(5_000L) }
            assertTrue("all bounded churn workers should finish", churn.none { it.isAlive })

            while (SystemClock.elapsedRealtime() < deadline &&
                !(selfCheck.isFile && cpuProfile.isFile && report.isFile && sampledArtReport(directory, testStartWallMs) != null && artHistory.isFile)
            ) {
                SystemClock.sleep(500L)
            }

            assertTrue(
                "the first 120-second core CPU segment and diagnostics decode should complete within 180 seconds",
                selfCheck.isFile && cpuProfile.isFile && report.isFile,
            )
            val artReport = sampledArtReport(directory, testStartWallMs)
            assertTrue("a new JVMTI ART segment should be decoded and retained", artReport != null && artHistory.isFile)
            val artSamplingThreadPresent = File("/proc/self/task").listFiles().orEmpty().any { task ->
                val name = runCatching { File(task, "comm").readText().trim() }.getOrDefault("")
                name.startsWith("Sampling Profil", ignoreCase = true) ||
                    Regex("(?i)(sampling.*profiler|profiler.*sampling)").containsMatchIn(name)
            }
            assertFalse("JVMTI checkpoint sampling must not leave ART's native sampling-profiler thread", artSamplingThreadPresent)
            val checkText = selfCheck.readText()
            assertTrue("the explicit CPU calibration should produce samples", Regex("outcome=passed samples=[1-9][0-9]* calibration_cpu_ms=200").containsMatchIn(checkText))
            assertTrue("first pprof output must be nonempty", cpuProfile.length() > 100)

            val reportText = report.readText()
            assertTrue("the schema 3 report should summarize CPU functions in the diagnostics process", reportText.contains("schema=3") && reportText.contains("CPU FUNCTION PROFILE") && reportText.contains("FUNCTION flat="))
            assertTrue("the deliberate calibration function should be visible in sampled symbols", reportText.contains("energyProfileCalibration"))
            listOf("/Users/", "/private/", "/data/user/", "private-build-id", "thread_id=").forEach { privateMarker ->
                assertFalse("profile summary must not contain private process data: $privateMarker", reportText.contains(privateMarker))
            }

            val artText = checkNotNull(artReport).readText()
            assertTrue("the completed segment should declare its JVMTI CPU clock", artText.contains("format=jvmti_kernel_cpu"))
            val hotFunctionHasCpu = Regex("FUNCTION flat_us=([0-9]+) inclusive_us=([0-9]+) symbol=([^\\s]+)")
                .findAll(artText)
                .any { row ->
                    val isHotMethod = row.groupValues[3].contains("artProfilerCpuWork")
                    val flatUs = row.groupValues[1].toLongOrNull() ?: 0L
                    val inclusiveUs = row.groupValues[2].toLongOrNull() ?: 0L
                    isHotMethod && (flatUs > 0L || inclusiveUs > 0L)
                }
            assertTrue("the hot Java method should have positive sampled CPU cost", hotFunctionHasCpu)
            assertTrue("the report should retain explicit thread-mapping coverage", artText.contains("unmapped_thread_observations="))
            assertTrue("the report should retain explicit native-thread coverage limits", artText.contains("native_unattached=unavailable"))
            val historyText = GZIPInputStream(artHistory.inputStream()).bufferedReader().use { it.readText() }
            assertTrue("compressed ART history should retain the sampled hot Java method", historyText.contains("artProfilerCpuWork"))
        } finally {
            runCatching { context.unbindService(connection) }
        }
    }

    @Volatile private var cpuWorkSink = 0L

    private fun artProfilerCpuWork(durationMs: Long) {
        val deadline = SystemClock.elapsedRealtime() + durationMs
        var value = 0L
        while (SystemClock.elapsedRealtime() < deadline) {
            value = value * 31 + 17
        }
        cpuWorkSink = value
    }

    private fun sampledArtReport(directory: File, sinceWallMs: Long): File? {
        return directory.listFiles().orEmpty()
            .filter { it.name.matches(Regex("art-report-(?:[0-5]|peak)\\.txt")) }
            .firstOrNull { file ->
                val text = runCatching { file.readText() }.getOrDefault("")
                val end = Regex("\\bend_ms=([0-9]+)").find(text)?.groupValues?.get(1)?.toLongOrNull() ?: return@firstOrNull false
                end >= sinceWallMs && text.contains("artProfilerCpuWork")
            }
    }
}
