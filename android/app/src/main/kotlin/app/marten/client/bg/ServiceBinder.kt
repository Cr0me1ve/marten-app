package app.marten.client.bg

import android.os.RemoteCallbackList
import android.util.Log
import androidx.lifecycle.MutableLiveData
import app.marten.client.IService
import app.marten.client.IServiceCallback
import app.marten.client.constant.Status
import app.marten.client.crashreporting.NativeCrashDiagnostics
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
class ServiceBinder(private val status: MutableLiveData<Status>) : IService.Stub() {
    companion object {
        private const val TAG = "ServiceBinder"
    }

    private val callbacks = RemoteCallbackList<IServiceCallback>()
    private val broadcastLock = Mutex()

    init {
        status.observeForever {
            NativeCrashDiagnostics.logPhase("box_service", "status_${it.name.lowercase()}")
            broadcast { callback ->
                callback.onServiceStatusChanged(it.ordinal)
            }
        }
    }

    @OptIn(DelicateCoroutinesApi::class)
    fun broadcast(work: (IServiceCallback) -> Unit) {
        GlobalScope.launch(Dispatchers.Main) {
            broadcastLock.withLock {
                val count = callbacks.beginBroadcast()
                try {
                    repeat(count) {
                        try {
                            work(callbacks.getBroadcastItem(it))
                        } catch (e: Throwable) {
                            Log.w(TAG, "service callback failed", e)
                        }
                    }
                } finally {
                    callbacks.finishBroadcast()
                }
            }
        }
    }

    override fun getStatus(): Int = (status.value ?: Status.Stopped).ordinal

    override fun registerCallback(callback: IServiceCallback) {
        callbacks.register(callback)
    }

    override fun unregisterCallback(callback: IServiceCallback?) {
        callbacks.unregister(callback)
    }

    fun close() {
        callbacks.kill()
    }
}
