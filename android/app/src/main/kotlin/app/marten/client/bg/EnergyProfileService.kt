package app.marten.client.bg

import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.FileObserver
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.os.SystemClock
import android.util.Base64
import android.system.Os
import android.system.OsConstants
import app.marten.client.BuildConfig
import app.marten.core.mobile.Mobile
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder

/** No Flutter engine, VPN owner or network listener lives in this process. */
class EnergyProfileService : Service() {
    private lateinit var worker: HandlerThread
    private lateinit var handler: Handler
    private lateinit var spool: File
    private lateinit var reports: File
    private lateinit var phase: EnergyProfilePhase
    private var observer: FileObserver? = null
    private var vmUri: URI? = null
    private var vmScheduled = false
    private var vmSegment = 0
    private var vmPeak = -1.0
    private var vmBusy = false
    private val slots = mutableMapOf<String, Int>()
    private var receivedBytes = 0L
    private var sentBytes = 0L
    private var generation = 0L
    private var guardian: Messenger? = null
    private var vmCursor = 0L
    private var targetStartTicks = 0L
    private var targetPid = 0
    private var targetRpcCpuMs = 0L
    private var targetCpuUnknown = false
    private val tickHz = runCatching { Os.sysconf(OsConstants._SC_CLK_TCK) }.getOrDefault(100L)

    override fun onCreate() {
        super.onCreate()
        spool = File(filesDir, "energy-private-v3").apply { mkdirs() }
        reports = File(getExternalFilesDir(null) ?: filesDir, "energy-profiles-v3").apply { mkdirs() }
        phase = EnergyProfilePhase(spool, "decode")
        vmPeak = runCatching { File(reports,"dart-peak-score.txt").readText().toDouble() }.getOrDefault(-1.0)
        generation = SystemClock.elapsedRealtime()
        worker = HandlerThread("marten-profile-decode", Process.THREAD_PRIORITY_BACKGROUND).also { it.start() }
        handler = Handler(worker.looper)
        observer = object : FileObserver(spool.absolutePath, MOVED_TO or CLOSE_WRITE) {
            override fun onEvent(event: Int, path: String?) {
                if (path != null && (Regex("core-[0-5]\\.job").matches(path) || Regex("art-[0-5]\\.ready").matches(path))) {
                    handler.post { decodeJob(path) }
                }
            }
        }.also { it.startWatching() }
        handler.post {
            phase.end()
            spool.listFiles().orEmpty().filter { Regex("core-[0-5]\\.job").matches(it.name) || Regex("art-[0-5]\\.ready").matches(it.name) }.forEach { decodeJob(it.name) }
        }
    }

    override fun onBind(intent: Intent): IBinder? {
        if (!BuildConfig.ENERGY_DIAGNOSTICS) return null
        return Messenger(Handler(worker.looper) { message ->
            if (message.what == REGISTER_VM) {
                val supplied = message.data.getString("uri")
                val uri = runCatching { URI(supplied) }.getOrNull()
                if (uri != null && uri.scheme == "http" && uri.host in listOf("127.0.0.1", "::1", "localhost") && uri.userInfo == null && uri.fragment == null) {
                    vmUri = uri
                    guardian = message.replyTo
                    targetPid = message.data.getInt("pid",0)
                    targetStartTicks = runCatching { parseEnergyStat(File("/proc/$targetPid/stat").readText())?.startTicks ?: 0 }.getOrDefault(0)
                    val cursor = runCatching { File(spool,"dart-cursor.txt").readText().trim().split(' ').map { it.toLong() } }.getOrNull()
                    vmCursor = if (targetStartTicks>0 && cursor?.size==3 && cursor[0]==targetPid.toLong() && cursor[1]==targetStartTicks) cursor[2] else 0
                    if (!vmScheduled) {
                        vmScheduled = true
                        handler.post { beginVmWindow() }
                    }
                }
            }
            true
        }).binder
    }

    private fun decodeJob(name: String) {
        if (!File(spool, name).isFile) return
        measured("decode_${if (name.startsWith("art-")) "art" else "core"}") {
            if (name.startsWith("art-")) {
                val prefix = name.removeSuffix(".ready")
                val completed = runClosedEnergyJob(File(spool,name),
                    listOf(File(spool,"$prefix.jvmti"), File(spool,"$prefix.trace")),
                    onLoss = { category -> recordProfileHistoryLoss(reports,"art",category) }) {
                val metadata = File(spool, name).readText().trim().split(' ')
                val jvmti = metadata.getOrNull(4) == "jvmti"
                val raw = File(spool, name.removeSuffix(".ready")+if (jvmti) ".jvmti" else ".trace")
                val start = metadata.getOrNull(0)?.toLongOrNull() ?: 0
                val end = metadata.getOrNull(1)?.trim()?.toLongOrNull() ?: 0
                require(start > 0 && end > start && raw.length() <= 4 * 1024 * 1024)
                val summary = if (jvmti) decodeJvmtiProfile(raw.readBytes()) else decodeArtProfile(raw.readBytes())
                val dropped = metadata.getOrNull(3)?.trim()?.toLongOrNull() ?: -1
                val gap = metadata.getOrNull(2)?.trim()?.toLongOrNull() ?: -1
                val sampleGap = if (jvmti) metadata.getOrNull(5)?.toLongOrNull() ?: -1 else -1
                var text = "MARTEN_PROFILE schema=3 process=app source=art start_ms=$start end_ms=$end rotation_gap_us=$gap max_sample_gap_us=$sampleGap dropped_segments=$dropped continuous=true sampling_interval_us=${if (jvmti) 100000 else 20000} decoder_process=diagnostics\n${summary.text}"
                if (!writeProfileAtomic(File(reports,"art-report-${name.substring(4,5)}.txt"),text)) throw IOException()
                val historyReady = appendProfileHistory(reports,"art",text.substringBefore("ART_PROFILE")+summary.historyText)
                text += "\nHISTORY source=art outcome=${if (historyReady) "ready" else "unavailable"}\n"
                writeProfileAtomic(File(reports,"art-report-${name.substring(4,5)}.txt"),text)
                val peak = File(reports, "art-peak-score.txt")
                val peakFormat = File(reports,"art-peak-format.txt")
                val currentFormat = runCatching { peakFormat.readText() }.getOrDefault("legacy")
                if (jvmti && currentFormat != "jvmti") {
                    writeProfileAtomic(peak,"-1")
                    writeProfileAtomic(peakFormat,"jvmti")
                }
                if ((jvmti || currentFormat != "jvmti") && summary.totalCpuUs > (runCatching { peak.readText().toLong() }.getOrDefault(-1)) && summary.totalCpuUs > 0) {
                    writeProfileAtomic(peak,summary.totalCpuUs.toString())
                    writeProfileAtomic(File(reports,"art-report-peak.txt"),text)
                }
                // Recorder owns live source availability; decoding historical jobs
                // must not overwrite its recording/failure status.
                }
                check(completed) { "capture unavailable" }
            } else {
                Mobile.decodeEnergyCapture(spool.absolutePath, (getExternalFilesDir(null) ?: filesDir).absolutePath, name)
            }
        }
    }

    private fun beginVmWindow() {
        if (vmBusy || vmUri == null) return
        vmBusy = true
        val dartPhase = EnergyProfilePhase(spool,"dart")
        dartPhase.begin("capture")
        try {
            guardian?.send(Message.obtain(null, VM_LEASE_BEGIN))
            rpc("setFlag",mapOf("name" to "profile_period","value" to "10000"))
            rpc("setFlag",mapOf("name" to "profiler","value" to "true"))
            val origin = vmCursor // zero on fresh VM: include retained startup samples
            val start = System.currentTimeMillis()
            writeProfileAtomic(File(reports,"dart-status.txt"),"MARTEN_PROFILE schema=3 source=dart outcome=recording continuous=true sampling_interval_us=10000 rotation_seconds=120\n")
            handler.postDelayed({ finishVmWindow(origin,start,dartPhase) },VM_FETCH_INTERVAL_MS)
        } catch (_: Throwable) {
            runCatching { rpc("setFlag",mapOf("name" to "profiler","value" to "false")); guardian?.send(Message.obtain(null,VM_LEASE_END)) }
            dartPhase.end(); vmBusy = false
            writeProfileAtomic(File(reports,"dart-status.txt"),"MARTEN_PROFILE schema=3 source=dart outcome=unavailable stage=enable_recording\n")
            // A failing VM transport never becomes a retry storm.
        }
    }

    private fun finishVmWindow(origin: Long, start: Long, dartPhase: EnergyProfilePhase) {
        var nextOrigin = origin
        var nextStart = start
        try {
            measured("dart_fetch") {
                guardian?.send(Message.obtain(null,VM_LEASE_BEGIN))
                val end = rpc("getVMTimelineMicros").get("timestamp").asLong
                nextOrigin = end + 1 // inclusive RPC endpoints must not double-count boundary samples
                nextStart = System.currentTimeMillis()
                val inventory = rpc("getVM").getAsJsonArray("isolates")
                val report = StringBuilder("MARTEN_PROFILE schema=3 source=dart start_ms=$start end_ms=${System.currentTimeMillis()} interval_us=${end-origin} continuous=true format=compact_perfetto decoder_process=diagnostics\n")
                val history = StringBuilder(report)
                var samples = 0
                var available = 0
                var unavailable = 0
                // The decoder is a different process, so no collector isolate
                // can contaminate any application isolate CPU sample.
                for (isolate in inventory.filter { it.asJsonObject.get("isSystemIsolate")?.asBoolean != true }.take(32)) {
                    val obj = isolate.asJsonObject
                    if (obj.get("isSystemIsolate")?.asBoolean == true) continue
                    val id = obj.get("id")?.asString ?: continue
                    val slot = slots.getOrPut(id) { slots.size }
                    report.append("DART_ISOLATE slot=$slot\n")
                    history.append("DART_ISOLATE slot=$slot\n")
                    try {
                        val profile = rpc("getPerfettoCpuSamples",mapOf("isolateId" to id,"timeOriginMicros" to origin.toString(),"timeExtentMicros" to (end-origin).toString()))
                        val encoded = profile.get("samples").asString
                        require(encoded.length <= 12 * 1024 * 1024)
                        val period = profile.get("samplePeriod").asLong
                        val coverage = "DART_RECORDING request_origin_us=$origin request_end_us=$end observed_origin_us=${profile.get("timeOriginMicros")?.asLong ?: -1} observed_extent_us=${profile.get("timeExtentMicros")?.asLong ?: -1} max_depth=${profile.get("maxStackDepth")?.asInt ?: -1} buffer_config_seconds=600 overflow_detection=unavailable\n"
                        report.append(coverage); history.append(coverage)
                        val summary = if (profile.get("sampleCount").asInt == 0) {
                            CompactCpuSummary(0,0,"DART_CPU outcome=no_samples samples=0 period_us=$period unresolved_leaf_samples=0 format=compact_perfetto scope=sampled_dart_and_vm_native_entries decoder_process=diagnostics\n")
                        } else decodePerfettoCpuSamples(Base64.decode(encoded,Base64.DEFAULT),period)
                        report.append(summary.text)
                        history.append(summary.historyText)
                        samples += summary.samples; available++
                    } catch (_: Throwable) {
                        report.append("DART_CPU outcome=unavailable stage=compact_capture\n"); history.append("DART_CPU outcome=unavailable stage=compact_capture\n"); unavailable++
                    }

                }
                val rate = samples.toDouble() / (System.currentTimeMillis()-start).coerceAtLeast(1)
                writeProfileAtomic(File(reports,"dart-report-${vmSegment % 6}.txt"),report.toString())
                val historyReady = appendProfileHistory(reports,"dart",history.toString())
                report.append("\nHISTORY source=dart outcome=${if (historyReady) "ready" else "unavailable"}\n")
                writeProfileAtomic(File(reports,"dart-report-${vmSegment % 6}.txt"),report.toString())
                vmCursor = nextOrigin
                writeProfileAtomic(File(spool,"dart-cursor.txt"),"$targetPid $targetStartTicks $vmCursor")
                if (samples > 0 && rate > vmPeak) { vmPeak = rate; writeProfileAtomic(File(reports,"dart-peak-score.txt"),rate.toString()); writeProfileAtomic(File(reports,"dart-report-peak.txt"),report.toString()) }
                writeProfileAtomic(File(reports,"dart-status.txt"),"MARTEN_PROFILE schema=3 source=dart outcome=${if (samples > 0) "ready" else if (available > 0) "no_samples" else "unavailable"} samples=$samples available_isolates=$available unavailable_isolates=$unavailable omitted_isolates=${(inventory.size()-available-unavailable).coerceAtLeast(0)}\n")
            }
        } catch (_: Throwable) {
            writeProfileAtomic(File(reports,"dart-status.txt"),"MARTEN_PROFILE schema=3 source=dart outcome=unavailable stage=compact_capture\n")
        } finally {
            // Keep sampling during fetch/decode and across report rotations.
            // Lease renewal only disables an orphaned recorder on worker failure.
            vmSegment++
            handler.postDelayed({ finishVmWindow(nextOrigin,nextStart,dartPhase) },VM_FETCH_INTERVAL_MS)

        }
    }

    private fun measured(kind: String, work: () -> Unit) {
        val cpu = Process.getElapsedCpuTime()
        val started = SystemClock.elapsedRealtime()
        val startedWall = System.currentTimeMillis()
        val rx = receivedBytes; val tx = sentBytes
        val targetCpu = targetRpcCpuMs
        phase.begin()
        var outcome = "complete"
        try { work() } catch (_: Throwable) { outcome = "unavailable" } finally {
            phase.end()
            if (outcome == "unavailable") {
                val source = if (kind.endsWith("core")) "core" else if (kind.endsWith("art")) "art" else "dart"
                val failure = "MARTEN_PROFILE schema=3 source=$source outcome=unavailable stage=decode start_ms=$startedWall end_ms=${System.currentTimeMillis()}\n"
                // The ART recorder owns current availability/format. A failed
                // closed segment is represented by its loss record and must
                // not replace a live recorder's state with historical failure.
                if (source != "art") writeProfileAtomic(File(reports,"$source-status.txt"),failure)
                runCatching { appendProfileHistory(reports,source,failure) }
            }
            appendEnergyRecord(File(getExternalFilesDir(null) ?: filesDir,"profiling-work.log"),"MARTEN_PROFILER_WORK schema=3 time_ms=${System.currentTimeMillis()} generation=$generation process=diagnostics kind=$kind outcome=$outcome cpu_ms=${Process.getElapsedCpuTime()-cpu} wall_ms=${SystemClock.elapsedRealtime()-started} loopback_rx_bytes=${receivedBytes-rx} loopback_tx_bytes=${sentBytes-tx} target_rpc_cpu_upper_bound_ms=${if (targetCpuUnknown) "unknown" else targetRpcCpuMs-targetCpu} scope=decoder_process_only target_vm_overhead_not_subtracted=true\n")
        }
    }

    private fun rpc(method: String, parameters: Map<String,String> = emptyMap()): JsonObject {
        val targetBefore = readTargetCpuMs()
        val base = checkNotNull(vmUri)
        val uri = energyVmRpcUri(base,method,parameters)
        val connection = uri.toURL().openConnection() as HttpURLConnection
        connection.connectTimeout = 3000; connection.readTimeout = 3000; connection.instanceFollowRedirects = false
        try {
            check(connection.responseCode == 200)
            val data = ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    receivedBytes += count
                    check(data.size()+count <= 12 * 1024 * 1024)
                    data.write(buffer,0,count)
                }
            }
            sentBytes += uri.rawPath.length + (uri.rawQuery?.length ?: 0)
            val response = JsonParser.parseString(data.toString("UTF-8")).asJsonObject
            check(!response.has("error"))
            return if (response.has("result")) response.getAsJsonObject("result") else response
        } finally {
            connection.disconnect()
            val after = readTargetCpuMs()
            if (targetBefore != null && after != null && after >= targetBefore) targetRpcCpuMs += after-targetBefore
            else if (targetPid > 0) targetCpuUnknown = true
        }
    }

    private fun readTargetCpuMs(): Long? = runCatching {
        if (targetPid <= 0) return@runCatching null
        parseEnergyStat(File("/proc/$targetPid/stat").readText())?.cpuTicks?.let { it * 1000 / tickHz }
    }.getOrNull()

    override fun onDestroy() {
        observer?.stopWatching()
        handler.removeCallbacksAndMessages(null)
        runCatching { rpc("setFlag",mapOf("name" to "profiler","value" to "false")) }
        phase.end()
        worker.quitSafely()
        super.onDestroy()
    }

    companion object {
        // Keep the 10 ms recorder running. Amortize repeated VM symbol tables
        // over two minutes, well inside the configured ten-minute sample ring.
        internal const val VM_FETCH_INTERVAL_MS = 120_000L
        internal const val REGISTER_VM = 1
        internal const val VM_LEASE_BEGIN = 2
        internal const val VM_LEASE_END = 3
    }
}

internal fun energyVmRpcUri(base: URI, method: String, parameters: Map<String,String>): URI {
    require(Regex("[a-zA-Z][a-zA-Z0-9]*").matches(method))
    val path = URI(base.scheme,null,base.host,base.port,base.path.trimEnd('/')+"/"+method,null,null).toASCIIString()
    val query = parameters.entries.joinToString("&") { URLEncoder.encode(it.key,"UTF-8")+"="+URLEncoder.encode(it.value,"UTF-8") }
    // The component-based URI constructor would escape the % in an already
    // encoded isolate ID a second time. Use the serialized URI constructor.
    return URI(path + if (query.isEmpty()) "" else "?$query")
}

/** Application-owned binding survives Activity background/teardown. */
internal object EnergyProfileClient {
    private var connection: ServiceConnection? = null
    private var messenger: Messenger? = null
    private var pendingUri: String? = null
    private var guardHandler: Handler? = null
    private var guardian: Messenger? = null
    private var lease: Runnable? = null
    @Synchronized fun bind(context: Context) {
        if (connection != null || !BuildConfig.ENERGY_DIAGNOSTICS) return
        val app = context.applicationContext
        if (guardHandler == null) {
            val guardThread = HandlerThread("marten-profile-guard",Process.THREAD_PRIORITY_BACKGROUND).also { it.start() }
            val guard = Handler(guardThread.looper)
            guardHandler = guard
            val disable = Runnable {
                val uri = pendingUri ?: return@Runnable
                val phase = EnergyProfilePhase(File(app.filesDir,"energy-private-v3"),"dart")
                phase.begin("decode")
                val stopped = runCatching {
                    val base = URI(uri)
                    require(base.scheme == "http" && base.host in listOf("127.0.0.1","::1","localhost"))
                    val address = URI(base.scheme,null,base.host,base.port,base.path.trimEnd('/')+"/setFlag","name=profiler&value=false",null)
                    val connection = address.toURL().openConnection() as HttpURLConnection
                    try {
                        connection.connectTimeout=3000; connection.readTimeout=3000; connection.instanceFollowRedirects=false
                        check(connection.responseCode==200)
                        val result = connection.inputStream.bufferedReader().use { it.readText().take(4096) }
                        check(!JsonParser.parseString(result).asJsonObject.has("error"))
                    } finally { connection.disconnect() }
                }.isSuccess
                if (stopped) phase.end()
                // If flag shutdown failed, retain an active marker: no future
                // interval can silently be classified as ordinary work.
                val reports=File(app.getExternalFilesDir(null) ?: app.filesDir,"energy-profiles-v3")
                writeProfileAtomic(File(reports,"dart-status.txt"),"MARTEN_PROFILE schema=3 source=dart outcome=unavailable reason=${if (stopped) "decoder_lease_expired" else "profiler_shutdown_unconfirmed"}\n")
            }
            lease=disable
            guardian=Messenger(Handler(guardThread.looper) { message ->
                guard.removeCallbacks(disable)
                if (message.what==EnergyProfileService.VM_LEASE_BEGIN) guard.postDelayed(disable,EnergyProfileService.VM_FETCH_INTERVAL_MS + 120_000L)
                true
            })
        }
        val binding = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) { messenger = Messenger(binder); sendVm() }
            override fun onServiceDisconnected(name: ComponentName) {
                messenger = null
                lease?.let { task -> guardHandler?.removeCallbacks(task); guardHandler?.post(task) }
            }
        }
        connection = binding
        if (!runCatching { app.bindService(Intent(app,EnergyProfileService::class.java),binding,Context.BIND_AUTO_CREATE) }.getOrDefault(false)) connection = null
    }
    @Synchronized fun registerVm(context: Context, uri: String) { pendingUri = uri; bind(context); sendVm() }
    private fun sendVm() {
        val uri = pendingUri ?: return
        runCatching { messenger?.send(Message.obtain(null,EnergyProfileService.REGISTER_VM).apply { replyTo=guardian; data = Bundle().apply { putString("uri",uri); putInt("pid",Process.myPid()) } }) }
    }
}

/** Compressed sanitized summaries for every completed interval, not just peaks. */
internal fun appendProfileHistory(directory: File, source: String, text: String): Boolean {
    val file = File(directory,"$source-history.txt.gz")
    val lengthFile = File(directory,"$source-history-length.txt")
    var committed = 0L
    var category = "history_encode"
    var appendStarted = false
    try {
        val output = ByteArrayOutputStream()
        GZIPOutputStream(output).use { it.write(text.toByteArray(Charsets.UTF_8)) }
        val data = output.toByteArray()
        require(data.size <= 8 * 1024 * 1024)
        category = "history_length"
        if (lengthFile.exists()) {
            val stored = lengthFile.readText().toLongOrNull()
            if (stored != null && stored >= 0 && stored <= file.length()) committed = stored
            else recordProfileHistoryLoss(directory,source,"history_uncommitted")
        } else if (file.length() > 0) {
            // One-time validation for legacy history without a commit marker.
            val valid = runCatching {
                GZIPInputStream(file.inputStream()).use { input ->
                    val buffer = ByteArray(8192)
                    var decoded = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        decoded += count
                        require(decoded <= 128L * 1024 * 1024)
                    }
                }
            }.isSuccess
            if (valid) committed = file.length()
            else recordProfileHistoryLoss(directory,source,"history_uncommitted")
        }
        if (file.length() != committed) RandomAccessFile(file,"rw").use { it.setLength(committed) }
        if (!writeProfileAtomic(lengthFile,committed.toString())) throw IOException()
        if (committed+data.size > 8 * 1024 * 1024) {
            category = "history_rotation"
            val old = File(directory,"${file.name}.old")
            if (old.exists() && !old.delete()) throw IOException()
            if (!file.renameTo(old)) throw IOException()
            committed = 0
            if (!writeProfileAtomic(lengthFile,"0")) throw IOException()
            val previous = File(directory,"$source-history-status.txt")
            val lost = historyLostCount(previous)
            writeProfileAtomic(previous,"MARTEN_PROFILE schema=3 outcome=retention_rotated history_limit_bytes=16777216 lost_segments=$lost\n")
        }
        category = "history_write"
        appendStarted = true
        FileOutputStream(file,true).use { it.write(data); it.fd.sync() }
        category = "history_commit"
        if (!writeProfileAtomic(lengthFile,(committed+data.size).toString())) throw IOException()
        return true
    } catch (_: Exception) {
        // A failed write/close/commit never becomes the prefix of another gzip
        // member. Export still clips to the previous committed marker.
        runCatching { if (appendStarted && file.exists()) RandomAccessFile(file,"rw").use { it.setLength(committed) } }
        recordProfileHistoryLoss(directory,source,category)
        return false
    }
}

private fun historyLostCount(file: File): Long = runCatching {
    Regex("lost_segments=([0-9]+)").find(file.readText())?.groupValues?.get(1)?.toLongOrNull() ?: 0L
}.getOrDefault(0L)

internal fun recordProfileHistoryLoss(directory: File, source: String, category: String) {
    val file = File(directory,"$source-history-status.txt")
    val count = historyLostCount(file)+1
    writeProfileAtomic(file,"MARTEN_PROFILE schema=3 outcome=loss category=$category lost_segments=$count\n")
}
