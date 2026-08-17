package app.marten.client.crashreporting

import java.lang.RuntimeException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeCrashDiagnosticsTest {
    @Test
    fun `enabled backend receives bounded message and updates native_last keys`() {
        val backend = RecordingBackend()

        NativeCrashDiagnostics.logPhase("application", "on_create_end", backend)

        assertEquals(1, backend.collectionEnabledReads)
        assertEquals(listOf("native component=application phase=on_create_end"), backend.loggedMessages)
        assertEquals("application", backend.customKeys["native_last_component"])
        assertEquals("on_create_end", backend.customKeys["native_last_phase"])
        assertTrue(backend.loggedMessages.first().length <= 160)
        assertEquals(2, backend.customKeys.size)
    }

    @Test
    fun `backend collection disabled is a no-op`() {
        val backend = RecordingBackend(collectionState = false)

        NativeCrashDiagnostics.logPhase("application", "on_create_end", backend)

        assertEquals(1, backend.collectionEnabledReads)
        assertTrue(backend.loggedMessages.isEmpty())
        assertEquals(0, backend.customKeyWrites)
    }

    @Test
    fun `latest phase always overwrites native_last keys`() {
        val backend = RecordingBackend()

        NativeCrashDiagnostics.logPhase("application", "on_create_end", backend)
        NativeCrashDiagnostics.logPhase("service", "ready", backend)

        assertEquals(
            listOf(
                "native component=application phase=on_create_end",
                "native component=service phase=ready",
            ),
            backend.loggedMessages,
        )
        assertEquals("service", backend.customKeys["native_last_component"])
        assertEquals("ready", backend.customKeys["native_last_phase"])
    }

    @Test
    fun `allowlisted tokens only and payload remains bounded`() {
        val maxToken = "a".repeat(64)
        val backend = RecordingBackend()

        NativeCrashDiagnostics.logPhase(maxToken, "phase_token", backend)
        assertEquals(1, backend.loggedMessages.size)
        assertEquals(maxToken, backend.customKeys["native_last_component"])
        assertTrue(backend.loggedMessages.single().length <= 160)

        NativeCrashDiagnostics.logPhase(maxToken + "0", "phase_token", backend)
        assertEquals(
            "oversized tokens must be rejected",
            1,
            backend.loggedMessages.size,
        )
        assertEquals("unsafe token should not update keys", maxToken, backend.customKeys["native_last_component"])
    }

    @Test
    fun `pii-like or unsafe component and phase tokens are rejected`() {
        val backend = RecordingBackend()
        val invalidComponents = listOf("Application", "app-phase", "user@domain", "123start", "with space", "token=abc")
        val invalidPhases = listOf("start-up", "phase one", "Phase", "user@example.com", "192.168.1.1")

        invalidComponents.forEach { component ->
            NativeCrashDiagnostics.logPhase(component, "bootstrap", backend)
        }
        invalidPhases.forEach { phase ->
            NativeCrashDiagnostics.logPhase("application", phase, backend)
        }

        assertEquals(0, backend.loggedMessages.size)
        assertTrue(backend.customKeys.isEmpty())
        assertEquals(0, backend.collectionEnabledReads)
    }

    @Test
    fun `backend exceptions are swallowed for collection enabled and writes`() {
        val collectionThrows = RecordingBackend(throwCollectionEnabled = true)
        NativeCrashDiagnostics.logPhase("application", "on_create_end", collectionThrows)

        val logThrows = RecordingBackend(throwOnLog = true)
        NativeCrashDiagnostics.logPhase("application", "on_create_end", logThrows)

        val keyThrows = RecordingBackend(throwOnSetCustomKey = true)
        NativeCrashDiagnostics.logPhase("application", "on_create_end", keyThrows)
        assertEquals(1, keyThrows.collectionEnabledReads)
        assertEquals(1, keyThrows.loggedMessages.size)
        assertEquals(1, keyThrows.customKeyWrites)
        assertTrue(keyThrows.customKeys.isEmpty())
    }
}

private class RecordingBackend(
    private val collectionState: Boolean = true,
    private val throwCollectionEnabled: Boolean = false,
    private val throwOnLog: Boolean = false,
    private val throwOnSetCustomKey: Boolean = false,
) : NativeCrashDiagnostics.Backend {
    var collectionEnabledReads = 0
    val loggedMessages = mutableListOf<String>()
    val customKeys = mutableMapOf<String, String>()
    var customKeyWrites = 0

    override val collectionEnabled: Boolean
        get() {
            collectionEnabledReads++
            if (throwCollectionEnabled) {
                throw RuntimeException("collectionEnabled failed")
            }
            return collectionState
        }

    override fun log(message: String) {
        if (throwOnLog) {
            throw RuntimeException("log failed")
        }
        loggedMessages.add(message)
    }

    override fun setCustomKey(key: String, value: String) {
        customKeyWrites++
        if (throwOnSetCustomKey) {
            throw RuntimeException("setCustomKey failed")
        }
        customKeys[key] = value
    }
}
