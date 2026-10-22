package app.marten.client

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ServicePresentationReattachSourceGuardTest {
    @Test
    fun `onCreate publishes the activity instance before cached Flutter engine attachment`() {
        val activity = sourceFile("MainActivity.kt")
        val onCreate = functionBody(activity, "onCreate")

        val publishInstance = onCreate.indexOf("instance = this")
        val attachCachedEngine = onCreate.indexOf("super.onCreate(savedInstanceState)")

        assertTrue("onCreate must publish MainActivity before Flutter attaches its cached engine", publishInstance >= 0)
        assertTrue("onCreate must attach the Flutter engine", attachCachedEngine >= 0)
        assertTrue("MainActivity instance must be available before cached engine attachment", publishInstance < attachCachedEngine)
    }

    @Test
    fun `restoreServicePresentation must update cached service status before reconnecting`() {
        val activity = sourceFile("MainActivity.kt")
        val restore = functionBody(activity, "restoreServicePresentation")

        val statusRead = restore.indexOf("serviceStatus.value = BoxService.currentPlatformStatus()")
        val reconnect = restore.indexOf("connectServicePresentation()")

        assertTrue("restoreServicePresentation should sync from service owner", statusRead >= 0)
        assertTrue("restoreServicePresentation should immediately reconnect through the lifecycle gate", reconnect >= 0)
        assertTrue("service status must be refreshed before reconnecting", statusRead < reconnect)
    }

    @Test
    fun `onStart and onResume re-attach presentation on every lifecycle boundary`() {
        val activity = sourceFile("MainActivity.kt")
        val onStart = functionBody(activity, "onStart")
        val onResume = functionBody(activity, "onResume")

        assertTrue(onStart.contains("restoreServicePresentation()"))
        assertTrue(onResume.contains("restoreServicePresentation()"))
        assertTrue(onStart.indexOf("super.onStart()") < onStart.indexOf("restoreServicePresentation()"))
        assertTrue(onStart.indexOf("servicePresentationActive = true") < onStart.indexOf("restoreServicePresentation()"))
        assertTrue(onResume.indexOf("super.onResume()") < onResume.indexOf("restoreServicePresentation()"))
    }

    @Test
    fun `onStop disconnects presentation binding while lifecycle reattachment remains available`() {
        val activity = sourceFile("MainActivity.kt")
        val onStop = functionBody(activity, "onStop")

        val deactivatePresentation = onStop.indexOf("servicePresentationActive = false")
        val disconnect = onStop.indexOf("connection.disconnect()")
        assertTrue("onStop must deactivate presentation before late service callbacks can connect", deactivatePresentation >= 0)
        assertTrue("onStop must release the activity-owned service binding", disconnect >= 0)
        assertTrue("onStop must deactivate presentation before disconnecting", deactivatePresentation < disconnect)
        assertTrue("onStop must still call through to the Activity lifecycle", onStop.contains("super.onStop()"))
    }

    @Test
    fun `presentation connection helpers and late service dispatch respect lifecycle activity`() {
        val activity = sourceFile("MainActivity.kt")
        val reconnect = functionBody(activity, "reconnect")
        val connectPresentation = functionBody(activity, "connectServicePresentation")
        val startService = functionBody(activity, "startService0")

        assertTrue(reconnect.contains("if (servicePresentationActive) connection.reconnect()"))
        assertTrue(connectPresentation.contains("if (servicePresentationActive) connection.connect()"))
        assertTrue("late service dispatch must use the lifecycle-gated connection helper", startService.contains("connectServicePresentation()"))
        assertFalse("late service dispatch must not bypass the presentation connection gate", startService.contains("connection.connect()"))
        assertFalse("late service dispatch must not bypass the presentation reconnection gate", startService.contains("connection.reconnect()"))
    }

    @Test
    fun `main activity does not retain or fan out service logs to an unused Flutter channel`() {
        val activity = sourceFile("MainActivity.kt")

        listOf(
            "LogHandler()",
            "logList",
            "logCallback",
            "onServiceWriteLog",
            "onServiceResetLogs",
            "runOnUiThread",
        ).forEach { legacyLogFanOut ->
            assertFalse(
                "MainActivity must not retain or deliver unused service logs through $legacyLogFanOut",
                activity.contains(legacyLogFanOut),
            )
        }
    }

    @Test
    fun `only VPN permission callbacks retain pending config identity until start service zero or an explicit denial`() {
        val activity = sourceFile("MainActivity.kt")
        val vpnCallback = sourceSection(
            activity,
            "private val prepareLauncher =",
            "private fun clearPendingStartConfigIdentity()",
        )

        assertTrue(
            "VPN permission grant must preserve the pending route identity through startService0",
            vpnCallback.contains("startService0()"),
        )
        assertFalse(
            "VPN permission callback must not restart through startService() and discard its identity",
            vpnCallback.contains("startService()"),
        )
        assertTrue(
            "VPN permission denial must clear the pending route identity",
            vpnCallback.contains("clearPendingStartConfigIdentity()"),
        )
        listOf(
            "awaitStrictNotificationPermission",
            "notificationPermissionLauncher",
            "pendingStrictNotificationPermission",
            "POST_NOTIFICATIONS",
            "RequestNotificationPermission",
        ).forEach { notificationAdmissionArtifact ->
            assertFalse(
                "MainActivity VPN admission must not retain or request notification permission through $notificationAdmissionArtifact",
                activity.contains(notificationAdmissionArtifact),
            )
        }
    }

    @Test
    fun `status observation in EventHandler uses the service-owned platform status source`() {
        val source = sourceFile("EventHandler.kt")
        val statusHandler = sourceSection(
            source,
            "statusChannel!!.setStreamHandler(object : EventChannel.StreamHandler {",
            "alertsChannel!!.setStreamHandler(object : EventChannel.StreamHandler {",
        )

        val onListen = sourceSection(
            statusHandler,
            "override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {",
            "override fun onCancel(arguments: Any?) {",
        )

        assertTrue(onListen.contains("statusObserver?.let(BoxService::removePlatformStatusObserver)"))
        assertTrue(onListen.contains("statusObserver = Observer"))
        assertTrue(onListen.contains("BoxService.observePlatformStatus(statusObserver!!)"))

        val removePreviousObserver = onListen.indexOf("statusObserver?.let(BoxService::removePlatformStatusObserver)")
        val attachObserver = onListen.indexOf("statusObserver = Observer")
        val observePlatformStatus = onListen.indexOf("BoxService.observePlatformStatus(statusObserver!!)")
        assertTrue("the previous service-owned observer must be removed before creating a replacement", removePreviousObserver < attachObserver)
        assertTrue("observation must happen after observer creation", attachObserver < observePlatformStatus)
        assertTrue("the previous service-owned observer must be removed before observing again", removePreviousObserver < observePlatformStatus)

        val onCancel = sourceSection(
            statusHandler,
            "override fun onCancel(arguments: Any?) {",
            "        })",
        )
        val removeCancelledObserver = onCancel.indexOf("statusObserver?.let(BoxService::removePlatformStatusObserver)")
        val clearObserver = onCancel.indexOf("statusObserver = null")
        assertTrue("cancelling must remove the service-owned observer", removeCancelledObserver >= 0)
        assertTrue("cancelling must clear the stored observer", clearObserver >= 0)
        assertTrue("cancelling must remove the observer before clearing it", removeCancelledObserver < clearObserver)

        assertFalse("EventHandler must not observe MainActivity's cached status", statusHandler.contains("serviceStatus.observeForever"))
        assertFalse("EventHandler must not restore activity presentation for status streams", statusHandler.contains("restoreServicePresentation()"))
    }

    private fun sourceFile(name: String): String {
        val source = File("src/main/kotlin/app/marten/client/$name")
        check(source.isFile) { "missing production source ${source.path}" }
        return source.readText()
    }

    private fun sourceSection(source: String, startMarker: String, endMarker: String): String {
        val start = source.indexOf(startMarker)
        val end = source.indexOf(endMarker, start + startMarker.length)
        require(start >= 0 && end >= 0) { "missing source section: $startMarker" }
        return source.substring(start, end)
    }

    private fun functionBody(source: String, name: String): String {
        val declaration = source.indexOf("fun $name")
        require(declaration >= 0) { "missing function $name" }
        val start = source.indexOf('{', declaration)
        require(start >= 0) { "function $name has no body" }
        var depth = 0
        for (index in start until source.length) {
            when (source[index]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return source.substring(start + 1, index)
            }
        }
        error("function $name body does not close")
    }
}
