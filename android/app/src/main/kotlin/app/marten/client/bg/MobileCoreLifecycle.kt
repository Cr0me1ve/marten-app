package app.marten.client.bg

import kotlinx.coroutines.CompletableDeferred
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

internal data class MobileForegroundSetupKey(
    val baseDir: String,
    val workingDir: String,
    val tempDir: String,
    val mode: Int,
    val grpcPort: Int,
    val debug: Boolean,
)

internal data class MobileForegroundSetupAdmission(
    val coalesced: Boolean,
    val waitedForOtherSetup: Boolean,
)

/**
 * Coalesces method-channel foreground setup calls that outlive Dart's caller.
 *
 * A Dart Future timeout does not cancel the Android method handler. Without
 * this coordinator, rapid retries queue duplicate Mobile.setup calls behind an
 * in-flight native close and each caller times out in turn. Identical requests
 * now join one result; a genuinely different request waits for that result and
 * then receives one serialized operation of its own.
 */
internal class MobileForegroundSetupCoordinator {
    private data class Operation(
        val key: MobileForegroundSetupKey,
        val completion: CompletableDeferred<Result<Unit>> = CompletableDeferred(),
    )

    private data class Admission(
        val operation: Operation,
        val owner: Boolean,
    )

    private val lock = Any()
    private var inFlight: Operation? = null

    suspend fun run(
        key: MobileForegroundSetupKey,
        block: suspend () -> Unit,
    ): MobileForegroundSetupAdmission {
        var waitedForOtherSetup = false
        while (true) {
            val admission = synchronized(lock) {
                val current = inFlight
                if (current != null) {
                    Admission(current, owner = false)
                } else {
                    val created = Operation(key)
                    inFlight = created
                    Admission(created, owner = true)
                }
            }

            if (admission.owner) {
                val outcome = try {
                    block()
                    Result.success(Unit)
                } catch (error: Throwable) {
                    Result.failure(error)
                }
                synchronized(lock) {
                    if (inFlight === admission.operation) inFlight = null
                }
                admission.operation.completion.complete(outcome)
                outcome.getOrThrow()
                return MobileForegroundSetupAdmission(
                    coalesced = false,
                    waitedForOtherSetup = waitedForOtherSetup,
                )
            }

            val outcome = admission.operation.completion.await()
            if (admission.operation.key == key) {
                outcome.getOrThrow()
                return MobileForegroundSetupAdmission(
                    coalesced = true,
                    waitedForOtherSetup = waitedForOtherSetup,
                )
            }
            waitedForOtherSetup = true
        }
    }
}
