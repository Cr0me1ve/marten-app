package app.marten.client.bg

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import app.marten.client.utils.GrpcClientProvider
import app.marten.core.api.v2.hcommon.Empty
import app.marten.core.api.v2.hcore.LogMessage
import app.marten.native_resume.MartenNativeCaptchaRunner
import com.squareup.wire.GrpcStreamingCall
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

internal sealed interface ServiceCaptchaControlEvent {
    val revision: Long

    data class Required(val url: String, override val revision: Long) : ServiceCaptchaControlEvent
    data class Terminal(val failed: Boolean, override val revision: Long) : ServiceCaptchaControlEvent
}

internal object ServiceCaptchaControlEventParser {
    private const val MAX_CONTROL_MESSAGE_LENGTH = 4 * 1024
    private val required = Regex(
        """^MARTEN_TURNCOAT_CAPTCHA url=(\S+) revision=([1-9][0-9]*)$""",
    )
    private val resolved = Regex(
        """^MARTEN_TURNCOAT_CAPTCHA_DONE revision=([1-9][0-9]*)$""",
    )
    private val failed = Regex(
        """^MARTEN_TURNCOAT_CAPTCHA_FAILED revision=([1-9][0-9]*)$""",
    )

    fun parse(message: String): ServiceCaptchaControlEvent? {
        if (message.isEmpty() || message.length > MAX_CONTROL_MESSAGE_LENGTH) return null
        failed.matchEntire(message)?.let { match ->
            return positiveRevision(match.groupValues[1])?.let {
                ServiceCaptchaControlEvent.Terminal(failed = true, revision = it)
            }
        }
        resolved.matchEntire(message)?.let { match ->
            return positiveRevision(match.groupValues[1])?.let {
                ServiceCaptchaControlEvent.Terminal(failed = false, revision = it)
            }
        }
        required.matchEntire(message)?.let { match ->
            return positiveRevision(match.groupValues[2])?.let {
                ServiceCaptchaControlEvent.Required(url = match.groupValues[1], revision = it)
            }
        }
        return null
    }

    private fun positiveRevision(raw: String): Long? = raw.toLongOrNull()?.takeIf { it > 0L }
}

/**
 * Owns the replayable TURNcoat CAPTCHA stream for an Android service
 * generation. It deliberately has no Activity or Flutter dependency.
 */
internal class ServiceOwnedCaptchaControlPlane(
    context: Context,
    private val scope: CoroutineScope,
    private val isGenerationActive: (Long) -> Boolean,
    private val onLifecycle: (
        event: String,
        outcome: String,
        generation: Long,
        revision: Long,
    ) -> Unit,
) {
    private companion object {
        const val STREAM_CONNECT_TIMEOUT_MS = 10_000L
        const val HEALTHY_STREAM_MIN_LIFETIME_MS = 30_000L
    }

    private val applicationContext = context.applicationContext
    private val powerManager = applicationContext.getSystemService(PowerManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var activeGeneration = 0L
    private var activeRevision = 0L
    private var listenerJob: Job? = null
    private var listenerCall: GrpcStreamingCall<Empty, LogMessage>? = null

    fun start(generation: Long, enabled: Boolean) {
        stop(clearRunner = false)
        if (!enabled || generation <= 0L) {
            record("listener", "disabled", generation, 0L)
            mainHandler.post {
                if (synchronized(lock) { activeGeneration == 0L }) {
                    runCatching { MartenNativeCaptchaRunner.clear(0L) }
                }
            }
            return
        }

        synchronized(lock) {
            activeGeneration = generation
            activeRevision = 0L
        }
        MartenNativeCaptchaRunner.initialize(applicationContext)
        record("listener", "started", generation, 0L)

        // Clear a runner retained by the previous core before admitting the
        // new stream. Starting the listener from the same main-loop task makes
        // this ordering deterministic even during rapid service reloads.
        mainHandler.post {
            if (!ownsGeneration(generation)) return@post
            runCatching { MartenNativeCaptchaRunner.clear(0L) }
            val launched = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                listen(generation)
            }
            val admitted = synchronized(lock) {
                if (activeGeneration != generation || listenerJob != null) {
                    false
                } else {
                    listenerJob = launched
                    true
                }
            }
            if (admitted) launched.start() else launched.cancel()
        }
    }

    fun stop(clearRunner: Boolean = true) {
        val snapshot = synchronized(lock) {
            val result = Triple(activeGeneration, listenerJob, listenerCall)
            activeGeneration = 0L
            activeRevision = 0L
            listenerJob = null
            listenerCall = null
            result
        }
        snapshot.third?.cancel()
        snapshot.second?.cancel()
        if (snapshot.first > 0L) {
            record("listener", "stopped", snapshot.first, 0L)
        }
        if (clearRunner) {
            mainHandler.post {
                // A newer start owns its own ordered clear. Never let an old
                // stop clear a challenge already accepted by that generation.
                if (synchronized(lock) { activeGeneration == 0L }) {
                    runCatching { MartenNativeCaptchaRunner.clear(0L) }
                }
            }
        }
    }

    private suspend fun listen(generation: Long) {
        var consecutiveFailures = 0
        try {
            while (currentCoroutineContext().isActive && ownsGeneration(generation)) {
                var connectedAtElapsedMs: Long? = null
                var receivedMessage = false
                val call = GrpcClientProvider
                    .streamingCoreClient(STREAM_CONNECT_TIMEOUT_MS)
                    .LogListener()
                if (!registerCall(generation, call)) {
                    call.cancel()
                    return
                }
                try {
                    val (requestSink, responseSource) = call.executeBlocking()
                    try {
                        requestSink.write(Empty())
                        requestSink.close()
                        connectedAtElapsedMs = SystemClock.elapsedRealtime()
                        record("listener", "connected", generation, 0L)
                        while (currentCoroutineContext().isActive && ownsGeneration(generation)) {
                            val message = responseSource.read() ?: break
                            receivedMessage = true
                            val event = ServiceCaptchaControlEventParser.parse(message.message) ?: continue
                            handle(generation, event)
                        }
                    } finally {
                        runCatching { requestSink.close() }
                        runCatching { responseSource.close() }
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Throwable) {
                    if (ownsGeneration(generation)) {
                        record("listener", "retry", generation, 0L)
                    }
                } finally {
                    unregisterCall(call)
                    call.cancel()
                }
                if (!currentCoroutineContext().isActive || !ownsGeneration(generation)) return
                val stableLongEnough = connectedAtElapsedMs?.let {
                    SystemClock.elapsedRealtime() - it >= HEALTHY_STREAM_MIN_LIFETIME_MS
                } == true
                if (receivedMessage || stableLongEnough) {
                    consecutiveFailures = 0
                }
                delay(
                    serviceCaptchaControlRetryDelayMs(
                        consecutiveFailures = consecutiveFailures,
                        deviceInteractive = powerManager?.isInteractive == true,
                    ),
                )
                consecutiveFailures = (consecutiveFailures + 1).coerceAtMost(30)
            }
        } finally {
            val currentJob = currentCoroutineContext()[Job]
            synchronized(lock) {
                if (listenerJob === currentJob) listenerJob = null
            }
        }
    }

    private fun handle(generation: Long, event: ServiceCaptchaControlEvent) {
        mainHandler.post {
            if (!ownsGeneration(generation)) {
                record("runner", "stale", generation, event.revision)
                return@post
            }
            when (event) {
                is ServiceCaptchaControlEvent.Required -> {
                    val accepted = runCatching {
                        MartenNativeCaptchaRunner.load(applicationContext, event.url, event.revision)
                    }.getOrDefault(false)
                    if (accepted) {
                        synchronized(lock) {
                            if (activeGeneration == generation) activeRevision = event.revision
                        }
                    }
                    record(
                        "required",
                        if (accepted) "accepted" else "rejected",
                        generation,
                        event.revision,
                    )
                }

                is ServiceCaptchaControlEvent.Terminal -> {
                    val expected = synchronized(lock) {
                        activeGeneration == generation && activeRevision == event.revision
                    }
                    val cleared = runCatching {
                        MartenNativeCaptchaRunner.clear(event.revision)
                    }.getOrDefault(false)
                    if (expected && cleared) {
                        synchronized(lock) {
                            if (activeGeneration == generation && activeRevision == event.revision) {
                                activeRevision = 0L
                            }
                        }
                    }
                    val outcome = when {
                        !cleared -> "rejected"
                        event.failed -> "failed"
                        expected -> "cleared"
                        else -> "forwarded"
                    }
                    record("terminal", outcome, generation, event.revision)
                }
            }
        }
    }

    private fun ownsGeneration(generation: Long): Boolean {
        val owned = synchronized(lock) { activeGeneration == generation }
        return owned && isGenerationActive(generation)
    }

    private fun registerCall(
        generation: Long,
        call: GrpcStreamingCall<Empty, LogMessage>,
    ): Boolean = synchronized(lock) {
        if (activeGeneration != generation || listenerCall != null) {
            false
        } else {
            listenerCall = call
            true
        }
    }

    private fun unregisterCall(call: GrpcStreamingCall<Empty, LogMessage>) {
        synchronized(lock) {
            if (listenerCall === call) listenerCall = null
        }
    }

    private fun record(event: String, outcome: String, generation: Long, revision: Long) {
        runCatching {
            MartenNativeCaptchaRunner.recordControl(
                applicationContext,
                event,
                outcome,
                revision,
                generation,
            )
        }
        runCatching { onLifecycle(event, outcome, generation, revision) }
    }
}
