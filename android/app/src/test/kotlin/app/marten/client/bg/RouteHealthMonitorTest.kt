package app.marten.client.bg

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RouteHealthMonitorTest {
    @Test
    fun `screen state rearm recalculates the remaining deadline without an immediate check`() = runBlocking {
        val initialScheduleRead = CompletableDeferred<Unit>()
        val checkEntered = CompletableDeferred<String>()
        var scheduleReads = 0
        var remainingDelayMs = 60_000L
        val monitor = RouteHealthMonitor(
            nowMs = { 0L },
            nextDelayMs = {
                scheduleReads++
                if (scheduleReads == 1) initialScheduleRead.complete(Unit)
                remainingDelayMs
            },
            check = { reason -> checkEntered.complete(reason) },
        )
        val job = launch { monitor.run() }

        withTimeout(2_000L) { initialScheduleRead.await() }
        remainingDelayMs = 25L
        val rearmedAtNanos = System.nanoTime()
        monitor.rearm()
        val reason = withTimeout(2_000L) { checkEntered.await() }
        val elapsedAfterRearmMs = (System.nanoTime() - rearmedAtNanos) / 1_000_000L

        assertEquals("periodic", reason)
        assertTrue("rearm must wait for the newly computed proof deadline", elapsedAfterRearmMs >= 15L)
        assertTrue("the rearm wake must recalculate the schedule", scheduleReads >= 2)
        job.cancelAndJoin()
    }

    @Test
    fun `wake arriving during a check runs afterward without parallel checks`() = runBlocking {
        val firstCheckEntered = CompletableDeferred<Unit>()
        val releaseFirstCheck = CompletableDeferred<Unit>()
        val secondCheckEntered = CompletableDeferred<Unit>()
        var callCount = 0
        var activeChecks = 0
        var maxActiveChecks = 0
        val reasons = mutableListOf<String>()

        val monitor = RouteHealthMonitor(
            nowMs = { 0L },
            nextDelayMs = { 60_000L },
            check = { reason ->
                activeChecks++
                maxActiveChecks = maxOf(maxActiveChecks, activeChecks)
                reasons += reason
                callCount++
                try {
                    if (callCount == 1) {
                        firstCheckEntered.complete(Unit)
                        releaseFirstCheck.await()
                    } else {
                        secondCheckEntered.complete(Unit)
                    }
                } finally {
                    activeChecks--
                }
            },
        )
        val job = launch { monitor.run() }

        monitor.request("network generation changed")
        withTimeout(2_000L) { firstCheckEntered.await() }
        monitor.request("forced proof requested while check is running")
        releaseFirstCheck.complete(Unit)
        withTimeout(2_000L) { secondCheckEntered.await() }

        assertEquals(2, callCount)
        assertEquals(1, maxActiveChecks)
        assertEquals(
            listOf("network generation changed", "forced proof requested while check is running"),
            reasons,
        )
        job.cancelAndJoin()
    }

    @Test
    fun `multiple wakes before the loop starts coalesce into one check`() = runBlocking {
        val checkEntered = CompletableDeferred<Unit>()
        var callCount = 0
        var nowMs = 0L
        val monitor = RouteHealthMonitor(
            nowMs = { nowMs },
            nextDelayMs = { 60_000L },
            check = {
                callCount++
                checkEntered.complete(Unit)
            },
        )
        val job = launch(start = CoroutineStart.LAZY) { monitor.run() }

        monitor.request("screen turned off", delayMs = 100L)
        monitor.request("screen turned on", delayMs = 100L)
        monitor.request("network callback", delayMs = 100L)
        nowMs = 100L
        job.start()
        withTimeout(2_000L) { checkEntered.await() }

        assertEquals("the earliest pending wake is serviced once", 1, callCount)
        job.cancelAndJoin()
    }

    @Test
    fun `stop cancellation interrupts a running check and ends the monitor`() = runBlocking {
        val checkEntered = CompletableDeferred<Unit>()
        val checkCancelled = CompletableDeferred<Unit>()
        var callCount = 0
        val monitor = RouteHealthMonitor(
            nowMs = { 0L },
            nextDelayMs = { 60_000L },
            check = {
                callCount++
                checkEntered.complete(Unit)
                try {
                    kotlinx.coroutines.awaitCancellation()
                } finally {
                    checkCancelled.complete(Unit)
                }
            },
        )
        val job = launch { monitor.run() }

        monitor.request("forced route proof")
        withTimeout(2_000L) { checkEntered.await() }
        job.cancelAndJoin()

        assertTrue(checkCancelled.isCompleted)
        assertFalse(job.isActive)
        assertEquals(1, callCount)
    }
}
