package app.marten.client.bg

import android.net.DnsResolver
import android.net.Network
import android.os.Build
import android.os.CancellationSignal
import android.system.ErrnoException
import android.system.OsConstants
import androidx.annotation.RequiresApi
import app.marten.core.libbox.ExchangeContext
import app.marten.core.libbox.LocalDNSTransport
import app.marten.core.mobile.EndpointResolver
import app.marten.core.mobile.EndpointResolveContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import java.net.InetAddress
import java.net.UnknownHostException

object LocalResolver : LocalDNSTransport, EndpointResolver {
    private const val RCODE_NXDOMAIN = 3
    private const val ENDPOINT_LOOKUP_TIMEOUT_MS = 2_000L

    /**
     * Resolves config-bootstrap endpoints on the exact physical Android
     * Network. Mobile config generation runs after the fail-closed VPN becomes
     * the UID default, so java.net/net.DefaultResolver would otherwise recurse
     * into that blocker before the selected outbound exists.
     *
     * The hostname and resolver error are intentionally never logged.
     */
    override fun resolve(ctx: EndpointResolveContext, domain: String): String {
        if (domain.isBlank()) return ""
        return runCatching {
            val addresses = runNativeDnsRequest(
                registerCancellation = { cancel -> ctx.onCancel { cancel() } },
                timeoutMs = ENDPOINT_LOOKUP_TIMEOUT_MS,
            ) {
                val physicalNetwork = DefaultNetworkMonitor.networkForSocket()
                    ?: return@runNativeDnsRequest emptyList<InetAddress>()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    resolveEndpointWithDnsResolver(physicalNetwork, domain)
                } else {
                    LegacyDnsWorker.lookup { physicalNetwork.getAllByName(domain).asList() }
                }
            }
            addresses.mapNotNull { it.hostAddress }.distinct().joinToString("\n")
        }.getOrDefault("")
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private suspend fun resolveEndpointWithDnsResolver(
        physicalNetwork: Network,
        domain: String,
    ): Collection<InetAddress> {
        val cancellation = CancellationSignal()
        return awaitNativeDnsAnswer(cancellation::cancel) { complete ->
            DnsResolver.getInstance().query(physicalNetwork, domain, DnsResolver.FLAG_EMPTY,
                Dispatchers.IO.asExecutor(), cancellation,
                object : DnsResolver.Callback<Collection<InetAddress>> {
                    override fun onAnswer(addresses: Collection<InetAddress>, rcode: Int) {
                        complete(Result.success(if (rcode == 0) addresses else emptyList()))
                    }
                    override fun onError(error: DnsResolver.DnsException) {
                        complete(Result.failure(error))
                    }
                })
        }
    }

    override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    private data class DnsAnswer<T>(val value: T, val rcode: Int)

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        try {
            val result = runNativeDnsRequest(
                registerCancellation = { cancel -> ctx.onCancel { cancel() } },
            ) {
                val physicalNetwork = try {
                    DefaultNetworkMonitor.require()
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    throw ErrnoException("physical network unavailable", OsConstants.ENETUNREACH)
                }
                val signal = CancellationSignal()
                awaitNativeDnsAnswer<DnsAnswer<ByteArray>>(signal::cancel) { complete ->
                    DnsResolver.getInstance().rawQuery(
                        physicalNetwork,
                        message,
                        // Keep Android's normal cache/retry policy on this exact physical Network.
                        DnsResolver.FLAG_EMPTY,
                        Dispatchers.IO.asExecutor(),
                        signal,
                        object : DnsResolver.Callback<ByteArray> {
                            override fun onAnswer(answer: ByteArray, rcode: Int) {
                                complete(Result.success(DnsAnswer(answer, rcode)))
                            }

                            override fun onError(error: DnsResolver.DnsException) {
                                complete(Result.failure(error))
                            }
                        },
                    )
                }
            }
            if (result.rcode == 0) ctx.rawSuccess(result.value) else ctx.errorCode(result.rcode)
        } catch (error: Exception) {
            publishDnsFailure(ctx, error)
        }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        try {
            val result = runNativeDnsRequest(
                registerCancellation = { cancel -> ctx.onCancel { cancel() } },
            ) {
                val physicalNetwork = try {
                    DefaultNetworkMonitor.require()
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    throw ErrnoException("physical network unavailable", OsConstants.ENETUNREACH)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val signal = CancellationSignal()
                    awaitNativeDnsAnswer<DnsAnswer<Collection<InetAddress>>>(signal::cancel) { complete ->
                        val callback = object : DnsResolver.Callback<Collection<InetAddress>> {
                            override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                                complete(Result.success(DnsAnswer(answer, rcode)))
                            }

                            override fun onError(error: DnsResolver.DnsException) {
                                complete(Result.failure(error))
                            }
                        }
                        val type = when {
                            network.endsWith("4") -> DnsResolver.TYPE_A
                            network.endsWith("6") -> DnsResolver.TYPE_AAAA
                            else -> null
                        }
                        if (type != null) {
                            DnsResolver.getInstance().query(
                                physicalNetwork, domain, type, DnsResolver.FLAG_EMPTY,
                                Dispatchers.IO.asExecutor(), signal, callback,
                            )
                        } else {
                            DnsResolver.getInstance().query(
                                physicalNetwork, domain, DnsResolver.FLAG_EMPTY,
                                Dispatchers.IO.asExecutor(), signal, callback,
                            )
                        }
                    }
                } else {
                    // Legacy Android has no cancellable DNS API. Release the native caller
                    // on cancellation/deadline and ignore any later system resolver result.
                    DnsAnswer(LegacyDnsWorker.lookup { physicalNetwork.getAllByName(domain).asList() }, 0)
                }
            }
            if (result.rcode == 0) {
                ctx.success(result.value.mapNotNull { it.hostAddress }.joinToString("\n"))
            } else {
                ctx.errorCode(result.rcode)
            }
        } catch (error: Exception) {
            publishDnsFailure(ctx, error)
        }
    }

    private fun publishDnsFailure(ctx: ExchangeContext, error: Exception) {
        when (error) {
            is TimeoutCancellationException -> ctx.errnoCode(OsConstants.ETIMEDOUT)
            is CancellationException -> ctx.errnoCode(OsConstants.ECANCELED)
            is UnknownHostException -> ctx.errorCode(RCODE_NXDOMAIN)
            is ErrnoException -> ctx.errnoCode(error.errno)
            else -> ctx.errnoCode((error.cause as? ErrnoException)?.errno ?: OsConstants.EIO)
        }
    }
}
