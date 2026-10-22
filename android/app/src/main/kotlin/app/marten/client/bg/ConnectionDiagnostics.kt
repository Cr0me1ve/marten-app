package app.marten.client.bg

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * Persisted, privacy-safe evidence for Android connection admission.
 *
 * Only fixed lifecycle/stage/category tokens, monotonic counters, durations,
 * and coarse transport state are accepted. Callers must never pass an endpoint,
 * profile, subscription, carrier/SIM identity, credential, exception text,
 * Android Network handle, or file path.
 */
object ConnectionDiagnostics {
    private const val TAG = "MartenConnection"
    private const val CURRENT_LOG_NAME = "connection-diagnostics.log"
    private const val OLD_LOG_NAME = "connection-diagnostics.log.old"
    private const val MAX_LOG_BYTES = 512 * 1024L
    private val safeToken = Regex("^[a-z0-9_]{1,48}$")
    private val attemptSequence = AtomicLong(System.currentTimeMillis() * 1_000L)
    private val writer = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "marten-connection-diagnostics").apply { isDaemon = true }
    }

    fun nextAttemptId(): Long = attemptSequence.incrementAndGet()

    fun record(
        context: Context,
        component: String,
        event: String,
        outcome: String,
        requestId: Long = 0L,
        generation: Long = 0L,
        attempt: Long = 0L,
        durationMs: Long = 0L,
        stage: String = "none",
        category: String = "none",
        networkGeneration: Long = 0L,
        tunGeneration: Long = 0L,
    ) {
        val safeComponent = component.takeIf(safeToken::matches) ?: "unknown"
        val safeEvent = event.takeIf(safeToken::matches) ?: "unknown"
        val safeOutcome = outcome.takeIf(safeToken::matches) ?: "unknown"
        val safeStage = stage.takeIf(safeToken::matches) ?: "unknown"
        val safeCategory = category.takeIf(safeToken::matches) ?: "unknown"
        val safeRequestId = maxOf(0L, requestId)
        val safeGeneration = maxOf(0L, generation)
        val safeAttempt = maxOf(0L, attempt)
        val safeDurationMs = maxOf(0L, durationMs)
        val safeNetworkGeneration = maxOf(0L, networkGeneration)
        val safeTunGeneration = maxOf(0L, tunGeneration)
        val eventTimeMs = System.currentTimeMillis()
        val eventElapsedMs = SystemClock.elapsedRealtime()
        val applicationContext = context.applicationContext
        writer.execute {
            runCatching {
                // ConnectivityManager and Settings are Binder-backed and can
                // occasionally stall for seconds while Android is publishing
                // a new VPN Network. Keep both them and file I/O off the
                // connection admission path. The captured timestamps retain
                // the actual event time; snapshot_lag_ms makes delayed
                // sampling explicit without exposing network identity.
                val network = readNetworkSnapshot(applicationContext)
                val snapshotLagMs =
                    (SystemClock.elapsedRealtime() - eventElapsedMs).coerceAtLeast(0L)
                val line = "MARTEN_CONNECTION_LIFECYCLE time_ms=$eventTimeMs " +
                    "elapsed_ms=$eventElapsedMs component=$safeComponent event=$safeEvent " +
                    "request=$safeRequestId outcome=$safeOutcome " +
                    "generation=$safeGeneration attempt=$safeAttempt " +
                    "duration_ms=$safeDurationMs stage=$safeStage category=$safeCategory " +
                    "network_generation=$safeNetworkGeneration " +
                    "tun_generation=$safeTunGeneration " +
                    "active_transport=${network.activeTransport} " +
                    "physical_transport=${network.physicalTransport} " +
                    "physical_available=${network.physicalAvailable} " +
                    "physical_validated=${network.physicalValidated} " +
                    "airplane=${network.airplane} snapshot_lag_ms=$snapshotLagMs"
                Log.i(TAG, line)
                val directory = applicationContext.getExternalFilesDir(null) ?: applicationContext.filesDir
                if (!directory.exists()) directory.mkdirs()
                val current = File(directory, CURRENT_LOG_NAME)
                val archived = File(directory, OLD_LOG_NAME)
                val encoded = "$line\n".toByteArray(Charsets.UTF_8)
                if (current.exists() && current.length() + encoded.size > MAX_LOG_BYTES) {
                    rotate(current, archived)
                }
                current.appendBytes(encoded)
            }.onFailure {
                // A filesystem exception may include a private device path.
                Log.w(TAG, "MARTEN_CONNECTION_LIFECYCLE component=diagnostics event=persist outcome=failed")
            }
        }
    }

    private fun readNetworkSnapshot(context: Context): NetworkSnapshot {
        val airplane = runCatching {
            Settings.Global.getInt(context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1
        }.getOrDefault(false)
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
            ?: return NetworkSnapshot("none", "none", false, false, airplane)
        return runCatching {
            val activeCapabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
            val physicalCapabilities = connectivity.allNetworks.mapNotNull { network ->
                connectivity.getNetworkCapabilities(network)?.takeIf { capabilities ->
                    !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED) &&
                        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                }
            }
            val physicalTransports = physicalCapabilities.map(::transport).toSet()
            val physicalTransport = when (physicalTransports.size) {
                0 -> "none"
                1 -> physicalTransports.first()
                else -> "multiple"
            }
            NetworkSnapshot(
                activeTransport = transport(activeCapabilities),
                physicalTransport = physicalTransport,
                physicalAvailable = physicalCapabilities.isNotEmpty(),
                physicalValidated = physicalCapabilities.any {
                    it.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                },
                airplane = airplane,
            )
        }.getOrElse {
            NetworkSnapshot("unknown", "unknown", false, false, airplane)
        }
    }

    private fun transport(capabilities: NetworkCapabilities?): String = when {
        capabilities == null -> "none"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
        else -> "other"
    }

    private fun rotate(current: File, archived: File) {
        if (archived.exists()) archived.delete()
        if (!current.renameTo(archived)) {
            current.copyTo(archived, overwrite = true)
            current.writeBytes(byteArrayOf())
        }
    }

    private data class NetworkSnapshot(
        val activeTransport: String,
        val physicalTransport: String,
        val physicalAvailable: Boolean,
        val physicalValidated: Boolean,
        val airplane: Boolean,
    )
}
