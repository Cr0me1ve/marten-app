package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreProcessServiceNetworkBindingSourceGuardTest {
    @Test
    fun `diagnostics binds only an open core to its verified network and fails closed otherwise`() {
        val service = source("CoreProcessService.kt")
        val diagnostics = section(service, "\"diagnostics\" -> {", "\"setup\" -> {")
        val setup = section(service, "\"setup\" -> {", "\"start\" ->")
        val remote = File("src/main/kotlin/app/marten/client/bg/RemoteMobile.kt").readText()
        val update = section(remote, "fun updateCrashReporting(", "private class PlatformLease")
        val boxService = File("src/main/kotlin/app/marten/client/bg/BoxService.kt").readText()
        val started = section(
            boxService,
            "private suspend fun markCoreRuntimeStarted(",
            "private suspend fun awaitTunRuntimeHealthForStarted()",
        )

        assertTrue("diagnostics admission must serialize with close on one lock", diagnostics.contains("synchronized(diagnosticsLock)"))
        assertTrue(
            "a queued stale proof cannot rebind after close seals the background owner",
            diagnostics.contains("backgroundOpen && network != null && connectivity.bindProcessToNetwork(network)"),
        )
        assertTrue("native diagnostics require the same admitted VPN network", diagnostics.contains("setNetworkAdmissionAllowed(admitted)"))
        assertTrue(
            "Crashlytics collection remains enabled only when both user opt-in and verified admission are true",
            diagnostics.contains("setCrashlyticsCollectionEnabled(enabled && admitted)"),
        )
        assertTrue("core setup opens diagnostics only for a real platform lease after native setup succeeds", setup.indexOf("Mobile.setup(") < setup.indexOf("if (platform != null) synchronized(diagnosticsLock) { backgroundOpen = true }"))
        assertTrue("Dart opt-out and strict-route admission are forwarded to the core", update.contains("getBoolean(\"flutter.enable_analytics\", true)") && update.contains("if (Settings.strictVpnRouteVerified)"))
        assertTrue("the verified Started transition records proof before requesting diagnostics", started.indexOf("Settings.strictVpnRouteVerified = true") in 0 until started.indexOf("Mobile.updateCrashReporting()"))
    }

    @Test
    fun `close seals diagnostics before unbinding and completes native cleanup despite optional SDK failures`() {
        val service = source("CoreProcessService.kt")
        val close = section(service, "\"close\" -> {", "\"reset\" ->")

        val seal = close.indexOf("backgroundOpen = false")
        val denyNativeAdmission = close.indexOf("setNetworkAdmissionAllowed(false)")
        val disableCollection = close.indexOf("setCrashlyticsCollectionEnabled(false)")
        val releaseNetwork = close.indexOf("bindProcessToNetwork(null)")
        val nativeClose = close.indexOf("Mobile.close(request.getLong(\"mode\"))")
        val descriptorClose = close.indexOf("platforms.forEach { it.closeDescriptors() }")
        val checkRelease = close.indexOf("check(networkReleased)")

        assertTrue("close seals queued callbacks while holding the diagnostics lock", close.contains("synchronized(diagnosticsLock)") && seal >= 0)
        assertTrue("close revokes native network admission before releasing the binding", denyNativeAdmission > seal && releaseNetwork > denyNativeAdmission)
        assertTrue("optional Crashlytics disable cannot prevent core cleanup", disableCollection > seal && close.contains("runCatching {\n                                        com.google.firebase.crashlytics.FirebaseCrashlytics"))
        assertTrue("the exact process binding is released before native close", nativeClose > releaseNetwork)
        assertTrue("native close and transferred descriptor cleanup precede reporting unbind failure", descriptorClose > nativeClose && checkRelease > descriptorClose)
    }

    private fun source(name: String): String {
        val candidates = listOf(
            File("src/main/kotlin/app/marten/client/bg/$name"),
            File("android/app/src/main/kotlin/app/marten/client/bg/$name"),
        )
        return candidates.firstOrNull { it.isFile }?.readText()
            ?: error("missing production source $name")
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
