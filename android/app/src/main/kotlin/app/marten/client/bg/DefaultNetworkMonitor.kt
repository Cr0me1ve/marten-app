package app.marten.client.bg

import android.net.Network
import android.util.Log
import app.marten.client.Application
import app.marten.core.libbox.InterfaceUpdateListener
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.net.NetworkInterface

object DefaultNetworkMonitor {
    private const val TAG = "DefaultNetworkMonitor"
    private const val MISSING_INTERFACE_CONFIRMATION_DELAY_MS = 1_000L

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
    private val monitorScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    var defaultNetwork: Network? = null
    private var activeRegistration: MonitorRegistration? = null
    private var interfaceListenerRegistration: InterfaceListenerRegistration? = null
    private var interfaceUpdateToken = 0L

    suspend fun start(ownerToken: Long, onNetworkChanged: ((Network?) -> Unit)? = null): Boolean {
        val registration = MonitorRegistration(ownerToken, onNetworkChanged)
        var previousRegistration: MonitorRegistration? = null
        val admitted = ServiceLifecycleOwnership.runIfCurrent(ownerToken) {
            synchronized(ownershipLock) {
                previousRegistration = activeRegistration
                activeRegistration = registration
                defaultNetwork = null
                interfaceUpdateToken++
            }
        }
        if (!admitted) {
            return false
        }

        previousRegistration?.let {
            DefaultNetworkListener.stop(it)
        }
        DefaultNetworkListener.start(registration) networkChanged@{ network ->
            val publication = publishIfActive(registration, network)
            if (!publication.accepted) {
                return@networkChanged
            }
            scheduleDefaultInterfaceUpdate(network)
            publication.observer?.invoke(network)
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
        val publication = publishIfActive(registration, initialNetwork)
        if (!publication.accepted) {
            DefaultNetworkListener.stop(registration)
            return false
        }
        scheduleDefaultInterfaceUpdate(initialNetwork)
        publication.observer?.invoke(initialNetwork)
        return true
    }

    suspend fun stop(ownerToken: Long) {
        val registration = synchronized(ownershipLock) {
            activeRegistration?.takeIf { it.ownerToken == ownerToken }?.also {
                interfaceUpdateToken++
                defaultNetwork = null
                activeRegistration = null
                if (interfaceListenerRegistration?.ownerToken == ownerToken) {
                    interfaceListenerRegistration = null
                }
            }
        }
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
     * revalidate this registration after acquiring [MobileCoreLifecycle].
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
        ServiceLifecycleOwnership.runIfCurrent(registration.ownerToken) {
            synchronized(ownershipLock) {
                if (activeRegistration === registration) {
                    defaultNetwork = network
                    publication = NetworkPublication(
                        accepted = true,
                        observer = registration.observer,
                    )
                }
            }
        }
        return publication
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
        MobileCoreLifecycle.run {
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
            val currentListener = listener ?: return@run
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
