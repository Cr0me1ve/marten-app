package app.marten.client.bg

import android.util.Log
import app.marten.core.mobile.Mobile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
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
    private var lastCompletedError: Throwable? = null

    fun start(): Boolean {
        val (_, started) = currentOrStart()
        return started
    }

    fun closeBlocking(timeoutMs: Long): MobileCloseResult {
        val (current, _) = currentOrStart()
        return waitFor(current, timeoutMs)
    }

    fun waitForClose(timeoutMs: Long): MobileCloseResult {
        val current = synchronized(lock) {
            operation ?: return MobileCloseResult(
                finished = true,
                error = lastCompletedError,
            )
        }
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
                        lastCompletedError = created.error.get()
                        if (operation === created) {
                            operation = null
                        }
                    }
                }
            }, threadName).apply {
                isDaemon = true
            }
            lastCompletedError = null
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
    private const val CLOSE_WAIT_TIMEOUT_MS = 15_000L

    private val coordinator = MobileCloseCoordinator("marten-mobile-core-close") {
        runBlocking {
            // Native teardown is serialized with setup/start, but callers never
            // hold this lifecycle mutex while waiting for it. A stuck native
            // operation therefore leaves one tracked close pending instead of
            // trapping manual Stop behind the recovery coroutine that requested
            // it. The Android TUN has already been released by that point.
            MobileCoreLifecycle.run {
                try {
                    Mobile.close(4L)
                } catch (error: Throwable) {
                    Log.w(TAG, "Mobile.close failed on native close thread", error)
                    throw error
                }
            }
        }
    }

    fun closeAsync(reason: String) {
        if (!coordinator.start()) {
            Log.w(TAG, "Mobile.close is already running after $reason")
        }
    }

    suspend fun closeBlocking(
        reason: String,
        timeoutMs: Long = CLOSE_WAIT_TIMEOUT_MS,
    ): Boolean = withContext(Dispatchers.IO) {
        // The exact close keeps running on its single native thread after this
        // wait expires. Android must never block a service lifecycle forever
        // behind native cleanup; callers fail closed and may only start again
        // after waitForCloseToFinish observes that same operation completing.
        val result = coordinator.closeBlocking(timeoutMs)
        result.error?.let {
            Log.w(TAG, "Mobile.close failed during $reason", it)
            return@withContext false
        }
        if (!result.finished) {
            Log.w(TAG, "Mobile.close did not finish within ${timeoutMs}ms during $reason")
        }
        return@withContext result.finished
    }

    suspend fun waitForCloseToFinish(
        reason: String,
        timeoutMs: Long = CLOSE_WAIT_TIMEOUT_MS,
    ): Boolean = withContext(Dispatchers.IO) {
        val result = coordinator.waitForClose(timeoutMs)
        result.error?.let {
            Log.w(TAG, "Mobile.close failed before $reason", it)
            return@withContext false
        }
        if (!result.finished) {
            Log.w(TAG, "previous Mobile.close is still running before $reason")
        }
        return@withContext result.finished
    }
}
