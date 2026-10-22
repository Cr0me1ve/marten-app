package app.marten.client.bg

private const val INTERACTIVE_STABLE_PROBE_INTERVAL_MS = 5 * 60_000L
private const val BACKGROUND_STABLE_PROBE_INTERVAL_MS = 30 * 60_000L
internal const val VPN_DATA_PLANE_PROOF_REUSE_MS = 15_000L
internal const val STANDARD_VPN_DATA_PLANE_ATTEMPT_TIMEOUT_MS = 4_000L
internal const val TURNCOAT_VPN_DATA_PLANE_ATTEMPT_TIMEOUT_MS = 30_000L

/**
 * A normal direct tunnel gets several fresh socket attempts inside the outer
 * startup budget. TURNcoat may need a longer first carrier wake-up, but both
 * paths are capped by the caller's remaining deadline.
 */
internal fun vpnDataPlaneAttemptTimeoutMs(
    turncoatRoute: Boolean,
    remainingBudgetMs: Long = Long.MAX_VALUE,
): Long {
    val preferred = if (turncoatRoute) {
        TURNCOAT_VPN_DATA_PLANE_ATTEMPT_TIMEOUT_MS
    } else {
        STANDARD_VPN_DATA_PLANE_ATTEMPT_TIMEOUT_MS
    }
    return minOf(preferred, remainingBudgetMs.coerceAtLeast(1L))
}

internal data class TunTrafficSnapshot(
    val interfaceName: String,
    val rxBytes: Long,
    val txBytes: Long,
)

internal fun hasTunTrafficAdvanced(
    previous: TunTrafficSnapshot?,
    current: TunTrafficSnapshot?,
): Boolean {
    if (previous == null || current == null) return false
    if (previous.interfaceName != current.interfaceName) return true
    return current.rxBytes > previous.rxBytes || current.txBytes > previous.txBytes
}

internal fun stableRouteProbeIntervalMs(deviceInteractive: Boolean): Long =
    if (deviceInteractive) INTERACTIVE_STABLE_PROBE_INTERVAL_MS else BACKGROUND_STABLE_PROBE_INTERVAL_MS

internal fun vpnDataPlaneProbeDelayMs(
    deviceInteractive: Boolean,
    lastProofElapsedRealtimeMs: Long,
    nowElapsedRealtimeMs: Long,
): Long {
    if (lastProofElapsedRealtimeMs <= 0L) return 0L
    val ageMs = (nowElapsedRealtimeMs - lastProofElapsedRealtimeMs).coerceAtLeast(0L)
    return (stableRouteProbeIntervalMs(deviceInteractive) - ageMs).coerceAtLeast(0L)
}

/** All stable protocols share one deadline; traffic does not shorten sleep. */
internal fun shouldRunVpnDataPlaneProbe(
    forced: Boolean,
    degraded: Boolean,
    deviceInteractive: Boolean,
    lastProofElapsedRealtimeMs: Long,
    nowElapsedRealtimeMs: Long,
): Boolean {
    if (forced || degraded || lastProofElapsedRealtimeMs <= 0L) return true
    return vpnDataPlaneProbeDelayMs(
        deviceInteractive, lastProofElapsedRealtimeMs, nowElapsedRealtimeMs,
    ) == 0L
}
