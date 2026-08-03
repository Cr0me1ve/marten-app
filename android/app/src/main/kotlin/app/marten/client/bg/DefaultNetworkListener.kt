package app.marten.client.bg

import android.annotation.TargetApi
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import app.marten.client.Application
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.ObsoleteCoroutinesApi
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.channels.actor
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

object DefaultNetworkListener {
    private const val TAG = "DefaultNetworkListener"
    private const val LOST_NETWORK_CONFIRMATION_DELAY_MS = 1_000L
    private const val MISSING_DEFAULT_NETWORK_MESSAGE = "missing default network"
    private const val DEFAULT_NETWORK_LISTENER_STOPPED_MESSAGE = "default network listener stopped"

    private sealed class NetworkMessage {
        class Start(val key: Any, val listener: (Network?) -> Unit) : NetworkMessage() {
            val response = CompletableDeferred<Unit>()
        }

        class Get : NetworkMessage() {
            val response = CompletableDeferred<Network>()
        }

        class Stop(val key: Any) : NetworkMessage()

        class Put(val network: Network) : NetworkMessage()

        class Update(val network: Network) : NetworkMessage()

        class Lost(val network: Network) : NetworkMessage()

        class ConfirmLost(val network: Network, val token: Int) : NetworkMessage()

        class Refresh(val excludedNetwork: Network?) : NetworkMessage() {
            val response = CompletableDeferred<Network?>()
        }
    }

    @OptIn(DelicateCoroutinesApi::class, ObsoleteCoroutinesApi::class)
    private val networkActor: SendChannel<NetworkMessage> =
        GlobalScope.actor<NetworkMessage>(Dispatchers.Unconfined) {
            val listeners = mutableMapOf<Any, (Network?) -> Unit>()
            var network: Network? = null
            var lostToken = 0
            val pendingRequests = arrayListOf<NetworkMessage.Get>()
            for (message in channel) {
                when (message) {
                    is NetworkMessage.Start -> {
                        if (listeners.isEmpty()) register()
                        listeners[message.key] = message.listener
                        if (network == null) network = findUsableNetwork()
                        if (network != null) message.listener(network)
                        message.response.complete(Unit)
                    }

                    is NetworkMessage.Get -> {
                        if (listeners.isEmpty()) {
                            val currentNetwork = findUsableNetwork()
                            if (currentNetwork != null) {
                                message.response.complete(currentNetwork)
                            } else {
                                message.response.completeExceptionally(
                                    IllegalStateException(MISSING_DEFAULT_NETWORK_MESSAGE),
                                )
                            }
                        } else {
                            if (network == null) {
                                network = findUsableNetwork()
                            }
                            val currentNetwork = network
                            if (currentNetwork != null) {
                                message.response.complete(currentNetwork)
                            } else {
                                pendingRequests += message
                            }
                        }
                    }

                    is NetworkMessage.Stop ->
                        if (listeners.isNotEmpty() &&
                            // was not empty
                            listeners.remove(message.key) != null &&
                            listeners.isEmpty()
                        ) {
                            lostToken++
                            network = null
                            pendingRequests.forEach {
                                it.response.completeExceptionally(
                                    IllegalStateException(DEFAULT_NETWORK_LISTENER_STOPPED_MESSAGE),
                                )
                            }
                            pendingRequests.clear()
                            unregister()
                        }

                    is NetworkMessage.Put -> {
                        if (listeners.isNotEmpty()) {
                            lostToken++
                            network = message.network
                            pendingRequests.forEach { it.response.complete(message.network) }
                            pendingRequests.clear()
                            listeners.values.forEach { it(network) }
                        }
                    }

                    is NetworkMessage.Update ->
                        if (listeners.isNotEmpty() && network == message.network) {
                            listeners.values.forEach {
                                it(
                                    network,
                                )
                            }
                        }

                    is NetworkMessage.Lost ->
                        if (listeners.isNotEmpty() && network == message.network) {
                            val fallbackNetwork = findUsableNetwork()
                            if (fallbackNetwork != null) {
                                lostToken++
                                network = fallbackNetwork
                                pendingRequests.forEach { it.response.complete(fallbackNetwork) }
                                pendingRequests.clear()
                                listeners.values.forEach { it(fallbackNetwork) }
                            } else {
                                val token = ++lostToken
                                GlobalScope.launch(Dispatchers.Default) {
                                    delay(LOST_NETWORK_CONFIRMATION_DELAY_MS)
                                    networkActor.send(NetworkMessage.ConfirmLost(message.network, token))
                                }
                            }
                        }

                    is NetworkMessage.ConfirmLost ->
                        if (listeners.isNotEmpty() && lostToken == message.token && network == message.network) {
                            val fallbackNetwork = findUsableNetwork()
                            network = fallbackNetwork
                            if (fallbackNetwork != null) {
                                pendingRequests.forEach { it.response.complete(fallbackNetwork) }
                                pendingRequests.clear()
                                listeners.values.forEach { it(fallbackNetwork) }
                            } else {
                                listeners.values.forEach { it(null) }
                            }
                        }

                    is NetworkMessage.Refresh -> {
                        lostToken++
                        network = findUsableNetwork(message.excludedNetwork)
                        if (network != null) {
                            pendingRequests.forEach { it.response.complete(network) }
                            pendingRequests.clear()
                            listeners.values.forEach { it(network) }
                        }
                        message.response.complete(network)
                    }
                }
            }
        }

    suspend fun start(key: Any, listener: (Network?) -> Unit) =
        NetworkMessage.Start(key, listener).run {
            networkActor.send(this)
            response.await()
        }

    suspend fun get(): Network = if (fallback) {
        @TargetApi(23)
        Application.connectivity.activeNetwork
            ?: error("missing default network") // failed to listen, return current if available
    } else {
        NetworkMessage.Get().run {
            networkActor.send(this)
            response.await()
        }
    }

    suspend fun refresh(excludedNetwork: Network?): Network? =
        NetworkMessage.Refresh(excludedNetwork).run {
            networkActor.send(this)
            response.await()
        }

    suspend fun stop(key: Any) = networkActor.send(NetworkMessage.Stop(key))

    // NB: this runs in ConnectivityThread, and this behavior cannot be changed until API 26
    private object Callback : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = runBlocking {
            networkActor.send(
                NetworkMessage.Put(
                    network,
                ),
            )
        }

        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
            // it's a good idea to refresh capabilities
            runBlocking { networkActor.send(NetworkMessage.Update(network)) }
        }

        override fun onLost(network: Network) = runBlocking {
            networkActor.send(
                NetworkMessage.Lost(
                    network,
                ),
            )
        }
    }

    private var fallback = false
    private val request =
        NetworkRequest.Builder().apply {
            addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            if (Build.VERSION.SDK_INT == 23) { // workarounds for OEM bugs
                removeCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                removeCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL)
            }
        }.build()
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Unfortunately registerDefaultNetworkCallback is going to return VPN interface since Android P DP1:
     * https://android.googlesource.com/platform/frameworks/base/+/dda156ab0c5d66ad82bdcf76cda07cbc0a9c8a2e
     *
     * This makes doing a requestNetwork with REQUEST necessary so that we don't get ALL possible networks that
     * satisfies default network capabilities but only THE default network. Unfortunately, we need to have
     * android.permission.CHANGE_NETWORK_STATE to be able to call requestNetwork.
     *
     * Source: https://android.googlesource.com/platform/frameworks/base/+/2df4c7d/services/core/java/com/android/server/ConnectivityService.java#887
     */
    private fun register() {
        when (Build.VERSION.SDK_INT) {
            in 31..Int.MAX_VALUE ->
                @TargetApi(31)
                {
                    try {
                        Application.connectivity.requestNetwork(request, Callback, mainHandler)
                    } catch (e: RuntimeException) {
                        Log.w(TAG, "requestNetwork failed, falling back to best matching callback", e)
                        Application.connectivity.registerBestMatchingNetworkCallback(
                            request,
                            Callback,
                            mainHandler,
                        )
                    }
                }

            in 28 until 31 ->
                @TargetApi(28)
                { // we want REQUEST here instead of LISTEN
                    Application.connectivity.requestNetwork(request, Callback, mainHandler)
                }

            in 26 until 28 ->
                @TargetApi(26)
                {
                    Application.connectivity.registerDefaultNetworkCallback(Callback, mainHandler)
                }

            in 24 until 26 ->
                @TargetApi(24)
                {
                    Application.connectivity.registerDefaultNetworkCallback(Callback)
                }

            else ->
                try {
                    fallback = false
                    Application.connectivity.requestNetwork(request, Callback)
                } catch (e: RuntimeException) {
                    fallback =
                        true // known bug on API 23: https://stackoverflow.com/a/33509180/2245107
                }
        }
    }

    @Suppress("DEPRECATION")
    private fun findUsableNetwork(excludedNetwork: Network? = null): Network? {
        fun Network.isUsable(): Boolean {
            val capabilities = Application.connectivity.getNetworkCapabilities(this) ?: return false
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return false
            return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        }

        return Application.connectivity.activeNetwork
            ?.takeUnless { it == excludedNetwork }
            ?.takeIf { it.isUsable() }
            ?: Application.connectivity.allNetworks.firstOrNull {
                it != excludedNetwork && it.isUsable()
            }
    }

    private fun unregister() {
        runCatching {
            Application.connectivity.unregisterNetworkCallback(Callback)
        }
    }
}
