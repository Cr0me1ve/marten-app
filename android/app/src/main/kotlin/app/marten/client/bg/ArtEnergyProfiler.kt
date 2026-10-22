package app.marten.client.bg

import android.content.Context
import android.os.Debug
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Supported JVMTI checkpoints plus kernel CPU counters avoid ART's unsafe
 * pthread clock sampling path (KR-204). All native frames remain explicit scope.
 */
object ArtEnergyProfiler {
    private var started = false
    private external fun nativeReady(): Boolean
    private external fun nativePoll()
    private external fun nativeSnapshot(): String

    @Synchronized fun start(context: Context) {
        if (started) return
        started = true
        val app = context.applicationContext
        val directory = File(app.getExternalFilesDir(null) ?: app.filesDir,"energy-profiles-v3").apply { mkdirs() }
        val spool = File(app.filesDir,"energy-private-v3").apply { mkdirs() }
        val status = File(directory,"art-status.txt")
        val phase = EnergyProfilePhase(spool,"art")
        phase.end()
        try {
            System.loadLibrary("marten_art_profiler")
            Debug.attachJvmtiAgent("libmarten_art_profiler.so", null, ArtEnergyProfiler::class.java.classLoader)
            check(nativeReady())
        } catch (_: Throwable) {
            writeProfileAtomic(status,"MARTEN_PROFILE schema=3 source=art outcome=unavailable reason=jvmti_attach_failed\n")
            return
        }
        val worker = HandlerThread("marten-art-profile",Process.THREAD_PRIORITY_BACKGROUND).also { it.start() }
        val handler = Handler(worker.looper)
        var startMs = System.currentTimeMillis()
        var lastRotation = SystemClock.elapsedRealtime()
        var previousPoll = SystemClock.elapsedRealtime()
        var maxGapUs = 0L
        var dropped = 0L
        phase.begin("capture")
        writeProfileAtomic(status,"MARTEN_PROFILE schema=3 source=art outcome=recording continuous=true format=jvmti_kernel_cpu sampling_interval_us=100000 rotation_seconds=60\n")
        val sample = object : Runnable {
            override fun run() {
                try {
                    val now = SystemClock.elapsedRealtime()
                    maxGapUs = maxOf(maxGapUs, maxOf(0L, now-previousPoll-100L)*1000)
                    previousPoll = now
                    nativePoll()
                    if (now-lastRotation >= 60_000L) {
                        val text = nativeSnapshot()
                        val slot = (0..5).firstOrNull { !File(spool,"art-$it.ready").exists() }
                        val endMs = System.currentTimeMillis()
                        if (slot == null || text.length > 2 * 1024 * 1024) dropped++
                        else {
                            writeProfileAtomic(File(spool,"art-$slot.jvmti"),text)
                            writeProfileAtomic(File(spool,"art-$slot.ready"),"$startMs $endMs 0 $dropped jvmti $maxGapUs\n")
                        }
                        startMs = endMs; lastRotation = now
                        writeProfileAtomic(status,"MARTEN_PROFILE schema=3 source=art outcome=recording continuous=true format=jvmti_kernel_cpu sampling_interval_us=100000 rotation_seconds=60 rotation_gap_us=0 max_sample_gap_us=$maxGapUs dropped_segments=$dropped\n")
                        maxGapUs = 0
                    }
                    handler.postDelayed(this,100L)
                } catch (_: Throwable) {
                    phase.end()
                    writeProfileAtomic(status,"MARTEN_PROFILE schema=3 source=art outcome=unavailable reason=jvmti_capture_failed\n")
                }
            }
        }
        handler.post(sample)
    }
}

internal fun decodeJvmtiProfile(bytes: ByteArray): ArtProfileSummary {
    require(bytes.size <= 2 * 1024 * 1024)
    val text = bytes.toString(Charsets.UTF_8)
    val header = text.lineSequence().first()
    require(header.startsWith("ART_PROFILE ") && header.contains("format=jvmti_kernel_cpu"))
    // The producer emits only static code symbols and numeric counters. Reject
    // malformed private spool content instead of copying arbitrary text outward.
    val symbol = "[a-zA-Z_$][a-zA-Z0-9_/$:<>()-]{0,239}"
    require(text.lineSequence().all { line ->
        line.isEmpty() ||
        (line.startsWith("ART_PROFILE ") || line.startsWith("ART_COVERAGE ")) && Regex("[a-zA-Z0-9_ =]+" ).matches(line) ||
        Regex("FUNCTION flat_us=[0-9]+ inclusive_us=[0-9]+ symbol=$symbol").matches(line) ||
        Regex("STACK value_us=[0-9]+ frames=$symbol( <- $symbol){0,11}").matches(line)
    })
    val records = Regex("records=([0-9]+)").find(header)?.groupValues?.get(1)?.toIntOrNull() ?: error("missing records")
    val cpu = Regex("total_observed_us=([0-9]+)").find(header)?.groupValues?.get(1)?.toLongOrNull() ?: error("missing CPU")
    return ArtProfileSummary(if (records>0) "ready" else "no_samples",cpu,records,text)
}

internal fun writeProfileAtomic(file: File, content: String): Boolean {
    val tmp = File(file.parentFile, "${file.name}.pending")
    return runCatching {
        java.io.FileOutputStream(tmp).use { it.write(content.toByteArray(Charsets.UTF_8)); it.fd.sync() }
        check(tmp.renameTo(file))
        true
    }.getOrElse { tmp.delete(); false }
}

internal data class ArtProfileSummary(val status: String, val totalCpuUs: Long, val records: Int, val text: String, val historyText: String = text)

internal fun decodeArtProfile(bytes: ByteArray): ArtProfileSummary {
    require(bytes.size <= 8 * 1024 * 1024)
    val delimiter = "*end\n".toByteArray()
    val end = (0..minOf(bytes.size - delimiter.size, 2 * 1024 * 1024)).firstOrNull { offset ->
        delimiter.indices.all { bytes[offset + it] == delimiter[it] }
    } ?: error("trace header unavailable")
    val header = bytes.copyOfRange(0, end).toString(Charsets.UTF_8)
    val binaryStart = end + delimiter.size
    require(bytes.size >= binaryStart + 18)
    val data = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
    require(data.getInt(binaryStart) == 0x574f4c53) // SLOW
    val version = data.getShort(binaryStart + 4).toInt() and 0xffff
    require(version in 2..3)
    val headerSize = data.getShort(binaryStart + 6).toInt() and 0xffff
    val clock = when {
        header.contains("clock=dual") -> "dual"
        header.contains("clock=thread-cpu") -> "thread_cpu"
        else -> "wall"
    }
    val recordSize = if (version == 3) data.getShort(binaryStart + 16).toInt() and 0xffff else 10
    require(recordSize in 10..32 && headerSize >= 16)
    val methods = mutableMapOf<Long, String>()
    var methodSection = false
    for (line in header.lineSequence()) {
        if (line.startsWith('*')) { methodSection = line == "*methods"; continue }
        if (!methodSection) continue
        val parts = line.split('\t')
        val id = parts.firstOrNull()?.removePrefix("0x")?.toLongOrNull(16) ?: continue
        if (parts.size < 3) continue
        // Static code names only; drop trace thread names, signatures, IDs and paths.
        val symbol = (parts[1].removePrefix("L").removeSuffix(";") + "::" + parts[2])
            .replace('.', ':').replace(Regex("[^a-zA-Z0-9_/$:<>()-]"), "_").take(240)
        methods[id] = symbol
    }
    val stacks = mutableMapOf<Int, MutableList<Long>>()
    val clocks = mutableMapOf<Int, Long>()
    val flat = mutableMapOf<String, Long>()
    val inclusive = mutableMapOf<String, Long>()
    val chains = mutableMapOf<String, Long>()
    var total = 0L
    var count = 0
    var offset = binaryStart + headerSize
    while (offset + recordSize <= bytes.size) {
        val thread = data.getShort(offset).toInt() and 0xffff
        val methodAction = data.getInt(offset + 2).toLong() and 0xffffffffL
        val time = data.getInt(offset + 6).toLong() and 0xffffffffL
        val stack = stacks.getOrPut(thread) { mutableListOf() }
        val before = clocks.put(thread, time)
        if (before != null && stack.isNotEmpty()) {
            val elapsed = (time - before) and 0xffffffffL
            if (elapsed < 10_000_000L) {
                val names = stack.map { methods[it] ?: "unknown_native_or_art" }
                val top = names.last()
                flat[top] = (flat[top] ?: 0) + elapsed
                names.toSet().forEach { inclusive[it] = (inclusive[it] ?: 0) + elapsed }
                val chain = names.takeLast(24).reversed().joinToString(" <- ")
                chains[chain] = (chains[chain] ?: 0) + elapsed
                total += elapsed
            }
        }
        val method = methodAction and 0xfffffffcL
        when ((methodAction and 3).toInt()) {
            0 -> if (stack.size < 512) stack.add(method)
            1, 2 -> {
                val index = stack.lastIndexOf(method)
                if (index >= 0) while (stack.size > index) stack.removeAt(stack.lastIndex)
                else stack.clear()
            }
        }
        count++; offset += recordSize
    }
    val outcome = if (count == 0) "no_samples" else "ready"
    fun render(maxRows: Int) = buildString {
        append("ART_PROFILE outcome=$outcome clock=$clock records=$count total_observed_us=$total overflow=${header.contains("data-file-overflow=true")} scope=sampled_java_and_native_entry_frames\n")
        for ((name, value) in inclusive.entries.sortedByDescending { it.value }.take(maxRows)) {
            append("FUNCTION flat_us=${flat[name] ?: 0} inclusive_us=$value symbol=$name\n")
        }
        for ((chain, value) in chains.entries.sortedByDescending { it.value }.take(maxRows)) {
            append("STACK value_us=$value frames=$chain\n")
        }
    }
    return ArtProfileSummary(outcome, if (clock == "wall") -1L else total, count, render(40),render(100_000))
}
