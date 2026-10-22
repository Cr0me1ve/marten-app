package app.marten.client.bg

import android.net.Network
import android.os.SystemClock
import android.util.Log
import app.marten.client.Application
import app.marten.core.libbox.InterfaceUpdateListener
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.net.NetworkInterface

object DefaultNetworkMonitor {
    private const val TAG = "DefaultNetworkMonitor"
    private const val MISSING_INTERFACE_CONFIRMATION_DELAY_MS = 1_000L
    private const val MISSING_NETWORK_RECONCILIATION_INTERVAL_MS = 500L
    private const val MISSING_NETWORK_RECONCILIATION_MAX_ATTEMPTS = 6
    private const val SOCKET_REJECTION_QUARANTINE_MS = 2_000L

    private class MonitorRegistration(
        val ownerToken: Long,
        val observer: ((Network?) -> Unit)?,
    )

    private class InterfaceListenerRegistration(
        val ownerToken: Long,
        val listener: InterfaceUpdateListener,
    ) {
        var lastDelivered: InterfaceAddress? = null
    }

    private data class InterfaceAddress(
        val name: String,
        val index: Int,
    )

    private data class NetworkPublication(
        val accepted: Boolean,
        val observer: ((Network?) -> Unit)? = null,
    )

    private val ownershipLock = Any()
    // Initial interface delivery is an input to native Start's route preflight.
    // Waiting for MobileCoreLifecycle here makes that Start wait for itself.
    private val interfaceUpdateMutex = Mutex()
    private val monitorScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    var defaultNetwork: Network? = null
    private var activeRegistration: MonitorRegistration? = null
    private var interfaceListenerRegistration: InterfaceListenerRegistration? = null
    private var interfaceUpdateToken = 0L
    private var missingNetworkRecoveryToken = 0L
    private var missingNetworkRecoveryInFlight = false
    private var missingNetworkRecoveryExhausted = false
    private var rejectedSocketNetwork: Network? = null
    private var rejectedSocketNetworkAtElapsed = 0L
    private var networkObservationRevision = 0L
    private var networkObservationWaiter = CompletableDeferred<Unit>()

    suspend fun start(ownerToken: Long, onNetworkChanged: ((Network?) -> Unit)? = null): Boolean {
        val registration = MonitorRegistration(ownerToken, onNetworkChanged)
        var previousRegistration: MonitorRegistration? = null
        var previousObservationWaiter: CompletableDeferred<Unit>? = null
        val admitted = ServiceLifecycleOwnership.runIfCurrent(ownerToken) {
            synchronized(ownershipLock) {
                previousRegistration = activeRegistration
                previousObservationWaiter = networkObservationWaiter
                networkObservationWaiter = CompletableDeferred()
                networkObservationRevision += 1L
                activeRegistration = registration
                defaultNetwork = null
                interfaceUpdateToken++
                missingNetworkRecoveryToken++
                missingNetworkRecoveryInFlight = false
                missingNetworkRecoveryExhausted = false
                rejectedSocketNetwork = null
                rejectedSocketNetworkAtElapsed = 0L
            }
        }
        if (!admitted) {
            return false
        }
        previousObservationWaiter?.complete(Unit)

        previousRegistration?.let {
            DefaultNetworkListener.stop(it)
        }
        DefaultNetworkListener.start(registration) networkChanged@{ network ->
            val admittedNetwork = network?.takeUnless(::isSocketNetworkQuarantined)
            val publication = publishIfActive(registration, admittedNetwork)
            if (!publication.accepted) {
                return@networkChanged
            }
            reconcileMissingNetwork(registration, admittedNetwork)
            scheduleDefaultInterfaceUpdate(admittedNetwork)
            publication.observer?.invoke(admittedNetwork)
        }
        if (!isActive(registration)) {
            DefaultNetworkListener.stop(registration)
            return false
        }

        // Starting without connectivity is a valid service state. Expiring this
        // local snapshot wait must yield null without cancelling the owner-scoped
        // startup coroutine; parent/manual cancellation still propagates normally.
        val initialNetwork = withTimeoutOrNull(MISSING_INTERFACE_CONFIRMATION_DELAY_MS) {
            DefaultNetworkListener.get()
        }
        val admittedInitialNetwork = initialNetwork?.takeUnless(::isSocketNetworkQuarantined)
        val publication = publishIfActive(registration, admittedInitialNetwork)
        if (!publication.accepted) {
            DefaultNetworkListener.stop(registration)
            return false
        }
        reconcileMissingNetwork(registration, admittedInitialNetwork)
        scheduleDefaultInterfaceUpdate(admittedInitialNetwork)
        publication.observer?.invoke(admittedInitialNetwork)
        return true
    }

    suspend fun stop(ownerToken: Long) {
        var previousObservationWaiter: CompletableDeferred<Unit>? = null
        val registration = synchronized(ownershipLock) {
            activeRegistration?.takeIf { it.ownerToken == ownerToken }?.also {
                previousObservationWaiter = networkObservationWaiter
                networkObservationWaiter = CompletableDeferred()
                networkObservationRevision += 1L
                interfaceUpdateToken++
                missingNetworkRecoveryToken++
                missingNetworkRecoveryInFlight = false
                missingNetworkRecoveryExhausted = false
                rejectedSocketNetwork = null
                rejectedSocketNetworkAtElapsed = 0L
                defaultNetwork = null
                activeRegistration = null
                if (interfaceListenerRegistration?.ownerToken == ownerToken) {
                    interfaceListenerRegistration = null
                }
            }
        }
        previousObservationWaiter?.complete(Unit)
        if (registration != null) {
            DefaultNetworkListener.stop(registration)
        }
    }

    suspend fun require(): Network {
        val network = defaultNetwork
        if (network != null) {
            return network
        }
        return DefaultNetworkListener.get()
    }

    /** Waits only for this owner's callback; stopping/replacing it wakes the waiter. */
    internal suspend fun awaitUsableNetwork(ownerToken: Long): Boolean = awaitStartupNetworkObservation {
        synchronized(ownershipLock) {
            if (activeRegistration?.ownerToken != ownerToken) null
            else StartupNetworkObservation(DefaultNetworkListener.isUsable(defaultNetwork), networkObservationWaiter)
        }
    }

    internal fun observationRevision(ownerToken: Long): Long? = synchronized(ownershipLock) {
        networkObservationRevision.takeIf { activeRegistration?.ownerToken == ownerToken }
    }

    /**
     * Sleeps primarily on Android network capability/link-property callbacks.
     * The bounded timeout is only a fallback for OEMs that update resolver
     * readiness without delivering either callback.
     */
    internal suspend fun awaitObservationAfter(
        ownerToken: Long,
        revision: Long,
        fallbackTimeoutMs: Long,
    ): Boolean {
        val waiter = synchronized(ownershipLock) {
            if (activeRegistration?.ownerToken != ownerToken) return false
            if (networkObservationRevision != revision) return true
            networkObservationWaiter
        }
        return withTimeoutOrNull(fallbackTimeoutMs.coerceAtLeast(1L)) {
            waiter.await()
            true
        } ?: false
    }

    /**
     * Resolves the physical network for a newly-created native socket.
     *
     * The callback-owned value remains authoritative while it is usable. If an
     * OEM dropped the replacement onAvailable callback, synchronously refresh
     * from ConnectivityManager before failing the dial. The recovered snapshot
     * is then published through the normal owner/generation gates so Android's
     * VPN declaration and the Go default-interface listener converge as well.
     */
    fun networkForSocket(): Network? {
        val excluded = quarantinedSocketNetwork()
        val cached = defaultNetwork
        if (cached != excluded && DefaultNetworkListener.isUsable(cached)) return cached

        val recovered = DefaultNetworkListener.snapshot(excluded)
        val registration = synchronized(ownershipLock) { activeRegistration }
        if (registration == null) return recovered
        if (recovered == null) {
            reconcileMissingNetwork(registration, null)
            return null
        }

        val publication = publishIfActive(registration, recovered)
        if (!publication.accepted) return recovered
        Log.i(TAG, "physical network snapshot recovered during socket admission")
        ConnectionDiagnostics.record(
            Application.application,
            component = "network",
            event = "socket_admission",
            outcome = "snapshot_recovered",
        )
        reconcileMissingNetwork(registration, recovered)
        scheduleDefaultInterfaceUpdate(recovered)
        publication.observer?.invoke(recovered)
        return recovered
    }

    /** Invalidates a cached physical network that netd rejected for a new fd. */
    fun reportSocketBindFailure(rejectedNetwork: Network) {
        val registration = synchronized(ownershipLock) { activeRegistration } ?: return
        var observationWaiter: CompletableDeferred<Unit>? = null
        val publication = synchronized(ownershipLock) {
            if (activeRegistration !== registration || defaultNetwork != rejectedNetwork) {
                NetworkPublication(accepted = false)
            } else {
                rejectedSocketNetwork = rejectedNetwork
                rejectedSocketNetworkAtElapsed = SystemClock.elapsedRealtime()
                defaultNetwork = null
                networkObservationRevision += 1L
                observationWaiter = networkObservationWaiter
                networkObservationWaiter = CompletableDeferred()
                NetworkPublication(accepted = true, observer = registration.observer)
            }
        }
        if (!publication.accepted) return
        observationWaiter?.complete(Unit)
        Log.w(TAG, "cached physical network rejected socket binding; reconciliation started")
        ConnectionDiagnostics.record(
            Application.application,
            component = "network",
            event = "socket_admission",
            outcome = "bind_rejected",
        )
        monitorScope.launch {
            if (!isActive(registration)) return@launch
            val refreshed = DefaultNetworkListener.refresh(registration)
            ConnectionDiagnostics.record(
                Application.application,
                component = "network",
                event = "network_request",
                outcome = if (refreshed) "refreshed" else "refresh_failed",
            )
        }
        reconcileMissingNetwork(registration, null, restartWindow = true)
        scheduleDefaultInterfaceUpdate(null)
        publication.observer?.invoke(null)
    }

    private fun quarantinedSocketNetwork(): Network? = synchronized(ownershipLock) {
        val rejected = rejectedSocketNetwork ?: return@synchronized null
        if (SystemClock.elapsedRealtime() - rejectedSocketNetworkAtElapsed < SOCKET_REJECTION_QUARANTINE_MS) {
            rejected
        } else {
            rejectedSocketNetwork = null
            rejectedSocketNetworkAtElapsed = 0L
            null
        }
    }

    private fun isSocketNetworkQuarantined(network: Network): Boolean = quarantinedSocketNetwork() == network

    fun setListener(ownerToken: Long, listener: InterfaceUpdateListener) {
        val registration = InterfaceListenerRegistration(ownerToken, listener)
        var installed = false
        ServiceLifecycleOwnership.runIfCurrent(ownerToken) {
            synchronized(ownershipLock) {
                if (activeRegistration?.ownerToken == ownerToken) {
                    interfaceListenerRegistration = registration
                    interfaceUpdateToken++
                    installed = true
                }
            }
        }
        if (installed) {
            scheduleDefaultInterfaceUpdate(defaultNetwork)
        }
    }

    fun clearListener(ownerToken: Long, expectedListener: InterfaceUpdateListener) {
        synchronized(ownershipLock) {
            val registration = interfaceListenerRegistration
            if (registration?.ownerToken != ownerToken || registration.listener !== expectedListener) return
            interfaceListenerRegistration = null
            interfaceUpdateToken++
        }
    }

    /**
     * Detaches the process-wide Go callback for an owner before that owner's
     * core generation is stopped or closed. Queued interface publications
     * revalidate this registration on the independent interface-update lane.
     * The native monitor also seals queued/in-flight callbacks before Close.
     */
    fun clearListener(ownerToken: Long) {
        synchronized(ownershipLock) {
            if (interfaceListenerRegistration?.ownerToken != ownerToken) return
            interfaceListenerRegistration = null
            interfaceUpdateToken++
        }
    }

    private fun isActive(registration: MonitorRegistration): Boolean {
        var active = false
        ServiceLifecycleOwnership.runIfCurrent(registration.ownerToken) {
            synchronized(ownershipLock) {
                active = activeRegistration === registration
            }
        }
        return active
    }

    private fun publishIfActive(
        registration: MonitorRegistration,
        network: Network?,
    ): NetworkPublication {
        var publication = NetworkPublication(accepted = false)
        var observationWaiter: CompletableDeferred<Unit>? = null
        ServiceLifecycleOwnership.runIfCurrent(registration.ownerToken) {
            synchronized(ownershipLock) {
                if (activeRegistration === registration) {
                    defaultNetwork = network
                    networkObservationRevision += 1L
                    observationWaiter = networkObservationWaiter
                    networkObservationWaiter = CompletableDeferred()
                    publication = NetworkPublication(
                        accepted = true,
                        observer = registration.observer,
                    )
                }
            }
        }
        observationWaiter?.complete(Unit)
        return publication
    }

    private fun reconcileMissingNetwork(
        registration: MonitorRegistration,
        network: Network?,
        restartWindow: Boolean = false,
    ) {
        if (network != null) {
            synchronized(ownershipLock) {
                if (activeRegistration === registration) {
                    missingNetworkRecoveryToken++
                    missingNetworkRecoveryInFlight = false
                    missingNetworkRecoveryExhausted = false
                }
            }
            return
        }

        val token = synchronized(ownershipLock) {
            if (activeRegistration !== registration) return
            if (restartWindow) {
                missingNetworkRecoveryToken++
                missingNetworkRecoveryInFlight = false
                missingNetworkRecoveryExhausted = false
            }
            if (missingNetworkRecoveryInFlight || missingNetworkRecoveryExhausted) return
            missingNetworkRecoveryInFlight = true
            ++missingNetworkRecoveryToken
        }
        Log.w(TAG, "physical network callback is missing; reconciliation started")
        ConnectionDiagnostics.record(
            Application.application,
            component = "network",
            event = "callback",
            outcome = "missing",
        )
        monitorScope.launch {
            repeat(MISSING_NETWORK_RECONCILIATION_MAX_ATTEMPTS) { attemptIndex ->
                val stillCurrent = synchronized(ownershipLock) {
                    activeRegistration === registration && missingNetworkRecoveryToken == token
                }
                if (!stillCurrent) return@launch

                val attempt = attemptIndex + 1
                val recovered = DefaultNetworkListener.snapshot(quarantinedSocketNetwork())
                if (recovered != null) {
                    val publication = publishIfActive(registration, recovered)
                    if (!publication.accepted) return@launch
                    synchronized(ownershipLock) {
                        if (missingNetworkRecoveryToken == token) {
                            missingNetworkRecoveryToken++
                            missingNetworkRecoveryInFlight = false
                            missingNetworkRecoveryExhausted = false
                        }
                    }
                    Log.i(TAG, "physical network callback reconciled after $attempt attempt(s)")
                    ConnectionDiagnostics.record(
                        Application.application,
                        component = "network",
                        event = "callback",
                        outcome = "recovered",
                        attempt = attempt.toLong(),
                    )
                    scheduleDefaultInterfaceUpdate(recovered)
                    publication.observer?.invoke(recovered)
                    return@launch
                }

                if (attempt < MISSING_NETWORK_RECONCILIATION_MAX_ATTEMPTS) {
                    delay(MISSING_NETWORK_RECONCILIATION_INTERVAL_MS)
                }
            }

            val waitingForCallback = synchronized(ownershipLock) {
                if (activeRegistration === registration && missingNetworkRecoveryToken == token) {
                    missingNetworkRecoveryInFlight = false
                    missingNetworkRecoveryExhausted = true
                    true
                } else {
                    false
                }
            }
            if (waitingForCallback) {
                Log.i(
                    TAG,
                    "physical network reconciliation window expired; waiting for connectivity callback",
                )
                ConnectionDiagnostics.record(
                    Application.application,
                    component = "network",
                    event = "callback",
                    outcome = "waiting_for_event",
                    attempt = MISSING_NETWORK_RECONCILIATION_MAX_ATTEMPTS.toLong(),
                )
            }
        }
    }

    private fun scheduleDefaultInterfaceUpdate(newNetwork: Network?) {
        var registration: InterfaceListenerRegistration? = null
        var token = 0L
        val ownerToken = synchronized(ownershipLock) {
            interfaceListenerRegistration?.ownerToken
        } ?: return
        ServiceLifecycleOwnership.runIfCurrent(ownerToken) {
            synchronized(ownershipLock) {
                val current = interfaceListenerRegistration
                if (current?.ownerToken == ownerToken && activeRegistration?.ownerToken == ownerToken) {
                    registration = current
                    token = ++interfaceUpdateToken
                }
            }
        }
        val expectedRegistration = registration ?: return

        // ConnectivityManager callbacks are allowed to arrive on the main
        // thread. Resolving the interface and crossing the gomobile boundary
        // must never run there. A monotonically increasing token also folds a
        // callback burst into the newest observable network state.
        monitorScope.launch {
            var network = newNetwork
            var address = resolveInterfaceAddress(network)
            if (address == null) {
                delay(MISSING_INTERFACE_CONFIRMATION_DELAY_MS)
                network = runCatching {
                    withTimeout(MISSING_INTERFACE_CONFIRMATION_DELAY_MS) {
                        DefaultNetworkListener.get()
                    }
                }.getOrNull()
                address = resolveInterfaceAddress(network)
            }

            if (network != null) {
                ServiceLifecycleOwnership.runIfCurrent(expectedRegistration.ownerToken) {
                    synchronized(ownershipLock) {
                        if (
                            token == interfaceUpdateToken &&
                            interfaceListenerRegistration === expectedRegistration &&
                            activeRegistration?.ownerToken == expectedRegistration.ownerToken
                        ) {
                            defaultNetwork = network
                        }
                    }
                }
            }
            publishInterfaceAddress(
                expectedRegistration = expectedRegistration,
                token = token,
                address = address ?: InterfaceAddress("", -1),
            )
        }
    }

    private suspend fun resolveInterfaceAddress(network: Network?): InterfaceAddress? {
        if (network == null) return null
        val interfaceName = runCatching {
            Application.connectivity
                .getLinkProperties(network)
                ?.interfaceName
        }.getOrNull()
            ?: return null
        repeat(10) {
            val networkInterface = runCatching {
                NetworkInterface.getByName(interfaceName)
            }.getOrNull()
            if (networkInterface != null) {
                return InterfaceAddress(interfaceName, networkInterface.index)
            }
            delay(100)
        }
        return null
    }

    private suspend fun publishInterfaceAddress(
        expectedRegistration: InterfaceListenerRegistration,
        token: Long,
        address: InterfaceAddress,
    ) {
        interfaceUpdateMutex.withLock {
            var listener: InterfaceUpdateListener? = null
            ServiceLifecycleOwnership.runIfCurrent(expectedRegistration.ownerToken) {
                synchronized(ownershipLock) {
                    if (
                        token == interfaceUpdateToken &&
                        interfaceListenerRegistration === expectedRegistration &&
                        activeRegistration?.ownerToken == expectedRegistration.ownerToken &&
                        expectedRegistration.lastDelivered != address
                    ) {
                        expectedRegistration.lastDelivered = address
                        listener = expectedRegistration.listener
                    }
                }
            }
            val currentListener = listener ?: return@withLock
            runCatching {
                currentListener.updateDefaultInterface(address.name, address.index)
            }.onFailure { error ->
                synchronized(ownershipLock) {
                    if (
                        interfaceListenerRegistration === expectedRegistration &&
                        expectedRegistration.lastDelivered == address
                    ) {
                        expectedRegistration.lastDelivered = null
                    }
                }
                Log.w(TAG, "failed to publish default interface ${address.name}/${address.index}", error)
            }
        }
    }
}
