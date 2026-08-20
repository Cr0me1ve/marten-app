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
        val reconnect = restore.indexOf("connection.connect()")

        assertTrue("restoreServicePresentation should sync from service owner", statusRead >= 0)
        assertTrue("restoreServicePresentation should immediately reconnect", reconnect >= 0)
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
        assertTrue(onResume.indexOf("super.onResume()") < onResume.indexOf("restoreServicePresentation()"))
    }

    @Test
    fun `permission callbacks retain pending config identity until start service zero or an explicit denial`() {
        val activity = sourceFile("MainActivity.kt")
        val notificationCallback = sourceSection(
            activity,
            "private val notificationPermissionLauncher =",
            "private val prepareLauncher =",
        )
        val vpnCallback = sourceSection(
            activity,
            "private val prepareLauncher =",
            "private fun clearPendingStartConfigIdentity()",
        )
        val requestPermissions = functionBody(activity, "onRequestPermissionsResult")
        val activityResult = functionBody(activity, "onActivityResult")

        listOf(notificationCallback, vpnCallback, requestPermissions, activityResult).forEach { callback ->
            assertTrue(
                "permission grant must preserve the pending route identity through startService0",
                callback.contains("startService0()"),
            )
            assertFalse(
                "permission callback must not restart through startService() and discard its identity",
                callback.contains("startService()"),
            )
            assertTrue(
                "permission denial must clear the pending route identity",
                callback.contains("clearPendingStartConfigIdentity()"),
            )
        }
    }

    @Test
    fun `status observation in EventHandler restores service presentation before observeForever`() {
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

        assertTrue(onListen.contains("activity.restoreServicePresentation()"))
        assertTrue(onListen.contains("statusObserver = Observer"))
        assertTrue(onListen.contains("activity.serviceStatus.observeForever(statusObserver!!)"))
        assertFalse(onListen.indexOf("activity.restoreServicePresentation()") > onListen.indexOf("activity.serviceStatus.observeForever(statusObserver!!)"))

        val restore = onListen.indexOf("activity.restoreServicePresentation()")
        val attachObserver = onListen.indexOf("statusObserver = Observer")
        val observeForever = onListen.indexOf("activity.serviceStatus.observeForever(statusObserver!!)")
        assertTrue("restoration must happen before creating the observer", restore < attachObserver)
        assertTrue("observation must happen after observer creation", attachObserver < observeForever)
        assertTrue(restore < observeForever)
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
