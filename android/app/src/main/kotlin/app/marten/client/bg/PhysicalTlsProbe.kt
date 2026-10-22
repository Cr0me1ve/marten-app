package app.marten.client.bg

import android.net.DnsResolver
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import android.util.Log
import app.marten.client.Application
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
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
    private val probeLock = Any()
    private var cancellationGeneration = 0L
    private var probesBlocked = false
    private val activeSockets = mutableSetOf<Socket>()
    private val activeDnsSignals = mutableSetOf<CancellationSignal>()
    private val directExecutor = Executor { command -> command.run() }

    /** Atomically closes admission and every cancellable blocking resource. */
    fun blockAndCancel() {
        val (sockets, dnsSignals) = synchronized(probeLock) {
            probesBlocked = true
            cancellationGeneration += 1L
            activeSockets.toList() to activeDnsSignals.toList()
        }
        dnsSignals.forEach(CancellationSignal::cancel)
        sockets.forEach { socket ->
            runCatching { socket.close() }
        }
    }

    fun allow() {
        synchronized(probeLock) {
            probesBlocked = false
        }
    }

    private fun beginProbe(): Long = synchronized(probeLock) {
        if (probesBlocked) {
            throw CancellationException("physical TLS probes are blocked during VPN transition")
        }
        cancellationGeneration
    }

    private suspend fun ensureProbeActive(generation: Long) {
        currentCoroutineContext().ensureActive()
        val active = synchronized(probeLock) {
            !probesBlocked && cancellationGeneration == generation
        }
        if (!active) {
            throw CancellationException("physical TLS probe retired for VPN transition")
        }
    }

    private fun registerSocket(socket: Socket, generation: Long): Boolean = synchronized(probeLock) {
        if (probesBlocked || cancellationGeneration != generation) {
            false
        } else {
            activeSockets.add(socket)
            true
        }
    }

    private fun removeSocket(socket: Socket) {
        synchronized(probeLock) {
            activeSockets.remove(socket)
        }
    }

    suspend fun measure(
        host: String,
        port: Int,
        serverName: String?,
        allowUntrusted: Boolean,
        timeoutMs: Long,
    ): Long = withContext(Dispatchers.IO) {
        val probeGeneration = beginProbe()
        ensureProbeActive(probeGeneration)
        val endpointHost = host.trim()
        require(endpointHost.isNotEmpty()) { "missing TLS probe host" }
        require(port in 1..65535) { "invalid TLS probe port" }
        val peerName = serverName?.trim().takeUnless { it.isNullOrEmpty() } ?: endpointHost
        val boundedTimeoutMs = timeoutMs.coerceIn(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
        val startedAtMs = SystemClock.elapsedRealtime()

        withTimeout(boundedTimeoutMs) {
            val network = selectProbeNetwork()
            ensureProbeActive(probeGeneration)
            val addresses = resolveCancellable(network, endpointHost, probeGeneration)
            ensureProbeActive(probeGeneration)
            require(addresses.isNotEmpty()) { "TLS probe host did not resolve" }

            var lastFailure: Throwable? = null
            for (address in addresses) {
                val remainingMs = boundedTimeoutMs - (SystemClock.elapsedRealtime() - startedAtMs)
                if (remainingMs <= 0L) break
                val socketTimeoutMs = remainingMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                val plainSocket = network.socketFactory.createSocket()
                if (!registerSocket(plainSocket, probeGeneration)) {
                    runCatching { plainSocket.close() }
                    throw CancellationException("physical TLS probe retired before socket registration")
                }
                try {
                    ensureProbeActive(probeGeneration)
                    plainSocket.soTimeout = socketTimeoutMs
                    plainSocket.connect(InetSocketAddress(address, port), socketTimeoutMs)
                    ensureProbeActive(probeGeneration)
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
                    if (!registerSocket(tlsSocket, probeGeneration)) {
                        runCatching { tlsSocket.close() }
                        throw CancellationException("physical TLS probe retired before TLS registration")
                    }
                    try {
                        tlsSocket.use {
                            ensureProbeActive(probeGeneration)
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
                            ensureProbeActive(probeGeneration)
                        }
                    } finally {
                        removeSocket(tlsSocket)
                    }
                    return@withTimeout max(1L, SystemClock.elapsedRealtime() - startedAtMs)
                } catch (error: Throwable) {
                    val retired = synchronized(probeLock) {
                        probesBlocked || cancellationGeneration != probeGeneration
                    }
                    if (error is CancellationException || retired) {
                        throw CancellationException("physical TLS probe retired for VPN transition").also {
                            it.initCause(error)
                        }
                    }
                    lastFailure = error
                    Log.d(
                        TAG,
                        "physical TLS handshake attempt failed " +
                            "error=${error.javaClass.simpleName} " +
                            "cause=${error.cause?.javaClass?.simpleName ?: "none"}",
                    )
                } finally {
                    removeSocket(plainSocket)
                    runCatching { plainSocket.close() }
                }
            }
            throw lastFailure ?: IllegalStateException("TLS handshake timed out")
        }
    }

    private suspend fun resolveCancellable(
        network: Network,
        host: String,
        generation: Long,
    ): List<InetAddress> {
        if (host.isIpLiteral()) return listOf(InetAddress.getByName(host))
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Network.getAllByName is a blocking resolver with no cancellation
            // handle. Reject it instead of letting a pre-connect DNS request
            // outlive the strict-egress transition on old Android releases.
            throw IllegalStateException("cancellable physical DNS requires Android 10 or newer")
        }
        return suspendCancellableCoroutine { continuation ->
            val signal = CancellationSignal()
            val completed = AtomicBoolean(false)
            val registered = synchronized(probeLock) {
                if (probesBlocked || cancellationGeneration != generation) {
                    false
                } else {
                    activeDnsSignals.add(signal)
                    true
                }
            }
            if (!registered) {
                continuation.cancel(
                    CancellationException("physical TLS probe retired before DNS registration"),
                )
                return@suspendCancellableCoroutine
            }
            fun finishSignal() {
                synchronized(probeLock) {
                    activeDnsSignals.remove(signal)
                }
            }
            fun completeOnce(outcome: Result<List<InetAddress>>) {
                finishSignal()
                if (completed.compareAndSet(false, true) && continuation.isActive) {
                    continuation.resumeWith(outcome)
                }
            }
            continuation.invokeOnCancellation {
                signal.cancel()
                completed.compareAndSet(false, true)
                finishSignal()
            }
            try {
                DnsResolver.getInstance().query(
                    network,
                    host,
                    0,
                    directExecutor,
                    signal,
                    object : DnsResolver.Callback<List<InetAddress>> {
                        override fun onAnswer(answer: List<InetAddress>, rcode: Int) {
                            completeOnce(Result.success(answer))
                        }

                        override fun onError(error: DnsResolver.DnsException) {
                            completeOnce(Result.failure(error))
                        }
                    },
                )
            } catch (error: Throwable) {
                // DnsResolver may reject synchronously before it owns the
                // callback. Retire the exact signal here so later transitions
                // do not repeatedly scan a dead registration.
                completeOnce(Result.failure(error))
            }
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
