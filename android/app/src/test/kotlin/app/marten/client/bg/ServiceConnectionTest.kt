package app.marten.client.bg

import android.content.ComponentName
import android.content.Intent
import android.content.SharedPreferences
import android.content.ServiceConnection as AndroidServiceConnection
import app.marten.client.Application
import app.marten.client.IService
import app.marten.client.IServiceCallback
import app.marten.client.Settings
import app.marten.client.constant.Alert
import app.marten.client.constant.ServiceMode
import app.marten.client.constant.SettingsKey
import app.marten.client.constant.Status
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

private class RecordingService(private val initialStatus: Status) : IService.Stub() {
    var registerCalls = 0
    var unregisterCalls = 0
    var lastStatus = initialStatus

    override fun getStatus(): Int = lastStatus.ordinal

    override fun registerCallback(callback: IServiceCallback) {
        registerCalls++
    }

    override fun unregisterCallback(callback: IServiceCallback?) {
        unregisterCalls++
    }
}

private class TestSharedPreferences : SharedPreferences {
    private val values = mutableMapOf<String, Any?>(
        SettingsKey.SERVICE_MODE to ServiceMode.VPN,
    )

    override fun getAll(): MutableMap<String, *> = values.toMutableMap()
    override fun getBoolean(key: String, defValue: Boolean): Boolean = (values[key] as? Boolean) ?: defValue
    override fun getFloat(key: String, defValue: Float): Float = (values[key] as? Float) ?: defValue
    override fun getInt(key: String, defValue: Int): Int = (values[key] as? Int) ?: defValue
    override fun getLong(key: String, defValue: Long): Long = (values[key] as? Long) ?: defValue
    override fun getString(key: String, defValue: String?): String? = (values[key] as? String) ?: defValue
    override fun getStringSet(key: String, defValue: MutableSet<String>?): MutableSet<String>? =
        (values[key] as? MutableSet<String>) ?: defValue

    override fun contains(key: String): Boolean = values.containsKey(key)

    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = apply { values[key] = value }
        override fun putFloat(key: String, value: Float): SharedPreferences.Editor = apply { values[key] = value }
        override fun putInt(key: String, value: Int): SharedPreferences.Editor = apply { values[key] = value }
        override fun putLong(key: String, value: Long): SharedPreferences.Editor = apply { values[key] = value }
        override fun putString(key: String, value: String?): SharedPreferences.Editor = apply { values[key] = value }

        override fun putStringSet(
            key: String,
            values: MutableSet<String>?,
        ): SharedPreferences.Editor = apply {
            this@TestSharedPreferences.values[key] = values
        }

        override fun remove(key: String): SharedPreferences.Editor = apply { values.remove(key) }
        override fun clear(): SharedPreferences.Editor = apply { values.clear() }
        override fun commit(): Boolean = true
        override fun apply() {
            commit()
        }
    }

    override fun registerOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) {
    }

    override fun unregisterOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) {
    }
}

private class FakeServiceContext(
    private val testSharedPreferences: TestSharedPreferences,
    var bindResult: Boolean = true,
    var connectNow: ((AndroidServiceConnection) -> Unit)? = null,
) : android.app.Application() {
    var bindCalls = 0
    var unbindCalls = 0
    var lastIntent: Intent? = null
    var throwOnBind: RuntimeException? = null
    val capturedConnections = mutableListOf<AndroidServiceConnection>()

    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = testSharedPreferences

    override fun bindService(service: Intent, conn: AndroidServiceConnection, flags: Int): Boolean {
        bindCalls += 1
        lastIntent = service
        capturedConnections += conn
        throwOnBind?.let { throw it }
        if (bindResult) {
            connectNow?.invoke(conn)
        }
        return bindResult
    }

    override fun unbindService(conn: AndroidServiceConnection) {
        unbindCalls += 1
    }

    override fun getPackageName(): String = "app.marten.client.bg.test"
    override fun getClassLoader(): ClassLoader = requireNotNull(javaClass.classLoader)
}

class NoopApplication : android.app.Application()

private class NoopServiceCallback : ServiceConnection.Callback {
    override fun onServiceStatusChanged(status: Status) {}
    override fun onServiceAlert(type: Alert, message: String?) {}
    override fun onServiceWriteLog(message: String?) {}
    override fun onServiceResetLogs(messages: List<String?>?) {}
}

private class RecordingServiceCallback : ServiceConnection.Callback {
    val statuses = mutableListOf<Status>()
    var bindingFailures = 0

    override fun onServiceStatusChanged(status: Status) {
        statuses += status
    }

    override fun onServiceBindingFailed() {
        bindingFailures += 1
    }
}

private inline fun withFakeSettingsPrefs(block: (FakeServiceContext) -> Unit) {
    val preferencesField = Settings::class.java.getDeclaredField("preferences\$delegate").apply {
        isAccessible = true
    }
    val preferencesDelegate = preferencesField.get(null)
    val preferencesValueField = preferencesDelegate!!::class.java.getDeclaredField("_value").apply {
        isAccessible = true
    }
    val previousPreferencesValue = preferencesValueField.get(preferencesDelegate)
    val sharedPreferences = TestSharedPreferences()
    val context = FakeServiceContext(sharedPreferences)
    try {
        preferencesValueField.set(preferencesDelegate, sharedPreferences)
        block(context)
    } finally {
        preferencesValueField.set(preferencesDelegate, previousPreferencesValue)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = NoopApplication::class, manifest = Config.NONE)
class ServiceConnectionTest {
    @Test
    fun `late bind registers and replays retained started status`() = withFakeSettingsPrefs { context ->
        val fakeService = RecordingService(Status.Stopped).apply {
            lastStatus = Status.Started
        }
        context.connectNow = { connection ->
            connection.onServiceConnected(ComponentName(context, fakeService.javaClass), fakeService.asBinder())
        }
        val callback = RecordingServiceCallback()
        val connection = ServiceConnection(context, callback)

        connection.connect()

        assertEquals(1, fakeService.registerCalls)
        assertEquals(listOf(Status.Started), callback.statuses)
        assertEquals(Status.Started, connection.currentStatus)
    }

    @Test
    fun `duplicate connect runs one bind call`() = withFakeSettingsPrefs { context ->
        val fakeService = RecordingService(Status.Started)
        context.connectNow = { connection ->
            connection.onServiceConnected(ComponentName(context, fakeService.javaClass), fakeService.asBinder())
        }

        val connection = ServiceConnection(context, NoopServiceCallback())
        connection.connect()
        connection.connect()

        assertEquals(1, context.bindCalls)
        assertEquals(Status.Started, connection.currentStatus)
    }

    @Test
    fun `disconnect unbinds once and clears current status`() = withFakeSettingsPrefs { context ->
        val fakeService = RecordingService(Status.Started)
        context.connectNow = { connection ->
            connection.onServiceConnected(ComponentName(context, fakeService.javaClass), fakeService.asBinder())
        }

        val connection = ServiceConnection(context, NoopServiceCallback())
        connection.connect()
        connection.disconnect()

        assertEquals(1, context.unbindCalls)
        assertNull(connection.currentStatus)
        assertEquals(1, fakeService.unregisterCalls)
    }

    @Test
    fun `subsequent connect rebinds after disconnect`() = withFakeSettingsPrefs { context ->
        val fakeService = RecordingService(Status.Started)
        val secondService = RecordingService(Status.Starting)
        var connected = false
        context.connectNow = { connection ->
            connected = !connected
            connection.onServiceConnected(
                ComponentName(context, fakeService.javaClass),
                if (connected) fakeService.asBinder() else secondService.asBinder(),
            )
        }

        val connection = ServiceConnection(context, NoopServiceCallback())
        connection.connect()
        connection.disconnect()
        connection.connect()

        assertEquals(2, context.bindCalls)
        assertEquals(Status.Starting, connection.currentStatus)
    }

    @Test
    fun `binding died after deliberate disconnect does not reconnect`() = withFakeSettingsPrefs { context ->
        val fakeService = RecordingService(Status.Started)
        context.connectNow = { connection ->
            connection.onServiceConnected(ComponentName(context, fakeService.javaClass), fakeService.asBinder())
        }

        val connection = ServiceConnection(context, NoopServiceCallback())
        connection.connect()
        connection.disconnect()
        connection.onBindingDied(ComponentName("app.marten.client.bg.test", "box-service"))

        assertEquals(1, context.bindCalls)
        assertEquals(1, context.unbindCalls)
        assertEquals(1, fakeService.unregisterCalls)
    }

    @Test
    fun `rejected bind can be retried`() = withFakeSettingsPrefs { context ->
        val fakeService = RecordingService(Status.Started)
        context.connectNow = { connection ->
            connection.onServiceConnected(ComponentName(context, fakeService.javaClass), fakeService.asBinder())
        }

        val connection = ServiceConnection(context, NoopServiceCallback())
        context.bindResult = false
        connection.connect()

        context.bindResult = true
        context.connectNow = { connection ->
            connection.onServiceConnected(ComponentName(context, fakeService.javaClass), fakeService.asBinder())
        }
        connection.connect()

        assertEquals(2, context.bindCalls)
        assertEquals(Status.Started, connection.currentStatus)
    }

    @Test
    fun `rejected and throwing binds report one failure each and stale callbacks cannot satisfy retry`() =
        withFakeSettingsPrefs { context ->
            val callback = RecordingServiceCallback()
            val connection = ServiceConnection(context, callback)

            context.bindResult = false
            assertEquals(false, connection.connect())
            assertEquals(1, callback.bindingFailures)
            assertNull(connection.currentStatus)
            val rejectedAttempt = context.capturedConnections.single()

            context.bindResult = true
            context.throwOnBind = IllegalStateException("system service rejected the bind")
            assertEquals(false, connection.connect())
            assertEquals(2, callback.bindingFailures)
            assertNull(connection.currentStatus)
            val throwingAttempt = context.capturedConnections.last()

            context.throwOnBind = null
            assertEquals(true, connection.connect())
            assertEquals(3, context.capturedConnections.size)
            val retryAttempt = context.capturedConnections.last()
            val service = RecordingService(Status.Started)
            val component = ComponentName(context, service.javaClass)

            rejectedAttempt.onServiceConnected(component, service.asBinder())
            throwingAttempt.onServiceConnected(component, service.asBinder())
            assertEquals(emptyList<Status>(), callback.statuses)
            assertNull(connection.currentStatus)

            retryAttempt.onServiceConnected(component, service.asBinder())
            assertEquals(listOf(Status.Started), callback.statuses)
            assertEquals(Status.Started, connection.currentStatus)
            assertEquals(2, callback.bindingFailures)
        }
}
