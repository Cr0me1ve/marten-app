package app.marten.client.bg

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout

/** The native request owns cancellation even while Android is waiting for a network. */
internal fun <T> runNativeDnsRequest(
    registerCancellation: (() -> Unit) -> Unit,
    timeoutMs: Long = 15_000L,
    operation: suspend () -> T,
): T = runBlocking {
    val requestJob = checkNotNull(currentCoroutineContext()[Job])
    registerCancellation { requestJob.cancel(CancellationException("native DNS request cancelled")) }
    withTimeout(timeoutMs) { operation() }
}

/** Android suppresses DNS callbacks after cancel; completion cannot depend on that callback. */
@OptIn(InternalCoroutinesApi::class)
internal suspend fun <T> awaitNativeDnsAnswer(
    cancelRequest: () -> Unit,
    submit: ((Result<T>) -> Unit) -> Unit,
): T = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { runCatching { cancelRequest() } }
    if (!continuation.isActive) return@suspendCancellableCoroutine
    val complete: (Result<T>) -> Unit = { result ->
        val token = result.fold(
            onSuccess = { continuation.tryResume(it) },
            onFailure = { continuation.tryResumeWithException(it) },
        )
        if (token != null) continuation.completeResume(token)
    }
    try {
        submit(complete)
    } catch (error: Exception) {
        runCatching { cancelRequest() }
        complete(Result.failure(error))
    }
}
