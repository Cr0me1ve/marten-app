package app.marten.client.bg

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileCoreCloserSourceGuardTest {
    @Test
    fun `close worker cancels listener admission before acquiring lifecycle mutex`() {
        val source = File("src/main/kotlin/app/marten/client/bg/MobileCoreCloser.kt").readText()
        val worker = source.substring(
            source.indexOf("private val coordinator = MobileCloseCoordinator"),
            source.indexOf("fun closeAsync"),
        )

        val cancelStart = worker.indexOf("Mobile.cancelStart()")
        val lifecycleRun = worker.indexOf("MobileCoreLifecycle.run")
        val exactClose = worker.indexOf("Mobile.close(4L)")
        assertTrue("close worker must cancel an in-flight native start", cancelStart >= 0)
        assertTrue("close worker must serialize the exact native close", lifecycleRun > cancelStart && exactClose > lifecycleRun)
    }

    @Test
    fun `timed out close remains one process-wide operation that later starts must join`() {
        val source = File("src/main/kotlin/app/marten/client/bg/MobileCoreCloser.kt").readText()
        val closeBlocking = source.substring(
            source.indexOf("suspend fun closeBlocking("),
            source.indexOf("suspend fun waitForCloseToFinish("),
        )
        val waitForClose = source.substring(
            source.indexOf("suspend fun waitForCloseToFinish("),
            source.lastIndexOf("\n}"),
        )

        assertTrue("bounded close must use the shared coordinator", closeBlocking.contains("coordinator.closeBlocking(timeoutMs)"))
        assertTrue("timeout must report incomplete without cancelling the close worker", closeBlocking.contains("if (!result.finished)"))
        assertTrue("later callers must join the tracked close instead of starting Mobile.close", waitForClose.contains("coordinator.waitForClose(timeoutMs)"))
        assertTrue("wait path must not issue a second exact native close", !waitForClose.contains("Mobile.close("))
    }

    @Test
    fun `one mobile close operation completes all event waiters after exactly one native close`() = runBlocking {
        val closeCalls = AtomicInteger(0)
        val enteredClose = CompletableDeferred<Unit>()
        val releaseClose = CompletableDeferred<Unit>()
        val coordinator = MobileCloseCoordinator("test-mobile-close") {
            closeCalls.incrementAndGet()
            enteredClose.complete(Unit)
            runBlocking { releaseClose.await() }
        }

        assertTrue("the first caller must own the single close operation", coordinator.start())
        withTimeout(1_000L) { enteredClose.await() }
        assertFalse("a concurrent caller must join rather than invoke a second native close", coordinator.start())

        val firstWaiter = async(start = CoroutineStart.UNDISPATCHED) {
            coordinator.awaitCloseCompletion()
        }
        val secondWaiter = async(start = CoroutineStart.UNDISPATCHED) {
            coordinator.awaitCloseCompletion()
        }
        releaseClose.complete(Unit)

        val first = withTimeout(1_000L) { firstWaiter.await() }
        val second = withTimeout(1_000L) { secondWaiter.await() }
        assertEquals("all waiters share one exact Mobile.close invocation", 1, closeCalls.get())
        assertTrue(first.finished)
        assertTrue(second.finished)
        assertNull(first.error)
        assertNull(second.error)

        val source = File("src/main/kotlin/app/marten/client/bg/MobileCoreCloser.kt").readText()
        val coordinatorSource = source.substring(
            source.indexOf("internal class MobileCloseCoordinator"),
            source.indexOf("object MobileCoreCloser"),
        )
        assertEquals(
            "the single operation's completion Deferred must be completed in one finally path",
            1,
            coordinatorSource.split("created.completion.complete(completedError)").size - 1,
        )
    }
}
