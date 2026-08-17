package app.marten.client.bg

import android.net.Network
import android.net.NetworkCapabilities
import android.os.SystemClock
import android.util.Log
import app.marten.client.Application
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.net.InetSocketAddress
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager
import kotlin.math.max

/**
 * Measures a real TLS handshake to a proxy endpoint. When another VPN is the
 * current route for Marten's UID, the probe follows that VPN; otherwise it uses
 * Android's physical (NOT_VPN) network. A completed TCP connect alone is
 * deliberately not enough: providers can accept SYN/ACK while blocking the
 * following ClientHello.
 */
object PhysicalTlsProbe {
    private const val TAG = "PhysicalTlsProbe"
    private const val MIN_TIMEOUT_MS = 250L
    private const val MAX_TIMEOUT_MS = 30_000L

    suspend fun measure(
        host: String,
        port: Int,
        serverName: String?,
        allowUntrusted: Boolean,
        timeoutMs: Long,
    ): Long = withContext(Dispatchers.IO) {
        val endpointHost = host.trim()
        require(endpointHost.isNotEmpty()) { "missing TLS probe host" }
        require(port in 1..65535) { "invalid TLS probe port" }
        val peerName = serverName?.trim().takeUnless { it.isNullOrEmpty() } ?: endpointHost
        val boundedTimeoutMs = timeoutMs.coerceIn(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
        val startedAtMs = SystemClock.elapsedRealtime()

        withTimeout(boundedTimeoutMs) {
            val network = selectProbeNetwork()
            val addresses = network.getAllByName(endpointHost)
            require(addresses.isNotEmpty()) { "TLS probe host did not resolve" }

            var lastFailure: Throwable? = null
            for (address in addresses) {
                val remainingMs = boundedTimeoutMs - (SystemClock.elapsedRealtime() - startedAtMs)
                if (remainingMs <= 0L) break
                val socketTimeoutMs = remainingMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                val plainSocket = network.socketFactory.createSocket()
                try {
                    plainSocket.soTimeout = socketTimeoutMs
                    plainSocket.connect(InetSocketAddress(address, port), socketTimeoutMs)
                    val tlsFactory = if (allowUntrusted) {
                        realityFallbackTlsFactory
                    } else {
                        SSLSocketFactory.getDefault() as SSLSocketFactory
                    }
                    val tlsSocket = (tlsFactory.createSocket(
                        plainSocket,
                        peerName,
                        port,
                        true,
                    ) as SSLSocket)
                    tlsSocket.use {
                        it.soTimeout = max(1L, boundedTimeoutMs - (SystemClock.elapsedRealtime() - startedAtMs))
                            .coerceAtMost(Int.MAX_VALUE.toLong())
                            .toInt()
                        val parameters = it.sslParameters
                        parameters.endpointIdentificationAlgorithm = if (allowUntrusted) null else "HTTPS"
                        if (!peerName.isIpLiteral()) {
                            parameters.serverNames = listOf(SNIHostName(peerName))
                        }
                        it.sslParameters = parameters
                        it.startHandshake()
                    }
                    return@withTimeout max(1L, SystemClock.elapsedRealtime() - startedAtMs)
                } catch (error: Throwable) {
                    lastFailure = error
                    Log.d(
                        TAG,
                        "physical TLS handshake attempt failed " +
                            "error=${error.javaClass.simpleName} " +
                            "cause=${error.cause?.javaClass?.simpleName ?: "none"}",
                    )
                    runCatching { plainSocket.close() }
                }
            }
            throw lastFailure ?: IllegalStateException("TLS handshake timed out")
        }
    }

    private suspend fun selectProbeNetwork(): Network {
        val activeNetwork = Application.connectivity.activeNetwork
        val activeCapabilities = activeNetwork?.let(Application.connectivity::getNetworkCapabilities)
        if (activeNetwork != null &&
            activeCapabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        ) {
            Log.d(TAG, "TLS probe route=active_vpn")
            return activeNetwork
        }

        Log.d(TAG, "TLS probe route=physical")
        return DefaultNetworkMonitor.require()
    }

    private fun String.isIpLiteral(): Boolean =
        matches(Regex("^[0-9.]+$")) || contains(':')

    /**
     * A REALITY client authenticates its peer with the configured REALITY
     * public key. This probe deliberately performs an ordinary fallback TLS
     * handshake, whose certificate is not that identity and can differ from
     * Android's CA/hostname expectations. Completing the cryptographic
     * handshake is still mandatory; a TCP accept or partial server flight is
     * never reported as a healthy result.
     */
    private val realityFallbackTlsFactory: SSLSocketFactory by lazy {
        val trustManager = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<X509Certificate>?, authType: String?) = Unit
            override fun checkServerTrusted(chain: Array<X509Certificate>?, authType: String?) = Unit
        }
        SSLContext.getInstance("TLS").apply {
            init(null, arrayOf(trustManager), SecureRandom())
        }.socketFactory
    }
}
