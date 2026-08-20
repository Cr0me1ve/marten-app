package app.marten.client.bg

import app.marten.client.constant.Status

private const val SHA256_HEX_LENGTH = 64

internal data class RuntimeConfigOwner(
    val generation: Long,
    val fingerprint: String,
    val usesTurncoat: Boolean,
)

/**
 * Binds one prepared route to the Android service generation that may own it.
 *
 * The encrypted resume snapshot is future intent and may be replaced while a
 * VPN is running. It is therefore not runtime authority. Only this immutable
 * generation record may authorize attaching Flutter to an existing core.
 */
internal class RuntimeConfigOwnership {
    @Volatile
    private var owner: RuntimeConfigOwner? = null

    fun admit(generation: Long, fingerprint: String?, usesTurncoat: Boolean): Boolean {
        val normalized = normalizeConfigFingerprint(fingerprint) ?: return false
        synchronized(this) {
            val current = owner
            if (current != null) {
                if (generation < current.generation) return false
                if (generation == current.generation) {
                    return current.fingerprint == normalized && current.usesTurncoat == usesTurncoat
                }
            }
            owner = RuntimeConfigOwner(generation, normalized, usesTurncoat)
        }
        return true
    }

    fun ownsGeneration(generation: Long): Boolean = owner?.generation == generation

    fun matchesActive(
        status: Status,
        currentGeneration: Long,
        expectedFingerprint: String?,
    ): Boolean {
        if (status != Status.Starting && status != Status.Started) return false
        val normalized = normalizeConfigFingerprint(expectedFingerprint) ?: return false
        val snapshot = owner ?: return false
        return snapshot.generation == currentGeneration && snapshot.fingerprint == normalized
    }

    fun matches(generation: Long, expectedFingerprint: String?): Boolean {
        val normalized = normalizeConfigFingerprint(expectedFingerprint) ?: return false
        val snapshot = owner ?: return false
        return snapshot.generation == generation && snapshot.fingerprint == normalized
    }

    fun usesTurncoat(generation: Long): Boolean? {
        val snapshot = owner ?: return null
        return snapshot.usesTurncoat.takeIf { snapshot.generation == generation }
    }

    /** Retires only owners at or before a completed stop barrier. */
    fun clearThrough(generation: Long) {
        synchronized(this) {
            if ((owner?.generation ?: Long.MAX_VALUE) <= generation) owner = null
        }
    }
}

internal fun normalizeConfigFingerprint(value: String?): String? {
    val normalized = value?.trim()?.lowercase() ?: return null
    if (normalized.length != SHA256_HEX_LENGTH) return null
    if (normalized.any { it !in '0'..'9' && it !in 'a'..'f' }) return null
    return normalized
}
