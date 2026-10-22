package app.marten.client.bg

/** Reads only names, frames and callstacks from the VM's compact Perfetto trace.
 * Paths, IDs, object references and native addresses are never emitted. */
internal data class CompactCpuSummary(val samples: Int, val unknownSamples: Int, val text: String, val historyText: String = text)

internal fun decodePerfettoCpuSamples(bytes: ByteArray, periodUs: Long): CompactCpuSummary {
    require(bytes.size <= 8 * 1024 * 1024)
    val names = mutableMapOf<Long, ProtoCursor>()
    val resolvedNames = mutableMapOf<Long, String>()
    val frames = mutableMapOf<Long, Long>()
    val stacks = mutableMapOf<Long, List<Long>>()
    val observations = mutableMapOf<Long, Int>()
    var packets = 0
    var count = 0
    ProtoCursor(bytes).fields { tag, wire, field ->
        if (tag != 1 || wire != 2) return@fields
        check(++packets <= 100_000)
        var interned: ProtoCursor? = null
        var sample: ProtoCursor? = null
        var flags = 0L
        field.fields { key, kind, value ->
            when {
                key == 12 && kind == 2 -> interned = value
                key == 66 && kind == 2 -> sample = value
                key == 13 && kind == 0 -> flags = value.number()
            }
        }
        if ((flags and 1L) != 0L) { names.clear(); resolvedNames.clear(); frames.clear(); stacks.clear(); observations.clear() }
        interned?.fields { key, kind, item ->
            if (kind != 2) return@fields
            when (key) {
                5 -> {
                    var id = 0L
                    var name: ProtoCursor? = null
                    item.fields { k, w, v ->
                        if (k == 1 && w == 0) id = v.number()
                        if (k == 2 && w == 2) name = v
                    }
                    if (id > 0 && name != null) { check(names.size < 100_000); names[id] = checkNotNull(name) }
                }
                6 -> {
                    var id = 0L; var name = 0L
                    item.fields { k, w, v ->
                        if (k == 1 && w == 0) id = v.number()
                        if (k == 2 && w == 0) name = v.number()
                    }
                    if (id > 0) { check(frames.size < 100_000); frames[id] = name }
                }
                7 -> {
                    var id = 0L; val stack = mutableListOf<Long>()
                    item.fields { k, w, v ->
                        if (k == 1 && w == 0) id = v.number()
                        if (k == 2 && w == 0) { check(stack.size < 512); stack.add(v.number()) }
                        if (k == 2 && w == 2) while (v.remaining()) { check(stack.size < 512); stack.add(v.number()) }
                    }
                    if (id > 0) { check(stacks.size < 20_000); stacks[id] = stack }
                }
            }
        }
        sample?.fields { key, kind, value ->
            if (key == 4 && kind == 0) {
                val stack = value.number()
                observations[stack] = (observations[stack] ?: 0) + 1
                count++
            }
        }
    }
    val flat = mutableMapOf<String, Int>()
    val inclusive = mutableMapOf<String, Int>()
    val chains = mutableMapOf<String, Int>()
    var unknown = 0
    for ((stackId, ticks) in observations) {
        // Perfetto stores root first; all Marten summaries use leaf first.
        val stack = stacks[stackId].orEmpty().takeLast(64).reversed().map {
            val id = frames[it] ?: 0
            resolvedNames.getOrPut(id) { names[id]?.let { raw -> safeCompactSymbol(raw.text()) } ?: "unknown_frame" }
        }
        val leaf = stack.firstOrNull() ?: "unknown_frame"
        if (leaf == "unknown_frame" || leaf == "unresolved_native_frame") unknown += ticks
        flat[leaf] = (flat[leaf] ?: 0) + ticks
        stack.toSet().forEach { inclusive[it] = (inclusive[it] ?: 0) + ticks }
        val chain = stack.take(24).joinToString(" <- ").ifEmpty { "unknown_frame" }
        chains[chain] = (chains[chain] ?: 0) + ticks
    }
    fun render(maxRows: Int) = buildString {
        append("DART_CPU outcome=${if (count > 0) "ready" else "no_samples"} samples=$count period_us=$periodUs unresolved_leaf_samples=$unknown format=compact_perfetto scope=sampled_dart_and_vm_native_entries decoder_process=diagnostics\n")
        for ((name, ticks) in inclusive.entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key }).take(maxRows)) {
            append("FUNCTION flat_samples=${flat[name] ?: 0} inclusive_samples=$ticks symbol=$name flat_pct=${if (count > 0) 100.0 * (flat[name] ?: 0) / count else 0.0} inclusive_pct=${if (count > 0) 100.0 * ticks / count else 0.0}\n")
        }
        for ((chain, ticks) in chains.entries.sortedByDescending { it.value }.take(maxRows)) append("STACK samples=$ticks frames=$chain\n")
    }
    return CompactCpuSummary(count, unknown, render(40),render(100_000))
}

internal fun safeCompactSymbol(name: String): String {
    if (name.contains("[Native]") || name.contains("0x") || COMPACT_PRIVATE_PATHS.any { name.contains(it) }) return "unresolved_native_frame"
    if (name.startsWith('/') || name.contains("://") || name.contains('@') || name.contains('\\') || name.contains("token=")) return "unknown_frame"
    return name.replace(".", "::").replace(COMPACT_SYMBOL_CHARS, "_").take(240).ifEmpty { "unknown_frame" }
}

private val COMPACT_PRIVATE_PATHS = listOf("/data/", "/system/", "/apex/", "/vendor/")
private val COMPACT_SYMBOL_CHARS = Regex("[^a-zA-Z0-9_:$<>/()-]")

/** A bounded protobuf cursor which skips unknown fields without copying them. */
private class ProtoCursor(private val bytes: ByteArray, private var at: Int = 0, private val end: Int = bytes.size) {
    fun remaining() = at < end
    fun number(): Long {
        var value = 0L
        for (shift in 0..63 step 7) {
            require(at < end)
            val b = bytes[at++].toInt() and 255
            if (shift == 63) require(b <= 1)
            value = value or ((b and 127).toLong() shl shift)
            if (b < 128) return value
        }
        error("invalid profile integer")
    }
    fun text(): String { require(end - at <= 4096); return String(bytes, at, end-at, Charsets.UTF_8) }
    fun fields(visit: (Int, Int, ProtoCursor) -> Unit) {
        while (remaining()) {
            val tag = number(); val kind = (tag and 7).toInt(); val key = (tag ushr 3).toInt()
            require(key > 0)
            if (kind == 0) {
                val start = at; number(); visit(key, kind, ProtoCursor(bytes, start, at)); continue
            }
            val size = when (kind) { 1 -> 8; 2 -> number().also { require(it >= 0 && it <= end - at) }.toInt(); 5 -> 4; else -> error("invalid profile field") }
            require(size <= end - at)
            val field = ProtoCursor(bytes, at, at + size); at += size
            visit(key, kind, field)
        }
    }
}
