package app.marten.client.bg

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import app.marten.client.constant.Status
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * Persisted, privacy-safe evidence for Quick Settings connection attempts.
 *
 * This deliberately records only lifecycle enums, monotonic request/revision
 * numbers and coarse Android network state. It must never receive a profile,
 * endpoint, subscription, carrier, SIM identifier or exception message.
 */
object QuickSettingsDiagnostics {
    private const val TAG = "MartenQuickSettings"
    private const val CURRENT_LOG_NAME = "quick-settings.log"
    private const val OLD_LOG_NAME = "quick-settings.log.old"
    private const val MAX_LOG_BYTES = 256 * 1024L
    private val safeToken = Regex("^[a-z0-9_]{1,48}$")
    private val requestSequence = AtomicLong(System.currentTimeMillis() * 1_000L)
    private val writer = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "marten-quick-settings-diagnostics").apply { isDaemon = true }
    }

    fun nextRequestId(): Long = requestSequence.incrementAndGet()

    fun record(
        context: Context,
        component: String,
        event: String,
        requestId: Long,
        outcome: String,
        status: Status? = null,
        generation: Long = 0L,
        revision: Long = 0L,
    ) {
        val safeComponent = component.takeIf(safeToken::matches) ?: "unknown"
        val safeEvent = event.takeIf(safeToken::matches) ?: "unknown"
        val safeOutcome = outcome.takeIf(safeToken::matches) ?: "unknown"
        val safeStatus = status?.name?.lowercase() ?: "unknown"
        val safeRequestId = maxOf(0L, requestId)
        val safeGeneration = maxOf(0L, generation)
        val safeRevision = maxOf(0L, revision)
        val eventTimeMs = System.currentTimeMillis()
        val eventElapsedMs = SystemClock.elapsedRealtime()
        val applicationContext = context.applicationContext
        writer.execute {
            runCatching {
                // Android may briefly serialize ConnectivityManager Binder
                // calls while a VPN Network is appearing or disappearing.
                // Diagnostics must never extend a Quick Settings request, so
                // snapshot collection and persistence share the ordered
                // background writer. Captured timestamps preserve event time.
                val network = readNetworkSnapshot(applicationContext)
                val snapshotLagMs =
                    (SystemClock.elapsedRealtime() - eventElapsedMs).coerceAtLeast(0L)
                val line = "MARTEN_QS_LIFECYCLE time_ms=$eventTimeMs " +
                    "elapsed_ms=$eventElapsedMs component=$safeComponent event=$safeEvent " +
                    "request=$safeRequestId status=$safeStatus " +
                    "outcome=$safeOutcome generation=$safeGeneration " +
                    "revision=$safeRevision transport=${network.transport} " +
                    "validated=${network.validated} internet=${network.internet} " +
                    "metered=${network.metered} airplane=${network.airplane} " +
                    "snapshot_lag_ms=$snapshotLagMs"
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
                // Do not log the exception: filesystem errors may contain a
                // private device path. The fixed marker is enough to show that
                // persistence failed while logcat remains available.
                Log.w(TAG, "MARTEN_QS_LIFECYCLE component=diagnostics event=persist outcome=failed")
            }
        }
    }

    private fun readNetworkSnapshot(context: Context): NetworkSnapshot {
        val airplane = runCatching {
            Settings.Global.getInt(context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1
        }.getOrDefault(false)
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
            ?: return NetworkSnapshot("none", false, false, false, airplane)
        return runCatching {
            val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
            val transport = when {
                capabilities == null -> "none"
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                else -> "other"
            }
            NetworkSnapshot(
                transport = transport,
                validated = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true,
                internet = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true,
                metered = connectivity.isActiveNetworkMetered,
                airplane = airplane,
            )
        }.getOrElse {
            NetworkSnapshot("unknown", false, false, false, airplane)
        }
    }

    private fun rotate(current: File, archived: File) {
        if (archived.exists()) archived.delete()
        if (!current.renameTo(archived)) {
            current.copyTo(archived, overwrite = true)
            current.writeBytes(byteArrayOf())
        }
    }

    private data class NetworkSnapshot(
        val transport: String,
        val validated: Boolean,
        val internet: Boolean,
        val metered: Boolean,
        val airplane: Boolean,
    )
}
