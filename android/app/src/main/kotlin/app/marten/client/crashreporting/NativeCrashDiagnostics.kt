package app.marten.client.crashreporting

import com.google.firebase.crashlytics.FirebaseCrashlytics

/**
 * Secret-free native lifecycle context for crashes that happen before Flutter
 * starts. Only fixed token-like component and phase names are accepted; raw
 * messages, exceptions, profile data, addresses, and identifiers never enter
 * this path.
 */
internal object NativeCrashDiagnostics {
    private const val MAX_TOKEN_LENGTH = 64
    private const val MAX_MESSAGE_LENGTH = 160
    private val safeToken = Regex("^[a-z][a-z0-9_]{0,${MAX_TOKEN_LENGTH - 1}}$")

    internal interface Backend {
        val collectionEnabled: Boolean

        fun log(message: String)

        fun setCustomKey(key: String, value: String)
    }

    private object FirebaseBackend : Backend {
        private val crashlytics: FirebaseCrashlytics
            get() = FirebaseCrashlytics.getInstance()

        override val collectionEnabled: Boolean
            get() = crashlytics.isCrashlyticsCollectionEnabled

        override fun log(message: String) {
            crashlytics.log(message)
        }

        override fun setCustomKey(key: String, value: String) {
            crashlytics.setCustomKey(key, value)
        }
    }

    fun logPhase(component: String, phase: String) {
        logPhase(component, phase, FirebaseBackend)
    }

    internal fun logPhase(component: String, phase: String, backend: Backend) {
        val safeComponent = component.takeIf(safeToken::matches) ?: return
        val safePhase = phase.takeIf(safeToken::matches) ?: return
        val message = "native component=$safeComponent phase=$safePhase"
        if (message.length > MAX_MESSAGE_LENGTH) return

        val enabled = runCatching { backend.collectionEnabled }.getOrDefault(false)
        if (!enabled) return

        runCatching {
            backend.log(message)
            backend.setCustomKey("native_last_component", safeComponent)
            backend.setCustomKey("native_last_phase", safePhase)
        }
    }
}
