package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreProcessCallSiteSourceGuardTest {
    @Test
    fun `background Start refreshes native debug mode off the main thread`() {
        val handler = source("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val remote = source("src/main/kotlin/app/marten/client/bg/RemoteMobile.kt")
        val start = section(handler, "Trigger.Start.method -> {", "Trigger.MarkStarted.method -> {")

        val debugRefresh = "withContext(Dispatchers.IO) { Mobile.setDebug(Settings.debugMode) }"
        assertTrue("Start must refresh native diagnostics before service startup", start.contains(debugRefresh))
        assertEquals("Start must issue one debug IPC, inside its IO context", 1, start.split("Mobile.setDebug(Settings.debugMode)").size - 1)
        assertTrue("setDebug reaches the shared IPC call that enforces worker-thread use", remote.contains("fun setDebug(debug: Boolean) { call(\"debug\")"))
        assertTrue("every RemoteMobile IPC call rejects the main thread", remote.contains("check(Looper.myLooper() != Looper.getMainLooper())"))
    }

    @Test
    fun `core diagnostics require VPN admission and preserve the Flutter opt out`() {
        val remote = source("src/main/kotlin/app/marten/client/bg/RemoteMobile.kt")
        val coreService = source("src/main/kotlin/app/marten/client/bg/CoreProcessService.kt")
        val settings = source("src/main/kotlin/app/marten/client/PlatformSettingsHandler.kt")
        val crashDiagnostics = source("src/main/kotlin/app/marten/client/crashreporting/NativeCrashDiagnostics.kt")
        val boxService = source("src/main/kotlin/app/marten/client/bg/BoxService.kt")
        val analytics = source("../../lib/core/analytics/analytics_controller.dart")

        val update = section(remote, "fun updateCrashReporting(", "private class PlatformLease")
        val diagnostics = section(coreService, "\"diagnostics\" -> {", "\"setup\" -> {")
        val settingsHandler = section(settings, "\"set_core_crash_reporting\" -> {", "Trigger.IsIgnoringBatteryOptimizations.method -> {")
        val started = section(
            boxService,
            "private suspend fun markCoreRuntimeStarted(",
            "private suspend fun awaitTunRuntimeHealthForStarted()",
        )
        val analyticsEnable = section(analytics, "Future<void> enableAnalytics()", "Future<void> disableAnalytics()")
        val analyticsDisable = section(analytics, "Future<void> disableAnalytics()", "Future<void> recordNonFatal")
        val analyticsInitialize = section(analytics, "Future<void> _initializeReporting()", "Future<void> disableAnalytics()")
        val platformAdmission = section(settings, "\"is_crash_reporting_admitted\" -> {", "\"read_early_crash_reports\" -> {")
        val nativeLogPhase = section(crashDiagnostics, "fun logPhase(component: String, phase: String)", "internal fun logPhase(component: String, phase: String, backend: Backend)")

        assertTrue("native diagnostics update must be ignored for a dead core generation", update.contains("owner.lifetime.acceptsCallbacks()"))
        assertTrue("network candidates may be selected only after route verification", update.contains("if (Settings.strictVpnRouteVerified)"))
        assertTrue("the user opt-out is read from Flutter preferences", update.contains("getBoolean(\"flutter.enable_analytics\", true)"))
        assertTrue("the diagnostics IPC carries both opt-in and the candidate VPN Network", update.contains("putBoolean(\"enabled\", optIn)") && update.contains("putParcelable(\"network\", verifiedNetwork)"))

        val bindNetwork = diagnostics.indexOf("connectivity.bindProcessToNetwork(network)")
        val setAdmission = diagnostics.indexOf("NativeCrashDiagnostics.setNetworkAdmissionAllowed(admitted)")
        val initialize = diagnostics.indexOf("if (admitted && enabled && !diagnosticsInitialized)")
        val setCollection = diagnostics.indexOf("setCrashlyticsCollectionEnabled(enabled && admitted)")
        assertTrue("core Crashlytics work must bind to the supplied VPN before enabling native network admission", bindNetwork >= 0 && setAdmission > bindNetwork)
        assertTrue("Firebase initialization requires both verified process binding and user opt-in", initialize > setAdmission)
        assertTrue("collection requires user opt-in and an admitted VPN-bound core process", setCollection > initialize)

        assertTrue("platform opt-out defaults closed when arguments are absent", settingsHandler.contains("call.arguments as? Boolean ?: false"))
        assertTrue("a verified Started publication requests core diagnostics only after recording verified ownership", started.indexOf("Settings.strictVpnRouteVerified = true") in 0 until started.indexOf("Mobile.updateCrashReporting()"))
        assertTrue("Flutter persists opt-in before forwarding it to the core process", analyticsEnable.indexOf("setBool(enableAnalyticsPrefKey, true)") in 0 until analyticsEnable.indexOf("_updateAndroidCoreCollection(true)"))
        val admissionCheck = analyticsInitialize.indexOf("invokeMethod<bool>('is_crash_reporting_admitted')")
        val firebaseConstruction = analyticsInitialize.indexOf("Firebase.initializeApp()")
        assertTrue("Android opt-in defers Firebase until exact current native VPN admission", admissionCheck >= 0 && firebaseConstruction > admissionCheck)
        assertTrue("native admission combines approved diagnostics networking and a verified VPN route", platformAdmission.contains("NativeCrashDiagnostics.isNetworkAdmissionAllowed()") && platformAdmission.contains("BoxService.hasVerifiedRouteForOptionalBackgroundWork()"))
        assertTrue("Flutter persists opt-out before disabling the core process collection", analyticsDisable.indexOf("setBool(enableAnalyticsPrefKey, false)") in 0 until analyticsDisable.indexOf("_updateAndroidCoreCollection(false)"))
        assertTrue("native phase reports require admitted network", nativeLogPhase.contains("if (!networkAdmissionAllowed) return"))
        assertTrue("native phase reports also require the user-enabled Crashlytics collection", crashDiagnostics.contains("if (!enabled) return"))
    }

    @Test
    fun `notification presentation and runtime state summaries do not wait on native core`() {
        val notification = source("src/main/kotlin/app/marten/client/bg/ServiceNotification.kt")
        val remote = source("src/main/kotlin/app/marten/client/bg/RemoteMobile.kt")
        val formatter = section(notification, "internal fun formatNotificationBytes(", "internal fun shouldStreamDynamicNotificationUpdates(")
        val runtimeState = section(remote, "fun runtimeState(): String", "fun updateCrashReporting(")

        assertFalse("notification presentation must not import a native core package", notification.contains("app.marten.core"))
        assertFalse("notification presentation must not use Libbox formatting", notification.contains("Libbox"))
        assertFalse("notification presentation must not call native Mobile APIs", Regex("\\bMobile\\b").containsMatchIn(notification))
        assertFalse("notification formatter must not delegate to Libbox.formatBytes", formatter.contains("formatBytes"))
        assertTrue("runtime state should summarize only the cached process/session state", runtimeState.contains("current?.remote != null"))
        listOf("call(", "ready.get(", "ready.await(", "runBlocking", "Looper", "Mobile.").forEach { blockingOrNativePath ->
            assertFalse("runtime-state reporting must not wait for or call the core: $blockingOrNativePath", runtimeState.contains(blockingOrNativePath))
        }
    }

    private fun source(path: String): String {
        val file = File(path)
        check(file.isFile) { "missing production source ${file.path}" }
        return file.readText()
    }

    private fun section(source: String, startMarker: String, endMarker: String): String {
        val start = source.indexOf(startMarker)
        require(start >= 0) { "missing source marker: $startMarker" }
        val end = source.indexOf(endMarker, start + startMarker.length)
        require(end >= 0) { "missing source marker: $endMarker" }
        return source.substring(start, end)
    }

    private fun functionBody(source: String, name: String): String {
        val declaration = source.indexOf("fun $name(")
        require(declaration >= 0) { "missing function $name" }
        val open = source.indexOf('{', declaration)
        require(open >= 0) { "function $name has no body" }
        var depth = 0
        for (index in open until source.length) {
            when (source[index]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return source.substring(open + 1, index)
            }
        }
        error("function $name body does not close")
    }
}
