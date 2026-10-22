package app.marten.client

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.lifecycle.Observer
import app.marten.client.bg.BoxService
import app.marten.client.bg.ServiceLifecycleOwnership
import app.marten.client.constant.Alert
import app.marten.client.constant.Status
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.JSONMethodCodec
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

data class NativeConnectRequest(
    val source: String,
    val requestId: Long,
    val handoffId: Long,
)

internal enum class NativeConnectDispatchResult {
    FLUTTER_HANDOFF,
    NATIVE_STARTED,
    NO_ENGINE,
    REJECTED,
}

internal data class NativeTerminalStopClaim(
    val terminalSessionEpoch: Long,
    val supersededUserSessionEpoch: Long?,
    val cancelledHandoffId: Long?,
)

/**
 * Fail-closed handoff for native user entry points while a Flutter engine is
 * alive. A request is retained until Dart installs its listener, so Quick
 * Settings, shortcuts and notifications cannot start the VPN behind Dart's
 * socket-draining strict-egress gate.
 */
object NativeConnectRequestBridge {
    private const val TAG = "A/NativeConnectBridge"
    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pending = ArrayDeque<NativeConnectRequest>()

    @Volatile
    private var engineAttached = false
    @Volatile
    private var foregroundPresentationActive = false
    private var events: EventChannel.EventSink? = null
    private var nextHandoffId = 0L
    private var deliveredHandoffId = 0L
    private var claimedHandoffId = 0L
    private var claimedStartLease = 0L

    fun onEngineAttached() {
        synchronized(lock) {
            engineAttached = true
        }
    }

    fun onEngineDetached() {
        synchronized(lock) {
            engineAttached = false
            foregroundPresentationActive = false
            events = null
            // A live engine is only a candidate owner until Dart acknowledges
            // the exact handoff after sealing its ordinary-network gate. Keep
            // every unacknowledged request for the replacement engine instead
            // of silently dropping the user's Quick Settings/shortcut gesture.
            deliveredHandoffId = 0L
        }
    }

    /**
     * A retained Flutter engine is not necessarily an executable owner for a
     * Quick Settings Connect. Once its Activity is genuinely stopped, Dart has
     * already closed the foreground core control plane and Android may freeze
     * its timers. Native service-owned startup must use the encrypted snapshot
     * instead of handing the gesture to that background engine.
     *
     * Transient notification-shade/Quick Settings `inactive` does not call
     * Activity.onStop(), so a tile opened over the visible Marten Activity
     * keeps the normal Flutter strict-egress handoff.
     */
    fun onForegroundPresentationStarted() {
        synchronized(lock) {
            foregroundPresentationActive = true
        }
        dispatchPendingOnMainThread()
    }

    fun onForegroundPresentationStopped() {
        synchronized(lock) {
            foregroundPresentationActive = false
        }
    }

    fun onListen(eventSink: EventChannel.EventSink?) {
        synchronized(lock) {
            events = eventSink
            deliveredHandoffId = 0L
        }
        dispatchPendingOnMainThread()
    }

    fun onCancel() {
        synchronized(lock) {
            events = null
            deliveredHandoffId = 0L
        }
    }

    /**
     * Returns true only when a live Flutter engine owns the request. Callers
     * may use the native cold-start path only when this returns false.
     */
    fun requestFlutterConnect(source: String, requestId: Long = 0L): Boolean {
        synchronized(lock) {
            if (!engineAttached || !foregroundPresentationActive || events == null) return false
            if (
                claimedHandoffId > 0L &&
                claimedStartLease > 0L &&
                pending.firstOrNull()?.handoffId == claimedHandoffId &&
                ServiceLifecycleOwnership.isExplicitStartLeaseCurrent(claimedStartLease)
            ) {
                // Connect is idempotent. In particular, do not replace the
                // request during the tiny claim -> native admission handoff;
                // exact completion must still be able to consume its lease.
                return true
            }
            // Connect is idempotent. Coalesce repeated tile/notification taps
            // while Dart is still bootstrapping instead of replaying a burst.
            nextHandoffId = if (nextHandoffId == Long.MAX_VALUE) 1L else nextHandoffId + 1L
            pending.clear()
            pending.addLast(
                NativeConnectRequest(
                    source = source.ifBlank { "native" },
                    requestId = maxOf(0L, requestId),
                    handoffId = nextHandoffId,
                ),
            )
            deliveredHandoffId = 0L
        }
        dispatchPendingOnMainThread()
        return true
    }

    /**
     * Atomically chooses the owner of a native Connect after an asynchronous
     * Android permission prompt. The exact lease was captured before opening
     * that prompt, so a terminal Stop can invalidate the callback instead of
     * allowing it to mint a newer user session.
     *
     * The no-engine callback deliberately runs while [lock] is held. This
     * closes the attach race: either Flutter is already the owner and receives
     * the exact lease, or native admission is dispatched before a new engine
     * can announce itself and create ordinary-network clients.
     */
    internal fun dispatchExplicitConnect(
        source: String,
        requestId: Long,
        explicitStartLease: Long,
        nativeConnect: (() -> Boolean)? = null,
    ): NativeConnectDispatchResult {
        var dispatchFlutter = false
        val result = synchronized(lock) {
            if (
                explicitStartLease <= 0L ||
                !ServiceLifecycleOwnership.isExplicitStartLeaseCurrent(explicitStartLease)
            ) {
                return@synchronized NativeConnectDispatchResult.REJECTED
            }

            if (!engineAttached || !foregroundPresentationActive || events == null) {
                val startNative = nativeConnect
                    ?: return@synchronized NativeConnectDispatchResult.NO_ENGINE
                return@synchronized if (startNative()) {
                    NativeConnectDispatchResult.NATIVE_STARTED
                } else {
                    NativeConnectDispatchResult.REJECTED
                }
            }

            if (
                claimedHandoffId > 0L &&
                claimedStartLease == explicitStartLease &&
                pending.firstOrNull()?.handoffId == claimedHandoffId
            ) {
                return@synchronized NativeConnectDispatchResult.FLUTTER_HANDOFF
            }

            nextHandoffId = if (nextHandoffId == Long.MAX_VALUE) 1L else nextHandoffId + 1L
            val request = NativeConnectRequest(
                source = source.ifBlank { "native" },
                requestId = maxOf(0L, requestId),
                handoffId = nextHandoffId,
            )
            pending.clear()
            pending.addLast(request)
            deliveredHandoffId = 0L
            claimedHandoffId = request.handoffId
            claimedStartLease = explicitStartLease
            dispatchFlutter = true
            NativeConnectDispatchResult.FLUTTER_HANDOFF
        }
        if (dispatchFlutter) dispatchPendingOnMainThread()
        return result
    }

    /**
     * A permission-host Activity was dismissed before Dart consumed its exact
     * handoff. Retire only that request; a newer gesture or admitted session is
     * never cancelled by an older Activity callback.
     */
    fun cancelPermissionHandoff(source: String, requestId: Long): Boolean = synchronized(lock) {
        val request = pending.firstOrNull() ?: return@synchronized false
        if (request.source != source.ifBlank { "native" } || request.requestId != maxOf(0L, requestId)) {
            return@synchronized false
        }
        claimedStartLease.takeIf { it > 0L }
            ?.let(ServiceLifecycleOwnership::releaseExplicitStartLease)
        pending.clear()
        deliveredHandoffId = 0L
        claimedHandoffId = 0L
        claimedStartLease = 0L
        true
    }

    fun claimFlutterConnect(handoffId: Long): Long? {
        if (handoffId <= 0L) return null
        return synchronized(lock) {
            val request = pending.firstOrNull()
            if (request?.handoffId != handoffId) {
                return@synchronized null
            }
            if (claimedHandoffId == handoffId && claimedStartLease > 0L) {
                // A permission-owned handoff is pre-bound to the lease that
                // existed before Android showed its asynchronous UI. Never
                // replace an invalidated lease here: a terminal Stop or newer
                // gesture must make the older callback permanently stale.
                return@synchronized claimedStartLease.takeIf(
                    ServiceLifecycleOwnership::isExplicitStartLeaseCurrent,
                )
            }
            ServiceLifecycleOwnership.issueExplicitStartLease().also { lease ->
                claimedHandoffId = handoffId
                claimedStartLease = lease
            }
        }
    }

    fun acknowledgeSatisfiedFlutterConnect(handoffId: Long): Boolean {
        if (handoffId <= 0L) return false
        var acknowledgedRequest: NativeConnectRequest? = null
        val acknowledged = synchronized(lock) {
            val request = pending.firstOrNull()
            if (request?.handoffId != handoffId) return@synchronized false
            if (claimedHandoffId == handoffId && claimedStartLease > 0L) {
                ServiceLifecycleOwnership.releaseExplicitStartLease(claimedStartLease)
            }
            pending.removeFirst()
            deliveredHandoffId = 0L
            claimedHandoffId = 0L
            claimedStartLease = 0L
            acknowledgedRequest = request
            true
        }
        if (acknowledged) {
            val request = acknowledgedRequest
            if (request != null) {
                // The Activity may still be returning from onCreate when Dart
                // synchronously acknowledges a retained Connected/Connecting
                // state. Post completion so the exact invisible permission
                // host cannot remain focused above SystemUI.
                mainHandler.post {
                    VpnPermissionActivity.completeSatisfiedFlutterHandoff(
                        source = request.source,
                        requestId = request.requestId,
                    )
                }
            }
            dispatchPendingOnMainThread()
        }
        return acknowledged
    }

    /**
     * Retires a Flutter handoff only when the service-owned Android lifecycle
     * independently confirms that the requested Connect is already running.
     * A retained Dart Connected frame must never consume a fresh native user
     * gesture after VPN ownership was revoked or transferred.
     */
    fun resolveSatisfiedFlutterConnect(handoffId: Long, platformStatus: Status): String {
        if (handoffId <= 0L) return "cancelled"
        if (platformStatus != Status.Started && platformStatus != Status.Starting) {
            return synchronized(lock) {
                if (pending.firstOrNull()?.handoffId == handoffId) "connect_required" else "cancelled"
            }
        }
        return if (acknowledgeSatisfiedFlutterConnect(handoffId)) "satisfied" else "cancelled"
    }

    fun completeFlutterConnectClaim(startLease: Long): Boolean = synchronized(lock) {
        if (
            startLease <= 0L ||
            claimedStartLease != startLease ||
            pending.firstOrNull()?.handoffId != claimedHandoffId
        ) {
            return@synchronized false
        }
        ServiceLifecycleOwnership.releaseExplicitStartLease(startLease)
        pending.removeFirst()
        deliveredHandoffId = 0L
        claimedHandoffId = 0L
        claimedStartLease = 0L
        true
    }

    /**
     * An authoritative terminal Stop owns every older native Connect gesture.
     * Clearing it here prevents an engine detach/re-attach from replaying that
     * stale request after the user has already stopped the VPN.
     */
    internal fun cancelPendingFlutterConnect(
        explicitUserStop: Boolean = false,
    ): NativeTerminalStopClaim = synchronized(lock) {
        val cancelledHandoffId = pending.firstOrNull()?.handoffId
        pending.clear()
        deliveredHandoffId = 0L
        claimedHandoffId = 0L
        claimedStartLease = 0L
        // Stop and handoff claim share this outer lock. Consequently either a
        // claim is issued entirely before this epoch invalidation, or the
        // exact request is already gone when Dart tries to claim it.
        val epochClaim = ServiceLifecycleOwnership.invalidateFlutterRestartForTerminalStop(
            explicitUserStop = explicitUserStop,
        )
        NativeTerminalStopClaim(
            terminalSessionEpoch = epochClaim.terminalSessionEpoch,
            supersededUserSessionEpoch = epochClaim.supersededUserSessionEpoch,
            cancelledHandoffId = cancelledHandoffId,
        )
    }

    /**
     * Admits a failure-owned terminal Stop only while its exact session is
     * still current. A newer Connect that won first cannot be cleared by a
     * delayed timeout/error continuation from the previous admission.
     */
    internal fun cancelPendingFlutterConnectIfUserSessionEpochCurrent(
        userSessionEpoch: Long,
    ): NativeTerminalStopClaim? = synchronized(lock) {
        val epochClaim =
            ServiceLifecycleOwnership.invalidateForTerminalStopIfUserSessionEpochCurrent(
                userSessionEpoch,
            ) ?: return@synchronized null
        val cancelledHandoffId = pending.firstOrNull()?.handoffId
        pending.clear()
        deliveredHandoffId = 0L
        claimedHandoffId = 0L
        claimedStartLease = 0L
        NativeTerminalStopClaim(
            terminalSessionEpoch = epochClaim.terminalSessionEpoch,
            supersededUserSessionEpoch = epochClaim.supersededUserSessionEpoch,
            cancelledHandoffId = cancelledHandoffId,
        )
    }

    private fun dispatchPendingOnMainThread() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post(::dispatchPendingOnMainThread)
            return
        }
        val delivery = synchronized(lock) {
            val sink = events ?: return
            val request = pending.firstOrNull() ?: return
            if (deliveredHandoffId == request.handoffId) return
            deliveredHandoffId = request.handoffId
            sink to request
        }
        val (sink, request) = delivery
        runCatching {
            sink.success(
                mapOf(
                    "source" to request.source,
                    "requestId" to request.requestId,
                    "handoffId" to request.handoffId,
                ),
            )
        }.onFailure {
            synchronized(lock) {
                if (events === sink) events = null
                if (deliveredHandoffId == request.handoffId) deliveredHandoffId = 0L
            }
            Log.e(TAG, "failed to deliver native connect request; retained for retry", it)
        }
    }
}

class EventHandler : FlutterPlugin {

    companion object {
        const val TAG = "A/EventHandler"
        const val SERVICE_STATUS = "app.marten.client/service.status"
        const val SERVICE_ALERTS = "app.marten.client/service.alerts"
        const val CONNECT_REQUESTS = "app.marten.client/connect.requests"
        const val CONNECT_REQUEST_ACKS = "app.marten.client/connect.requests.ack"
    }

    private var statusChannel: EventChannel? = null
    private var alertsChannel: EventChannel? = null
    private var connectRequestsChannel: EventChannel? = null
    private var connectRequestAcksChannel: MethodChannel? = null

    private var statusObserver: Observer<Status>? = null
    private var alertsObserver: Observer<ServiceEvent?>? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        NativeConnectRequestBridge.onEngineAttached()
        statusChannel = EventChannel(flutterPluginBinding.binaryMessenger, SERVICE_STATUS, JSONMethodCodec.INSTANCE)
        alertsChannel = EventChannel(flutterPluginBinding.binaryMessenger, SERVICE_ALERTS, JSONMethodCodec.INSTANCE)
        connectRequestsChannel =
            EventChannel(flutterPluginBinding.binaryMessenger, CONNECT_REQUESTS, JSONMethodCodec.INSTANCE)
        connectRequestAcksChannel = MethodChannel(flutterPluginBinding.binaryMessenger, CONNECT_REQUEST_ACKS).apply {
            setMethodCallHandler { call, result ->
                val handoffId = (call.arguments as? Map<*, *>)?.get("handoffId") as? Number
                when (call.method) {
                    "claim" -> result.success(
                        handoffId?.let { NativeConnectRequestBridge.claimFlutterConnect(it.toLong()) },
                    )

                    "ack_satisfied" -> result.success(
                        handoffId?.let {
                            NativeConnectRequestBridge.resolveSatisfiedFlutterConnect(
                                handoffId = it.toLong(),
                                platformStatus = BoxService.currentPlatformStatus(),
                            )
                        } ?: "cancelled",
                    )

                    "cancel_claim" -> {
                        val startLease =
                            (call.arguments as? Map<*, *>)?.get("startLease") as? Number
                        result.success(
                            startLease != null &&
                                NativeConnectRequestBridge.completeFlutterConnectClaim(startLease.toLong()),
                        )
                    }

                    else -> result.notImplemented()
                }
            }
        }

        statusChannel!!.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                statusObserver?.let(BoxService::removePlatformStatusObserver)
                statusObserver = Observer {
                    Log.d(TAG, "new status: $it")
                    val map = listOf(
                        Pair("status", it.name)
                    )
                        .toMap()
                    events?.success(map)
                }
                BoxService.observePlatformStatus(statusObserver!!)
            }

            override fun onCancel(arguments: Any?) {
                statusObserver?.let(BoxService::removePlatformStatusObserver)
                statusObserver = null
            }
        })

        alertsChannel!!.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                alertsObserver = Observer {
                    if (it == null) return@Observer
                    val activity = MainActivity.instance
                    val boundStatus = activity.boundServiceStatus

                    // MutableLiveData replays its last value to every new
                    // Flutter engine. Alerts are one-shot events, so consume
                    // the retained value before forwarding it. In particular,
                    // a VpnRevoked from an earlier session must not override a
                    // currently bound Started service and leave Flutter stuck
                    // in Connecting while the VPN is already working.
                    activity.serviceAlerts.value = null
                    if (!shouldDeliverServiceAlert(it, boundStatus)) {
                        Log.w(TAG, "discarding stale alert while service is started: $it")
                        return@Observer
                    }
                    Log.d(TAG, "new alert: $it")
                    val map = listOf(
                        Pair("status", it.status.name),
                        Pair("alert", it.alert?.name),
                        Pair("message", it.message)
                    )
                        .mapNotNull { p -> p.second?.let { Pair(p.first, p.second) } }
                        .toMap()
                    events?.success(map)
                }
                MainActivity.instance.serviceAlerts.observeForever(alertsObserver!!)
            }

            override fun onCancel(arguments: Any?) {
                if (alertsObserver != null)
                    MainActivity.instance.serviceAlerts.removeObserver(alertsObserver!!)
            }
        })

        connectRequestsChannel!!.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                NativeConnectRequestBridge.onListen(events)
            }

            override fun onCancel(arguments: Any?) {
                NativeConnectRequestBridge.onCancel()
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NativeConnectRequestBridge.onEngineDetached()
        statusObserver?.let(BoxService::removePlatformStatusObserver)
        statusObserver = null
        statusChannel?.setStreamHandler(null)
        if (alertsObserver != null)
            MainActivity.instance.serviceAlerts.removeObserver(alertsObserver!!)
        alertsChannel?.setStreamHandler(null)
        connectRequestsChannel?.setStreamHandler(null)
        connectRequestAcksChannel?.setMethodCallHandler(null)
        connectRequestAcksChannel = null
    }
}

data class ServiceEvent(val status: Status, val alert: Alert? = null, val message: String? = null)
