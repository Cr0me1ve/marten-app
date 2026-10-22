package app.marten.client

import android.content.Context
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import android.util.Log
import app.marten.client.bg.ProxyService
import app.marten.client.bg.VPNService
import app.marten.client.constant.PerAppProxyMode
import app.marten.client.constant.ServiceMode
import app.marten.client.constant.SettingsKey
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.ObjectInputStream


object Settings {

    private const val TAG = "A/Settings"
    private const val TERMINAL_STOP_MARKER_FILE = "vpn-terminal-stop.marker"
    private val terminalStateLock = Any()

    @Volatile
    private var terminalStopMarkerKnown: Boolean? = null

    private val preferences by lazy {
        val context = Application.application.applicationContext
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    }

    private fun terminalStopMarkerFile(): File =
        File(Application.application.noBackupFilesDir, TERMINAL_STOP_MARKER_FILE)

    private fun hasTerminalStopMarkerLocked(): Boolean {
        terminalStopMarkerKnown?.let { return it }
        return terminalStopMarkerFile().exists().also {
            terminalStopMarkerKnown = it
        }
    }

    private fun clearTerminalStopMarkerLocked(): Boolean {
        val marker = terminalStopMarkerFile()
        if (!marker.exists()) {
            terminalStopMarkerKnown = false
            return true
        }
        return runCatching {
            check(marker.delete()) { "terminal stop marker delete was rejected" }
            syncParentDirectory(marker)
            terminalStopMarkerKnown = false
            true
        }.getOrElse {
            terminalStopMarkerKnown = marker.exists()
            Log.e(TAG, "failed to durably clear terminal VPN stop marker", it)
            false
        }
    }

    /**
     * Native-authoritative terminal-stop tombstone. Merely observing this file
     * rejects process/package-replacement recovery even if a late Flutter
     * SharedPreferences writer publishes stale true after the native Stop.
     */
    private fun persistTerminalStopMarkerLocked(): Boolean {
        val marker = terminalStopMarkerFile()
        val previouslyKnownDurable = terminalStopMarkerKnown == true && marker.exists()
        return runCatching {
            val parent = checkNotNull(marker.parentFile)
            check(parent.isDirectory || parent.mkdirs()) {
                "terminal stop marker directory is unavailable"
            }
            FileOutputStream(marker, false).use { stream ->
                stream.write(1)
                stream.fd.sync()
            }
            syncParentDirectory(marker)
            terminalStopMarkerKnown = true
            true
        }.getOrElse {
            // A newly visible file whose fsync failed is not sufficient
            // authority to release the Android VPN in this process. A marker
            // that was already known durable remains authoritative.
            terminalStopMarkerKnown = previouslyKnownDurable
            Log.e(TAG, "failed to persist terminal VPN stop marker", it)
            previouslyKnownDurable
        }
    }

    private fun syncParentDirectory(file: File) {
        val parent = checkNotNull(file.parentFile)
        val descriptor = Os.open(
            parent.absolutePath,
            OsConstants.O_RDONLY,
            0,
        )
        try {
            Os.fsync(descriptor)
        } finally {
            Os.close(descriptor)
        }
    }

    private const val LIST_IDENTIFIER = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"

    var perAppProxyMode: String
        get() = preferences.getString(SettingsKey.PER_APP_PROXY_MODE, PerAppProxyMode.OFF)!!
        set(value) = preferences.edit().putString(SettingsKey.PER_APP_PROXY_MODE, value).apply()

    val perAppProxyEnabled: Boolean
        get() = perAppProxyMode != PerAppProxyMode.OFF

    val perAppProxyList: List<String>
        get() {
            val stringValue = if (perAppProxyMode == PerAppProxyMode.INCLUDE) {
                preferences.getString(SettingsKey.PER_APP_PROXY_INCLUDE_LIST, "")!!
            } else {
                preferences.getString(SettingsKey.PER_APP_PROXY_EXCLUDE_LIST, "")!!
            }
            val list = if (!stringValue.startsWith(LIST_IDENTIFIER)) {
                stringValue.split(";")
            } else try {
                decodeListString(stringValue.substring(LIST_IDENTIFIER.length))
            } catch (e: java.lang.Exception) {
                emptyList()
            }
            return list.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        }

    private fun decodeListString(listString: String): List<String> {
        val stream = ObjectInputStream(ByteArrayInputStream(Base64.decode(listString, 0)))
        return (stream.readObject() as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
    }

    var activeConfigPath: String
        get() = preferences.getString(SettingsKey.ACTIVE_CONFIG_PATH, "")!!
        set(value) = preferences.edit().putString(SettingsKey.ACTIVE_CONFIG_PATH, value).apply()

    var activeProfileName: String
        get() = preferences.getString(SettingsKey.ACTIVE_PROFILE_NAME, "")!!
        set(value) = preferences.edit().putString(SettingsKey.ACTIVE_PROFILE_NAME, value).apply()

    var activeConfigUsesTurncoat: Boolean
        get() = preferences.getBoolean(SettingsKey.ACTIVE_CONFIG_USES_TURNCOAT, false)
        set(value) = preferences.edit().putBoolean(SettingsKey.ACTIVE_CONFIG_USES_TURNCOAT, value).apply()

    var activeConfigFingerprint: String
        get() = preferences.getString(SettingsKey.ACTIVE_CONFIG_FINGERPRINT, "")!!
        set(value) = preferences.edit().putString(SettingsKey.ACTIVE_CONFIG_FINGERPRINT, value).apply()

    var serviceMode: String
        get() = preferences.getString(SettingsKey.SERVICE_MODE, ServiceMode.VPN)!!
        set(value) = preferences.edit().putString(SettingsKey.SERVICE_MODE, value).apply()

    var configOptions: String
        get() = preferences.getString(SettingsKey.CONFIG_OPTIONS, "")!!
        set(value) = preferences.edit().putString(SettingsKey.CONFIG_OPTIONS, value).apply()

    var debugMode: Boolean
        get() = preferences.getBoolean(SettingsKey.DEBUG_MODE, true)
        set(value) = preferences.edit().putBoolean(SettingsKey.DEBUG_MODE, value).apply()

    var disableMemoryLimit: Boolean
        get() = preferences.getBoolean(SettingsKey.DISABLE_MEMORY_LIMIT, false)
        set(value) =
            preferences.edit().putBoolean(SettingsKey.DISABLE_MEMORY_LIMIT, value).apply()

    var dynamicNotification: Boolean
        get() = preferences.getBoolean(SettingsKey.DYNAMIC_NOTIFICATION, true)
        set(value) =
            preferences.edit().putBoolean(SettingsKey.DYNAMIC_NOTIFICATION, value).apply()

    var systemProxyEnabled: Boolean
        get() = preferences.getBoolean(SettingsKey.SYSTEM_PROXY_ENABLED, true)
        set(value) =
            preferences.edit().putBoolean(SettingsKey.SYSTEM_PROXY_ENABLED, value).apply()

    var startedByUser: Boolean
        get() = synchronized(terminalStateLock) {
            !hasTerminalStopMarkerLocked() &&
                preferences.getBoolean(SettingsKey.STARTED_BY_USER, false)
        }
        set(value) {
            synchronized(terminalStateLock) {
                if (value && !clearTerminalStopMarkerLocked()) {
                    // A stale durable Stop always wins over a new start when
                    // storage cannot clear it. The caller's normal admission
                    // checks will observe false and keep the VPN fail-closed.
                    Log.e(TAG, "refusing VPN start because the terminal stop marker could not be cleared")
                    preferences.edit()
                        .putBoolean(SettingsKey.STARTED_BY_USER, false)
                        .putBoolean(SettingsKey.STRICT_VPN_ROUTE_VERIFIED, false)
                        .putBoolean(SettingsKey.START_CORE_ON_STARTING_SERVICE, false)
                        .apply()
                    return
                }
                val editor = preferences.edit()
                    .putBoolean(SettingsKey.STARTED_BY_USER, value)
                    .apply {
                        if (!value) putBoolean(SettingsKey.STRICT_VPN_ROUTE_VERIFIED, false)
                    }
                if (value) {
                    // Connect acceptance can be queued behind an exact native
                    // Stop barrier. Persist the replacement intent before the
                    // service command is allowed to wait there, so process
                    // death cannot resurrect the old terminal Stop or lose the
                    // newest accepted user session.
                    if (!editor.commit()) {
                        Log.e(TAG, "failed to durably persist accepted VPN start; restoring terminal stop")
                        persistTerminalStopMarkerLocked()
                        preferences.edit()
                            .putBoolean(SettingsKey.STARTED_BY_USER, false)
                            .putBoolean(SettingsKey.STRICT_VPN_ROUTE_VERIFIED, false)
                            .putBoolean(SettingsKey.START_CORE_ON_STARTING_SERVICE, false)
                            .apply()
                    }
                } else {
                    editor.apply()
                }
            }
        }

    var strictVpnRouteVerified: Boolean
        get() = preferences.getBoolean(SettingsKey.STRICT_VPN_ROUTE_VERIFIED, false)
        set(value) = preferences.edit().putBoolean(SettingsKey.STRICT_VPN_ROUTE_VERIFIED, value).apply()

    fun serviceClass(): Class<*> {
        return when (serviceMode) {
            ServiceMode.VPN -> VPNService::class.java
            else -> ProxyService::class.java
        }
    }

    private var currentServiceMode : String? = null

    suspend fun rebuildServiceMode(): Boolean {
        var newMode = ServiceMode.NORMAL
        try {
            if (serviceMode == ServiceMode.VPN) {
                newMode = ServiceMode.VPN
            }
        } catch (_: Exception) {
        }
        if (currentServiceMode == newMode) {
            return false
        }
        currentServiceMode = newMode
        return true
    }

    private suspend fun needVPNService(): Boolean {
        val filePath = activeConfigPath
        if (filePath.isBlank()) return false
        val content = JSONObject(File(filePath).readText())
        val inbounds = content.getJSONArray("inbounds")
        for (index in 0 until inbounds.length()) {
            val inbound = inbounds.getJSONObject(index)
            if (inbound.getString("type") == "tun") {
                return true
            }
        }
        return false
    }

    var workingDir: String
        get() = preferences.getString(SettingsKey.WORKING_DIR, "./")!!
        set(value) = preferences.edit().putString(SettingsKey.WORKING_DIR, value).apply()
    var tempDir: String
        get() = preferences.getString(SettingsKey.TMP_DIR, "./")!!
        set(value) = preferences.edit().putString(SettingsKey.TMP_DIR, value).apply()

    var baseDir: String
        get() = preferences.getString(SettingsKey.BASE_DIR, "./")!!
        set(value) = preferences.edit().putString(SettingsKey.BASE_DIR, value).apply()



    var grpcFlutterPublicKey: ByteArray
        get() {
            val encoded = preferences.getString(SettingsKey.GRPC_FLUTTER_PUBLIC_KEY, null)
            return encoded?.let { Base64.decode(it, Base64.DEFAULT) } ?: ByteArray(0)
        }
        set(value) {
            val encoded = Base64.encodeToString(value, Base64.DEFAULT)
            preferences.edit().putString(SettingsKey.GRPC_FLUTTER_PUBLIC_KEY, encoded).apply()
        }
    var grpcServiceModePort: Int
        get() = preferences.getInt(SettingsKey.GRPC_PORT, 17079)!!
        set(value) = preferences.edit().putInt(SettingsKey.GRPC_PORT, value).apply()

    var startCoreAfterStartingService: Boolean
        get() = preferences.getBoolean(SettingsKey.START_CORE_ON_STARTING_SERVICE, false)
        set(value) = preferences.edit().putBoolean(SettingsKey.START_CORE_ON_STARTING_SERVICE, value).apply()

    fun persistStoppedState(): Boolean {
        synchronized(terminalStateLock) {
            val markerPersisted =
                hasTerminalStopMarkerLocked() || persistTerminalStopMarkerLocked()
            var preferencesPersisted = false
            for (attempt in 0 until 3) {
                val committed = preferences.edit()
                    .putBoolean(SettingsKey.STARTED_BY_USER, false)
                    .putBoolean(SettingsKey.STRICT_VPN_ROUTE_VERIFIED, false)
                    .putBoolean(SettingsKey.START_CORE_ON_STARTING_SERVICE, false)
                    .commit()
                if (committed) {
                    preferencesPersisted = true
                    break
                }
            }

            if (!preferencesPersisted && markerPersisted) {
                Log.e(TAG, "SharedPreferences stop commit failed; durable fail-closed marker remains authoritative")
            }
            if (!markerPersisted) {
                Log.e(
                    TAG,
                    "authoritative terminal-stop marker could not be persisted; " +
                        "SharedPreferences alone cannot arbitrate a late Flutter writer",
                )
            }
            // SharedPreferences is only the ordinary cache. The no-backup
            // marker is the authoritative tombstone that a late Dart writer
            // cannot overwrite, so platform VPN release is allowed only when
            // that marker exists. No background retry, timer or wake lock is
            // created for a storage failure.
            return markerPersisted
        }
    }


}
