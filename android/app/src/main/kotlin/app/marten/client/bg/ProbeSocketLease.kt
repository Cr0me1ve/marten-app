package app.marten.client.bg

import java.io.IOException
import java.net.Socket
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch

/** Owns the raw descriptor as well as any TLS wrapper until the probe finishes. */
internal class ProbeSocketLease {
    private val lock = Any()
    private val sockets = ArrayList<Socket>(2)
    private var closed = false
    @Volatile
    var expired: Boolean = false
        private set

    fun own(socket: Socket): Boolean {
        val accepted = synchronized(lock) {
            if (closed) false else {
                if (sockets.none { it === socket }) sockets.add(socket)
                true
            }
        }
        if (!accepted) runCatching { socket.close() }
        return accepted
    }

    fun expire() = close(expired = true)

    fun close() = close(expired = false)

    private fun close(expired: Boolean) {
        val owned = synchronized(lock) {
            if (closed) return
            this.expired = expired
            closed = true
            sockets.toList().also { sockets.clear() }
        }
        // Closing the raw descriptor first interrupts a blocking TLS read/write;
        // closing only the wrapper can itself wait for its in-flight operation.
        owned.forEach { runCatching { it.close() } }
    }
}

/** A passive timer exists only while this particular proof owns network I/O. */
internal suspend fun <T> withBoundedProbeSockets(
    timeoutMs: Long,
    block: suspend (ProbeSocketLease) -> T,
): T = coroutineScope {
    val sockets = ProbeSocketLease()
    val deadline = launch(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) {
        try {
            delay(timeoutMs.coerceAtLeast(1L))
            sockets.expire()
        } finally {
            // A child observes parent cancellation before the blocking parent's
            // completion handlers can run, and can therefore unblock that parent.
            sockets.close()
        }
    }
    try {
        block(sockets)
    } catch (error: IOException) {
        // Closing a canceled socket reports IOException. Preserve cancellation
        // so this expected loser cannot fail the whole endpoint race.
        currentCoroutineContext().ensureActive()
        throw error
    } finally {
        deadline.cancel()
        sockets.close()
    }
}
