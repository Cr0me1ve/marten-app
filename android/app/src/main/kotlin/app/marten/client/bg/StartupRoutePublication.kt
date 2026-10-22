package app.marten.client.bg

import kotlinx.coroutines.withTimeoutOrNull

internal enum class StartupRoutePublicationResult { STARTED, PROOF_CHANGED, FAILED }

/** Retry a lost publication proof within the same admitted operation and budget. */
internal suspend fun awaitStartupRoutePublication(
    deadlineElapsedMs: Long,
    now: () -> Long,
    isCurrent: () -> Boolean,
    recoveryActive: () -> Boolean,
    hasCurrentProof: () -> Boolean,
    verify: suspend (Long) -> Boolean,
    publish: suspend () -> StartupRoutePublicationResult,
): Boolean {
    val budgetMs = deadlineElapsedMs - now()
    if (budgetMs <= 0L) return false
    return withTimeoutOrNull(budgetMs) {
        repeat(3) { attempt ->
            if (!isCurrent() || recoveryActive()) return@withTimeoutOrNull false
            val remainingMs = deadlineElapsedMs - now()
            if (remainingMs <= 0L) return@withTimeoutOrNull false
            if ((attempt > 0 || !hasCurrentProof()) && !verify(remainingMs)) return@withTimeoutOrNull false
            if (!isCurrent() || recoveryActive() || now() >= deadlineElapsedMs) return@withTimeoutOrNull false
            when (publish()) {
                StartupRoutePublicationResult.STARTED -> return@withTimeoutOrNull true
                StartupRoutePublicationResult.FAILED -> return@withTimeoutOrNull false
                StartupRoutePublicationResult.PROOF_CHANGED -> Unit
            }
            // The rejection's exact cause survives a subsequent topology callback.
            // A fresh proof is required on retry even if the old Network returns.
            if (!isCurrent() || recoveryActive()) return@withTimeoutOrNull false
        }
        false
    } ?: false
}
