package app.marten.client.bg

import android.net.Network
import app.marten.client.Application
import app.marten.core.libbox.InterfaceUpdateListener
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.net.NetworkInterface

object DefaultNetworkMonitor {
    private const val MISSING_INTERFACE_CONFIRMATION_DELAY_MS = 1_000L

    private class MonitorRegistration(
        val ownerToken: Long,
        val observer: ((Network?) -> Unit)?,
    )

    private class InterfaceListenerRegistration(
        val ownerToken: Long,
        val listener: InterfaceUpdateListener,
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
    private var missingInterfaceToken = 0

    suspend fun start(ownerToken: Long, onNetworkChanged: ((Network?) -> Unit)? = null): Boolean {
        val registration = MonitorRegistration(ownerToken, onNetworkChanged)
        var previousRegistration: MonitorRegistration? = null
        val admitted = ServiceLifecycleOwnership.runIfCurrent(ownerToken) {
            synchronized(ownershipLock) {
                previousRegistration = activeRegistration
                activeRegistration = registration
                defaultNetwork = null
                missingInterfaceToken++
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
            checkDefaultInterfaceUpdate(network)
            publication.observer?.invoke(network)
        }
        if (!isActive(registration)) {
            DefaultNetworkListener.stop(registration)
            return false
        }

        val initialNetwork = runCatching {
            withTimeout(MISSING_INTERFACE_CONFIRMATION_DELAY_MS) {
                DefaultNetworkListener.get()
            }
        }.getOrElse {
            if (it is CancellationException) throw it
            null
        }
        val publication = publishIfActive(registration, initialNetwork)
        if (!publication.accepted) {
            DefaultNetworkListener.stop(registration)
            return false
        }
        checkDefaultInterfaceUpdate(initialNetwork)
        publication.observer?.invoke(initialNetwork)
        return true
    }

    suspend fun stop(ownerToken: Long) {
        val registration = synchronized(ownershipLock) {
            activeRegistration?.takeIf { it.ownerToken == ownerToken }?.also {
                missingInterfaceToken++
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

    suspend fun refresh(excludedNetwork: Network?): Network? {
        if (excludedNetwork == defaultNetwork) {
            defaultNetwork = null
        }
        val refreshedNetwork = DefaultNetworkListener.refresh(excludedNetwork)
        val registration = synchronized(ownershipLock) { activeRegistration } ?: return null
        val publication = publishIfActive(registration, refreshedNetwork)
        if (!publication.accepted) {
            return null
        }
        checkDefaultInterfaceUpdate(refreshedNetwork)
        publication.observer?.invoke(refreshedNetwork)
        return refreshedNetwork
    }

    fun setListener(ownerToken: Long, listener: InterfaceUpdateListener) {
        val registration = InterfaceListenerRegistration(ownerToken, listener)
        var installed = false
        ServiceLifecycleOwnership.runIfCurrent(ownerToken) {
            synchronized(ownershipLock) {
                if (activeRegistration?.ownerToken == ownerToken) {
                    interfaceListenerRegistration = registration
                    missingInterfaceToken++
                    installed = true
                }
            }
        }
        if (installed) {
            checkDefaultInterfaceUpdate(defaultNetwork)
        }
    }

    fun clearListener(ownerToken: Long, expectedListener: InterfaceUpdateListener) {
        synchronized(ownershipLock) {
            val registration = interfaceListenerRegistration
            if (registration?.ownerToken != ownerToken || registration.listener !== expectedListener) return
            interfaceListenerRegistration = null
            missingInterfaceToken++
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

    private fun checkDefaultInterfaceUpdate(newNetwork: Network?) {
        val registration = synchronized(ownershipLock) { interfaceListenerRegistration } ?: return
        if (!isActive(registration)) return
        val listener = registration.listener
        if (newNetwork != null) {
            val interfaceName = Application.connectivity
                .getLinkProperties(newNetwork)
                ?.interfaceName
            if (interfaceName == null) {
                scheduleMissingInterfaceConfirmation(registration)
                return
            }
            for (times in 0 until 10) {
                val interfaceIndex: Int
                try {
                    interfaceIndex = NetworkInterface.getByName(interfaceName).index
                } catch (e: Exception) {
                    Thread.sleep(100)
                    continue
                }
                val stillCurrent = markInterfaceUpdateIfActive(registration)
                if (!stillCurrent) return
                listener.updateDefaultInterface(interfaceName, interfaceIndex)
                return
            }
            scheduleMissingInterfaceConfirmation(registration)
        } else {
            scheduleMissingInterfaceConfirmation(registration)
        }
    }

    private fun isActive(registration: InterfaceListenerRegistration): Boolean {
        var active = false
        ServiceLifecycleOwnership.runIfCurrent(registration.ownerToken) {
            synchronized(ownershipLock) {
                active =
                    interfaceListenerRegistration === registration &&
                        activeRegistration?.ownerToken == registration.ownerToken
            }
        }
        return active
    }

    private fun markInterfaceUpdateIfActive(registration: InterfaceListenerRegistration): Boolean {
        var active = false
        ServiceLifecycleOwnership.runIfCurrent(registration.ownerToken) {
            synchronized(ownershipLock) {
                if (
                    interfaceListenerRegistration === registration &&
                    activeRegistration?.ownerToken == registration.ownerToken
                ) {
                    missingInterfaceToken++
                    active = true
                }
            }
        }
        return active
    }

    private fun scheduleMissingInterfaceConfirmation(
        expectedRegistration: InterfaceListenerRegistration,
    ) {
        var token = 0
        ServiceLifecycleOwnership.runIfCurrent(expectedRegistration.ownerToken) {
            synchronized(ownershipLock) {
                if (
                    interfaceListenerRegistration === expectedRegistration &&
                    activeRegistration?.ownerToken == expectedRegistration.ownerToken
                ) {
                    token = ++missingInterfaceToken
                }
            }
        }
        if (token == 0) return

        monitorScope.launch {
            delay(MISSING_INTERFACE_CONFIRMATION_DELAY_MS)
            val recoveredNetwork = runCatching {
                withTimeout(MISSING_INTERFACE_CONFIRMATION_DELAY_MS) {
                    DefaultNetworkListener.get()
                }
            }.getOrNull()
            var stillCurrent = false
            ServiceLifecycleOwnership.runIfCurrent(expectedRegistration.ownerToken) {
                synchronized(ownershipLock) {
                    if (
                        token == missingInterfaceToken &&
                        interfaceListenerRegistration === expectedRegistration &&
                        activeRegistration?.ownerToken == expectedRegistration.ownerToken
                    ) {
                        if (recoveredNetwork != null) {
                            defaultNetwork = recoveredNetwork
                        }
                        stillCurrent = true
                    }
                }
            }
            if (!stillCurrent) {
                return@launch
            }
            if (recoveredNetwork != null) {
                checkDefaultInterfaceUpdate(recoveredNetwork)
            } else {
                expectedRegistration.listener.updateDefaultInterface("", -1)
            }
        }
    }
}
