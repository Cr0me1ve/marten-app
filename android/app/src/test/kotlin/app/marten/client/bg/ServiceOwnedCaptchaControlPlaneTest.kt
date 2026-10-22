package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ServiceOwnedCaptchaControlPlaneTest {
    @Test
    fun `control parser accepts only exact versioned CAPTCHA messages`() {
        val required = ServiceCaptchaControlEventParser.parse(
            "MARTEN_TURNCOAT_CAPTCHA url=http://127.0.0.1:8765/?blank=1 revision=7",
        ) as? ServiceCaptchaControlEvent.Required
        assertNotNull(required)
        assertEquals("http://127.0.0.1:8765/?blank=1", required!!.url)
        assertEquals(7L, required.revision)

        val done = ServiceCaptchaControlEventParser.parse(
            "MARTEN_TURNCOAT_CAPTCHA_DONE revision=8",
        ) as? ServiceCaptchaControlEvent.Terminal
        assertNotNull(done)
        assertFalse(done!!.failed)
        assertEquals(8L, done.revision)

        val failed = ServiceCaptchaControlEventParser.parse(
            "MARTEN_TURNCOAT_CAPTCHA_FAILED revision=9",
        ) as? ServiceCaptchaControlEvent.Terminal
        assertNotNull(failed)
        assertTrue(failed!!.failed)
        assertEquals(9L, failed.revision)

        listOf(
            "MARTEN_TURNCOAT_CAPTCHA url=http://127.0.0.1:8765/?blank=1",
            "MARTEN_TURNCOAT_CAPTCHA_DONE",
            "MARTEN_TURNCOAT_CAPTCHA_FAILED revision=0",
            "MARTEN_TURNCOAT_CAPTCHA_DONE revision=-1",
            "MARTEN_TURNCOAT_CAPTCHA_DONE revision=9223372036854775808",
            "MARTEN_TURNCOAT_CAPTCHA url=http://127.0.0.1:8765/?blank=1 revision=7 extra=ignored",
            "INFO MARTEN_TURNCOAT_CAPTCHA_DONE revision=8",
            "MARTEN_TURNCOAT_CAPTCHA_DONE revision=8\n",
        ).forEach { message ->
            assertNull("must reject non-control message: $message", ServiceCaptchaControlEventParser.parse(message))
        }
    }

    @Test
    fun `BoxService owns CAPTCHA listener after setup through recovery and teardown`() {
        val boxService = source("src/main/kotlin/app/marten/client/bg/BoxService.kt")
        val controlPlane = source("src/main/kotlin/app/marten/client/bg/ServiceOwnedCaptchaControlPlane.kt")

        assertTrue(boxService.contains("private val serviceCaptchaControlPlane = ServiceOwnedCaptchaControlPlane("))
        val initialSetup = boxService.indexOf("Mobile.setup(", boxService.indexOf("core setup request"))
        assertTrue("service must call Mobile.setup", initialSetup >= 0)
        assertAfter(boxService, initialSetup, "serviceCaptchaControlPlane.start(")

        val recovery = boxService.indexOf("private suspend fun recoverMobileCore")
        assertTrue("recovery method missing", recovery >= 0)
        val recoverySetup = boxService.indexOf("Mobile.setup(", recovery)
        assertTrue("recovery must call Mobile.setup", recoverySetup >= 0)
        assertAfter(boxService, recoverySetup, "serviceCaptchaControlPlane.start(")

        val stopService = boxService.indexOf("private fun stopService(")
        assertTrue("service stop method missing", stopService >= 0)
        assertAfter(boxService, stopService, "serviceCaptchaControlPlane.stop()")
        val destroy = boxService.indexOf("fun onDestroy()")
        assertTrue("service destroy method missing", destroy >= 0)
        assertAfter(boxService, destroy, "serviceCaptchaControlPlane.stop()")

        assertTrue(controlPlane.contains("MartenNativeCaptchaRunner.initialize(applicationContext)"))
        assertFalse(
            "service-owned listener must not require an Activity",
            Regex("^import android\\.app\\.Activity", RegexOption.MULTILINE).containsMatchIn(controlPlane),
        )
        assertFalse("service-owned listener must not require a Flutter engine", controlPlane.contains("FlutterEngine"))
        assertFalse("service-owned listener must not require a Flutter method channel", controlPlane.contains("MethodChannel"))
    }

    @Test
    fun `service CAPTCHA listener delegates retry cadence to the screen-aware energy policy`() {
        val controlPlane = source("src/main/kotlin/app/marten/client/bg/ServiceOwnedCaptchaControlPlane.kt")
        val policy = source("src/main/kotlin/app/marten/client/bg/ServiceEnergyPolicy.kt")
        val listenStart = controlPlane.indexOf("private suspend fun listen(generation: Long)")
        val handleStart = controlPlane.indexOf("private fun handle(generation: Long", listenStart)
        assertTrue("CAPTCHA listener missing", listenStart >= 0 && handleStart > listenStart)
        val listen = controlPlane.substring(listenStart, handleStart)

        assertTrue(policy.contains("private const val CAPTCHA_CONTROL_RETRY_MIN_MS = 2_000L"))
        assertTrue(policy.contains("private const val CAPTCHA_CONTROL_RETRY_BACKGROUND_MIN_MS = 15_000L"))
        assertTrue(policy.contains("private const val CAPTCHA_CONTROL_RETRY_MAX_MS = 60_000L"))
        assertFalse("short two-second cap must not return", policy.contains("CAPTCHA_CONTROL_RETRY_MAX_MS = 2_000L"))
        assertFalse("CAPTCHA listener must not spin at 250 ms", listen.contains("delay(250L)"))
        assertFalse("CAPTCHA listener must not hard-code a two-second retry", listen.contains("delay(2_000L)"))

        assertTrue(listen.contains("serviceCaptchaControlRetryDelayMs("))
        assertTrue(listen.contains("deviceInteractive = powerManager?.isInteractive == true"))
        assertTrue(controlPlane.contains("const val HEALTHY_STREAM_MIN_LIFETIME_MS = 30_000L"))
        assertTrue(listen.contains("receivedMessage = true"))
        assertTrue(listen.contains("SystemClock.elapsedRealtime() - it >= HEALTHY_STREAM_MIN_LIFETIME_MS"))
        assertTrue(listen.contains("if (receivedMessage || stableLongEnough) {\n                    consecutiveFailures = 0"))
    }

    @Test
    fun `generated Dart automation asset is the service runner source of truth`() {
        val gradle = source("build.gradle")
        val dart = source("../../lib/features/captcha/widget/captcha_page.dart")
        val nativeRunner = source(
            "../../packages/marten_native_resume/android/src/main/kotlin/app/marten/native_resume/MartenNativeCaptchaRunner.kt",
        )

        assertTrue(dart.contains("const _captchaAutomationScript = '''"))
        assertTrue(gradle.contains("def captchaAutomationSource = rootProject.file('../lib/features/captcha/widget/captcha_page.dart')"))
        assertTrue(gradle.contains("def startMarker = \"const _captchaAutomationScript = '''\\n\""))
        assertTrue(gradle.contains("source.substring(start + startMarker.length(), end)"))
        assertTrue(gradle.contains("main.assets.srcDir(generatedCaptchaAssetsDirectory)"))
        assertTrue(gradle.contains("dependsOn(generateCaptchaAutomationAsset)"))

        assertTrue(nativeRunner.contains("private const val AUTOMATION_ASSET = \"marten_captcha_automation.js\""))
        assertTrue(nativeRunner.contains("context.assets.open(AUTOMATION_ASSET)"))
        assertTrue(nativeRunner.contains("uri.scheme == \"http\""))
        assertTrue(nativeRunner.contains("uri.host == \"localhost\" || uri.host == \"127.0.0.1\""))
        assertTrue(nativeRunner.contains("uri.port == CAPTCHA_PORT"))
        assertTrue(nativeRunner.contains("uri.getQueryParameter(\"blank\") == \"1\""))
        assertTrue(nativeRunner.contains(".encodedAuthority(\"127.0.0.1:\$CAPTCHA_PORT\")"))
    }

    @Test
    fun `Quick Settings and CAPTCHA lifecycle lines are allowlisted and private-data free`() {
        val quickSettings = source("src/main/kotlin/app/marten/client/bg/QuickSettingsDiagnostics.kt")
        val nativeRunner = source(
            "../../packages/marten_native_resume/android/src/main/kotlin/app/marten/native_resume/HeadlessCaptchaWebView.kt",
        )

        assertTrue(quickSettings.contains("private val safeToken = Regex"))
        assertTrue(quickSettings.contains("MARTEN_QS_LIFECYCLE"))
        assertTrue(nativeRunner.contains("MARTEN_CAPTCHA_LIFECYCLE"))
        assertTrue(nativeRunner.contains("allowedControlEvents"))
        assertTrue(nativeRunner.contains("allowedControlOutcomes"))
        assertTrue(nativeRunner.contains("allowedLifecycleEvents"))
        assertTrue(nativeRunner.contains("allowedReasons"))

        lifecycleLine(quickSettings, "MARTEN_QS_LIFECYCLE").assertNoPrivatePayload()
        lifecycleLine(nativeRunner, "component=android event=control").assertNoPrivatePayload()
        lifecycleLine(nativeRunner, "component=android event=\$safeEvent").assertNoPrivatePayload()
    }

    private fun assertAfter(source: String, after: Int, expected: String) {
        assertTrue("expected `$expected` after offset $after", source.indexOf(expected, after) > after)
    }

    private fun source(path: String): String = File(path).readText()

    private fun lifecycleLine(source: String, marker: String): String {
        val markerStart = source.indexOf(marker)
        assertTrue("missing lifecycle marker $marker", markerStart >= 0)
        val lineStart = source.lastIndexOf("val line", markerStart).takeIf { it >= 0 } ?: markerStart
        val lineEnd = source.indexOf("Log.i", markerStart).takeIf { it >= 0 } ?: source.length
        return source.substring(lineStart, lineEnd).lowercase()
    }

    private fun String.assertNoPrivatePayload() {
        listOf("endpoint", "profile", "sim", "token", "cookie", "url").forEach { forbidden ->
            assertFalse("lifecycle line leaks $forbidden: $this", contains(forbidden))
        }
    }
}
