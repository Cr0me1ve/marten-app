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
import android.content.ServiceConnection
import android.os.IBinder
import android.os.RemoteException
import android.util.Log
import androidx.appcompat.app.AppCompatActivity


class ServiceConnection(private val context: Context, callback: Callback, private val register: Boolean = true) : ServiceConnection {
    companion object {
        private const val TAG = "ServiceConnection"
    }

    private val callback = ServiceCallback(callback)
    private val bindingLock = Any()

    @Volatile
    private var service: IService? = null
    @Volatile
    private var bound = false

    val currentStatus get() = service?.let { boundService ->
        runCatching { Status.values()[boundService.status] }.getOrNull()
    }
    val status get() = currentStatus ?: Status.Stopped

    fun connect() {
        val shouldBind = synchronized(bindingLock) {
            if (bound) {
                false
            } else {
                bound = true
                true
            }
        }
        if (!shouldBind) return

        val intent = Intent(context, Settings.serviceClass()).setAction(Action.SERVICE)
        val accepted = runCatching {
            context.bindService(intent, this, AppCompatActivity.BIND_AUTO_CREATE)
        }.getOrElse {
            synchronized(bindingLock) {
                bound = false
            }
            throw it
        }
        if (!accepted) {
            synchronized(bindingLock) {
                bound = false
            }
            Log.w(TAG, "service binding request was rejected")
            return
        }
        Log.d(TAG, "request connect")
    }

    fun disconnect() {
        val (wasBound, disconnectedService) = synchronized(bindingLock) {
            val wasBound = bound
            bound = false
            val disconnectedService = service
            service = null
            wasBound to disconnectedService
        }
        if (register) {
            try {
                disconnectedService?.unregisterCallback(callback)
            } catch (e: RemoteException) {
                Log.e(TAG, "cleanup service connection", e)
            }
        }
        if (wasBound) {
            try {
                context.unbindService(this)
            } catch (_: IllegalArgumentException) {
            }
        }
        Log.d(TAG, "request disconnect")
    }

    fun reconnect() {
        disconnect()
        connect()
        Log.d(TAG, "request reconnect")
    }

    override fun onServiceConnected(name: ComponentName, binder: IBinder) {
        val connectedService = IService.Stub.asInterface(binder)
        val accepted = synchronized(bindingLock) {
            if (!bound) {
                false
            } else {
                service = connectedService
                true
            }
        }
        if (!accepted) {
            Log.i(TAG, "ignoring service connection delivered after unbind")
            return
        }
        try {
            if (register) connectedService.registerCallback(callback)
            val replayedStatus = connectedService.status
            callback.onServiceStatusChanged(replayedStatus)
            Log.i(
                TAG,
                "service connected; replayed status=${Status.values().getOrNull(replayedStatus)?.name ?: "invalid"}",
            )
        } catch (e: RemoteException) {
            Log.e(TAG, "initialize service connection", e)
        }
    }

    override fun onServiceDisconnected(name: ComponentName?) {
        val disconnectedService = synchronized(bindingLock) {
            val disconnectedService = service
            service = null
            disconnectedService
        }
        try {
            disconnectedService?.unregisterCallback(callback)
        } catch (e: RemoteException) {
            Log.e(TAG, "cleanup service connection", e)
        }
        Log.d(TAG, "service disconnected")
    }

    override fun onBindingDied(name: ComponentName?) {
        val shouldReconnect = synchronized(bindingLock) { bound }
        if (shouldReconnect) {
            reconnect()
        }
        Log.d(TAG, "service dead")
    }

    interface Callback {
        fun onServiceStatusChanged(status: Status)

        fun onServiceAlert(type: Alert, message: String?) {
        }

        fun onServiceWriteLog(message: String?) {
        }

        fun onServiceResetLogs(messages: List<String?>?) {
        }
    }

    class ServiceCallback(private val callback: Callback) : IServiceCallback.Stub() {
        override fun onServiceStatusChanged(status: Int) {
            callback.onServiceStatusChanged(Status.values()[status])
        }

        override fun onServiceAlert(type: Int, message: String?) {
            callback.onServiceAlert(Alert.values()[type], message)
        }

        override fun onServiceWriteLog(message: String?) {
            callback.onServiceWriteLog(message)
        }

        override fun onServiceResetLogs(messages: List<String?>?) {
            callback.onServiceResetLogs(messages)
        }
    }
}
