package app.marten.client.bg

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withTimeoutOrNull

/** One serialized lane for periodic and event-requested route supervision. */
internal class RouteHealthMonitor(
    private val nowMs: () -> Long,
    private val nextDelayMs: () -> Long,
    private val check: suspend (String) -> Unit,
) {
    private data class Request(val dueAtMs: Long, val reason: String)
    private val lock = Any()
    private val changes = Channel<Unit>(Channel.CONFLATED)
    private var pending: Request? = null

    fun rearm() {
        changes.trySend(Unit)
    }

    fun request(reason: String, delayMs: Long = 0L) {
        val now = nowMs()
        val delay = delayMs.coerceAtLeast(0L).coerceAtMost(Long.MAX_VALUE - now)
        synchronized(lock) {
            val candidate = Request(now + delay, reason)
            if (pending == null || candidate.dueAtMs < pending!!.dueAtMs) {
                pending = candidate
            }
        }
        changes.trySend(Unit)
    }

    suspend fun run() {
        while (currentCoroutineContext().isActive) {
            val now = nowMs()
            val eventDelay = synchronized(lock) {
                pending?.let { (it.dueAtMs - now).coerceAtLeast(0L) } ?: Long.MAX_VALUE
            }
            val waitMs = minOf(nextDelayMs().coerceAtLeast(0L), eventDelay)
            if (waitMs > 0L) {
                val changed = withTimeoutOrNull(waitMs) { changes.receive(); true } ?: false
                if (changed) continue // Re-evaluate proof age and screen state.
            }
            val reason = synchronized(lock) {
                pending?.takeIf { it.dueAtMs <= nowMs() }?.also { pending = null }?.reason
            } ?: "periodic"
            // Requests arriving here remain pending for the next iteration;
            // they never run a second probe concurrently or disappear behind it.
            check(reason)
        }
    }
}
