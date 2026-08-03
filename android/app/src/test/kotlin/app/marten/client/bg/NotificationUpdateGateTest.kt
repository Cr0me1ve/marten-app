package app.marten.client.bg

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
}
