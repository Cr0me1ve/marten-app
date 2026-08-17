package app.marten.native_resume

import android.content.Context
import android.os.Build
import android.security.KeyPairGeneratorSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import java.io.File
import java.io.FileOutputStream
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
 * Keystore-backed persistent recovery config with short-lived plaintext leases.
 *
 * The encrypted payload lives in no-backup internal storage. Mobile receives a
 * generation-owned cache lease only for the synchronous config read performed
 * by Mobile.start; every exit path deletes that lease.
 */
object NativeResumeConfigStore {
    private const val AES_ALIAS = "marten-native-resume-aes-v1"
    private const val LEGACY_RSA_ALIAS = "marten-native-resume-rsa-v1"
    private const val STORE_DIR = "marten-recovery"
    private const val STORE_FILE = "session.v1.enc"
    private const val LEGACY_WRAPPED_KEY_FILE = "session.v1.key"
    private const val LEASE_DIR = "marten-recovery-leases"
    private val header = "MARTEN_ANDROID_RECOVERY_V1\n".toByteArray(Charsets.US_ASCII)

    data class StoredConfig(val encryptedPath: String, val usesTurncoat: Boolean)

    @Synchronized
    fun storeFromPlaintextFile(context: Context, source: File): StoredConfig {
        require(source.isFile) { "prepared config is missing" }
        val plaintext = source.readBytes()
        require(plaintext.isNotEmpty()) { "prepared config is empty" }
        val usesTurncoat = containsAsciiIgnoreCase(plaintext, "\"turncoat\"")
        val encrypted = encrypt(context, plaintext)
        val target = encryptedFile(context)
        target.parentFile?.mkdirs()
        val staged = File(target.parentFile, "${target.name}.staged")
        try {
            FileOutputStream(staged).use { output ->
                output.write(encrypted)
                output.fd.sync()
            }
            // Both files live in the same private directory. POSIX rename is
            // an atomic replacement on Android, so Quick Settings can observe
            // either the complete previous snapshot or the complete new one,
            // never a delete/promote gap.
            Os.rename(staged.absolutePath, target.absolutePath)
        } finally {
            staged.delete()
            plaintext.fill(0)
        }
        cleanupPlaintextLeases(context)
        deleteLegacyPlaintextCopies(context)
        return StoredConfig(target.absolutePath, usesTurncoat)
    }

    @Synchronized
    fun createPlaintextLease(context: Context, generation: Long): File {
        cleanupPlaintextLeases(context)
        val encrypted = encryptedFile(context)
        require(encrypted.isFile) { "encrypted recovery config is missing" }
        val plaintext = decrypt(context, encrypted.readBytes())
        val directory = File(context.cacheDir, LEASE_DIR).apply { mkdirs() }
        val lease = File(directory, "config-$generation.lease")
        try {
            lease.writeBytes(plaintext)
            return lease
        } finally {
            plaintext.fill(0)
        }
    }

    @Synchronized
    fun deleteLease(lease: File?) {
        if (lease == null) return
        runCatching { lease.delete() }
    }

    @Synchronized
    fun cleanupPlaintextLeases(context: Context) {
        File(context.cacheDir, LEASE_DIR).deleteRecursively()
        deleteLegacyPlaintextCopies(context)
    }

    fun isEncryptedPayload(bytes: ByteArray): Boolean {
        if (bytes.size <= header.size + 1) return false
        return header.indices.all { bytes[it] == header[it] }
    }

    fun hasStoredConfig(context: Context): Boolean = encryptedFile(context).isFile

    @Synchronized
    fun clear(context: Context) {
        cleanupPlaintextLeases(context)
        val encrypted = encryptedFile(context)
        if (encrypted.exists() && !encrypted.delete()) {
            error("failed to delete encrypted recovery config")
        }
    }

    private fun encryptedFile(context: Context) = File(File(context.noBackupFilesDir, STORE_DIR), STORE_FILE)

    private fun deleteLegacyPlaintextCopies(context: Context) {
        val roots = listOfNotNull(context.getExternalFilesDir(null), context.filesDir, context.cacheDir)
        val relativePaths = listOf(
            "configs/notification_resume_config.tmp.json",
            "configs/parsed-manual.tmp.json",
            "configs/built-full-manual.json",
            "data/current-config.json",
        )
        val candidates = roots.flatMap { root -> relativePaths.map { relative -> File(root, relative) } }
        candidates.forEach { runCatching { it.delete() } }
    }

    private fun containsAsciiIgnoreCase(haystack: ByteArray, needle: String): Boolean {
        val expected = needle.toByteArray(Charsets.US_ASCII)
        if (expected.isEmpty() || haystack.size < expected.size) return false
        for (start in 0..haystack.size - expected.size) {
            var matches = true
            for (offset in expected.indices) {
                val actual = haystack[start + offset].toInt() and 0xff
                val wanted = expected[offset].toInt() and 0xff
                val foldedActual = if (actual in 'A'.code..'Z'.code) actual + 32 else actual
                val foldedWanted = if (wanted in 'A'.code..'Z'.code) wanted + 32 else wanted
                if (foldedActual != foldedWanted) {
                    matches = false
                    break
                }
            }
            if (matches) return true
        }
        return false
    }

    private fun encrypt(context: Context, plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey(context))
        val ciphertext = cipher.doFinal(plaintext)
        val iv = cipher.iv
        require(iv.size <= 255)
        return header + byteArrayOf(iv.size.toByte()) + iv + ciphertext
    }

    private fun decrypt(context: Context, payload: ByteArray): ByteArray {
        require(isEncryptedPayload(payload)) { "invalid encrypted recovery config" }
        val ivSize = payload[header.size].toInt() and 0xff
        val ivStart = header.size + 1
        val ciphertextStart = ivStart + ivSize
        require(ivSize in 12..32 && ciphertextStart < payload.size) { "invalid encrypted recovery payload" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(context),
            GCMParameterSpec(128, payload.copyOfRange(ivStart, ciphertextStart)),
        )
        return cipher.doFinal(payload.copyOfRange(ciphertextStart, payload.size))
    }

    private fun secretKey(context: Context): SecretKey {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) modernSecretKey() else legacySecretKey(context)
    }

    private fun modernSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(AES_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                AES_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    @Suppress("DEPRECATION")
    private fun legacySecretKey(context: Context): SecretKey {
        val wrappedKeyFile = File(File(context.noBackupFilesDir, STORE_DIR), LEGACY_WRAPPED_KEY_FILE)
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!keyStore.containsAlias(LEGACY_RSA_ALIAS)) {
            val start = Calendar.getInstance()
            val end = Calendar.getInstance().apply { add(Calendar.YEAR, 25) }
            val spec = KeyPairGeneratorSpec.Builder(context)
                .setAlias(LEGACY_RSA_ALIAS)
                .setSubject(X500Principal("CN=Marten Recovery"))
                .setSerialNumber(BigInteger.ONE)
                .setStartDate(start.time)
                .setEndDate(end.time)
                .build()
            KeyPairGenerator.getInstance("RSA", "AndroidKeyStore").apply { initialize(spec) }.generateKeyPair()
        }
        val privateKey = keyStore.getKey(LEGACY_RSA_ALIAS, null)
        val publicKey = keyStore.getCertificate(LEGACY_RSA_ALIAS).publicKey
        if (wrappedKeyFile.isFile) {
            val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
            cipher.init(Cipher.DECRYPT_MODE, privateKey)
            return SecretKeySpec(cipher.doFinal(wrappedKeyFile.readBytes()), "AES")
        }
        val raw = ByteArray(32).also(SecureRandom()::nextBytes)
        val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
        cipher.init(Cipher.ENCRYPT_MODE, publicKey)
        wrappedKeyFile.parentFile?.mkdirs()
        wrappedKeyFile.writeBytes(cipher.doFinal(raw))
        return SecretKeySpec(raw, "AES").also { raw.fill(0) }
    }
}
