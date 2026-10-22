package app.marten.client.bg

import java.io.File
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.util.zip.GZIPInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EnergyProfilePhaseTest {
    @Test
    fun `ordinary windows require identical idle phases and one prior quiet interval`() {
        val idle = EnergyPhaseSnapshot("core:1-2:idle|art:0-0:idle", active = false)
        assertFalse(energyOrdinaryWindow(null, idle, quietBefore = 10))
        assertFalse(energyOrdinaryWindow(idle, idle, quietBefore = 0))
        assertFalse(energyOrdinaryWindow(idle, idle.copy(signature = "core:1-3:idle|art:0-0:idle"), quietBefore = 1))
        assertFalse(energyOrdinaryWindow(idle, idle.copy(active = true), quietBefore = 2))
        assertFalse(energyOrdinaryWindow(idle.copy(active = true), idle, quietBefore = 2))
        assertTrue(energyOrdinaryWindow(idle, idle, quietBefore = 1))
    }

    @Test
    fun `phase reader identifies active and interrupted producers without leaking their pid`() {
        val directory = Files.createTempDirectory("marten-phase-").toFile()
        try {
            File(directory, "core-phase.txt").writeText("phase=capture sequence=10-1 pid=2147483647\n")
            val interrupted = readEnergyPhases(directory)
            assertFalse(interrupted.active)
            assertTrue(interrupted.interrupted)
            assertFalse(interrupted.signature.contains("2147483647"))
            assertTrue(interrupted.signature.contains("interrupted"))

            File(directory, "core-phase.txt").writeText("phase=capture sequence=10-2 pid=not-a-pid\n")
            val active = readEnergyPhases(directory)
            assertTrue(active.active)
            assertFalse(active.interrupted)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `VM profiler stays enabled across adjacent fetches with only a failure lease`() {
        val service = source("src/main/kotlin/app/marten/client/bg/EnergyProfileService.kt")
        val client = service.substringAfter("internal object EnergyProfileClient")
        val serviceCompact = service.replace(Regex("\\s+"), "")
        val fetchIntervalMs = EnergyProfileService.VM_FETCH_INTERVAL_MS
        val sampleRingMs = 600_000L
        val leaseHeadroomMs = 120_000L
        val orphanLeaseMs = fetchIntervalMs + leaseHeadroomMs

        assertEquals(120_000L, fetchIntervalMs)
        assertEquals(fetchIntervalMs + leaseHeadroomMs, orphanLeaseMs)
        assertTrue("the VM sample ring must retain at least five fetch windows", sampleRingMs >= fetchIntervalMs * 5)
        assertTrue("a disconnected decoder lease must outlive one complete fetch interval", orphanLeaseMs > fetchIntervalMs)
        assertTrue(client.replace(Regex("\\s+"), "").contains("guard.postDelayed(disable,EnergyProfileService.VM_FETCH_INTERVAL_MS+120_000L)"))
        assertTrue(client.contains("guard.removeCallbacks(disable)"))
        assertTrue(client.contains("guardHandler?.post(task)"))
        assertTrue(client.contains("if (stopped) phase.end()"))
        assertTrue(client.contains("profiler_shutdown_unconfirmed"))
        assertTrue(client.contains("value=false"))
        assertFalse(client.contains("SystemClock.sleep"))
        assertFalse(client.contains("Thread.sleep"))
        assertFalse(client.contains("WakeLock"))
        assertFalse(client.contains("AlarmManager"))
        assertFalse(service.contains("budget-paused"))

        assertTrue(service.contains("VM_LEASE_BEGIN"))
        assertTrue(service.contains("VM_LEASE_END"))
        assertTrue(serviceCompact.contains("profile_period\",\"value\"to\"10000\""))
        assertTrue(service.contains("sampling_interval_us=10000 rotation_seconds=120"))
        assertTrue(serviceCompact.contains("handler.postDelayed({finishVmWindow(origin,start,dartPhase)},VM_FETCH_INTERVAL_MS)"))
        assertTrue(serviceCompact.contains("handler.postDelayed({finishVmWindow(nextOrigin,nextStart,dartPhase)},VM_FETCH_INTERVAL_MS)"))
        assertTrue(service.contains("Keep sampling during fetch/decode and across report rotations"))
        assertTrue(serviceCompact.contains(".take(32)"))
        assertTrue(serviceCompact.contains("DART_RECORDINGrequest_origin_us=\$originrequest_end_us=\$end"))
        assertTrue(serviceCompact.contains("buffer_config_seconds=600overflow_detection=unavailable"))
        assertTrue(serviceCompact.contains("valorigin=vmCursor//zeroonfreshVM:includeretainedstartupsamples"))
        assertTrue(serviceCompact.contains("nextOrigin=end+1//inclusiveRPCendpointsmustnotdouble-countboundarysamples"))
        assertTrue(serviceCompact.contains("File(spool,\"dart-cursor.txt\").readText()"))
        assertTrue(serviceCompact.contains("cursor[0]==targetPid.toLong()&&cursor[1]==targetStartTicks"))
        assertTrue(serviceCompact.contains("writeProfileAtomic(File(spool,\"dart-cursor.txt\"),\"\$targetPid\$targetStartTicks\$vmCursor\")"))
    }

    @Test
    fun `Dart peak survives decoder service restart and only a hotter interval replaces it`() {
        val service = source("src/main/kotlin/app/marten/client/bg/EnergyProfileService.kt")
        val compact = service.replace(Regex("\\s+"), "")

        assertTrue(compact.contains("vmPeak=runCatching{File(reports,\"dart-peak-score.txt\").readText().toDouble()}.getOrDefault(-1.0)"))
        val update = "if(samples>0&&rate>vmPeak){vmPeak=rate;writeProfileAtomic(File(reports,\"dart-peak-score.txt\"),rate.toString());writeProfileAtomic(File(reports,\"dart-report-peak.txt\"),report.toString())}"
        assertTrue("peak score and report must only advance together for a hotter interval", compact.contains(update))
    }

    @Test
    fun `ART profiling uses bounded JVMTI kernel CPU sampling and retains legacy decoding`() {
        val profiler = source("src/main/kotlin/app/marten/client/bg/ArtEnergyProfiler.kt")
        val decoder = source("src/main/kotlin/app/marten/client/bg/EnergyProfileService.kt")
        val nativeProfiler = source("src/main/cpp/marten_art_profiler.cpp")
        val profilerCompact = profiler.replace(Regex("\\s+"), "")
        val decoderCompact = decoder.replace(Regex("\\s+"), "")
        val nativeCompact = nativeProfiler.replace(Regex("\\s+"), "")

        assertTrue(profilerCompact.contains("File(app.filesDir,\"energy-private-v3\")"))
        assertTrue(profilerCompact.contains("File(app.getExternalFilesDir(null)?:app.filesDir,\"energy-profiles-v3\")"))
        for (unsafeEntryPoint in listOf("Debug.startMethodTracingSampling", "startMethodTracingSampling", "RunSamplingThread", "pthread_getcpuclockid")) {
            assertFalse("the JVMTI profiler must not enter the unsafe ART sampler: $unsafeEntryPoint", profiler.contains(unsafeEntryPoint))
            assertFalse("the native profiler must not enter the unsafe ART sampler: $unsafeEntryPoint", nativeProfiler.contains(unsafeEntryPoint))
        }
        assertTrue(profilerCompact.contains("Debug.attachJvmtiAgent("))
        assertTrue(profilerCompact.contains("Debug.attachJvmtiAgent(\"libmarten_art_profiler.so\""))
        assertFalse("JVMTI agent loading must use the basename so filesystem paths cannot be rejected", profiler.contains("applicationInfo.nativeLibraryDir"))
        assertTrue(profilerCompact.contains("nativePoll()"))
        assertTrue(profilerCompact.contains("handler.postDelayed(this,100L)"))
        assertTrue(profilerCompact.contains("now-lastRotation>=60_000L"))
        assertTrue(profilerCompact.contains("art-\$slot.jvmti"))
        assertTrue(profilerCompact.contains("format=jvmti_kernel_cpu"))
        assertTrue(nativeProfiler.contains("Agent_OnAttach"))
        assertTrue(nativeProfiler.contains("JVMTI_VERSION_1_2"))
        assertTrue(nativeCompact.contains("callbacks.ThreadStart=thread_start"))
        assertTrue(nativeCompact.contains("SetThreadLocalStorage(thread"))
        assertTrue(nativeProfiler.contains("/proc/self/task/%d/stat"))
        assertTrue(nativeCompact.contains("current.ticks<=old->second.ticks"))
        assertTrue(nativeProfiler.contains("GetStackTrace(threads[i]"))
        assertTrue(nativeCompact.contains("after.start!=current.start"))
        assertTrue(nativeCompact.contains("kMaxThreads=512"))
        assertTrue(nativeCompact.contains("kMaxFunctions=4096"))
        assertTrue(nativeProfiler.contains("unmapped_thread_observations="))
        assertTrue(nativeProfiler.contains("native_unattached=unavailable"))
        assertTrue(decoderCompact.contains("valraw=File(spool,name.removeSuffix(\".ready\")+if(jvmti)\".jvmti\"else\".trace\")"))
        assertTrue(decoderCompact.contains("if(jvmti)decodeJvmtiProfile(raw.readBytes())elsedecodeArtProfile(raw.readBytes())"))
        assertTrue(decoderCompact.contains("appendProfileHistory(reports,\"art\",text.substringBefore(\"ART_PROFILE\")+summary.historyText)"))
        assertTrue(decoderCompact.contains("GZIPOutputStream(output)"))
        assertTrue(decoderCompact.contains("FileOutputStream(file,true)"))
        assertTrue(decoderCompact.contains("writeProfileAtomic(File(reports,\"art-report-\${name.substring(4,5)}.txt\"),text)"))
        assertFalse("decoding completed segments must not replace the live recorder status", decoderCompact.contains("writeProfileAtomic(File(reports,\"art-status.txt\"),ART_CAPTURE_STATUS)"))
    }

    @Test
    fun `profile history appends complete compressed segments and records the committed length`() {
        val directory = Files.createTempDirectory("marten-profile-history-").toFile()
        try {
            appendProfileHistory(directory, "dart", "MARTEN_PROFILE schema=3 segment=1\n")
            appendProfileHistory(directory, "dart", "MARTEN_PROFILE schema=3 segment=2\n")

            val compressed = File(directory, "dart-history.txt.gz")
            val text = GZIPInputStream(compressed.inputStream()).bufferedReader().use { it.readText() }
            assertTrue(text.contains("segment=1"))
            assertTrue(text.contains("segment=2"))
            assertEquals(compressed.length().toString(), File(directory, "dart-history-length.txt").readText())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `diagnostic Dart sampling flags configure a long ring before Flutter VM startup`() {
        val activity = source("src/main/kotlin/app/marten/client/MainActivity.kt")
        val configure = activity.indexOf("intent.putExtra(\"dart-flags\"")
        val startup = activity.indexOf("super.onCreate(savedInstanceState)")

        assertTrue(activity.contains("if (BuildConfig.ENERGY_DIAGNOSTICS)"))
        assertTrue(activity.contains("intent.putExtra(\"enable-dart-profiling\",true)"))
        val flags = Regex("intent\\.putExtra\\(\\\"dart-flags\\\",\\s*\\\"([^\\\"]+)\\\"\\)")
            .find(activity)
            ?.groupValues
            ?.get(1)
        assertEquals(
            "--profile_period=10000,--sample-buffer-duration=600,--max_profile_depth=64",
            flags,
        )
        assertFalse(flags.orEmpty().contains("--profiler"))
        assertFalse(flags.orEmpty().contains("--profile-period"))
        assertFalse(flags.orEmpty().contains("--max-profile-depth"))
        assertTrue(configure >= 0 && startup > configure)
    }

    @Test
    fun `VM RPC URI encodes isolate slashes once and preserves decoded query values`() {
        val uri = energyVmRpcUri(
            URI("http://localhost:8181/vm/"),
            "getPerfettoCpuSamples",
            mapOf(
                "isolateId" to "isolates/123",
                "timeOriginMicros" to "1734567890123",
                "timeExtentMicros" to "20000000",
            ),
        )

        assertEquals("http", uri.scheme)
        assertEquals("localhost", uri.host)
        assertEquals(8181, uri.port)
        assertEquals("/vm/getPerfettoCpuSamples", uri.rawPath)
        assertFalse(uri.rawQuery.contains("%252F", ignoreCase = true))
        assertTrue(uri.rawQuery.contains("isolateId=isolates%2F123"))

        val decoded = uri.rawQuery.split('&').associate { pair ->
            val (key, value) = pair.split('=', limit = 2)
            URLDecoder.decode(key, StandardCharsets.UTF_8) to
                URLDecoder.decode(value, StandardCharsets.UTF_8)
        }
        assertEquals("isolates/123", decoded["isolateId"])
        assertEquals("1734567890123", decoded["timeOriginMicros"])
        assertEquals("20000000", decoded["timeExtentMicros"])
    }

    @Test
    fun `VM RPC URI preserves localhost authority and nested VM endpoint path`() {
        val uri = energyVmRpcUri(
            URI("http://127.0.0.1:4567/custom/vm-service/"),
            "getVMTimelineMicros",
            emptyMap(),
        )

        assertEquals("127.0.0.1", uri.host)
        assertEquals(4567, uri.port)
        assertEquals("/custom/vm-service/getVMTimelineMicros", uri.path)
        assertNull(uri.rawQuery)
    }

    private fun source(path: String): String {
        val file = File(path)
        check(file.isFile) { "missing production source ${file.path}" }
        return file.readText()
    }
}
