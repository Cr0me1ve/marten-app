package app.marten.client.bg

import android.content.Context
import android.util.Log
import androidx.work.ListenableWorker
import androidx.work.WorkerFactory
import androidx.work.WorkerParameters
import app.marten.client.crashreporting.NativeCrashDiagnostics
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import dev.fluttercommunity.workmanager.BackgroundWorker

/**
 * Prevents WorkManager from starting a headless Flutter engine while Marten's
 * owner UID could still open an ordinary socket outside an admitted route.
 *
 * WorkManager itself is initialized lazily when the foreground Flutter plugin
 * attaches. That initialization is local scheduler/database work. The only
 * Marten job is the plugin's [BackgroundWorker], and this factory ensures its
 * Dart code cannot run during a live strict-VPN transition. It may run when
 * the current service owns a fresh data-plane proof for its exact start,
 * Android Network, and TUN generations, or when that service has fully
 * released the terminal state and ordinary networking is safe again.
 */
internal object StrictVpnWorkerFactory : WorkerFactory() {
    override fun createWorker(
        appContext: Context,
        workerClassName: String,
        workerParameters: WorkerParameters,
    ): ListenableWorker? {
        if (workerClassName != BackgroundWorker::class.java.name) return null
        return StrictVpnBackgroundWorker(appContext, workerParameters)
    }
}

internal class StrictVpnBackgroundWorker(
    appContext: Context,
    private val workerParameters: WorkerParameters,
) : ListenableWorker(appContext, workerParameters) {
    private val delegateLock = Any()

    @Volatile
    private var delegate: BackgroundWorker? = null

    override fun startWork(): ListenableFuture<Result> {
        val worker = synchronized(delegateLock) {
            val verifiedVpnRoute =
                NativeCrashDiagnostics.isNetworkAdmissionAllowed() &&
                    BoxService.hasVerifiedRouteForOptionalBackgroundWork()
            val terminalOrdinaryNetwork =
                BoxService.hasTerminalOrdinaryNetworkAdmissionForOptionalBackgroundWork()
            if (isStopped || (!verifiedVpnRoute && !terminalOrdinaryNetwork)) {
                Log.i(TAG, "background work deferred until VPN route proof or terminal network release")
                return Futures.immediateFuture(Result.retry())
            }
            Log.i(
                TAG,
                if (verifiedVpnRoute) {
                    "background work admitted through verified VPN route"
                } else {
                    "background work admitted after terminal network release"
                },
            )
            BackgroundWorker(applicationContext, workerParameters).also {
                delegate = it
            }
        }
        return worker.startWork()
    }

    override fun onStopped() {
        synchronized(delegateLock) {
            delegate?.stop(stopReason)
        }
    }

    private companion object {
        const val TAG = "MartenWorkManager"
    }
}
