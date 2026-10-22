package app.marten.client.bg

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EnergyDiagnosticsTest {
    @Test
    fun `proc stat parser handles spaces and closing parentheses in comm and reads selected fields`() {
        val parsed = parseEnergyStat(procStat("worker ) with spaces", utime = 123, stime = 45, threads = 7, start = 9876))

        assertNotNull(parsed)
        assertEquals(168L, parsed!!.cpuTicks)
        assertEquals(9876L, parsed.startTicks)
        assertEquals(7L, parsed.threadCount)
    }

    @Test
    fun `proc stat parser rejects malformed and incomplete required fields`() {
        assertNull(parseEnergyStat("17 (no closing delimiter S 1 2 3"))
        assertNull(parseEnergyStat("17 (worker) S 1 2 3"))
        assertNull(parseEnergyStat(procStat("worker", utime = "bad")))
        assertNull(parseEnergyStat(procStat("worker", stime = "bad")))
        assertNull(parseEnergyStat(procStat("worker", threads = "bad")))
        assertNull(parseEnergyStat(procStat("worker", start = "bad")))
    }

    @Test
    fun `monotonic deltas mark missing counters and resets unknown`() {
        assertEquals(-1L, energyCounterDelta(10, null))
        assertEquals(-1L, energyCounterDelta(10, -1))
        assertEquals(-1L, energyCounterDelta(9, 10))
        assertEquals(0L, energyCounterDelta(10, 10))
        assertEquals(7L, energyCounterDelta(17, 10))
    }

    @Test
    fun `delta fields distinguish baseline from interval and preserve missing values`() {
        val baseline = EnergySample(100, 80, 12, 40, 50, -1, 4).deltaFields(null)
        assertEquals(
            "window_ms=-1 awake_ms=-1 cpu_delta_ms=-1 traffic_scope=uid uid_rx_bytes=-1 uid_tx_bytes=-1 write_chars=-1 write_calls=-1",
            baseline,
        )

        val previous = EnergySample(100, 80, 12, 40, 50, -1, 4)
        val current = EnergySample(145, 110, 20, 63, 70, 30, 2)
        assertEquals(
            "window_ms=45 awake_ms=30 cpu_delta_ms=8 traffic_scope=uid uid_rx_bytes=23 uid_tx_bytes=20 write_chars=-1 write_calls=-1",
            current.deltaFields(previous),
        )
    }

    @Test
    fun `first delayed sample includes startup process CPU while traffic and IO counters stay unknown`() {
        val processStart = EnergySample(12_000, 10_000, 0, -1, -1, -1, -1)
        val firstDelayedSample = EnergySample(22_000, 18_000, 37, -1, -1, 150, 2)

        assertEquals(
            "window_ms=10000 awake_ms=8000 cpu_delta_ms=37 traffic_scope=uid uid_rx_bytes=-1 uid_tx_bytes=-1 write_chars=-1 write_calls=-1",
            firstDelayedSample.deltaFields(processStart),
        )
    }

    @Test
    fun `thread classification emits only fixed categories and maps unknown names to other`() {
        val samples = listOf(
            energyThreadCategory("main-like-private-name", main = true),
            energyThreadCategory("FlutterWorker.ui", main = false),
            energyThreadCategory("FlutterWorker.raster", main = false),
            energyThreadCategory("FlutterWorker.io", main = false),
            energyThreadCategory("Binder:123_4", main = false),
            energyThreadCategory("grpc-poller", main = false),
            energyThreadCategory("marten-energy", main = false),
            energyThreadCategory("HeapTaskDaemon", main = false),
            energyThreadCategory("sensitive-custom-thread-42", main = false),
        )

        assertEquals(listOf("main", "flutter_ui", "flutter_raster", "flutter_io", "binder", "grpc", "diagnostics", "runtime", "other"), samples)
        assertTrue(samples.all { it in ENERGY_THREAD_CATEGORIES })
        assertFalse(samples.any { it.contains("sensitive") || it.contains("123") })
    }

    @Test
    fun `append rotates a bounded current file before writing the next record`() {
        val dir = Files.createTempDirectory("marten-energy-").toFile()
        try {
            val current = File(dir, "energy-app.log")
            val original = "x".repeat(EnergyDiagnostics.MAX_FILE_BYTES.toInt() - 2)
            current.writeText(original)

            appendEnergyRecord(current, "y\n")
            assertEquals(EnergyDiagnostics.MAX_FILE_BYTES, current.length())
            appendEnergyRecord(current, "z\n")

            assertEquals(original + "y\n", File(dir, "energy-app.log.old").readText())
            assertEquals("z\n", current.readText())
            assertTrue(current.length() <= EnergyDiagnostics.MAX_FILE_BYTES)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `sampler is diagnostic build gated and uses delayed uptime scheduling with process and UID counters`() {
        val application = source("src/main/kotlin/app/marten/client/Application.kt")
        val sampler = source("src/main/kotlin/app/marten/client/bg/EnergyDiagnostics.kt")

        assertTrue(application.contains("if (BuildConfig.ENERGY_DIAGNOSTICS)"))
        assertTrue(application.contains("EnergyDiagnostics.start(this, isCoreProcess)"))
        assertTrue(sampler.contains("HandlerThread("))
        assertTrue(sampler.contains("handler.postDelayed(task, 10_000L)"))
        assertTrue(sampler.contains("handler.postDelayed(this, INTERVAL_MS)"))
        assertTrue(sampler.contains("INTERVAL_MS = 60_000L"))
        assertTrue(sampler.contains("SystemClock.uptimeMillis()"))
        assertTrue(sampler.contains("Process.getElapsedCpuTime()"))
        assertTrue(sampler.contains("TrafficStats.getUidRxBytes(Process.myUid())"))
        assertTrue(sampler.contains("TrafficStats.getUidTxBytes(Process.myUid())"))
        val samplerCompact = sampler.replace(Regex("\\s+"), "")
        assertTrue(
            Regex("varprevious:EnergySample\\?=EnergySample\\(Process.getStartElapsedRealtime\\(\\),Process.getStartUptimeMillis\\(\\),0L,-1L,-1L,-1L,-1L,?\\)")
                .containsMatchIn(samplerCompact),
        )
        assertFalse(sampler.contains("PowerManager.WakeLock"))
        assertFalse(sampler.contains(".acquire("))
        assertFalse(sampler.contains("AlarmManager"))
        assertFalse(sampler.contains("HttpURLConnection"))
        assertFalse(sampler.contains("Socket("))
    }

    private fun procStat(
        comm: String,
        utime: Any = 10,
        stime: Any = 3,
        threads: Any = 2,
        start: Any = 456,
    ): String {
        // Fields after comm start at process stat field 3 (state). utime,
        // stime, num_threads, and starttime are fields 14, 15, 20, and 22.
        val fields = MutableList(20) { "1" }
        fields[0] = "S"
        fields[11] = utime.toString()
        fields[12] = stime.toString()
        fields[17] = threads.toString()
        fields[19] = start.toString()
        return "123 ($comm) ${fields.joinToString(" ")}"
    }

    private fun source(path: String): String {
        val file = File(path)
        check(file.isFile) { "missing production source ${file.path}" }
        return file.readText()
    }
}
