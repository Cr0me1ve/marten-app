package app.marten.client.bg

private const val CORE_RECOVERY_POLL_MS = 2_000L
private const val CORE_STABLE_POLL_MS = 15_000L
private const val VPN_OWNERSHIP_INTERACTIVE_POLL_MS = 5_000L
private const val VPN_OWNERSHIP_BACKGROUND_POLL_MS = 15_000L
private const val ROUTE_DEGRADED_POLL_MS = 500L
private const val ROUTE_ICMP_INTERACTIVE_POLL_MS = 3_000L
private const val ROUTE_ICMP_BACKGROUND_POLL_MS = 10_000L
private const val ROUTE_STABLE_INTERACTIVE_POLL_MS = 30_000L
private const val ROUTE_STABLE_BACKGROUND_POLL_MS = 60_000L

/**
 * Stable foreground-service health checks are deliberately sparse. Android
 * network, screen and Doze callbacks request immediate validation, while a
 * recovery already in progress retains a short bounded supervision interval.
 */
internal fun coreWatchdogPollDelayMs(recoveryInProgress: Boolean): Long =
    if (recoveryInProgress) CORE_RECOVERY_POLL_MS else CORE_STABLE_POLL_MS

internal fun vpnOwnershipWatchdogPollDelayMs(deviceInteractive: Boolean): Long =
    if (deviceInteractive) {
        VPN_OWNERSHIP_INTERACTIVE_POLL_MS
    } else {
        VPN_OWNERSHIP_BACKGROUND_POLL_MS
    }

internal fun selectedRouteWatchdogPollDelayMs(
    degraded: Boolean,
    icmpRoute: Boolean,
    deviceInteractive: Boolean,
): Long = when {
    degraded -> ROUTE_DEGRADED_POLL_MS
    icmpRoute && deviceInteractive -> ROUTE_ICMP_INTERACTIVE_POLL_MS
    icmpRoute -> ROUTE_ICMP_BACKGROUND_POLL_MS
    deviceInteractive -> ROUTE_STABLE_INTERACTIVE_POLL_MS
    else -> ROUTE_STABLE_BACKGROUND_POLL_MS
}
