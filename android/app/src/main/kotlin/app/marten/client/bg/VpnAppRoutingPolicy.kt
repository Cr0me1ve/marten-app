package app.marten.client.bg

import app.marten.client.constant.PerAppProxyMode

internal sealed class VpnAppRoutingPlan {
    data class IncludeOnly(val packages: List<String>) : VpnAppRoutingPlan()

    data class Exclude(val packages: List<String>) : VpnAppRoutingPlan()
}

/**
 * Resolves the one Android Builder routing mode for a VPN generation.
 *
 * Android forbids mixing allowed and disallowed application lists. The
 * subscription options and the user-selected split-tunnelling mode therefore
 * have to be reduced to one plan before mutating VpnService.Builder.
 */
internal fun resolveVpnAppRoutingPlan(
    ownPackageName: String,
    perAppProxyMode: String,
    perAppProxyPackages: List<String>,
    optionIncludePackages: List<String>,
    optionExcludePackages: List<String>,
): VpnAppRoutingPlan {
    val selectedPackages = normalizePackageNames(perAppProxyPackages)
    val includedByOptions = normalizePackageNames(optionIncludePackages)
    val excludedByOptions = normalizePackageNames(optionExcludePackages)
        .filter { it != ownPackageName }
    val bypassPackages = excludedByOptions.toSet()

    return when (perAppProxyMode) {
        PerAppProxyMode.INCLUDE -> {
            val includedPackages = (selectedPackages + ownPackageName)
                .distinct()
                .filter { it == ownPackageName || it !in bypassPackages }
            VpnAppRoutingPlan.IncludeOnly(includedPackages)
        }

        PerAppProxyMode.EXCLUDE -> VpnAppRoutingPlan.Exclude(
            (selectedPackages + excludedByOptions)
                .distinct()
                .filter { it != ownPackageName },
        )

        PerAppProxyMode.OFF -> {
            if (includedByOptions.isNotEmpty()) {
                VpnAppRoutingPlan.IncludeOnly(
                    (includedByOptions + ownPackageName)
                        .distinct()
                        .filter { it == ownPackageName || it !in bypassPackages },
                )
            } else {
                VpnAppRoutingPlan.Exclude(excludedByOptions.distinct())
            }
        }

        else -> error("android: invalid per-app VPN routing mode")
    }
}

private fun normalizePackageNames(packages: List<String>): List<String> =
    packages.map(String::trim).filter(String::isNotEmpty).distinct()
