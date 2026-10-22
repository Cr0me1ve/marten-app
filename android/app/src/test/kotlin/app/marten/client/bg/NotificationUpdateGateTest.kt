package app.marten.client.bg

import app.marten.client.constant.Status
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationUpdateGateTest {
    @Test
    fun `closed gate after closeForeground call does not permit updates`() {
        val gate = NotificationUpdateGate()

        gate.openForeground()
        val generation = gate.beginStreaming()
        gate.closeForeground()

        assertFalse(gate.permitsUpdate(generation))
    }

    @Test
    fun `open foreground plus beginStreaming allows only current generation`() {
        val gate = NotificationUpdateGate()

        gate.openForeground()
        val firstGeneration = gate.beginStreaming()
        val secondGeneration = gate.beginStreaming()

        assertTrue(gate.permitsUpdate(secondGeneration))
        assertFalse(gate.permitsUpdate(firstGeneration))
    }

    @Test
    fun `stopStreaming invalidates previous generation`() {
        val gate = NotificationUpdateGate()

        gate.openForeground()
        val generation = gate.beginStreaming()
        gate.stopStreaming()

        assertFalse(gate.permitsUpdate(generation))
    }

    @Test
    fun `new generation from beginStreaming replaces old one`() {
        val gate = NotificationUpdateGate()

        gate.openForeground()
        val oldGeneration = gate.beginStreaming()
        val newGeneration = gate.beginStreaming()

        assertFalse(gate.permitsUpdate(oldGeneration))
        assertTrue(gate.permitsUpdate(newGeneration))
    }

    @Test
    fun `closeForeground invalidates and blocks subsequent updates`() {
        val gate = NotificationUpdateGate()

        gate.openForeground()
        val firstGeneration = gate.beginStreaming()
        gate.closeForeground()
        val secondGeneration = gate.beginStreaming()

        assertFalse(gate.permitsUpdate(firstGeneration))
        assertFalse(gate.permitsUpdate(secondGeneration))
    }

    @Test
    fun `reopening foreground without new beginStreaming does not revive old generation`() {
        val gate = NotificationUpdateGate()

        gate.openForeground()
        val generation = gate.beginStreaming()
        gate.closeForeground()
        gate.openForeground()

        assertFalse(gate.permitsUpdate(generation))
    }

    @Test
    fun `beginStreaming after open foreground creates allowed current generation`() {
        val gate = NotificationUpdateGate()

        gate.openForeground()
        val generation = gate.beginStreaming()

        assertTrue(gate.permitsUpdate(generation))
    }

    @Test
    fun `dynamic notification updates are allowed only for a permitted started platform service`() {
        assertTrue(
            shouldPublishDynamicNotificationUpdate(
                platformStatus = Status.Started,
                gatePermitsUpdate = true,
            ),
        )
        assertFalse(
            shouldPublishDynamicNotificationUpdate(
                platformStatus = Status.Started,
                gatePermitsUpdate = false,
            ),
        )
        listOf(Status.Starting, Status.Stopping, Status.Stopped).forEach { status ->
            assertFalse(
                "$status must retain its lifecycle notification instead of publishing live traffic statistics",
                shouldPublishDynamicNotificationUpdate(
                    platformStatus = status,
                    gatePermitsUpdate = true,
                ),
            )
        }
    }

    @Test
    fun `dynamic notification throughput uses elapsed time and a five second minimum publish interval`() {
        assertEquals(
            "interactive notification updates must not wake NotificationManager more frequently than every five seconds",
            5_000L,
            DYNAMIC_NOTIFICATION_MIN_UPDATE_INTERVAL_MS,
        )
        assertEquals("one second of 2 KiB traffic is reported as 2 KiB/s", 2_048L, dynamicNotificationBytesPerSecond(2_048L, 1_000L))
        assertEquals(
            "a delayed sample must be normalized by its measured elapsed duration instead of being reported as a burst",
            2_048L,
            dynamicNotificationBytesPerSecond(10_240L, 5_000L),
        )
        assertEquals(0L, dynamicNotificationBytesPerSecond(1L, 0L))
        assertEquals(0L, dynamicNotificationBytesPerSecond(-1L, 5_000L))
    }

    @Test
    fun `UID traffic totals preserve real deltas and reset unsupported or rollback counters`() {
        assertEquals(2_048L, dynamicNotificationTrafficDelta(1_024L, 3_072L))
        assertEquals(0L, dynamicNotificationTrafficDelta(3_072L, 1_024L))
        assertEquals(0L, dynamicNotificationTrafficDelta(-1L, 1_024L))
        assertEquals(0L, dynamicNotificationTrafficDelta(1_024L, -1L))
    }

    @Test
    fun `UID traffic stream gates notification statistics through lifecycle status and generation`() {
        val source = File("src/main/kotlin/app/marten/client/bg/ServiceNotification.kt").readText()
        val streamStart = source.indexOf("private suspend fun streamUidTraffic")
        val streamEnd = source.indexOf("private fun readUidTrafficSample", streamStart)
        assertTrue("streamUidTraffic must exist", streamStart >= 0)
        assertTrue("streamUidTraffic must end before UID sampling helper", streamEnd > streamStart)
        val stream = source.substring(streamStart, streamEnd)
        val helper = stream.indexOf("shouldPublishDynamicNotificationUpdate(")
        val update = stream.indexOf("updateStatus(previous, current)")

        assertTrue("traffic stream must consult the platform status update helper", helper >= 0)
        assertTrue("platform status must be passed to the notification update helper", stream.contains("platformStatus = status.value"))
        assertTrue("the generation gate must be passed to the notification update helper", stream.contains("gatePermitsUpdate = notificationUpdateGate.permitsUpdate(streamGeneration)"))
        assertTrue("traffic may be rendered only after the helper permits it", update > helper)

        val initialSample = stream.indexOf("var previous = readUidTrafficSample()")
        val wait = stream.indexOf("delay(DYNAMIC_NOTIFICATION_MIN_UPDATE_INTERVAL_MS)", initialSample)
        val currentSample = stream.indexOf("val current = readUidTrafficSample()", wait)
        val advancePrevious = stream.indexOf("previous = current", update)
        assertTrue(
            "traffic samples must wait five seconds, then capture and advance their baseline after the gate check",
            initialSample >= 0 && wait > initialSample && currentSample > wait && update > currentSample && advancePrevious > update,
        )

        val receiveStart = source.indexOf("override fun onReceive(context: Context, intent: Intent)")
        val screenOff = source.indexOf("Intent.ACTION_SCREEN_OFF ->", receiveStart)
        val stopStream = source.indexOf("stopTrafficUpdates()", screenOff)
        assertTrue(
            "screen-off must fully stop the UI-only traffic stream instead of retaining a periodic wake source",
            screenOff > receiveStart && stopStream > screenOff,
        )

        val stopTraffic = source.indexOf("fun stopTrafficUpdates()")
        val cancel = source.indexOf("streamingJob?.cancel()", stopTraffic)
        assertTrue("stopping traffic updates must cancel the polling coroutine", stopTraffic >= 0 && cancel > stopTraffic)
    }
}
