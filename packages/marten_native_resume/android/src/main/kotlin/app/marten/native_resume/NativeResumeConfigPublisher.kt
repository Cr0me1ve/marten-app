package app.marten.native_resume

import android.content.Context
import java.io.File

/**
 * Publishes the encrypted snapshot and its native lifecycle metadata as one
 * app-private operation. It is shared by the foreground start path and by
 * automatically registered headless Flutter engines.
 */
object NativeResumeConfigPublisher {
    private const val PREFERENCES_NAME = "FlutterSharedPreferences"
    private const val ACTIVE_CONFIG_PATH = "flutter.active_config_path"
    private const val ACTIVE_PROFILE_NAME = "flutter.active_profile_name"
    private const val ACTIVE_CONFIG_USES_TURNCOAT = "flutter.active_config_uses_turncoat"

    @Synchronized
    fun store(context: Context, source: File, profileName: String): NativeResumeConfigStore.StoredConfig {
        val stored = NativeResumeConfigStore.storeFromPlaintextFile(context, source)
        check(
            preferences(context).edit()
                .putString(ACTIVE_CONFIG_PATH, stored.encryptedPath)
                .putString(ACTIVE_PROFILE_NAME, profileName)
                .putBoolean(ACTIVE_CONFIG_USES_TURNCOAT, stored.usesTurncoat)
                .commit(),
        ) { "failed to publish native resume config metadata" }
        return stored
    }

    @Synchronized
    fun clear(context: Context) {
        NativeResumeConfigStore.clear(context)
        check(
            preferences(context).edit()
                .putString(ACTIVE_CONFIG_PATH, "")
                .putString(ACTIVE_PROFILE_NAME, "")
                .putBoolean(ACTIVE_CONFIG_USES_TURNCOAT, false)
                .commit(),
        ) { "failed to clear native resume config metadata" }
    }

    private fun preferences(context: Context) =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
}
