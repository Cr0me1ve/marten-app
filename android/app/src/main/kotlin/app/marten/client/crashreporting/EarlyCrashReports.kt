package app.marten.client.crashreporting

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import java.security.MessageDigest

/** Local-only startup diagnostics. Never constructs Firebase, opens a socket or schedules work. */
internal object EarlyCrashReports {
    private const val MAX_BYTES = 16 * 1024
    private const val HISTORY_LIMIT = 32
    private const val MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000
    private val token = Regex("[^A-Za-z0-9_.$<>]")
    @Volatile private var sdkReady = false
    @Volatile private var collectionAllowed: Boolean? = null
    private var installed = false

    fun directory(context: Context): File = File(context.noBackupFilesDir, "early-crash-reports")
    private fun preferences(context: Context) = context.getSharedPreferences("local_crash_capture", Context.MODE_PRIVATE)
    private fun enabled(context: Context) = collectionAllowed ?: context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        .getBoolean("flutter.enable_analytics", true)

    fun setCollectionEnabled(context: Context, enabled: Boolean) {
        collectionAllowed = enabled
        if (!enabled) clear(context)
    }
    private fun file(context: Context): File = File(directory(context), if (app.marten.client.Application.isCoreProcess) "core.json" else "app.json")

    @Synchronized fun install(context: Context) {
        if (installed) return
        installed = true
        // Do not discard retained exits on upgrade. Only opt-out establishes a
        // capture cutoff; the independently bounded Android history may predate us.
        if (!enabled(context)) clear(context)
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                if (enabled(context)) {
                    val frames = error.stackTrace.take(32).mapIndexed { index, frame ->
                        "#$index      ${safe(frame.className)}.${safe(frame.methodName)} (package:marten/native_startup/native.dart:${frame.lineNumber.coerceAtLeast(1)}:1)"
                    }.joinToString("\n")
                    val report = JSONObject()
                        .put("type", safe(error.javaClass.name))
                        .put("stack", frames)
                        .put("fatal", true)
                        .put("reason", "android_early_uncaught")
                        .put("timestamp_ms", System.currentTimeMillis())
                        .put("sdk_covered", sdkReady)
                    val destination = file(context)
                    destination.parentFile?.mkdirs()
                    val temporary = File(destination.path + ".tmp")
                    temporary.outputStream().use { output ->
                        output.write(report.toString().toByteArray(Charsets.UTF_8).take(MAX_BYTES).toByteArray())
                        output.fd.sync()
                    }
                    check(temporary.renameTo(destination))
                }
            } catch (_: Throwable) {
                // Failure to save diagnostics must not replace Android's original crash handling.
            } finally {
                previous?.uncaughtException(thread, error)
            }
        }
    }

    private fun safe(value: String): String = value.replace(token, "_").take(160)

    @Synchronized fun markSdkReady(context: Context) {
        if (sdkReady) return
        sdkReady = true
        notePhase(context, "sdk_ready")
    }

    private fun identity(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }

    @Synchronized fun acknowledge(context: Context, ids: List<String>) {
        for (name in listOf("app.json", "core.json")) {
            val source = File(directory(context), name)
            runCatching {
                if (source.exists() && source.length() <= MAX_BYTES) {
                    val bytes = source.readBytes()
                    if ("$name:${identity(bytes)}" in ids) {
                        // SDK acceptance is not server delivery. Keep bounded local evidence.
                        writeAtomic(File(directory(context), name.replace(".json", "-last.json")), bytes)
                        source.delete()
                    }
                }
            }
        }
        val watermark = ids.filter { it.startsWith("exit:") }.mapNotNull { it.substringAfter("exit:").substringBefore(':').toLongOrNull() }.maxOrNull()
        if (watermark != null) {
            val prefs = preferences(context)
            prefs.edit().putLong("exit_watermark", maxOf(watermark, prefs.getLong("exit_watermark", 0))).commit()
        }
    }

    @Synchronized fun clear(context: Context) {
        for (name in listOf("app.json", "core.json", "app-last.json", "core-last.json", "app-state.json", "core-state.json", "expected-exits.json").flatMap { listOf(it, "$it.tmp") }) {
            File(directory(context), name).delete()
        }
        preferences(context).edit().putLong("exit_watermark", System.currentTimeMillis())
            .putLong("exit_capture_since", System.currentTimeMillis()).commit()
    }

    /** Peek then acknowledge only after the receiving SDK accepts all records. Runs on platform background queue. */
    @Synchronized fun read(context: Context): List<Map<String, Any>> {
        if (!enabled(context)) { clear(context); return emptyList() }
        val reports = mutableListOf<Map<String, Any>>()
        for (name in listOf("app.json", "core.json")) {
            val source = File(directory(context), name)
            if (!source.exists()) continue
            runCatching {
                check(source.length() <= MAX_BYTES)
                val bytes = source.readBytes()
                check(bytes.size <= MAX_BYTES)
                val json = JSONObject(bytes.toString(Charsets.UTF_8))
                if (!json.optBoolean("sdk_covered", false)) {
                    reports.add(mapOf("id" to "$name:${identity(bytes)}", "type" to json.getString("type"), "stack" to json.getString("stack"),
                        "reason" to json.getString("reason"), "fatal" to json.getBoolean("fatal")))
                }
            }.onFailure { source.delete() }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val watermark = preferences(context).getLong("exit_watermark", 0)
            historicalExits(context).second.filter { it.timestamp > watermark }.asReversed().forEach { exit ->
                val summary = summarizeExit(context, exit)
                val category = summary["category"] as String
                val role = summary["process_role"] as String
                if (role != "other" && category in abnormalCategories && summary["expected"] != true) {
                    // This is system evidence, never a fabricated fatal stack. OS kills
                    // are not Crashlytics crashes; record a distinct diagnostic event.
                    val reason = "android_process_exit_${role}_$category"
                    reports.add(mapOf("id" to "exit:${exit.timestamp}:$role:$category", "type" to reason,
                        "stack" to "", "reason" to reason, "fatal" to false,
                        "message" to "historical=true timestamp_ms=${exit.timestamp} status=${exit.status} source_version=unknown"))
                }
            }
        }
        return reports
    }

    private val abnormalCategories = setOf("java_crash", "native_crash", "anr", "low_memory", "signaled",
        "excessive_resource", "dependency_died", "initialization_failure", "other")

    private fun writeAtomic(destination: File, bytes: ByteArray) {
        check(bytes.size <= MAX_BYTES)
        destination.parentFile?.mkdirs()
        val temporary = File(destination.path + ".tmp")
        temporary.outputStream().use { output -> output.write(bytes); output.fd.sync() }
        check(temporary.renameTo(destination))
    }

    @Synchronized fun notePhase(context: Context, phase: String) {
        if (!enabled(context) || !Regex("^[a-z][a-z0-9_]{0,63}$").matches(phase)) return
        runCatching {
            writeAtomic(File(directory(context), if (app.marten.client.Application.isCoreProcess) "core-state.json" else "app-state.json"),
                JSONObject().put("phase", phase).put("timestamp_ms", System.currentTimeMillis())
                    .put("sdk_ready", sdkReady).put("version_code", app.marten.client.BuildConfig.VERSION_CODE)
                    .toString().toByteArray(Charsets.UTF_8))
        }
    }

    /** Exact PID stays private and is used solely to identify our intentional core retirement. */
    @Synchronized fun markExpectedCoreExit(context: Context, pid: Int) {
        if (!enabled(context) || pid <= 0) return
        runCatching {
            val destination = File(directory(context), "expected-exits.json")
            val old = if (destination.length() in 1..MAX_BYTES) JSONArray(destination.readText()) else JSONArray()
            val entries = (0 until old.length()).map { old.getJSONObject(it) }.takeLast(HISTORY_LIMIT - 1)
            val updated = JSONArray()
            entries.forEach(updated::put)
            updated.put(JSONObject().put("pid", pid).put("timestamp_ms", System.currentTimeMillis()))
            writeAtomic(destination, updated.toString().toByteArray(Charsets.UTF_8))
        }
    }

    private fun expectedCoreExit(context: Context, exit: ApplicationExitInfo): Boolean {
        if (exit.reason != ApplicationExitInfo.REASON_SIGNALED || exit.status != 9 ||
            exit.processName != context.packageName + ":core") return false
        return runCatching {
            val source = File(directory(context), "expected-exits.json")
            if (source.length() !in 1..MAX_BYTES) return@runCatching false
            val entries = JSONArray(source.readText())
            (0 until entries.length()).any { index ->
                val entry = entries.getJSONObject(index)
                entry.optInt("pid") == exit.pid && exit.timestamp - entry.optLong("timestamp_ms") in 0..30_000
            }
        }.getOrDefault(false)
    }

    private fun historicalExits(context: Context): Pair<String, List<ApplicationExitInfo>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return "unsupported" to emptyList()
        return try {
            val manager = context.getSystemService(ActivityManager::class.java)
                ?: return "query_failed" to emptyList()
            val cutoff = maxOf(System.currentTimeMillis() - MAX_AGE_MS,
                preferences(context).getLong("exit_capture_since", 0))
            "available" to manager.getHistoricalProcessExitReasons(null, 0, HISTORY_LIMIT)
                .filter { it.timestamp >= cutoff }.take(HISTORY_LIMIT)
        } catch (_: Throwable) { "query_failed" to emptyList() }
    }

    /** Uses names only to classify a fixed role, never exports names/IDs/descriptions/traces. */
    internal fun summarizeExit(context: Context, exit: ApplicationExitInfo): Map<String, Any> {
        val category = when (exit.reason) {
            ApplicationExitInfo.REASON_CRASH -> "java_crash"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
            ApplicationExitInfo.REASON_ANR -> "anr"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
            ApplicationExitInfo.REASON_SIGNALED -> "signaled"
            ApplicationExitInfo.REASON_EXIT_SELF -> "exit_self"
            ApplicationExitInfo.REASON_USER_REQUESTED -> "user_requested"
            ApplicationExitInfo.REASON_USER_STOPPED -> "user_stopped"
            ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "package_updated"
            ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "package_state_changed"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resource"
            ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency_died"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "initialization_failure"
            ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "permission_change"
            ApplicationExitInfo.REASON_FREEZER -> "freezer"
            ApplicationExitInfo.REASON_OTHER -> "other"
            else -> "unknown"
        }
        val role = when (exit.processName) {
            context.packageName -> "app"
            context.packageName + ":core" -> "core"
            context.packageName + ":diagnostics" -> "diagnostics"
            else -> "other"
        }
        return mapOf("timestamp_ms" to exit.timestamp, "process_role" to role, "category" to category,
            "status" to exit.status, "importance" to exit.importance,
            "pss_kb" to exit.pss.coerceAtLeast(0), "rss_kb" to exit.rss.coerceAtLeast(0),
            "expected" to expectedCoreExit(context, exit))
    }

    /** Local-only and independent of SDK readiness/admission. Never acknowledges evidence. */
    @Synchronized fun snapshot(context: Context): String {
        val allowed = enabled(context)
        val buffer = StringBuilder("MARTEN_CRASH_DIAGNOSTICS schema=1 collection=${if (allowed) "enabled" else "disabled"} sdk_ready=$sdkReady network_admitted=${NativeCrashDiagnostics.isNetworkAdmissionAllowed()}\n")
        if (!allowed) return buffer.append("history_status=disabled\n").toString()
        buffer.append("android_sdk=${Build.VERSION.SDK_INT} history_scope=system_retained max_records=$HISTORY_LIMIT max_age_days=7 incomplete_possible=true trace_scope=system_categories_only\n")
        for (role in listOf("app", "core")) {
            val stateFile = File(directory(context), "$role-state.json")
            runCatching {
                if (stateFile.length() in 1..MAX_BYTES) {
                    val state = JSONObject(stateFile.readText())
                    buffer.append("MARTEN_REPORTING process_role=$role phase=${safe(state.getString("phase"))} timestamp_ms=${state.optLong("timestamp_ms")} sdk_ready=${state.optBoolean("sdk_ready")} version_code=${state.optInt("version_code")} scope=last_record\n")
                }
            }
            for (name in listOf("$role-last.json", "$role.json")) {
                runCatching {
                    val source = File(directory(context), name)
                    if (source.length() in 1..MAX_BYTES) {
                        val report = JSONObject(source.readText())
                        buffer.append("MARTEN_LOCAL_EXCEPTION process_role=$role timestamp_ms=${report.optLong("timestamp_ms")} type=${safe(report.getString("type"))} sdk_covered=${report.optBoolean("sdk_covered")}\n")
                        // Frames contain only structural class/method/line captured above.
                        report.getString("stack").lineSequence().take(32).forEach { line ->
                            if (Regex("""^#[0-9]+ +[A-Za-z0-9_.$<>]+ \(package:marten/native_startup/native\.dart:[0-9]+:1\)$""").matches(line)) buffer.append(line).append('\n')
                        }
                    }
                }
            }
        }
        val (status, exits) = historicalExits(context)
        buffer.append("history_status=$status count=${exits.size}\n")
        exits.forEach { exit -> buffer.append("MARTEN_PROCESS_EXIT ").append(summarizeExit(context, exit).entries.joinToString(" ") { "${it.key}=${it.value}" }).append('\n') }
        return buffer.toString()
    }
}
