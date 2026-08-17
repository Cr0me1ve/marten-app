package app.marten.client.security

import android.content.Context
import android.os.Build
import android.security.KeyPairGeneratorSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Calendar
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.security.auth.x500.X500Principal

/**
 * Android-Keystore protected TURN credential documents.
 *
 * The Go credential manager supplies only SHA-256 storage keys and performs
 * tuple/group validation. This class provides atomic CAS and encrypted,
 * no-backup persistence; it never logs plaintext or encrypted payloads.
 */
object TurncoatCredentialStore {
    private const val AES_ALIAS = "marten-turncoat-credentials-aes-v1"
    private const val LEGACY_RSA_ALIAS = "marten-turncoat-credentials-rsa-v1"
    private const val STORE_DIR = "marten-turncoat-credentials"
    private const val LEGACY_WRAPPED_KEY_FILE = "store.v1.key"
    private const val MAX_DOCUMENT_BYTES = 1024 * 1024L
    private val header = "MARTEN_TURNCOAT_CREDENTIALS_V1\n".toByteArray(Charsets.US_ASCII)
    private val storageKeyPattern = Regex("^[0-9a-f]{64}$")

    @Synchronized
    fun load(context: Context, storageKey: String): String {
        validateStorageKey(storageKey)
        val target = targetFile(context, storageKey)
        if (!target.isFile) return ""
        return try {
            require(target.length() in 1L..MAX_DOCUMENT_BYTES) { "invalid TURN credential payload size" }
            val plaintext = decrypt(context, storageKey, AtomicFile(target).readFully())
            try {
                plaintext.toString(Charsets.UTF_8)
            } finally {
                plaintext.fill(0)
            }
        } catch (_: Exception) {
            // A partial, tampered, or no-longer-decryptable document is never
            // returned to native code. Removing it makes recovery fail-safe.
            runCatching { AtomicFile(target).delete() }
            ""
        }
    }

    @Synchronized
    fun compareAndSwap(
        context: Context,
        storageKey: String,
        expected: String,
        replacement: String,
    ): Boolean {
        validateStorageKey(storageKey)
        val current = load(context, storageKey)
        if (current != expected) return false
        val target = targetFile(context, storageKey)
        if (replacement.isEmpty()) {
            AtomicFile(target).delete()
            return !target.exists()
        }
        val plaintext = replacement.toByteArray(Charsets.UTF_8)
        return try {
            require(plaintext.size.toLong() <= MAX_DOCUMENT_BYTES) { "TURN credential document is too large" }
            val encrypted = encrypt(context, storageKey, plaintext)
            target.parentFile?.mkdirs()
            val atomic = AtomicFile(target)
            val output = atomic.startWrite()
            try {
                output.write(encrypted)
                atomic.finishWrite(output)
                true
            } catch (error: Throwable) {
                atomic.failWrite(output)
                throw error
            }
        } finally {
            plaintext.fill(0)
        }
    }

    internal fun directory(context: Context): File = File(context.noBackupFilesDir, STORE_DIR)

    private fun targetFile(context: Context, storageKey: String): File =
        File(directory(context), "$storageKey.v1.enc")

    private fun validateStorageKey(storageKey: String) {
        require(storageKeyPattern.matches(storageKey)) { "invalid TURN credential storage key" }
    }

    private fun encrypt(context: Context, storageKey: String, plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey(context))
        cipher.updateAAD(storageKey.toByteArray(Charsets.US_ASCII))
        val ciphertext = cipher.doFinal(plaintext)
        val iv = cipher.iv
        require(iv.size <= 255)
        return header + byteArrayOf(iv.size.toByte()) + iv + ciphertext
    }

    private fun decrypt(context: Context, storageKey: String, payload: ByteArray): ByteArray {
        require(payload.size > header.size + 1 && header.indices.all { payload[it] == header[it] }) {
            "invalid TURN credential payload"
        }
        val ivSize = payload[header.size].toInt() and 0xff
        val ivStart = header.size + 1
        val ciphertextStart = ivStart + ivSize
        require(ivSize in 12..32 && ciphertextStart < payload.size) { "invalid TURN credential payload" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(context),
            GCMParameterSpec(128, payload.copyOfRange(ivStart, ciphertextStart)),
        )
        cipher.updateAAD(storageKey.toByteArray(Charsets.US_ASCII))
        return cipher.doFinal(payload.copyOfRange(ciphertextStart, payload.size))
    }

    private fun secretKey(context: Context): SecretKey =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) modernSecretKey() else legacySecretKey(context)

    private fun modernSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(AES_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    AES_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generateKey()
        }
    }

    @Suppress("DEPRECATION")
    private fun legacySecretKey(context: Context): SecretKey {
        val wrappedKeyFile = File(directory(context), LEGACY_WRAPPED_KEY_FILE)
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!keyStore.containsAlias(LEGACY_RSA_ALIAS)) {
            val start = Calendar.getInstance()
            val end = Calendar.getInstance().apply { add(Calendar.YEAR, 25) }
            val spec = KeyPairGeneratorSpec.Builder(context)
                .setAlias(LEGACY_RSA_ALIAS)
                .setSubject(X500Principal("CN=Marten TURN Credentials"))
                .setSerialNumber(BigInteger.ONE)
                .setStartDate(start.time)
                .setEndDate(end.time)
                .build()
            KeyPairGenerator.getInstance("RSA", "AndroidKeyStore").apply { initialize(spec) }.generateKeyPair()
        }
        val privateKey = keyStore.getKey(LEGACY_RSA_ALIAS, null)
        val publicKey = keyStore.getCertificate(LEGACY_RSA_ALIAS).publicKey
        if (wrappedKeyFile.isFile) {
            runCatching {
                return Cipher.getInstance("RSA/ECB/PKCS1Padding").run {
                    init(Cipher.DECRYPT_MODE, privateKey)
                    SecretKeySpec(doFinal(wrappedKeyFile.readBytes()), "AES")
                }
            }.onFailure {
                AtomicFile(wrappedKeyFile).delete()
            }
        }
        val raw = ByteArray(32).also(SecureRandom()::nextBytes)
        return try {
            val wrapped = Cipher.getInstance("RSA/ECB/PKCS1Padding").run {
                init(Cipher.ENCRYPT_MODE, publicKey)
                doFinal(raw)
            }
            wrappedKeyFile.parentFile?.mkdirs()
            AtomicFile(wrappedKeyFile).run {
                val output = startWrite()
                try {
                    output.write(wrapped)
                    finishWrite(output)
                } catch (error: Throwable) {
                    failWrite(output)
                    throw error
                }
            }
            SecretKeySpec(raw, "AES")
        } finally {
            raw.fill(0)
        }
    }
}
