package app.marten.client.bg

import app.marten.client.constant.Status
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeConfigOwnershipTest {
    private val firstFingerprint = "a".repeat(64)
    private val secondFingerprint = "b".repeat(64)

    @Test
    fun `current starting or started generation accepts only its exact config fingerprint`() {
        val ownership = RuntimeConfigOwnership()
        assertTrue(ownership.admit(generation = 41, fingerprint = firstFingerprint, usesTurncoat = true))

        for (status in listOf(Status.Starting, Status.Started)) {
            assertTrue(ownership.matchesActive(status, currentGeneration = 41, expectedFingerprint = firstFingerprint))
            assertTrue(
                ownership.matchesActive(
                    status,
                    currentGeneration = 41,
                    expectedFingerprint = firstFingerprint.uppercase(),
                ),
            )
            assertFalse(ownership.matchesActive(status, currentGeneration = 41, expectedFingerprint = secondFingerprint))
        }
    }

    @Test
    fun `missing malformed or stale identity fails closed`() {
        val ownership = RuntimeConfigOwnership()
        assertFalse(ownership.admit(generation = 40, fingerprint = null, usesTurncoat = false))
        assertFalse(ownership.admit(generation = 40, fingerprint = "g".repeat(64), usesTurncoat = false))
        assertTrue(ownership.admit(generation = 41, fingerprint = firstFingerprint, usesTurncoat = false))

        for (invalid in listOf<String?>(null, "", "a".repeat(63), "g".repeat(64))) {
            assertFalse(ownership.matchesActive(Status.Started, currentGeneration = 41, expectedFingerprint = invalid))
        }
        assertFalse(ownership.matchesActive(Status.Started, currentGeneration = 42, expectedFingerprint = firstFingerprint))
        assertFalse(ownership.matchesActive(Status.Stopping, currentGeneration = 41, expectedFingerprint = firstFingerprint))
        assertFalse(ownership.matchesActive(Status.Stopped, currentGeneration = 41, expectedFingerprint = firstFingerprint))
    }

    @Test
    fun `stale stop cleanup cannot retire a replacement route owner`() {
        val ownership = RuntimeConfigOwnership()
        assertTrue(ownership.admit(generation = 41, fingerprint = firstFingerprint, usesTurncoat = true))
        assertTrue(ownership.admit(generation = 42, fingerprint = secondFingerprint, usesTurncoat = false))

        ownership.clearThrough(41)

        assertTrue(ownership.matchesActive(Status.Starting, currentGeneration = 42, expectedFingerprint = secondFingerprint))
        assertTrue(ownership.ownsGeneration(42))
        assertFalse(ownership.ownsGeneration(41))
        assertFalse(ownership.matches(41, firstFingerprint))
        assertEquals(false, ownership.usesTurncoat(42))
    }

    @Test
    fun `retiring the current generation removes all attach authority`() {
        val ownership = RuntimeConfigOwnership()
        assertTrue(ownership.admit(generation = 42, fingerprint = secondFingerprint, usesTurncoat = true))

        ownership.clearThrough(42)

        assertFalse(ownership.matchesActive(Status.Started, currentGeneration = 42, expectedFingerprint = secondFingerprint))
        assertNull(ownership.usesTurncoat(42))
    }

    @Test
    fun `owner is immutable within its admitted generation`() {
        val ownership = RuntimeConfigOwnership()
        assertTrue(ownership.admit(generation = 42, fingerprint = firstFingerprint, usesTurncoat = true))

        assertFalse(ownership.admit(generation = 42, fingerprint = secondFingerprint, usesTurncoat = true))
        assertFalse(ownership.admit(generation = 42, fingerprint = firstFingerprint, usesTurncoat = false))

        assertTrue(ownership.matchesActive(Status.Started, currentGeneration = 42, expectedFingerprint = firstFingerprint))
        assertFalse(ownership.matchesActive(Status.Started, currentGeneration = 42, expectedFingerprint = secondFingerprint))
        assertEquals(true, ownership.usesTurncoat(42))
    }

    @Test
    fun `a stale lower-generation admission cannot replace a newer owner`() {
        val ownership = RuntimeConfigOwnership()
        assertTrue(ownership.admit(generation = 42, fingerprint = secondFingerprint, usesTurncoat = false))

        assertFalse(ownership.admit(generation = 41, fingerprint = firstFingerprint, usesTurncoat = true))

        assertTrue(ownership.matchesActive(Status.Starting, currentGeneration = 42, expectedFingerprint = secondFingerprint))
        assertFalse(ownership.matchesActive(Status.Starting, currentGeneration = 42, expectedFingerprint = firstFingerprint))
        assertEquals(false, ownership.usesTurncoat(42))
    }
}
