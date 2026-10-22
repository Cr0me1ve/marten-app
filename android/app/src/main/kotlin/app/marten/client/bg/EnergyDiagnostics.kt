package app.marten.client.bg

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.TrafficStats
import android.os.BatteryManager
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import app.marten.core.mobile.Mobile

/** Local diagnostic-build sampler. No native calls, network, wake locks or alarms.
 * Handler delays use uptime: suspension postpones sampling rather than waking the
 * phone. Wall and awake windows are both retained so CPU is not diluted silently.
 * Each process writes its own bounded files. All emitted values are numbers or
 * fixed enums; proc command/thread names and IDs never leave the classifier.
 */
object EnergyDiagnostics {
    internal const val INTERVAL_MS = 60_000L
    internal const val MAX_FILE_BYTES = 1024 * 1024L
    private var started = false

    @Synchronized
    fun start(context: Context, coreProcess: Boolean, decoderProcess: Boolean = false) {
        if (started) return
        started = true
        val app = context.applicationContext
        val role = if (decoderProcess) "diagnostics" else if (coreProcess) "core" else "app"
        val worker = HandlerThread("marten-energy", Process.THREAD_PRIORITY_BACKGROUND)
        worker.start()
        val handler = Handler(worker.looper)
        // The first delayed read still accounts for CPU since process creation;
        // delaying the sampler must not discard cold-start work.
        var previous: EnergySample? = EnergySample(
            Process.getStartElapsedRealtime(), Process.getStartUptimeMillis(),
            0L, -1L, -1L, -1L, -1L,
        )
        var previousPhase: EnergyPhaseSnapshot? = null
        var quietWindows = 0
        val generation = SystemClock.elapsedRealtime()
        val spool = File(app.filesDir, "energy-private-v3")
        var threadsBefore = emptyMap<String, EnergyThreadStat>()
        val tickHz = runCatching { Os.sysconf(OsConstants._SC_CLK_TCK) }.getOrDefault(100L)
        val pageBytes = runCatching { Os.sysconf(OsConstants._SC_PAGESIZE) }.getOrDefault(4096L)
        if (coreProcess) {
            // This worker is separate from core admission/cancel and UI threads.
            val captureWorker = HandlerThread("marten-energy-control",Process.THREAD_PRIORITY_BACKGROUND).also { it.start() }
            Handler(captureWorker.looper).post {
                runCatching {
                    EnergyProfileClient.bind(app)
                    Mobile.startEnergyCapture(
                        (app.getExternalFilesDir(null) ?: app.filesDir).absolutePath,
                        spool.absolutePath,
                    )
                }
            }
        } else if (!decoderProcess) {
            handler.post { EnergyProfileClient.bind(app) }
            ArtEnergyProfiler.start(app)
        }
        val task = object : Runnable {
            override fun run() {
                runCatching {
                    val begun = SystemClock.uptimeMillis()
                    val samplerCpu = android.os.Debug.threadCpuTimeNanos()
                    val stat = parseEnergyStat(File("/proc/self/stat").readText())
                    val io = readNumericFields(File("/proc/self/io"))
                    val rssPages = File("/proc/self/statm").readText().trim().split(Regex("\\s+")).getOrNull(1)?.toLongOrNull()
                    val sample = EnergySample(
                        SystemClock.elapsedRealtime(), SystemClock.uptimeMillis(),
                        Process.getElapsedCpuTime(), TrafficStats.getUidRxBytes(Process.myUid()),
                        TrafficStats.getUidTxBytes(Process.myUid()), io["wchar"] ?: -1,
                        io["syscw"] ?: -1,
                    )
                    val tasks = File("/proc/self/task").listFiles().orEmpty()
                    val threadsNow = mutableMapOf<String, EnergyThreadStat>()
                    val categories = mutableMapOf<String, Long>()
                    var scanComplete = tasks.size <= 512
                    for (directory in tasks.take(512)) {
                        if (SystemClock.uptimeMillis() - begun > 100L) {
                            scanComplete = false
                            break
                        }
                        runCatching {
                            val raw = directory.resolve("stat").readText()
                            val current = parseEnergyStat(raw) ?: return@runCatching
                            threadsNow[directory.name] = current
                            val before = threadsBefore[directory.name]
                            if (before != null && before.startTicks == current.startTicks) {
                                val ticks = energyCounterDelta(current.cpuTicks, before.cpuTicks)
                                if (ticks >= 0) {
                                    val category = energyThreadCategory(
                                        raw.substringAfter('(').substringBeforeLast(')'),
                                        directory.name == Process.myPid().toString(),
                                    )
                                    categories[category] = (categories[category] ?: 0) + ticks
                                }
                            }
                        }.onFailure { scanComplete = false }
                    }
                    val power = app.getSystemService(PowerManager::class.java)
                    val battery = app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                    val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                    val percent = if (level >= 0 && scale > 0) level * 100 / scale else -1
                    val batteryManager = app.getSystemService(BatteryManager::class.java)
                    val currentUa = batteryManager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
                        ?.takeUnless { it == Int.MIN_VALUE }
                    val chargeUah = batteryManager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
                        ?.takeUnless { it == Int.MIN_VALUE }
                    val importance = ActivityManager.RunningAppProcessInfo().also { ActivityManager.getMyMemoryState(it) }.importance
                    val dir = app.getExternalFilesDir(null) ?: app.filesDir
                    val phase = readEnergyPhases(spool)
                    val ordinary = energyOrdinaryWindow(previousPhase, phase, quietWindows)
                    val line = buildString {
                        append("MARTEN_ENERGY schema=3 time_ms=${System.currentTimeMillis()} generation=$generation process=$role ")
                        append("sample=${if (previous == null) "baseline" else "interval"} ")
                        append(sample.deltaFields(previous))
                        append(" cpu_total_ms=${sample.cpuMs} rss_kb=${rssPages?.let { it * pageBytes / 1024 } ?: -1}")
                        append(" threads=${stat?.threadCount ?: -1} thread_scan_complete=$scanComplete tick_hz=$tickHz")
                        // Includes only threads alive at both samples; exited/new
                        // thread CPU is still included in process cpu_delta_ms.
                        append(" thread_cpu_scope=survivors")
                        for (category in ENERGY_THREAD_CATEGORIES) {
                            append(" thread_${category}_ticks=${categories[category] ?: 0}")
                        }
                        append(" interactive=${power?.isInteractive ?: false} doze=${power?.isDeviceIdleMode ?: false}")
                        append(" power_save=${power?.isPowerSaveMode ?: false} importance=$importance")
                        append(" battery_pct=$percent battery_temp_deci_c=${battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1}")
                        append(" plugged=${battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1}")
                        // Device battery current/charge, not per-app attribution.
                        append(" device_current_ua=${currentUa ?: "unknown"} device_charge_uah=${chargeUah ?: "unknown"}")
                        append(" sampler_ms=${SystemClock.uptimeMillis() - begun}")
                        append(" sampler_cpu_us=${(android.os.Debug.threadCpuTimeNanos()-samplerCpu)/1000}")
                        append(" ordinary_window=$ordinary profiler_active=${phase.active} profiler_interrupted=${phase.interrupted}")
                        append('\n')
                    }
                    dir.mkdirs()
                    appendEnergyRecord(File(dir, "energy-$role.log"), line)
                    previous = sample
                    quietWindows = if (!phase.active && previousPhase?.signature == phase.signature) quietWindows + 1 else 0
                    previousPhase = phase
                    threadsBefore = threadsNow
                }
                // Failure drops just this sample. Never touches VPN lifecycle,
                // and never writes raw exceptions, proc content or device paths.
                handler.postDelayed(this, INTERVAL_MS)
            }
        }
        handler.postDelayed(task, 10_000L)
    }
}

internal data class EnergyThreadStat(val cpuTicks: Long, val startTicks: Long, val threadCount: Long)

internal fun parseEnergyStat(raw: String): EnergyThreadStat? {
    // comm may contain spaces and ')' so split only after the final delimiter.
    val close = raw.lastIndexOf(')')
    if (close < 0) return null
    val fields = raw.substring(close + 1).trim().split(Regex("\\s+"))
    val user = fields.getOrNull(11)?.toLongOrNull() ?: return null
    val system = fields.getOrNull(12)?.toLongOrNull() ?: return null
    val start = fields.getOrNull(19)?.toLongOrNull() ?: return null
    val count = fields.getOrNull(17)?.toLongOrNull() ?: return null
    return EnergyThreadStat(user + system, start, count)
}

internal val ENERGY_THREAD_CATEGORIES = listOf("main", "flutter_ui", "flutter_raster", "flutter_io", "binder", "grpc", "diagnostics", "runtime", "other")

internal fun energyThreadCategory(name: String, main: Boolean): String = when {
    main -> "main"
    name.endsWith(".ui") -> "flutter_ui"
    name.endsWith(".raster") -> "flutter_raster"
    name.endsWith(".io") -> "flutter_io"
    name.startsWith("Binder:") -> "binder"
    name.contains("grpc", ignoreCase = true) -> "grpc"
    name.startsWith("Sampling Profil") || name.startsWith("Dart Profiler") || name.startsWith("marten-energy") || name.startsWith("marten-art") || name.startsWith("marten-profile") || name.startsWith("marten-connecti") || name.startsWith("marten-quick") -> "diagnostics"
    name in listOf("HeapTaskDaemon", "Jit thread pool", "FinalizerDaemon", "ReferenceQueueD") -> "runtime"
    else -> "other"
}

internal fun energyCounterDelta(current: Long, previous: Long?): Long =
    if (previous == null || previous < 0 || current < previous) -1 else current - previous

internal data class EnergySample(
    val elapsedMs: Long, val awakeMs: Long, val cpuMs: Long,
    val rxBytes: Long, val txBytes: Long, val writeChars: Long, val writeCalls: Long,
) {
    fun deltaFields(previous: EnergySample?): String =
        "window_ms=${energyCounterDelta(elapsedMs, previous?.elapsedMs)} " +
            "awake_ms=${energyCounterDelta(awakeMs, previous?.awakeMs)} " +
            "cpu_delta_ms=${energyCounterDelta(cpuMs, previous?.cpuMs)} " +
            "traffic_scope=uid uid_rx_bytes=${energyCounterDelta(rxBytes, previous?.rxBytes)} " +
            "uid_tx_bytes=${energyCounterDelta(txBytes, previous?.txBytes)} " +
            "write_chars=${energyCounterDelta(writeChars, previous?.writeChars)} " +
            "write_calls=${energyCounterDelta(writeCalls, previous?.writeCalls)}"
}

private fun readNumericFields(file: File): Map<String, Long> = runCatching {
    file.readLines().mapNotNull { line ->
        val pieces = line.split(':', limit = 2)
        pieces.getOrNull(1)?.trim()?.toLongOrNull()?.let { pieces[0] to it }
    }.toMap()
}.getOrDefault(emptyMap())

internal fun appendEnergyRecord(current: File, line: String) {
    val bytes = line.toByteArray(Charsets.UTF_8)
    if (current.length() + bytes.size > EnergyDiagnostics.MAX_FILE_BYTES) {
        val old = File(current.parentFile, "${current.name}.old")
        if (old.exists()) check(old.delete())
        check(current.renameTo(old))
    }
    // One append write per complete record; exporter also applies final redaction.
    FileOutputStream(current, true).use { it.write(bytes) }
}
