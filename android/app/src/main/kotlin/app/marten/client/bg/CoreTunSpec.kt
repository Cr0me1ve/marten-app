package app.marten.client.bg

import android.os.Bundle
import app.marten.core.libbox.RoutePrefixIterator
import app.marten.core.libbox.StringIterator
import app.marten.core.libbox.TunOptions

/** Value-only IPC contract. No Go object or process-local fd crosses Binder. */
internal data class CoreTunAddress(val address: String, val prefix: Int)
internal data class CoreTunSpec(
    val mtu: Int,
    val autoRoute: Boolean,
    val dnsServer: String,
    val inet4Address: List<CoreTunAddress>,
    val inet6Address: List<CoreTunAddress>,
    val includePackage: List<String>,
    val excludePackage: List<String>,
    val isHTTPProxyEnabled: Boolean,
    val httpProxyServer: String,
    val httpProxyServerPort: Int,
) {
    fun toBundle() = Bundle().apply {
        putInt("mtu", mtu); putBoolean("autoRoute", autoRoute); putString("dns", dnsServer)
        putStringArrayList("v4", ArrayList(inet4Address.map { "${it.address}/${it.prefix}" }))
        putStringArrayList("v6", ArrayList(inet6Address.map { "${it.address}/${it.prefix}" }))
        putStringArrayList("include", ArrayList(includePackage))
        putStringArrayList("exclude", ArrayList(excludePackage))
        putBoolean("proxy", isHTTPProxyEnabled); putString("proxyHost", httpProxyServer)
        putInt("proxyPort", httpProxyServerPort)
    }
    companion object {
        private fun prefixes(iterator: RoutePrefixIterator): List<CoreTunAddress> = buildList {
            while (iterator.hasNext()) iterator.next().let { add(CoreTunAddress(it.address(), it.prefix())) }
        }
        private fun strings(iterator: StringIterator): List<String> = buildList {
            while (iterator.hasNext()) add(iterator.next())
        }
        fun from(options: TunOptions): CoreTunSpec {
            val proxyEnabled = options.isHTTPProxyEnabled
            // libbox's optional proxy getters dereference its nullable proxy config.
            return CoreTunSpec(
                options.mtu, options.autoRoute, options.dnsServerAddress.value,
                prefixes(options.inet4Address), prefixes(options.inet6Address),
                strings(options.includePackage), strings(options.excludePackage),
                proxyEnabled,
                if (proxyEnabled) options.httpProxyServer else "",
                if (proxyEnabled) options.httpProxyServerPort else 0,
            )
        }
        fun from(bundle: Bundle): CoreTunSpec {
            fun addresses(key: String) = bundle.getStringArrayList(key).orEmpty().map {
                CoreTunAddress(it.substringBeforeLast('/'), it.substringAfterLast('/').toInt())
            }
            return CoreTunSpec(
                bundle.getInt("mtu"), bundle.getBoolean("autoRoute"), bundle.getString("dns").orEmpty(),
                addresses("v4"), addresses("v6"), bundle.getStringArrayList("include").orEmpty(),
                bundle.getStringArrayList("exclude").orEmpty(), bundle.getBoolean("proxy"),
                bundle.getString("proxyHost").orEmpty(), bundle.getInt("proxyPort"),
            )
        }
    }
}
