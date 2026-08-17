package app.marten.client.security

import android.content.Context
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
class TurncoatCredentialStoreTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val storageKey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    @After
    fun cleanUp() {
        TurncoatCredentialStore.directory(context).deleteRecursively()
    }

    @Test
    fun `credential documents are isolated in no-backup storage`() {
        val directory = TurncoatCredentialStore.directory(context)
        assertEquals(File(context.noBackupFilesDir, "marten-turncoat-credentials"), directory)
        assertFalse("credential directory must not be app files storage", directory.parentFile == context.filesDir)
        assertFalse("credential directory must not be cache storage", directory.parentFile == context.cacheDir)
    }

    @Test
    fun `corrupt payload is removed and never returned to native`() {
        val target = File(TurncoatCredentialStore.directory(context), "$storageKey.v1.enc")
        target.parentFile!!.mkdirs()
        target.writeText("not an encrypted TURN credential document")

        assertEquals("", TurncoatCredentialStore.load(context, storageKey))
        assertFalse("corrupt credential document must be deleted", target.exists())
    }

    @Test
    fun `compare and swap rejects stale expected value without writing`() {
        val target = File(TurncoatCredentialStore.directory(context), "$storageKey.v1.enc")
        assertFalse(TurncoatCredentialStore.compareAndSwap(context, storageKey, "stale", "replacement"))
        assertFalse("CAS mismatch must not create an encrypted document", target.exists())
    }

    @Test
    fun `storage key must be a SHA-256 hex digest`() {
        val invalid = listOf("", "plain scope", "ABCDEF", "g".repeat(64), "a".repeat(63))
        for (key in invalid) {
            try {
                TurncoatCredentialStore.load(context, key)
                throw AssertionError("key $key should be rejected")
            } catch (_: IllegalArgumentException) {
                // Expected: arbitrary scope strings must not become filenames.
            }
        }
    }

    @Test
    fun `implementation keeps AES GCM atomic writes AAD and secret-free logging`() {
        val source = File("src/main/kotlin/app/marten/client/security/TurncoatCredentialStore.kt").readText()
        val bridge = File("src/main/kotlin/app/marten/client/bg/PlatformInterfaceWrapper.kt").readText()

        assertTrue(source.contains("AndroidKeyStore"))
        assertTrue(source.contains("AES/GCM/NoPadding"))
        assertTrue(source.contains("cipher.updateAAD(storageKey.toByteArray"))
        assertTrue(source.contains("AtomicFile(target)"))
        assertTrue(source.contains("AtomicFile(target).delete()"))
        assertTrue(source.contains("MAX_DOCUMENT_BYTES = 1024 * 1024L"))
        assertTrue(source.contains("target.length() in 1L..MAX_DOCUMENT_BYTES"))
        assertTrue(source.contains("plaintext.size.toLong() <= MAX_DOCUMENT_BYTES"))
        assertFalse("credential persistence must not log payloads", source.contains("Log."))
        assertTrue(bridge.contains("override fun loadTurncoatCredential(storageKey: String)"))
        assertTrue(bridge.contains("override fun compareAndSwapTurncoatCredential("))
        assertTrue(bridge.contains("TurncoatCredentialStore.compareAndSwap("))
    }
}
