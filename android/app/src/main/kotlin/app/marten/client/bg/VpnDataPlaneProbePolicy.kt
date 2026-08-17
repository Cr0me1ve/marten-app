package app.marten.client.bg

private const val ACTIVE_TUN_TRAFFIC_PROBE_MIN_AGE_MS = 5 * 60_000L
private const val INTERACTIVE_STABLE_PROBE_INTERVAL_MS = 5 * 60_000L
private const val BACKGROUND_STABLE_PROBE_INTERVAL_MS = 30 * 60_000L
private const val TURNCOAT_STABLE_PROBE_INTERVAL_MS = 60_000L
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

/**
 * Reuses the existing route-watchdog wakeups instead of creating another
 * timer. A full data-plane request is immediate for startup/recovery and a
 * degraded route, activity-aware for a busy TUN, and deliberately rare while
 * the VPN is stable and idle.
 */
internal fun shouldRunVpnDataPlaneProbe(
    forced: Boolean,
    degraded: Boolean,
    turncoatRoute: Boolean,
    deviceInteractive: Boolean,
    tunTrafficAdvanced: Boolean,
    lastProofElapsedRealtimeMs: Long,
    nowElapsedRealtimeMs: Long,
): Boolean {
    if (forced || degraded || lastProofElapsedRealtimeMs <= 0L) return true
    val proofAgeMs = (nowElapsedRealtimeMs - lastProofElapsedRealtimeMs).coerceAtLeast(0L)
    if (tunTrafficAdvanced && proofAgeMs >= ACTIVE_TUN_TRAFFIC_PROBE_MIN_AGE_MS) return true
    val stableIntervalMs = if (turncoatRoute) {
        // TURN relay probes prove only the allocation, not the Hysteria
        // backend or Android TUN. Keep a real end-to-end proof fresh even
        // while the device is in the background.
        TURNCOAT_STABLE_PROBE_INTERVAL_MS
    } else if (deviceInteractive) {
        INTERACTIVE_STABLE_PROBE_INTERVAL_MS
    } else {
        BACKGROUND_STABLE_PROBE_INTERVAL_MS
    }
    return proofAgeMs >= stableIntervalMs
}
