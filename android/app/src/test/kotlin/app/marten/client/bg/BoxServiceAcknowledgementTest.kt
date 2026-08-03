package app.marten.client.bg

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = NoopApplication::class, manifest = Config.NONE)
class BoxServiceAcknowledgementTest {
    @Test
    fun `verified-route acknowledgement fails closed when no BoxService is active`() = runBlocking {
        val activeInstance = BoxService::class.java.getDeclaredField("activeInstance").apply {
            isAccessible = true
        }
        val previous = activeInstance.get(null)
        activeInstance.set(null, null)
        try {
            assertFalse(BoxService.acknowledgeVerifiedRoute())
        } finally {
            activeInstance.set(null, previous)
        }
    }
}
