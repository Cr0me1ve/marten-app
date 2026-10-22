package app.marten.client.bg

import android.content.Context
import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

internal data class VpnDataPlaneProbeResult(
    val healthy: Boolean,
    val latencyMs: Long,
    val responseBytes: Int,
    val stage: VpnDataPlaneProbeStage,
    val vpnNetworkHandle: Long? = null,
    val failure: String? = null,
    val networkReadinessPending: Boolean = false,
) {
    val summary: String
        get() = if (healthy) {
            "VPN data-plane GET and DNS verified stage=${stage.token} latency=${latencyMs}ms bytes=$responseBytes"
        } else {
            "VPN data-plane proof failed stage=${stage.token} category=${failure ?: "unknown"}"
        }
}

internal enum class VpnDataPlaneProbeStage(val token: String) {
    VPN_NETWORK("vpn_network"),
    UNDERLYING_NETWORK("underlying_network"),
    UNDERLYING_DNS("underlying_dns"),
    HTTP_CONNECT("http_connect"),
    TLS_HANDSHAKE("tls_handshake"),
    HTTP_WRITE("http_write"),
    HTTP_READ("http_read"),
    VPN_DNS("vpn_dns"),
    COMPLETE("complete"),
}

internal fun vpnDataPlaneExceptionCategory(error: Throwable, unexpected: Boolean): String {
    fun safeKind(value: Throwable): String = value.javaClass.simpleName
        .replace(Regex("[^A-Za-z0-9]+"), "_")
        .trim('_')
        .lowercase()
        .take(24)
        .ifBlank { "unknown" }

    // Only exception class names are retained. They distinguish a peer reset,
    // protocol failure and certificate failure without ever persisting the
    // exception message, hostname, address, profile, or credential material.
    val root = generateSequence(error) { current ->
        current.cause?.takeUnless { it === current }
    }.take(6).last()
    return buildString {
        append(if (unexpected) "unexpected" else "io")
        append('_')
        append(safeKind(error))
        if (root !== error) {
            append('_')
            append(safeKind(root))
        }
    }.take(48).trimEnd('_')
}

internal fun selectMostAdvancedVpnDataPlaneFailure(
    failures: List<VpnDataPlaneProbeResult>,
): VpnDataPlaneProbeResult = failures.maxWithOrNull(
    compareBy<VpnDataPlaneProbeResult> { it.stage.ordinal }
        .thenBy { it.latencyMs },
) ?: error("at least one VPN data-plane failure is required")

private data class NetworkDnsResult(
    val addresses: Collection<InetAddress> = emptyList(),
    val failure: String? = null,
)

private data class HttpsProbeEndpoint(
    val host: String,
    val path: String,
    val expectedStatusCode: Int,
)

/**
 * Executes a real Android-network request on the VPN Network. Marten's UID is
 * intentionally part of its own VPN UID ranges; native upstream sockets are
 * separately protected and bound to the underlying Network by VPNService.
 * This proves Marten's path through the current TUN generation. Admission of
 * at least one external app for an include-only plan is enforced separately
 * while applying [VpnAppRoutingPlan], so this self-probe cannot validate an
 * otherwise empty allowlist.
 */
internal class VpnDataPlaneProbe(context: Context) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val endpointCursor = AtomicInteger(0)

    fun currentVpnNetworkHandle(): Long? = runCatching {
        val network = connectivity.activeNetwork ?: return@runCatching null
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return@runCatching null
        if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return@runCatching null
        network.networkHandle
    }.getOrNull()

    suspend fun run(
        underlyingNetwork: Network?,
        timeoutMs: Long = DEFAULT_PROBE_TIMEOUT_MS,
        redundantEndpoints: Boolean = false,
    ): VpnDataPlaneProbeResult = withContext(Dispatchers.IO) {
        val probeStartedAt = SystemClock.elapsedRealtime()
        val deadlineElapsedRealtimeMs = SystemClock.elapsedRealtime() + timeoutMs.coerceAtLeast(1L)
        // Builder.establish() returns before ConnectivityService necessarily
        // publishes the new VPN as this UID's active Network. The core can be
        // fully started while activeNetwork still briefly points at Wi-Fi.
        // Wait through that bounded platform hand-off instead of rejecting and
        // tearing down an otherwise healthy tunnel on the first snapshot.
        val vpnNetwork = awaitActiveVpnNetwork(deadlineElapsedRealtimeMs)
            ?: return@withContext failure(
                VpnDataPlaneProbeStage.VPN_NETWORK,
                "caller_not_routed_to_vpn",
                probeStartedAt,
            )
        val resolverNetwork = underlyingNetwork
            ?: return@withContext failure(
                VpnDataPlaneProbeStage.UNDERLYING_NETWORK,
                "underlying_network_unavailable",
                probeStartedAt,
                networkReadinessPending = true,
            )
        val endpoints = nextProbeEndpoints(if (redundantEndpoints) PROBE_ENDPOINTS.size else 1)
        if (endpoints.size == 1) {
            return@withContext runEndpoint(
                vpnNetwork = vpnNetwork,
                resolverNetwork = resolverNetwork,
                probeEndpoint = endpoints.single(),
                deadlineElapsedRealtimeMs = deadlineElapsedRealtimeMs,
                probeStartedAt = probeStartedAt,
            )
        }

        // Startup and active recovery use independent authenticated endpoints
        // concurrently. The first complete HTTPS+VPN-DNS proof wins and
        // structured cancellation closes every losing socket. Thus a blocked
        // connectivity provider cannot add a full attempt timeout, while every
        // accepted result still proves the exact current Android VPN Network.
        coroutineScope {
            val completed = Channel<VpnDataPlaneProbeResult>(capacity = endpoints.size)
            val jobs = endpoints.map { endpoint ->
                launch {
                    completed.trySend(
                        runEndpoint(
                            vpnNetwork = vpnNetwork,
                            resolverNetwork = resolverNetwork,
                            probeEndpoint = endpoint,
                            deadlineElapsedRealtimeMs = deadlineElapsedRealtimeMs,
                            probeStartedAt = probeStartedAt,
                        ),
                    )
                }
            }
            val failures = ArrayList<VpnDataPlaneProbeResult>(endpoints.size)
            try {
                repeat(endpoints.size) {
                    val result = completed.receive()
                    if (result.healthy) return@coroutineScope result
                    failures += result
                }
                selectMostAdvancedVpnDataPlaneFailure(failures)
            } finally {
                jobs.forEach { it.cancel() }
                completed.close()
            }
        }
    }

    private suspend fun runEndpoint(
        vpnNetwork: Network,
        resolverNetwork: Network,
        probeEndpoint: HttpsProbeEndpoint,
        deadlineElapsedRealtimeMs: Long,
        probeStartedAt: Long,
    ): VpnDataPlaneProbeResult {
        var stage = VpnDataPlaneProbeStage.UNDERLYING_DNS

        // Resolve the HTTPS probe target on the protected underlying Network
        // so a broken tunnel resolver cannot prevent the transport proof itself.
        // Once that request warms and proves the route, verifyVpnDns performs a
        // separate uncached lookup on the VPN Network. Admission requires both:
        // user apps need a working TUN route and working DNS through that route.
        stage = VpnDataPlaneProbeStage.UNDERLYING_DNS
        val underlyingDnsTimeoutMs = remainingTimeoutMs(deadlineElapsedRealtimeMs)?.toLong()
            ?: return failure(stage, "timeout", probeStartedAt)
        val underlyingDns = resolveNetworkDns(
            resolverNetwork,
            probeEndpoint.host,
            timeoutMs = underlyingDnsTimeoutMs,
            bypassCache = false,
        )
        val probeAddress = underlyingDns.addresses.firstOrNull { it is Inet4Address }
            ?: underlyingDns.addresses.firstOrNull()
            ?: return failure(
                stage,
                if (underlyingDns.failure == "timeout") "timeout" else "underlying_dns_unavailable",
                probeStartedAt,
                networkReadinessPending = true,
            )

        val socketBudgetMs = remainingTimeoutMs(deadlineElapsedRealtimeMs)?.toLong()
            ?: return failure(stage, "timeout", probeStartedAt)
        return withBoundedProbeSockets(socketBudgetMs) { sockets ->
            try {
                val nonce = SystemClock.elapsedRealtimeNanos().toString(16)
                stage = VpnDataPlaneProbeStage.HTTP_CONNECT
                val connectTimeoutMs = remainingTimeoutMs(deadlineElapsedRealtimeMs)
                    ?: return@withBoundedProbeSockets failure(stage, "timeout", probeStartedAt)
                // Exercise the same UID-routed default path used by ordinary apps.
                // Explicit Network-bound sockets are not equivalent on every OEM:
                // some devices accept the VLESS stream but stall the first socket
                // bound back to the VPN netId until an ordinary app opens traffic.
                // The active VPN handle is checked before and again when the proof
                // is published, so an underlying-network fallback cannot pass.
                val openedSocket = Socket().apply {
                    soTimeout = connectTimeoutMs
                    tcpNoDelay = true
                }
                if (!sockets.own(openedSocket)) {
                    currentCoroutineContext().ensureActive()
                    return@withBoundedProbeSockets failure(stage, "timeout", probeStartedAt)
                }
                currentCoroutineContext().ensureActive()
                openedSocket.connect(InetSocketAddress(probeAddress, PROBE_PORT), connectTimeoutMs)

                // A plaintext connectivity-check response is not a trustworthy
                // data-plane proof: transparent proxies and carrier middleboxes can
                // truncate, replace, or synthesize it even when the selected VPN
                // route itself is healthy. Keep the already UID-routed descriptor,
                // but authenticate the probe host before sending the GET. Passing
                // Keep both peer identity and SNI explicit. Some OEM Conscrypt
                // builds do not infer SNI when an already-connected UID-routed
                // descriptor is upgraded in place, even though createSocket also
                // receives the peer host.
                stage = VpnDataPlaneProbeStage.TLS_HANDSHAKE
                val tlsSocket = (SSLSocketFactory.getDefault() as SSLSocketFactory)
                    .createSocket(openedSocket, probeEndpoint.host, PROBE_PORT, true) as SSLSocket
                if (!sockets.own(tlsSocket)) {
                    currentCoroutineContext().ensureActive()
                    return@withBoundedProbeSockets failure(stage, "timeout", probeStartedAt)
                }
                tlsSocket.useClientMode = true
                tlsSocket.sslParameters = tlsSocket.sslParameters.apply {
                    endpointIdentificationAlgorithm = "HTTPS"
                    serverNames = listOf(SNIHostName(probeEndpoint.host))
                }
                val handshakeTimeoutMs = remainingTimeoutMs(deadlineElapsedRealtimeMs)
                if (handshakeTimeoutMs == null) {
                    return@withBoundedProbeSockets failure(stage, "timeout", probeStartedAt)
                }
                tlsSocket.soTimeout = handshakeTimeoutMs
                currentCoroutineContext().ensureActive()
                tlsSocket.startHandshake()

                stage = VpnDataPlaneProbeStage.HTTP_WRITE
                val request = buildString {
                    append("GET ${probeEndpoint.path}?marten=$nonce HTTP/1.1\r\n")
                    append("Host: ${probeEndpoint.host}\r\n")
                    append("Accept-Encoding: identity\r\n")
                    append("Cache-Control: no-cache\r\n")
                    append("Connection: close\r\n\r\n")
                }.toByteArray(StandardCharsets.US_ASCII)
                tlsSocket.getOutputStream().apply {
                    write(request)
                    flush()
                }

                stage = VpnDataPlaneProbeStage.HTTP_READ
                tlsSocket.soTimeout = remainingTimeoutMs(deadlineElapsedRealtimeMs)
                    ?: return@withBoundedProbeSockets failure(stage, "timeout", probeStartedAt)
                val responseHeaders = readResponseHeaders(BufferedInputStream(tlsSocket.getInputStream()))
                    ?: return@withBoundedProbeSockets failure(stage, "malformed_http_response", probeStartedAt)
                val statusLine = responseHeaders.toString(StandardCharsets.US_ASCII)
                    .lineSequence()
                    .firstOrNull()
                    .orEmpty()
                val statusCode = statusLine.split(' ', limit = 3).getOrNull(1)?.toIntOrNull()
                if (statusCode != probeEndpoint.expectedStatusCode) {
                    return@withBoundedProbeSockets failure(stage, "unexpected_http_status", probeStartedAt)
                }
                stage = VpnDataPlaneProbeStage.VPN_DNS
                val dnsTimeoutMs = remainingTimeoutMs(deadlineElapsedRealtimeMs)?.toLong()
                    ?: return@withBoundedProbeSockets failure(stage, "timeout", probeStartedAt)
                val dnsFailure = verifyVpnDns(vpnNetwork, probeEndpoint.host, dnsTimeoutMs)
                if (dnsFailure != null) {
                    return@withBoundedProbeSockets failure(stage, "vpn_dns_$dnsFailure", probeStartedAt)
                }
                currentCoroutineContext().ensureActive()
                if (sockets.expired || remainingTimeoutMs(deadlineElapsedRealtimeMs) == null) {
                    return@withBoundedProbeSockets failure(stage, "timeout", probeStartedAt)
                }
                VpnDataPlaneProbeResult(
                    healthy = true,
                    latencyMs = SystemClock.elapsedRealtime() - probeStartedAt,
                    responseBytes = 0,
                    stage = VpnDataPlaneProbeStage.COMPLETE,
                    vpnNetworkHandle = vpnNetwork.networkHandle,
                )
            } catch (error: CancellationException) {
                throw error
            } catch (_: SocketTimeoutException) {
                currentCoroutineContext().ensureActive()
                failure(stage, "timeout", probeStartedAt)
            } catch (error: IOException) {
                currentCoroutineContext().ensureActive()
                failure(
                    stage,
                    if (sockets.expired) "timeout" else vpnDataPlaneExceptionCategory(error, unexpected = false),
                    probeStartedAt,
                )
            } catch (error: Exception) {
                currentCoroutineContext().ensureActive()
                failure(
                    stage,
                    if (sockets.expired) "timeout" else vpnDataPlaneExceptionCategory(error, unexpected = true),
                    probeStartedAt,
                )
            }
        }
    }

    private suspend fun verifyVpnDns(vpnNetwork: Network, host: String, timeoutMs: Long): String? {
        val boundedTimeoutMs = minOf(VPN_DNS_TIMEOUT_MS, timeoutMs.coerceAtLeast(1L))
        val result = resolveNetworkDns(vpnNetwork, host, boundedTimeoutMs, bypassCache = true)
        return result.failure ?: if (result.addresses.isEmpty()) "empty" else null
    }

    private suspend fun resolveNetworkDns(
        network: Network,
        host: String,
        timeoutMs: Long,
        bypassCache: Boolean,
    ): NetworkDnsResult {
        val boundedTimeoutMs = timeoutMs.coerceAtLeast(1L)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return withTimeoutOrNull(boundedTimeoutMs) {
                runInterruptible(Dispatchers.IO) {
                    try {
                        NetworkDnsResult(addresses = network.getAllByName(host).asList())
                    } catch (_: IOException) {
                        NetworkDnsResult(failure = "io")
                    }
                }
            } ?: NetworkDnsResult(failure = "timeout")
        }
        return resolveNetworkDnsAsync(network, host, boundedTimeoutMs, bypassCache)
    }

    @Suppress("NewApi")
    private suspend fun resolveNetworkDnsAsync(
        network: Network,
        host: String,
        timeoutMs: Long,
        bypassCache: Boolean,
    ): NetworkDnsResult {
        val result = CompletableDeferred<NetworkDnsResult>()
        val cancellationSignal = CancellationSignal()
        return try {
            DnsResolver.getInstance().query(
                network,
                host,
                DnsResolver.TYPE_A,
                if (bypassCache) {
                    DnsResolver.FLAG_NO_CACHE_LOOKUP or DnsResolver.FLAG_NO_CACHE_STORE
                } else {
                    0
                },
                Dispatchers.IO.asExecutor(),
                cancellationSignal,
                object : DnsResolver.Callback<Collection<InetAddress>> {
                    override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                        result.complete(
                            if (rcode == 0) {
                                NetworkDnsResult(addresses = answer)
                            } else {
                                NetworkDnsResult(failure = "rcode_$rcode")
                            },
                        )
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        result.complete(NetworkDnsResult(failure = "error_${error.code}"))
                    }
                },
            )
            withTimeoutOrNull(timeoutMs) { result.await() }
                ?: NetworkDnsResult(failure = "timeout")
        } catch (error: CancellationException) {
            throw error
        } catch (_: SecurityException) {
            NetworkDnsResult(failure = "security")
        } catch (_: Exception) {
            NetworkDnsResult(failure = "unexpected")
        } finally {
            cancellationSignal.cancel()
        }
    }

    private fun readResponseHeaders(input: BufferedInputStream): ByteArray? {
        val output = ByteArrayOutputStream()
        var terminatorBytes = 0
        while (output.size() < MAX_RESPONSE_HEADER_BYTES) {
            val next = input.read()
            if (next < 0) return null
            output.write(next)
            terminatorBytes = when {
                terminatorBytes == 0 && next == '\r'.code -> 1
                terminatorBytes == 1 && next == '\n'.code -> 2
                terminatorBytes == 2 && next == '\r'.code -> 3
                terminatorBytes == 3 && next == '\n'.code -> return output.toByteArray()
                next == '\r'.code -> 1
                else -> 0
            }
        }
        return null
    }

    private suspend fun awaitActiveVpnNetwork(probeDeadlineElapsedRealtimeMs: Long): android.net.Network? {
        val deadline = minOf(
            probeDeadlineElapsedRealtimeMs,
            SystemClock.elapsedRealtime() + ACTIVE_VPN_WAIT_TIMEOUT_MS,
        )
        do {
            currentCoroutineContext().ensureActive()
            val network = connectivity.activeNetwork
            val capabilities = network?.let(connectivity::getNetworkCapabilities)
            if (network != null && capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true) {
                return network
            }
            if (SystemClock.elapsedRealtime() >= deadline) return null
            delay(ACTIVE_VPN_WAIT_POLL_MS)
        } while (true)
    }

    private fun remainingTimeoutMs(deadlineElapsedRealtimeMs: Long): Int? {
        val remainingMs = deadlineElapsedRealtimeMs - SystemClock.elapsedRealtime()
        if (remainingMs <= 0L) return null
        return remainingMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt().coerceAtLeast(1)
    }

    private fun nextProbeEndpoints(count: Int): List<HttpsProbeEndpoint> {
        val start = endpointCursor.getAndIncrement()
        return List(count.coerceIn(1, PROBE_ENDPOINTS.size)) { offset ->
            PROBE_ENDPOINTS[Math.floorMod(start + offset, PROBE_ENDPOINTS.size)]
        }
    }

    private fun failure(
        stage: VpnDataPlaneProbeStage,
        category: String,
        startedAtElapsedRealtimeMs: Long,
        networkReadinessPending: Boolean = false,
    ) = VpnDataPlaneProbeResult(
        healthy = false,
        latencyMs = (SystemClock.elapsedRealtime() - startedAtElapsedRealtimeMs).coerceAtLeast(0L),
        responseBytes = 0,
        stage = stage,
        failure = category,
        networkReadinessPending = networkReadinessPending,
    )

    private companion object {
        private val PROBE_ENDPOINTS = listOf(
            HttpsProbeEndpoint("cp.cloudflare.com", "/generate_204", 204),
            HttpsProbeEndpoint("connectivitycheck.platform.hicloud.com", "/generate_204", 204),
            HttpsProbeEndpoint("www.gstatic.com", "/generate_204", 204),
        )
        private const val PROBE_PORT = 443
        private const val DEFAULT_PROBE_TIMEOUT_MS = 30_000L
        private const val VPN_DNS_TIMEOUT_MS = 12_000L
        private const val ACTIVE_VPN_WAIT_TIMEOUT_MS = 5_000L
        private const val ACTIVE_VPN_WAIT_POLL_MS = 50L
        private const val MAX_RESPONSE_HEADER_BYTES = 8_192
    }
}
