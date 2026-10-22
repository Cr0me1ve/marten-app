package app.marten.client.bg

import java.util.concurrent.FutureTask
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Old Android DNS cannot interrupt libc. Bound both callers and orphan work. */
internal object LegacyDnsWorker {
    private val executor = ThreadPoolExecutor(0, 2, 30, TimeUnit.SECONDS,
        SynchronousQueue(), { task -> Thread(task, "marten-legacy-dns").apply { isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy())

    suspend fun <T> lookup(resolve: () -> T): T {
        val task = AtomicReference<FutureTask<Unit>?>()
        val cancelled = AtomicBoolean()
        return awaitNativeDnsAnswer({
            cancelled.set(true)
            task.get()?.cancel(true)
        }) { complete ->
            val work = FutureTask {
                complete(runCatching(resolve))
                Unit
            }
            task.set(work)
            if (cancelled.get()) work.cancel(true)
            else executor.execute(work)
        }
    }
}
