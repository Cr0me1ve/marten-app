package app.marten.client.bg

import app.marten.client.constant.Status
import java.io.File
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
    fun `system info stream gates notification statistics through the platform status helper`() {
        val source = File("src/main/kotlin/app/marten/client/bg/ServiceNotification.kt").readText()
        val streamStart = source.indexOf("private suspend fun streamSystemInfo")
        val streamEnd = source.indexOf("fun stopListenSystemInfo", streamStart)
        assertTrue("streamSystemInfo must exist", streamStart >= 0)
        assertTrue("streamSystemInfo must end before stop listener", streamEnd > streamStart)
        val stream = source.substring(streamStart, streamEnd)
        val helper = stream.indexOf("shouldPublishDynamicNotificationUpdate(")
        val update = stream.indexOf("updateStatus(previous, current)")

        assertTrue("statistics stream must consult the platform status update helper", helper >= 0)
        assertTrue("platform status must be passed to the notification update helper", stream.contains("platformStatus = status.value"))
        assertTrue("the generation gate must be passed to the notification update helper", stream.contains("gatePermitsUpdate = notificationUpdateGate.permitsUpdate(streamGeneration)"))
        assertTrue("statistics may be rendered only after the helper permits them", update > helper)
    }
}
