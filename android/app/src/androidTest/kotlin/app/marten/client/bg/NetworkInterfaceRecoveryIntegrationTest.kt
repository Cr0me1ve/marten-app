package app.marten.client.bg

import androidx.test.ext.junit.runners.AndroidJUnit4
import app.marten.core.libbox.InterfaceUpdateListener
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NetworkInterfaceRecoveryIntegrationTest {
    @Test(timeout = 15_000)
    fun interfaceCallbackCompletesDuringLifecycleStartAndRetiredListenerCannotClearSuccessor() = runBlocking {
        val owner = ServiceLifecycleOwnership.acquire()
        val releaseLifecycle = CompletableDeferred<Unit>()
        val lifecycleEntered = CompletableDeferred<Unit>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        var lifecycleJob: Job? = null
        var activeOwner = owner

        try {
            assertTrue("network monitor registration should be admitted", withTimeout(4_000L) {
                DefaultNetworkMonitor.start(owner)
            })

            lifecycleJob = scope.launch {
                MobileCoreLifecycle.run {
                    lifecycleEntered.complete(Unit)
                    releaseLifecycle.await()
                }
            }
            withTimeout(3_000L) { lifecycleEntered.await() }

            val firstDelivery = CompletableDeferred<Pair<String, Int>>()
            val retiredListener = object : InterfaceUpdateListener {
                override fun updateDefaultInterface(name: String, index: Int) {
                    firstDelivery.complete(name to index)
                }
            }
            DefaultNetworkMonitor.setListener(owner, retiredListener)

            // In the old implementation the callback entered MobileCoreLifecycle.run
            // and could not finish until this test released the same lock held by Start.
            withTimeout(4_500L) { firstDelivery.await() }
            assertTrue("the native lifecycle start must still be holding its lock", checkNotNull(lifecycleJob).isActive)

            val successorOwner = ServiceLifecycleOwnership.acquire()
            activeOwner = successorOwner
            assertTrue("replacement monitor owner should be admitted", withTimeout(4_000L) {
                DefaultNetworkMonitor.start(successorOwner)
            })
            val successorDelivery = CompletableDeferred<Pair<String, Int>>()
            val successorListener = object : InterfaceUpdateListener {
                override fun updateDefaultInterface(name: String, index: Int) {
                    successorDelivery.complete(name to index)
                }
            }
            DefaultNetworkMonitor.setListener(successorOwner, successorListener)
            DefaultNetworkMonitor.clearListener(owner, retiredListener)

            withTimeout(4_500L) { successorDelivery.await() }
            assertTrue("clearing a retired listener must leave its successor active", checkNotNull(lifecycleJob).isActive)
        } finally {
            releaseLifecycle.complete(Unit)
            lifecycleJob?.let { withTimeout(3_000L) { it.join() } }
            DefaultNetworkMonitor.clearListener(activeOwner)
            DefaultNetworkMonitor.stop(activeOwner)
            scope.cancel()
        }
    }
}
