package app.marten.client.bg

import kotlinx.coroutines.Deferred

internal data class StartupNetworkObservation(val usable: Boolean, val changed: Deferred<Unit>)

/** A callback wait has no online deadline; owner retirement is a terminal observation. */
internal suspend fun awaitStartupNetworkObservation(observe: () -> StartupNetworkObservation?): Boolean {
    while (true) {
        val snapshot = observe() ?: return false
        if (snapshot.usable) return true
        snapshot.changed.await()
    }
}
