package app.marten.client

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class StartupPhaseSourceGuardTest {
    @Test
    fun `application and activity expose monotonic secret-free startup phases`() {
        val application = sourceFile("Application.kt")
        val activity = sourceFile("MainActivity.kt")

        assertOrdered(application, "application_attach", "application_on_create_start", "application_on_create_end")
        assertOrdered(activity, "activity_on_create_start", "activity_on_create_end")
        assertOrdered(activity, "flutter_engine_configure_start", "flutter_engine_configure_end")
        assertTrue(activity.contains("onFlutterUiDisplayed"))
        assertTrue(activity.contains("flutter_ui_displayed"))

        val phaseLogger = application.substring(
            application.indexOf("fun logStartupPhase"),
            application.indexOf("lateinit var application"),
        )
        assertTrue(phaseLogger.contains("startup phase=\$phase elapsed_ms=\$elapsed"))
        assertTrue(!phaseLogger.contains("secret"))
    }

    private fun assertOrdered(source: String, vararg phases: String) {
        var previous = -1
        phases.forEach { phase ->
            val current = source.indexOf("\"$phase\"")
            assertTrue("missing startup phase $phase", current >= 0)
            assertTrue("startup phase $phase must follow its predecessor", current > previous)
            previous = current
        }
    }

    private fun sourceFile(name: String): String {
        val source = File("src/main/kotlin/app/marten/client/$name")
        check(source.isFile) { "missing production source ${source.path}" }
        return source.readText()
    }
}
