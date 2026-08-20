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
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.job
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
import java.util.concurrent.atomic.AtomicReference

internal data class VpnDataPlaneProbeResult(
    val healthy: Boolean,
    val latencyMs: Long,
    val responseBytes: Int,
    val vpnNetworkHandle: Long? = null,
    val failure: String? = null,
) {
    val summary: String
        get() = if (healthy) {
            "VPN data-plane GET and DNS verified latency=${latencyMs}ms bytes=$responseBytes"
        } else {
            "VPN data-plane proof failed category=${failure ?: "unknown"}"
        }
}

private data class NetworkDnsResult(
    val addresses: Collection<InetAddress> = emptyList(),
    val failure: String? = null,
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

    fun currentVpnNetworkHandle(): Long? = runCatching {
        val network = connectivity.activeNetwork ?: return@runCatching null
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return@runCatching null
        if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return@runCatching null
        network.networkHandle
    }.getOrNull()

    suspend fun run(
        underlyingNetwork: Network?,
        timeoutMs: Long = DEFAULT_PROBE_TIMEOUT_MS,
    ): VpnDataPlaneProbeResult = withContext(Dispatchers.IO) {
        val deadlineElapsedRealtimeMs = SystemClock.elapsedRealtime() + timeoutMs.coerceAtLeast(1L)
        // Builder.establish() returns before ConnectivityService necessarily
        // publishes the new VPN as this UID's active Network. The core can be
        // fully started while activeNetwork still briefly points at Wi-Fi.
        // Wait through that bounded platform hand-off instead of rejecting and
        // tearing down an otherwise healthy tunnel on the first snapshot.
        val vpnNetwork = awaitActiveVpnNetwork(deadlineElapsedRealtimeMs)
            ?: return@withContext failure("caller_not_routed_to_vpn")
        val resolverNetwork = underlyingNetwork
            ?: return@withContext failure("underlying_network_unavailable")

        // Resolve the numeric HTTP target on the protected underlying Network
        // so a broken tunnel resolver cannot prevent the transport proof itself.
        // Once that request warms and proves the route, verifyVpnDns performs a
        // separate uncached lookup on the VPN Network. Admission requires both:
        // user apps need a working TUN route and working DNS through that route.
        val underlyingDnsTimeoutMs = remainingTimeoutMs(deadlineElapsedRealtimeMs)?.toLong()
            ?: return@withContext failure("timeout")
        val underlyingDns = resolveNetworkDns(
            resolverNetwork,
            timeoutMs = underlyingDnsTimeoutMs,
            bypassCache = false,
        )
        val probeAddress = underlyingDns.addresses.firstOrNull { it is Inet4Address }
            ?: underlyingDns.addresses.firstOrNull()
            ?: return@withContext failure(
                if (underlyingDns.failure == "timeout") "timeout" else "underlying_dns_unavailable",
            )

        val startedAt = SystemClock.elapsedRealtime()
        val socket = AtomicReference<Socket?>()
        // Socket.connect/read do not reliably react to coroutine cancellation.
        // Closing the descriptor from the Job completion handler makes a user
        // stop authoritative instead of waiting for the per-attempt timeout.
        val cancellationHandle = currentCoroutineContext().job.invokeOnCompletion {
            runCatching { socket.getAndSet(null)?.close() }
        }
        try {
            val nonce = SystemClock.elapsedRealtimeNanos().toString(16)
            val connectTimeoutMs = remainingTimeoutMs(deadlineElapsedRealtimeMs)
                ?: return@withContext failure("timeout")
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
            socket.set(openedSocket)
            currentCoroutineContext().ensureActive()
            openedSocket.connect(InetSocketAddress(probeAddress, PROBE_PORT), connectTimeoutMs)
            val request = buildString {
                append("GET $PROBE_PATH?marten=$nonce HTTP/1.1\r\n")
                append("Host: $PROBE_HOST\r\n")
                append("Accept-Encoding: identity\r\n")
                append("Cache-Control: no-cache\r\n")
                append("Connection: close\r\n\r\n")
            }.toByteArray(StandardCharsets.US_ASCII)
            openedSocket.getOutputStream().apply {
                write(request)
                flush()
            }

            openedSocket.soTimeout = remainingTimeoutMs(deadlineElapsedRealtimeMs)
                ?: return@withContext failure("timeout")
            val responseHeaders = readResponseHeaders(BufferedInputStream(openedSocket.getInputStream()))
                ?: return@withContext failure("malformed_http_response")
            val statusLine = responseHeaders.toString(StandardCharsets.US_ASCII)
                .lineSequence()
                .firstOrNull()
                .orEmpty()
            val statusCode = statusLine.split(' ', limit = 3).getOrNull(1)?.toIntOrNull()
            if (statusCode != EXPECTED_STATUS_CODE) {
                return@withContext failure("unexpected_http_status")
            }
            val dnsTimeoutMs = remainingTimeoutMs(deadlineElapsedRealtimeMs)?.toLong()
                ?: return@withContext failure("timeout")
            val dnsFailure = verifyVpnDns(vpnNetwork, dnsTimeoutMs)
            if (dnsFailure != null) {
                return@withContext failure("vpn_dns_$dnsFailure")
            }
            VpnDataPlaneProbeResult(
                healthy = true,
                latencyMs = SystemClock.elapsedRealtime() - startedAt,
                responseBytes = 0,
                vpnNetworkHandle = vpnNetwork.networkHandle,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (_: SocketTimeoutException) {
            currentCoroutineContext().ensureActive()
            failure("timeout")
        } catch (error: IOException) {
            currentCoroutineContext().ensureActive()
            val category = "io_${error.javaClass.simpleName}"
            failure(category)
        } catch (error: Exception) {
            val category = "unexpected_${error.javaClass.simpleName}"
            failure(category)
        } finally {
            cancellationHandle.dispose()
            runCatching { socket.getAndSet(null)?.close() }
        }
    }

    private suspend fun verifyVpnDns(vpnNetwork: Network, timeoutMs: Long): String? {
        val boundedTimeoutMs = minOf(VPN_DNS_TIMEOUT_MS, timeoutMs.coerceAtLeast(1L))
        val result = resolveNetworkDns(vpnNetwork, boundedTimeoutMs, bypassCache = true)
        return result.failure ?: if (result.addresses.isEmpty()) "empty" else null
    }

    private suspend fun resolveNetworkDns(
        network: Network,
        timeoutMs: Long,
        bypassCache: Boolean,
    ): NetworkDnsResult {
        val boundedTimeoutMs = timeoutMs.coerceAtLeast(1L)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return withTimeoutOrNull(boundedTimeoutMs) {
                runInterruptible(Dispatchers.IO) {
                    try {
                        NetworkDnsResult(addresses = network.getAllByName(PROBE_HOST).asList())
                    } catch (_: IOException) {
                        NetworkDnsResult(failure = "io")
                    }
                }
            } ?: NetworkDnsResult(failure = "timeout")
        }
        return resolveNetworkDnsAsync(network, boundedTimeoutMs, bypassCache)
    }

    @Suppress("NewApi")
    private suspend fun resolveNetworkDnsAsync(
        network: Network,
        timeoutMs: Long,
        bypassCache: Boolean,
    ): NetworkDnsResult {
        val result = CompletableDeferred<NetworkDnsResult>()
        val cancellationSignal = CancellationSignal()
        return try {
            DnsResolver.getInstance().query(
                network,
                PROBE_HOST,
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

    private fun failure(category: String) = VpnDataPlaneProbeResult(
        healthy = false,
        latencyMs = 0L,
        responseBytes = 0,
        failure = category,
    )

    private companion object {
        private const val PROBE_HOST = "connectivitycheck.gstatic.com"
        private const val PROBE_PATH = "/generate_204"
        private const val PROBE_PORT = 80
        private const val EXPECTED_STATUS_CODE = 204
        private const val DEFAULT_PROBE_TIMEOUT_MS = 30_000L
        private const val VPN_DNS_TIMEOUT_MS = 12_000L
        private const val ACTIVE_VPN_WAIT_TIMEOUT_MS = 5_000L
        private const val ACTIVE_VPN_WAIT_POLL_MS = 50L
        private const val MAX_RESPONSE_HEADER_BYTES = 8_192
    }
}
