package app.marten.client.bg

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StartupRoutePublicationTest {
    @Test
    fun `fresh proof can recover a publication invalidated during network transition`() = runBlocking {
        var now = 1_000L
        var proof = true
        var publications = 0
        var verifications = 0
        val budgets = mutableListOf<Long>()

        val published = awaitStartupRoutePublication(
            deadlineElapsedMs = 4_000L,
            now = { now },
            isCurrent = { true },
            recoveryActive = { false },
            hasCurrentProof = { proof },
            verify = { remaining ->
                verifications++
                budgets += remaining
                proof = true
                true
            },
            publish = {
                publications++
                if (publications == 1) {
                    proof = false
                    now += 250L
                    StartupRoutePublicationResult.PROOF_CHANGED
                } else {
                    StartupRoutePublicationResult.STARTED
                }
            },
        )

        assertTrue("fresh VPN proof should permit publication within the original acknowledgement", published)
        assertEquals(2, publications)
        assertEquals(1, verifications)
        assertEquals(listOf(2_750L), budgets)
    }

    @Test
    fun `stale owner cannot be revived by retry after proof disappears`() = runBlocking {
        var current = true
        var proof = true
        var verifications = 0
        var publications = 0

        val published = awaitStartupRoutePublication(
            deadlineElapsedMs = 10_000L,
            now = { 1_000L },
            isCurrent = { current },
            recoveryActive = { false },
            hasCurrentProof = { proof },
            verify = {
                verifications++
                proof = true
                true
            },
            publish = {
                publications++
                current = false
                proof = false
                StartupRoutePublicationResult.PROOF_CHANGED
            },
        )

        assertFalse(published)
        assertEquals(1, publications)
        assertEquals("a superseded generation must not get a fresh proof", 0, verifications)
    }

    @Test
    fun `failed native proof is not retried inside publication helper`() = runBlocking {
        var verifications = 0
        var publications = 0

        val published = awaitStartupRoutePublication(
            deadlineElapsedMs = 10_000L,
            now = { 1_000L },
            isCurrent = { true },
            recoveryActive = { false },
            hasCurrentProof = { false },
            verify = {
                verifications++
                false
            },
            publish = {
                publications++
                StartupRoutePublicationResult.FAILED
            },
        )

        assertFalse(published)
        assertEquals(1, verifications)
        assertEquals(0, publications)
    }

    @Test
    fun `valid proof with unhealthy publication is not retried`() = runBlocking {
        var verifications = 0
        var publications = 0

        val published = awaitStartupRoutePublication(
            deadlineElapsedMs = 10_000L,
            now = { 1_000L },
            isCurrent = { true },
            recoveryActive = { false },
            hasCurrentProof = { true },
            verify = {
                verifications++
                true
            },
            publish = {
                publications++
                StartupRoutePublicationResult.FAILED
            },
        )

        assertFalse(published)
        assertEquals(1, publications)
        assertEquals("health failure with a still-valid proof must stay with the normal recovery owner", 0, verifications)
    }

    @Test
    fun `recovery ownership or exhausted deadline cancels before verification`() = runBlocking {
        var verifications = 0
        var publications = 0
        suspend fun attempt(now: Long, recovering: Boolean): Boolean = awaitStartupRoutePublication(
            deadlineElapsedMs = 1_000L,
            now = { now },
            isCurrent = { true },
            recoveryActive = { recovering },
            hasCurrentProof = { false },
            verify = {
                verifications++
                true
            },
            publish = {
                publications++
                StartupRoutePublicationResult.STARTED
            },
        )

        assertFalse(attempt(now = 500L, recovering = true))
        assertFalse(attempt(now = 1_000L, recovering = false))
        assertEquals(0, verifications)
        assertEquals(0, publications)
    }

    @Test
    fun `publication invalidation retries at most three times with shrinking shared budget`() = runBlocking {
        var now = 0L
        var proof = false
        var verifications = 0
        var publications = 0
        val budgets = mutableListOf<Long>()

        val published = awaitStartupRoutePublication(
            deadlineElapsedMs = 1_000L,
            now = { now },
            isCurrent = { true },
            recoveryActive = { false },
            hasCurrentProof = { proof },
            verify = { remaining ->
                budgets += remaining
                verifications++
                proof = true
                now += 100L * verifications
                true
            },
            publish = {
                publications++
                proof = false
                now += 100L
                StartupRoutePublicationResult.PROOF_CHANGED
            },
        )

        assertFalse(published)
        assertEquals("publication retries are bounded", 3, publications)
        assertEquals("every retry needs a new proof", 3, verifications)
        assertEquals("remaining time is passed through without resetting the operation deadline", listOf(1_000L, 800L, 500L), budgets)
    }

    @Test
    fun `publication proof rejection remains authoritative if a proof reappears before retry`() = runBlocking {
        var proof = true
        var verifications = 0
        var publications = 0
        val order = mutableListOf<String>()

        val published = awaitStartupRoutePublication(
            deadlineElapsedMs = 10_000L,
            now = { 1_000L },
            isCurrent = { true },
            recoveryActive = { false },
            hasCurrentProof = { proof },
            verify = {
                verifications++
                order += "verify"
                proof = true
                true
            },
            publish = {
                publications++
                if (publications == 1) {
                    // A network callback restores the old proof after the
                    // publication gate rejected its snapshot.
                    proof = true
                    order += "rejected"
                    StartupRoutePublicationResult.PROOF_CHANGED
                } else {
                    order += "published"
                    StartupRoutePublicationResult.STARTED
                }
            },
        )

        assertTrue(published)
        assertEquals(1, verifications)
        assertEquals(2, publications)
        assertEquals(listOf("rejected", "verify", "published"), order)
    }

    @Test
    fun `shared deadline cancels an in-flight verifier`() = runBlocking {
        val verifierCancelled = CompletableDeferred<Unit>()
        val published = awaitStartupRoutePublication(
            deadlineElapsedMs = 25L,
            now = { 0L },
            isCurrent = { true },
            recoveryActive = { false },
            hasCurrentProof = { false },
            verify = {
                try {
                    awaitCancellation()
                } finally {
                    verifierCancelled.complete(Unit)
                }
            },
            publish = { StartupRoutePublicationResult.STARTED },
        )

        assertFalse(published)
        assertTrue("the shared deadline must cancel the verifier instead of allowing it to outlive acknowledgement", verifierCancelled.isCompleted)
    }
}
