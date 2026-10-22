package app.marten.client.bg

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LegacyDnsWorkerTest {
    @Test
    fun `cancellation interrupts legacy resolver and a later lookup can complete`() = runBlocking {
        val started = CountDownLatch(1)
        val interrupted = CountDownLatch(1)
        coroutineScope {
            val stalled = async(start = CoroutineStart.UNDISPATCHED) {
                LegacyDnsWorker.lookup {
                    started.countDown()
                    try {
                        CountDownLatch(1).await()
                        "stale"
                    } catch (error: InterruptedException) {
                        interrupted.countDown()
                        throw error
                    }
                }
            }

            try {
                assertTrue("legacy resolver did not start", started.await(1, TimeUnit.SECONDS))
                stalled.cancelAndJoin()
                assertTrue("native cancellation did not interrupt the resolver worker", interrupted.await(1, TimeUnit.SECONDS))
            } finally {
                stalled.cancelAndJoin()
            }
        }

        assertEquals("fresh", withTimeout(1_000) { LegacyDnsWorker.lookup { "fresh" } })
    }

    @Test
    fun `uninterruptible legacy calls cannot accumulate beyond the bounded worker pool`() = runBlocking {
        val started = CountDownLatch(2)
        val release = CountDownLatch(1)
        val completed = AtomicInteger()
        coroutineScope {
            val first = async(start = CoroutineStart.UNDISPATCHED) { stalledLookup(started, release, completed) }
            val second = async(start = CoroutineStart.UNDISPATCHED) { stalledLookup(started, release, completed) }
            try {
                assertTrue("both bounded resolver workers were not occupied", started.await(1, TimeUnit.SECONDS))

                val rejected = runCatching { LegacyDnsWorker.lookup { "must not run" } }.exceptionOrNull()
                assertTrue("a third blocked libc lookup must be rejected promptly", rejected is java.util.concurrent.RejectedExecutionException)

                first.cancel()
                second.cancel()
                release.countDown()
                first.cancelAndJoin()
                second.cancelAndJoin()
                val completedByDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(1)
                while (completed.get() != 2 && System.nanoTime() < completedByDeadline) {
                    kotlinx.coroutines.yield()
                }
                assertEquals("released resolver workers should finish their late calls", 2, completed.get())
                assertTrue(first.isCancelled)
                assertTrue(second.isCancelled)
            } finally {
                first.cancel()
                second.cancel()
                release.countDown()
                first.cancelAndJoin()
                second.cancelAndJoin()
            }
        }

        assertEquals("a worker is reusable after an uninterruptible call returns", "fresh", withTimeout(1_000) {
            LegacyDnsWorker.lookup { "fresh" }
        })
    }

    private suspend fun stalledLookup(
        started: CountDownLatch,
        release: CountDownLatch,
        completed: AtomicInteger,
    ): String = LegacyDnsWorker.lookup {
        started.countDown()
        while (true) {
            try {
                release.await()
                break
            } catch (_: InterruptedException) {
                // Model API 24–28 libc DNS that does not honor the caller's interrupt.
            }
        }
        completed.incrementAndGet()
        "late"
    }
}
