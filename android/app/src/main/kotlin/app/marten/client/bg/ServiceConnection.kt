package app.marten.client.bg

import app.marten.client.IService
import app.marten.client.IServiceCallback
import app.marten.client.Settings
import app.marten.client.constant.Action
import app.marten.client.constant.Alert
import app.marten.client.constant.Status
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection as AndroidServiceConnection
import android.os.IBinder
import android.os.RemoteException
import android.util.Log
import androidx.appcompat.app.AppCompatActivity


class ServiceConnection(private val context: Context, callback: Callback, private val register: Boolean = true) : AndroidServiceConnection {
    companion object {
        private const val TAG = "ServiceConnection"
    }

    private val target = callback
    private val bindingLock = Any()
    @Volatile private var service: IService? = null
    private var attempt: Attempt? = null

    private inner class Attempt : AndroidServiceConnection {
        val callback = ServiceCallback(target) { synchronized(bindingLock) { attempt === this } }
        var bound = false
        override fun onServiceConnected(name: ComponentName, binder: IBinder) = connected(this, binder)
        override fun onServiceDisconnected(name: ComponentName?) { failed(this) }
        override fun onNullBinding(name: ComponentName?) { failed(this) }
        override fun onBindingDied(name: ComponentName?) {
            if (failed(this)) connect()
        }
    }

    val currentStatus get() = service?.let { boundService ->
        runCatching { Status.values()[boundService.status] }.getOrNull()
    }
    val status get() = currentStatus ?: Status.Stopped

    fun connect(): Boolean {
        val request = synchronized(bindingLock) {
            if (attempt != null) return true
            Attempt().also { attempt = it }
        }
        val intent = Intent(context, Settings.serviceClass()).setAction(Action.SERVICE)
        val accepted = runCatching {
            synchronized(bindingLock) {
                if (attempt !== request) return false
                context.bindService(intent, request, AppCompatActivity.BIND_AUTO_CREATE).also { request.bound = it }
            }
        }.getOrDefault(false)
        if (accepted && synchronized(bindingLock) { attempt !== request }) {
            cleanup(request, null)
            return false
        }
        if (!accepted) {
            Log.w(TAG, "service binding request was rejected")
            failed(request)
        }
        return accepted
    }

    private fun failed(request: Attempt): Boolean {
        val removed = remove(request) ?: return false
        cleanup(request, removed.second)
        target.onServiceBindingFailed()
        return true
    }

    private fun remove(request: Attempt): Pair<Boolean, IService?>? = synchronized(bindingLock) {
        if (attempt !== request) return@synchronized null
        attempt = null
        val disconnectedService = service
        service = null
        request.bound to disconnectedService
    }

    private fun cleanup(request: Attempt, disconnectedService: IService?) {
        if (register) runCatching { disconnectedService?.unregisterCallback(request.callback) }
        if (request.bound) {
            request.bound = false
            runCatching { context.unbindService(request) }
        }
    }

    fun disconnect() {
        val request = synchronized(bindingLock) { attempt } ?: return
        val removed = remove(request) ?: return
        cleanup(request, removed.second)
    }

    fun reconnect() { disconnect(); connect() }

    private fun connected(request: Attempt, binder: IBinder) {
        val connectedService = IService.Stub.asInterface(binder)
        synchronized(bindingLock) {
            if (attempt !== request) return
            service = connectedService
        }
        try {
            if (register) connectedService.registerCallback(request.callback)
            val status = connectedService.status
            if (Status.values().getOrNull(status) == null) failed(request)
            else request.callback.onServiceStatusChanged(status)
        } catch (_: RemoteException) {
            failed(request)
        }
    }

    // Preserve the Android callback surface for existing callers/tests. Actual
    // OS binds use a distinct Attempt, so callbacks from a retired bind cannot
    // complete a successor's pending Quick Settings command.
    override fun onServiceConnected(name: ComponentName, binder: IBinder) {
        synchronized(bindingLock) { attempt }?.let { connected(it, binder) }
    }
    override fun onServiceDisconnected(name: ComponentName?) {
        synchronized(bindingLock) { attempt }?.let { failed(it) }
    }
    override fun onBindingDied(name: ComponentName?) {
        synchronized(bindingLock) { attempt }?.onBindingDied(name)
    }
    override fun onNullBinding(name: ComponentName?) {
        synchronized(bindingLock) { attempt }?.let { failed(it) }
    }

    interface Callback {
        fun onServiceStatusChanged(status: Status)
        fun onServiceBindingFailed() {}

        fun onServiceAlert(type: Alert, message: String?) {
        }

        fun onServiceWriteLog(message: String?) {
        }

        fun onServiceResetLogs(messages: List<String?>?) {
        }
    }

    class ServiceCallback(private val callback: Callback, private val isCurrent: () -> Boolean = { true }) : IServiceCallback.Stub() {
        override fun onServiceStatusChanged(status: Int) {
            if (isCurrent()) Status.values().getOrNull(status)?.let(callback::onServiceStatusChanged)
        }

        override fun onServiceAlert(type: Int, message: String?) {
            if (isCurrent()) Alert.values().getOrNull(type)?.let { callback.onServiceAlert(it, message) }
        }

        override fun onServiceWriteLog(message: String?) {
            if (isCurrent()) callback.onServiceWriteLog(message)
        }

        override fun onServiceResetLogs(messages: List<String?>?) {
            if (isCurrent()) callback.onServiceResetLogs(messages)
        }
    }
}
