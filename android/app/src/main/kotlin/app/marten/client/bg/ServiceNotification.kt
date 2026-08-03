package app.marten.client.bg

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import androidx.annotation.StringRes
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.MutableLiveData
import app.marten.client.Application
import app.marten.client.MainActivity
import app.marten.client.R
import app.marten.client.Settings
import app.marten.client.constant.Action
import app.marten.client.constant.Status
import app.marten.client.utils.GrpcClientProvider
import app.marten.core.api.v2.hcommon.Empty
import app.marten.core.api.v2.hcore.CoreClient
import app.marten.core.api.v2.hcore.SystemInfo
import app.marten.core.libbox.Libbox
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicLong

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
        val intent = Intent(service, Settings.serviceClass()).apply {
            action = Action.SERVICE_CONNECT
        }
        val connectFlags =
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0) or
                PendingIntent.FLAG_CANCEL_CURRENT
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(service, 3, intent, connectFlags)
        } else {
            PendingIntent.getService(service, 3, intent, connectFlags)
        }
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
        if (Settings.dynamicNotification && checkPermission()) {
            startListenSystemInfo()
            withContext(Dispatchers.Main) {
                registerReceiver()
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

    fun updateStatus(previous: SystemInfo, current: SystemInfo) {
        val uplink = current.uplink_total - previous.uplink_total
        val downlink = current.downlink_total - previous.downlink_total
        val outbound = displayName(current.current_outbound)
        val speed = "${Libbox.formatBytes(uplink)}/s ↑\t${Libbox.formatBytes(downlink)}/s ↓"
        val title = displayName(current.current_profile).ifBlank { outbound }.ifBlank { "Marten" }
        Application.notificationManager.notify(
            serviceNotificationId,
            runningBuilder(title, speed).build(),
        )
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_SCREEN_ON -> {
                startListenSystemInfo()
            }

            Intent.ACTION_SCREEN_OFF -> {
                stopListenSystemInfo()
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
        stopListenSystemInfo()
        unregisterScreenReceiver()
    }

    private fun closeForeground(removeNotification: Boolean) {
        notificationUpdateGate.closeForeground()
        stopListenSystemInfo()
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

    fun startListenSystemInfo() {
        Log.d("notification", "startListenSystemInfo")
        val streamGeneration = notificationUpdateGate.beginStreaming()
        streamingJob?.cancel()

        streamingJob = streamingCoroutineScope.launch(Dispatchers.IO) {
            Log.d("notification", "startListenSystemInfo-launch")

            val coreClient = GrpcClientProvider.grpcClient.create(CoreClient::class)

            try {
                var previous = readSystemInfo(coreClient)

                while (isActive) {
                    delay(1_000)
                    val current = readSystemInfo(coreClient)
                    withContext(Dispatchers.Main.immediate) {
                        if (notificationUpdateGate.permitsUpdate(streamGeneration)) {
                            updateStatus(previous, current)
                        }
                    }
                    previous = current
                }
            } catch (e: CancellationException) {
                Log.d("notification", "SystemInfo polling cancelled")
            } catch (e: Exception) {
                Log.e("notification", "SystemInfo polling failed", e)
            }
        }
    }

    private fun readSystemInfo(coreClient: CoreClient): SystemInfo {
        val (sink, source) = coreClient.GetSystemInfo().executeBlocking()
        return try {
            sink.write(Empty())
            // Complete the single request before waiting for the first item of
            // the server stream. Keeping the sink open deadlocks Wire/Go gRPC.
            sink.close()
            source.read() ?: SystemInfo()
        } finally {
            runCatching { sink.close() }
            runCatching { source.close() }
        }
    }

    fun stopListenSystemInfo() {
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
