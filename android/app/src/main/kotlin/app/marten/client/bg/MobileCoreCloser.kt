package app.marten.client.bg

import android.util.Log
import app.marten.core.mobile.Mobile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicReference

internal data class MobileCloseResult(
    val finished: Boolean,
    val error: Throwable? = null,
)

/**
 * Coalesces all overlapping close requests onto one native close thread.
 *
 * The operation is reserved and its thread is started while holding [lock].
 * Therefore an async caller cannot be delayed between admission and starting
 * the close, allowing a blocking caller to start a second Mobile.close().
 */
internal class MobileCloseCoordinator(
    private val threadName: String,
    private val closeAction: () -> Unit,
) {
    private class Operation {
        val error = AtomicReference<Throwable?>(null)
        lateinit var thread: Thread
    }

    private val lock = Any()
    private var operation: Operation? = null

    fun start(): Boolean {
        val (_, started) = currentOrStart()
        return started
    }

    fun closeBlocking(timeoutMs: Long): MobileCloseResult {
        val (current, _) = currentOrStart()
        return waitFor(current, timeoutMs)
    }

    fun waitForClose(timeoutMs: Long): MobileCloseResult {
        val current = synchronized(lock) { operation } ?: return MobileCloseResult(finished = true)
        return waitFor(current, timeoutMs)
    }

    private fun currentOrStart(): Pair<Operation, Boolean> {
        synchronized(lock) {
            operation?.let { return it to false }

            val created = Operation()
            created.thread = Thread({
                try {
                    closeAction()
                } catch (error: Throwable) {
                    created.error.set(error)
                } finally {
                    synchronized(lock) {
                        if (operation === created) {
                            operation = null
                        }
                    }
                }
            }, threadName).apply {
                isDaemon = true
            }
            operation = created
            created.thread.start()
            return created to true
        }
    }

    private fun waitFor(current: Operation, timeoutMs: Long): MobileCloseResult {
        current.thread.join(timeoutMs)
        return MobileCloseResult(
            finished = !current.thread.isAlive,
            error = current.error.get(),
        )
    }
}

object MobileCoreCloser {
    private const val TAG = "A/MobileCoreCloser"

    private val coordinator = MobileCloseCoordinator("marten-mobile-core-close") {
        try {
            Mobile.close(4L)
        } catch (error: Throwable) {
            Log.w(TAG, "Mobile.close failed on native close thread", error)
            throw error
        }
    }

    fun closeAsync(reason: String) {
        if (!coordinator.start()) {
            Log.w(TAG, "Mobile.close is already running after $reason")
        }
    }

    suspend fun closeBlocking(reason: String): Boolean = withContext(Dispatchers.IO) {
        // A close may be slow, but a new setup cannot safely start until the
        // process-global native operation has actually returned.
        val result = coordinator.closeBlocking(0L)
        result.error?.let {
            Log.w(TAG, "Mobile.close failed during $reason", it)
            return@withContext false
        }
        return@withContext result.finished
    }

    suspend fun waitForCloseToFinish(reason: String): Boolean = withContext(Dispatchers.IO) {
        val result = coordinator.waitForClose(0L)
        result.error?.let {
            Log.w(TAG, "Mobile.close failed before $reason", it)
            return@withContext false
        }
        return@withContext result.finished
    }
}
