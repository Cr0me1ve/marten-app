package app.marten.client.bg

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Serializes every process-wide native core lifecycle transition.
 *
 * The mobile core owns process-global Go state, so foreground and background
 * setup, start, stop, and close operations must never overlap.
 */
internal class MobileCoreLifecycleCoordinator {
    private val mutex = Mutex()

    suspend fun <T> run(block: suspend () -> T): T = mutex.withLock {
        block()
    }
}

internal object MobileCoreLifecycle {
    private val coordinator = MobileCoreLifecycleCoordinator()

    suspend fun <T> run(block: suspend () -> T): T = coordinator.run(block)
}
