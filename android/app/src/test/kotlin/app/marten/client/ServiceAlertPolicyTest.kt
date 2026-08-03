package app.marten.client

import app.marten.client.constant.Alert
import app.marten.client.constant.Status
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ServiceAlertPolicyTest {
    @Test
    fun `retained stopped alert cannot override a live bound service`() {
        val event = ServiceEvent(Status.Stopped, Alert.VpnRevoked)

        assertFalse(shouldDeliverServiceAlert(event, Status.Started))
    }

    @Test
    fun `stopped alert is delivered when the service is no longer started`() {
        val event = ServiceEvent(Status.Stopped, Alert.VpnRevoked)

        assertTrue(shouldDeliverServiceAlert(event, Status.Stopped))
        assertTrue(shouldDeliverServiceAlert(event, Status.Stopping))
    }

    @Test
    fun `alert is retained until a bound service can confirm it is stale`() {
        val event = ServiceEvent(Status.Stopped, Alert.VpnRevoked)

        assertTrue(shouldDeliverServiceAlert(event, null))
    }
}
