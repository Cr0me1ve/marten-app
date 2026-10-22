package app.marten.client.crashreporting

import java.io.File
import java.util.regex.Pattern
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FirebaseDefaultsSourceGuardTest {
    @Test
    fun `crashlytics defaults do not require configured Firebase projects`() {
        val manifest = sourceFromRoot("src/main/AndroidManifest.xml")
        assertTrue(
            "android manifest must keep crashlytics collection disabled until VPN route admission",
            hasAndroidManifestMetadataValue(manifest, "firebase_crashlytics_collection_enabled", false),
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

    @Test
    fun `hasProcessNetworkAdmission requires active VPN service ownership and network admission diagnostics`() {
        val boxService = sourceFromRoot("src/main/kotlin/app/marten/client/bg/BoxService.kt")
        val processAdmission = functionBody(boxService, "hasProcessNetworkAdmission")

        assertTrue(
            "process admission must remain tied to VPNService instance",
            processAdmission.contains("service is VPNService"),
        )
        assertTrue(
            "process admission must require descriptor retention before admitting traffic",
            processAdmission.contains("hasRetainedVpnDescriptor()"),
        )
        assertTrue(
            "process admission must require diagnostics approval",
            processAdmission.contains("NativeCrashDiagnostics.isNetworkAdmissionAllowed()"),
        )
    }

    private fun hasAndroidManifestMetadataValue(manifest: String, name: String, expectedEnabled: Boolean): Boolean {
        val pattern = Pattern.compile(
            """<meta-data[^>]*android:name=['\"]$name['\"][^>]*android:value=['\"]([^'\"]+)['\"][^>]*/>""",
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

    private fun functionBody(source: String, name: String): String {
        val declaration = source.indexOf("fun $name")
        check(declaration >= 0) { "function $name not found" }
        val nextFun = source.indexOf("\n\n    private fun ", declaration + "fun ".length)
        return if (nextFun < 0) {
            source.substring(declaration)
        } else {
            source.substring(declaration, nextFun)
        }
    }
}
