package app.marten.client.bg

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StartupNetworkWaitTest {
    @Test
    fun `offline startup remains suspended until a usable network callback`() = runBlocking {
        var usable = false
        var changed = CompletableDeferred<Unit>()
        val waiting = async {
            awaitStartupNetworkObservation {
                StartupNetworkObservation(usable = usable, changed = changed)
            }
        }

        // Cross the 8-second online Start RPC deadline while offline. Network
        // absence is passive state and must not fail the owner-scoped wait.
        // Keep a broad test-only watchdog; full Android release/debug builds
        // can contend with this test's dispatcher for several seconds.
        withTimeout(30_000L) {
            delay(8_100L)
            assertFalse("an offline observation must not complete startup", waiting.isCompleted)
            usable = true
            changed.complete(Unit)
            assertTrue("the callback makes the new observation ready", waiting.await())
        }
    }

    @Test
    fun `unusable callback renews the observation wait instead of allowing startup`() = runBlocking {
        var usable = false
        var changed = CompletableDeferred<Unit>()
        val waiting = async {
            awaitStartupNetworkObservation {
                StartupNetworkObservation(usable = usable, changed = changed)
            }
        }

        yield()
        val firstCallback = changed
        changed = CompletableDeferred()
        firstCallback.complete(Unit)
        delay(25L)
        assertFalse("a callback with no usable network must keep waiting", waiting.isCompleted)

        usable = true
        changed.complete(Unit)
        assertTrue(withTimeout(1_000L) { waiting.await() })
    }

    @Test
    fun `stop wakes the waiter and an obsolete owner is rejected`() = runBlocking {
        var activeOwner: Long? = 41L
        val stopWake = CompletableDeferred<Unit>()
        val waiting = async {
            awaitStartupNetworkObservation {
                if (activeOwner != 41L) null
                else StartupNetworkObservation(usable = false, changed = stopWake)
            }
        }

        yield()
        activeOwner = null // Stop removes this owner's monitor registration.
        stopWake.complete(Unit)
        assertFalse("Stop must wake and reject the obsolete owner", withTimeout(1_000L) { waiting.await() })
    }

    @Test
    fun `cancellation propagates while the network observation is pending`() = runBlocking {
        val neverChanged = CompletableDeferred<Unit>()
        val waiting = async {
            awaitStartupNetworkObservation {
                StartupNetworkObservation(usable = false, changed = neverChanged)
            }
        }

        yield()
        waiting.cancel()
        assertTrue("explicit cancellation must terminate the pending wait", waiting.isCancelled)
        try {
            waiting.await()
            throw AssertionError("a cancelled startup wait must not report success")
        } catch (_: CancellationException) {
            // Expected: caller cancellation is distinct from network absence.
        }
    }
}
