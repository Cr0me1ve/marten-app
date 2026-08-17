package app.marten.client.crashreporting

import java.io.File
import java.util.regex.Pattern
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FirebaseDefaultsSourceGuardTest {
    @Test
    fun `crashlytics metadata and plist defaults enable reporting out of the box`() {
        val manifest = sourceFromRoot("src/main/AndroidManifest.xml")
        val iosInfoPlist = sourceFromRoot("../ios/Runner/Info.plist")
        val macosInfoPlist = sourceFromRoot("../macos/Runner/Info.plist")

        assertTrue(
            "android manifest must keep crashlytics collection enabled by default",
            hasAndroidManifestMetadataValue(manifest, "firebase_crashlytics_collection_enabled", true),
        )
        assertTrue(
            "iOS Info.plist must keep crashlytics collection enabled by default",
            isCrashlyticsPlistEnabled(iosInfoPlist),
        )
        assertTrue(
            "macOS Info.plist must keep crashlytics collection enabled by default",
            isCrashlyticsPlistEnabled(macosInfoPlist),
        )
    }

    @Test
    fun `android settings debug mode fallback and method channel wiring remain user controllable`() {
        val settings = sourceFromRoot("src/main/kotlin/app/marten/client/Settings.kt")
        val handler = sourceFromRoot("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val handlerFallbackAssignments = "Settings.debugMode = args[\"debug\"] as Boolean? ?: true"

        assertTrue(
            "Android debug-mode preference should default to enabled when unset",
            settings.contains("getBoolean(SettingsKey.DEBUG_MODE, true)"),
        )
        assertTrue(
            "setup and start should use caller-provided debug value with enabled-by-default fallback",
            handler.contains(handlerFallbackAssignments),
        )
        assertEquals(
            "setup and start should both assign fallback-enabled debug mode",
            2,
            handler.split(handlerFallbackAssignments).size - 1,
        )
        assertTrue(
            "user-provided debug mode must continue to control native core startup",
            handler.contains("Mobile.setDebug(Settings.debugMode)"),
        )
        assertFalse(
            "hardcoded disable path should remain explicit and reachable",
            handler.contains("as Boolean? ?: false"),
        )
    }

    private fun hasAndroidManifestMetadataValue(manifest: String, name: String, expectedEnabled: Boolean): Boolean {
        val pattern = Pattern.compile(
            """<meta-data[^>]*android:name=["']$name["'][^>]*android:value=["']([^"']+)["'][^>]*/>""",
        )
        val match = pattern.matcher(manifest).run {
            if (find()) group(1) else null
        } ?: return false
        return if (expectedEnabled) {
            match.equals("true", ignoreCase = true)
        } else {
            match.equals("false", ignoreCase = true)
        }
    }

    private fun isCrashlyticsPlistEnabled(plist: String): Boolean {
        val pattern = Pattern.compile(
            """<key>FirebaseCrashlyticsCollectionEnabled</key>\s*<([a-z]+)\/>""",
            Pattern.DOTALL,
        )
        val match = pattern.matcher(plist).takeIf { it.find() } ?: return false
        return match.group(1) == "true"
    }

    private fun sourceFromRoot(relative: String): String = sourceFromCandidates(
        listOf(
            relative,
            "android/$relative",
            "../android/$relative",
            "../../android/$relative",
            "android/app/$relative",
            "../android/app/$relative",
        ),
    )

    private fun sourceFromCandidates(candidates: List<String>): String {
        val source = candidates
            .map { File(it) }
            .firstOrNull { it.isFile }
        require(source != null) { "missing source for candidates: ${candidates.joinToString()}" }
        return source.readText()
    }
}
