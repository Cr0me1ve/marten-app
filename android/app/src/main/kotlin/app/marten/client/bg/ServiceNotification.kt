package app.marten.client.bg

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.TrafficStats
import android.os.Build
import android.os.Process
import android.os.SystemClock
import android.util.Log
import androidx.annotation.StringRes
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.MutableLiveData
import app.marten.client.Application
import app.marten.client.MainActivity
import app.marten.client.R
import app.marten.client.Settings
import app.marten.client.VpnPermissionActivity
import app.marten.client.constant.Action
import app.marten.client.constant.Status
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicLong
import java.util.Locale

/** Presentation must remain usable even when the native runtime cannot answer. */
internal fun formatNotificationBytes(bytes: Long): String {
    val value = bytes.coerceAtLeast(0L)
    if (value < 10L) return "$value B"
    val units = arrayOf("B", "kB", "MB", "GB", "TB", "PB", "EB")
    var scaled = value.toDouble()
    var unit = 0
    while (scaled >= 1_000.0 && unit < units.lastIndex) {
        scaled /= 1_000.0
        unit++
    }
    val rounded = kotlin.math.floor(scaled * 10.0 + 0.5) / 10.0
    return String.format(Locale.ROOT, if (rounded < 10.0) "%.1f %s" else "%.0f %s", rounded, units[unit])
}

internal fun shouldStreamDynamicNotificationUpdates(
    dynamicNotificationEnabled: Boolean,
    notificationPermissionGranted: Boolean,
    deviceInteractive: Boolean,
): Boolean =
    dynamicNotificationEnabled && notificationPermissionGranted && deviceInteractive

internal fun shouldPublishDynamicNotificationUpdate(
    platformStatus: Status?,
    gatePermitsUpdate: Boolean,
): Boolean = gatePermitsUpdate && platformStatus == Status.Started

internal const val DYNAMIC_NOTIFICATION_MIN_UPDATE_INTERVAL_MS = 5_000L

internal fun dynamicNotificationBytesPerSecond(deltaBytes: Long, elapsedMs: Long): Long {
    if (deltaBytes <= 0L || elapsedMs <= 0L) return 0L
    return (deltaBytes.toDouble() * 1_000.0 / elapsedMs.toDouble())
        .coerceAtMost(Long.MAX_VALUE.toDouble())
        .toLong()
}

internal data class DynamicNotificationTrafficSample(
    val uplinkTotal: Long,
    val downlinkTotal: Long,
    val capturedAtMs: Long,
)

internal fun dynamicNotificationTrafficDelta(previousTotal: Long, currentTotal: Long): Long {
    if (previousTotal < 0L || currentTotal < previousTotal) return 0L
    return currentTotal - previousTotal
}

internal class NotificationUpdateGate {
    private val streamingGeneration = AtomicLong()

    @Volatile
    private var foregroundActive = false

    fun openForeground() {
        foregroundActive = true
    }

    fun beginStreaming(): Long = streamingGeneration.incrementAndGet()

    fun stopStreaming() {
        streamingGeneration.incrementAndGet()
    }

    fun closeForeground() {
        foregroundActive = false
        stopStreaming()
    }

    fun permitsUpdate(generation: Long): Boolean =
        foregroundActive && streamingGeneration.get() == generation
}

class ServiceNotification(private val status: MutableLiveData<Status>, private val service: Service) : BroadcastReceiver() {
    companion object {
        private const val serviceNotificationId = 1
        private const val stoppedNotificationId = 2
        private const val notificationChannel = "service"
        val flags =
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0) or
                PendingIntent.FLAG_UPDATE_CURRENT

        fun checkPermission(): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                return true
            }
            return Application.notification.areNotificationsEnabled()
        }
    }

    private val streamingCoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val notificationUpdateGate = NotificationUpdateGate()
    private var receiverRegistered = false
    private var streamingJob: Job? = null
    private var runningTitle = "Marten"
    private var lastDynamicContent: String? = null

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Application.notification.getNotificationChannel(notificationChannel)?.setShowBadge(false)
            Application.notification.createNotificationChannel(
                NotificationChannel(
                    notificationChannel,
                    service.getString(R.string.notification_channel_name),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    setShowBadge(false)
                },
            )
        }
    }

    private fun baseBuilder(ongoing: Boolean): NotificationCompat.Builder {
        return NotificationCompat.Builder(service, notificationChannel)
            .setShowWhen(false)
            .setOngoing(ongoing)
            .setContentTitle("Marten")
            .setOnlyAlertOnce(true)
            .setSmallIcon(R.drawable.ic_stat_logo_sharp)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openAppIntent())
            .setBadgeIconType(NotificationCompat.BADGE_ICON_NONE)
            .setNumber(0)
            .setPriority(NotificationCompat.PRIORITY_LOW)
    }

    private fun runningBuilder(title: String, content: String): NotificationCompat.Builder {
        return baseBuilder(ongoing = true)
            .setContentTitle(title.ifBlank { "Marten" })
            .setContentText(content)
            .setStyle(NotificationCompat.BigTextStyle().bigText(content))
            .addAction(
                NotificationCompat.Action.Builder(
                    0,
                    service.getText(R.string.stop),
                    stopIntent(),
                ).build(),
            )
    }

    private fun stoppedBuilder(serverName: String): NotificationCompat.Builder {
        val title = displayName(serverName).ifBlank { "Marten" }
        val content = service.getString(R.string.status_stopped)
        return baseBuilder(ongoing = false)
            .setContentTitle(title)
            .setContentText(content)
            .addAction(
                NotificationCompat.Action.Builder(
                    0,
                    service.getText(R.string.connect),
                    connectIntent(),
                ).build(),
            )
    }

    private fun openAppIntent(): PendingIntent {
        return PendingIntent.getActivity(
            service,
            0,
            Intent(service, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flags,
        )
    }

    private fun connectIntent(): PendingIntent {
        return VpnPermissionActivity.pendingIntent(
            service,
            3,
            source = VpnPermissionActivity.SOURCE_NOTIFICATION,
        )
    }

    private fun stopIntent(): PendingIntent {
        return PendingIntent.getBroadcast(
            service,
            2,
            Intent(Action.SERVICE_CLOSE)
                .setPackage(Application.application.packageName)
                .putExtra(Action.EXTRA_KEEP_NOTIFICATION, true),
            flags,
        )
    }

    fun show(profileName: String, @StringRes contentTextId: Int) {
        ensureChannel()
        Application.notificationManager.cancel(stoppedNotificationId)
        val title = displayName(profileName).ifBlank { "Marten" }
        val content = service.getString(contentTextId)
        runningTitle = title
        lastDynamicContent = null
        notificationUpdateGate.openForeground()
        service.startForeground(serviceNotificationId, runningBuilder(title, content).build())
    }

    fun showStopped(serverName: String) {
        if (!checkPermission()) {
            close(removeNotification = true)
            return
        }
        ensureChannel()
        closeForeground(removeNotification = true)
        Application.notificationManager.notify(stoppedNotificationId, stoppedBuilder(serverName).build())
    }

    suspend fun start() {
        val permissionGranted = checkPermission()
        if (Settings.dynamicNotification && permissionGranted) {
            withContext(Dispatchers.Main.immediate) {
                registerReceiver()
                // A service can be restored while the display is already off,
                // in which case Android sends no new SCREEN_OFF broadcast.
                // Never start traffic sampling solely because the service was
                // created; it is presentation-only work and must not run during sleep.
                if (
                    shouldStreamDynamicNotificationUpdates(
                        dynamicNotificationEnabled = Settings.dynamicNotification,
                        notificationPermissionGranted = permissionGranted,
                        deviceInteractive = Application.powerManager.isInteractive,
                    )
                ) {
                    startTrafficUpdates()
                } else {
                    stopTrafficUpdates()
                }
            }
        }
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        service.registerReceiver(this, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        })
        receiverRegistered = true
    }

    private fun updateStatus(
        previous: DynamicNotificationTrafficSample,
        current: DynamicNotificationTrafficSample,
    ) {
        val elapsedMs = current.capturedAtMs - previous.capturedAtMs
        val uplink = dynamicNotificationBytesPerSecond(
            dynamicNotificationTrafficDelta(previous.uplinkTotal, current.uplinkTotal),
            elapsedMs,
        )
        val downlink = dynamicNotificationBytesPerSecond(
            dynamicNotificationTrafficDelta(previous.downlinkTotal, current.downlinkTotal),
            elapsedMs,
        )
        val speed = "${formatNotificationBytes(uplink)}/s ↑\t${formatNotificationBytes(downlink)}/s ↓"
        if (lastDynamicContent == speed) return
        lastDynamicContent = speed
        Application.notificationManager.notify(
            serviceNotificationId,
            runningBuilder(runningTitle, speed).build(),
        )
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_SCREEN_ON -> {
                if (
                    shouldStreamDynamicNotificationUpdates(
                        dynamicNotificationEnabled = Settings.dynamicNotification,
                        notificationPermissionGranted = checkPermission(),
                        deviceInteractive = Application.powerManager.isInteractive,
                    )
                ) {
                    startTrafficUpdates()
                } else {
                    stopTrafficUpdates()
                }
            }

            Intent.ACTION_SCREEN_OFF -> {
                stopTrafficUpdates()
            }
        }
    }

    fun close(removeNotification: Boolean = true) {
        closeForeground(removeNotification)
        if (removeNotification) {
            Application.notificationManager.cancel(stoppedNotificationId)
        }
    }

    fun stopDynamicUpdates() {
        stopTrafficUpdates()
        unregisterScreenReceiver()
    }

    private fun closeForeground(removeNotification: Boolean) {
        notificationUpdateGate.closeForeground()
        stopTrafficUpdates()
        ServiceCompat.stopForeground(
            service,
            if (removeNotification) ServiceCompat.STOP_FOREGROUND_REMOVE else ServiceCompat.STOP_FOREGROUND_DETACH,
        )
        if (removeNotification) {
            Application.notificationManager.cancel(serviceNotificationId)
        }
        unregisterScreenReceiver()
    }

    private fun unregisterScreenReceiver() {
        if (receiverRegistered) {
            runCatching {
                service.unregisterReceiver(this)
            }.onFailure {
                Log.w("notification", "failed to unregister screen receiver", it)
            }
            receiverRegistered = false
        }
    }

    fun startTrafficUpdates() {
        Log.d("notification", "startTrafficUpdates")
        val streamGeneration = notificationUpdateGate.beginStreaming()
        streamingJob?.cancel()

        streamingJob = streamingCoroutineScope.launch(Dispatchers.IO) {
            Log.d("notification", "startTrafficUpdates-launch")

            try {
                streamUidTraffic(streamGeneration)
            } catch (e: CancellationException) {
                Log.d("notification", "traffic updates cancelled")
            } catch (e: Exception) {
                Log.e("notification", "traffic updates failed", e)
            }
        }
    }

    private suspend fun streamUidTraffic(streamGeneration: Long) {
        var previous = readUidTrafficSample()
        while (currentCoroutineContext().isActive) {
            delay(DYNAMIC_NOTIFICATION_MIN_UPDATE_INTERVAL_MS)
            val current = readUidTrafficSample()
            withContext(Dispatchers.Main.immediate) {
                if (
                    shouldPublishDynamicNotificationUpdate(
                        platformStatus = status.value,
                        gatePermitsUpdate = notificationUpdateGate.permitsUpdate(streamGeneration),
                    )
                ) {
                    updateStatus(previous, current)
                }
            }
            previous = current
        }
    }

    private fun readUidTrafficSample(): DynamicNotificationTrafficSample =
        DynamicNotificationTrafficSample(
            // The core's protected transport sockets run under this UID, so kernel
            // counters provide notification throughput without waking the gRPC core.
            uplinkTotal = TrafficStats.getUidTxBytes(Process.myUid()),
            downlinkTotal = TrafficStats.getUidRxBytes(Process.myUid()),
            capturedAtMs = SystemClock.elapsedRealtime(),
        )

    fun stopTrafficUpdates() {
        try {
            notificationUpdateGate.stopStreaming()
            streamingJob?.cancel()
            streamingJob = null
        } catch (e: Exception) {
            Log.d("notification", "Exception $e")
        }
    }

    private fun displayName(value: String?): String {
        val raw = value?.trim().orEmpty()
        if (raw.isEmpty()) return ""
        return raw.split("§").first().trim()
    }
}
