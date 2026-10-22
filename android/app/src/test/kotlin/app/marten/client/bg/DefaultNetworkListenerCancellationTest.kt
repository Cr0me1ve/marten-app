package app.marten.client.bg

import android.net.ConnectivityManager
import android.net.Network
import android.content.ContextWrapper
import app.marten.client.Application as MartenApplication
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.RobolectricTestRunner

private class NetworkListenerBaseApplication : android.app.Application()

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = NetworkListenerBaseApplication::class, manifest = Config.NONE)
class DefaultNetworkListenerCancellationTest {
    @Test
    fun `cancelled offline gets drain before a live get and stop unregisters the callback`() = runBlocking {
        val application = allocateMartenApplication(RuntimeEnvironment.getApplication())
        MartenApplication.application = application
        val connectivity = MartenApplication.connectivity
        val connectivityShadow = shadowOf(connectivity)
        val key = Any()
        val callbackCount = AtomicInteger()

        try {
            DefaultNetworkListener.start(key) { callbackCount.incrementAndGet() }
            assertTrue("actor must register its physical-network callback", connectivityShadow.networkCallbacks.isNotEmpty())

            // Start each request undispatched so its Get message is already in the real actor before cancellation.
            val cancelledGets = List(512) {
                async(start = CoroutineStart.UNDISPATCHED) { DefaultNetworkListener.get() }
            }
            cancelledGets.forEach { it.cancelAndJoin() }
            assertTrue(cancelledGets.all { it.isCancelled })

            val liveGet = async(start = CoroutineStart.UNDISPATCHED) { DefaultNetworkListener.get() }
            assertFalse("a live Get must remain pending while every physical network is offline", liveGet.isCompleted)

            val callbackClass = DefaultNetworkListener::class.java.declaredClasses.single { it.simpleName == "Callback" }
            val callbackField = callbackClass.getDeclaredField("INSTANCE").apply { isAccessible = true }
            val callback = callbackField.get(null) as ConnectivityManager.NetworkCallback
            val network = Network::class.java.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
            callback.onAvailable(network)

            assertEquals("the actor must release the live waiter after the first callback", network, withTimeout(1_000) { liveGet.await() })
            assertEquals("the registration listener sees the same callback event", 1, callbackCount.get())

            DefaultNetworkListener.stop(key)
            DefaultNetworkListener.stop(key)
            assertTrue("Stop must unregister the actor callback exactly once and leave no registration", connectivityShadow.networkCallbacks.isEmpty())
        } finally {
            DefaultNetworkListener.stop(key)
        }
    }

    private fun allocateMartenApplication(baseContext: android.content.Context): MartenApplication {
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val unsafe = unsafeClass.getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null)
        val application = unsafeClass.getMethod("allocateInstance", Class::class.java)
            .invoke(unsafe, MartenApplication::class.java) as MartenApplication
        ContextWrapper::class.java.getDeclaredField("mBase").apply { isAccessible = true }.set(application, baseContext)
        return application
    }
}
