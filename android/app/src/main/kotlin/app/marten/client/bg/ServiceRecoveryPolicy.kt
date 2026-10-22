package app.marten.client.bg

import app.marten.core.api.v2.hcore.CoreStates
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

internal suspend fun <T> runNonCancellableServiceCleanup(block: suspend () -> T): T =
    withContext(NonCancellable) {
        block()
    }

internal fun requiresCoreCleanupEscalation(
    closeCompleted: Boolean,
    tunQuiescent: Boolean,
): Boolean = !closeCompleted || !tunQuiescent

internal fun isTunRuntimeQuiescent(
    descriptorValid: Boolean,
    candidateCount: Int,
): Boolean = !descriptorValid && candidateCount == 0

/**
 * Determines whether Marten's previous Android TUN generation is gone.
 *
 * On Android 12+ ConnectivityManager identifies the VPN owner, so a TUN that
 * belongs to another app must not block a Marten start. Older releases keep
 * the conservative global-interface fallback because ownerUid is unavailable.
 */
internal fun isOwnedTunRuntimeQuiescent(
    descriptorValid: Boolean,
    ownVpnActive: Boolean,
    ownershipKnown: Boolean,
    globalCandidateCount: Int,
    allowPlatformVpnReplacement: Boolean = false,
): Boolean =
    !descriptorValid &&
        (
            allowPlatformVpnReplacement ||
                if (ownershipKnown) {
                    !ownVpnActive
                } else {
                    globalCandidateCount == 0
                }
            )

internal fun isTunReleaseCompleteForCleanup(
    descriptorValid: Boolean,
    candidateCount: Int,
    serviceStopping: Boolean,
): Boolean =
    !descriptorValid &&
        (serviceStopping || candidateCount == 0)

internal fun isOwnedTunReleaseCompleteForCleanup(
    descriptorValid: Boolean,
    ownVpnActive: Boolean,
    ownershipKnown: Boolean,
    globalCandidateCount: Int,
    serviceStopping: Boolean,
): Boolean =
    !descriptorValid &&
        (
            serviceStopping ||
                if (ownershipKnown) {
                    !ownVpnActive
                } else {
                    globalCandidateCount == 0
                }
            )

internal fun isTunRuntimeHealthy(
    descriptorValid: Boolean,
    interfaceUp: Boolean,
    candidateCount: Int,
): Boolean = descriptorValid && interfaceUp && candidateCount == 1

internal fun isOwnedTunRuntimeHealthy(
    descriptorValid: Boolean,
    ownVpnActive: Boolean,
    ownershipKnown: Boolean,
    interfaceUp: Boolean,
    ownedCandidateCount: Int,
    globalCandidateCount: Int,
): Boolean =
    if (ownershipKnown) {
        descriptorValid && ownVpnActive && interfaceUp && ownedCandidateCount == 1
    } else {
        isTunRuntimeHealthy(descriptorValid, interfaceUp, globalCandidateCount)
    }

/** Identifies the framework VPN generation owned by a retained packet sink. */
internal enum class FailClosedVpnKind {
    STARTUP,
    RETIREMENT,
}

/** Exact framework generation marker installed on one fail-closed VPN Network. */
internal data class FailClosedVpnGeneration(
    val kind: FailClosedVpnKind,
    val markerAddress: String,
)

internal enum class PlatformVpnRetirementOutcome {
    RELEASED,
    RETAINED,
    FAILED,
}

/**
 * A retained descriptor is reusable as Marten's packet sink only when Android
 * has published the exact fail-closed VPN generation that owns it.
 *
 * Builder.establish() can replace the framework VPN network before the old
 * ParcelFileDescriptor becomes invalid. A unique address marker, rather than
 * the reusable startup/retirement kind, prevents a stale Network of the same
 * kind from authorizing a native restart or another VPN replacement.
 */
internal fun isFailClosedVpnBarrierReady(
    retainedGeneration: FailClosedVpnGeneration?,
    publishedMarkerAddresses: Set<String>,
    tunRuntimeHealthy: Boolean,
): Boolean =
    retainedGeneration != null &&
        retainedGeneration.markerAddress in publishedMarkerAddresses &&
        tunRuntimeHealthy

internal fun coreRecoveryRetryDelayMs(failedAttempts: Int): Long {
    val exponentialStep = (failedAttempts.coerceAtLeast(1) - 1).coerceAtMost(5)
    return (2_000L shl exponentialStep).coerceAtMost(60_000L)
}

/** Maps verbose in-memory recovery reasons to fixed privacy-safe diagnostics. */
internal fun coreRecoveryReasonCategory(reason: String): String {
    val normalized = reason.lowercase()
    return when {
        "runtime watchdog lost marten vpn" in normalized -> "vpn_ownership"
        "verified route did not produce a healthy android tun" in normalized -> "tun_health"
        "network route recovery" in normalized -> "network_route"
        "native" in normalized && "reset" in normalized -> "native_reset"
        "native startup route" in normalized ||
            "selected-route" in normalized ||
            "selected server unavailable" in normalized -> "startup_route"
        "route watchdog" in normalized -> "route_watchdog"
        "local core runtime" in normalized -> "core_runtime"
        "core did not start" in normalized || "core remained starting" in normalized -> "core_start"
        else -> "unknown"
    }
}

internal fun isCoreRuntimeHealthy(coreState: CoreStates?): Boolean = coreState == CoreStates.STARTED

internal fun isCurrentNetworkRouteProof(
    proofGeneration: Long,
    currentGeneration: Long,
    routeHealthy: Boolean,
    userSessionActive: Boolean,
): Boolean =
    routeHealthy &&
        userSessionActive &&
        proofGeneration == currentGeneration

internal fun shouldEscalateRouteRecovery(failedChecks: Int, threshold: Int): Boolean =
    failedChecks >= threshold

/**
 * Keeps a stable, already verified VPN user-visible while one periodic proof
 * has a transient failure but the same healthy TUN is still carrying traffic.
 *
 * This grace is deliberately one-shot. A second check, an already degraded
 * route, a missing proof, or an unhealthy/idle TUN must use the normal
 * fail-closed degradation path.
 */
internal fun shouldPreserveVerifiedRouteAfterTransientProbeFailure(
    platformStarted: Boolean,
    routeAlreadyDegraded: Boolean,
    priorFailedChecks: Int,
    currentProofAvailable: Boolean,
    tunHealthy: Boolean,
    tunTrafficAdvanced: Boolean,
): Boolean =
    platformStarted &&
        !routeAlreadyDegraded &&
        priorFailedChecks == 0 &&
        currentProofAvailable &&
        tunHealthy &&
        tunTrafficAdvanced

/** Publishes recovery only for hard evidence or a confirmed failure count. */
internal fun shouldPublishRouteRecoveryStatus(
    failedChecks: Int,
    recoveryThreshold: Int,
    hardFailure: Boolean,
): Boolean = hardFailure || shouldEscalateRouteRecovery(failedChecks, recoveryThreshold)

internal data class TunInterfaceState(
    val name: String,
    val index: Int,
    val up: Boolean,
    val mtu: Int,
    val addressCount: Int,
)

internal fun selectTunRuntimeInterface(interfaces: List<TunInterfaceState>): TunInterfaceState? =
    interfaces.maxWithOrNull(
        compareBy<TunInterfaceState> { it.up }
            .thenBy { it.index },
    )

internal fun shouldRetryFailedNativeStartup(
    routeVerified: Boolean,
    userSessionActive: Boolean,
    startStillCurrent: Boolean,
): Boolean = !routeVerified && userSessionActive && startStillCurrent

internal fun shouldDelegateRouteVerificationToNativeRecovery(
    nativeRecoveryActive: Boolean,
    userSessionActive: Boolean,
    startStillCurrent: Boolean,
): Boolean = nativeRecoveryActive && userSessionActive && startStillCurrent

internal fun shouldRestoreUserSessionFromServiceCommand(
    restartedBySystem: Boolean,
    processRecoveryRequested: Boolean,
    connectFromNotification: Boolean,
    userSessionActive: Boolean,
    activeConfigAvailable: Boolean,
): Boolean = (restartedBySystem || processRecoveryRequested) &&
    !connectFromNotification &&
    userSessionActive &&
    activeConfigAvailable

internal fun shouldRecoverUnverifiedStartedCore(
    sawStartedCore: Boolean,
    coreState: CoreStates?,
    userSessionActive: Boolean,
): Boolean = sawStartedCore && userSessionActive && coreState == CoreStates.STOPPED

internal fun shouldRecoverNeverStartedCore(
    sawStartedCore: Boolean,
    coreState: CoreStates?,
    userSessionActive: Boolean,
    elapsedMs: Long,
    timeoutMs: Long,
): Boolean = !sawStartedCore &&
    userSessionActive &&
    (coreState == null || coreState == CoreStates.STOPPED) &&
    elapsedMs >= timeoutMs

internal fun shouldRecoverStalledStartingCore(
    sawStartedCore: Boolean,
    coreState: CoreStates?,
    userSessionActive: Boolean,
    elapsedMs: Long,
    timeoutMs: Long,
): Boolean = !sawStartedCore &&
    userSessionActive &&
    coreState == CoreStates.STARTING &&
    elapsedMs >= timeoutMs

internal fun shouldRecoverUnverifiedRunningCore(
    sawStartedCore: Boolean,
    coreState: CoreStates?,
    userSessionActive: Boolean,
    elapsedMs: Long,
    timeoutMs: Long,
): Boolean = sawStartedCore &&
    userSessionActive &&
    coreState == CoreStates.STARTED &&
    elapsedMs >= timeoutMs

/**
 * Applies one deadline to the whole continuously-online recovery generation.
 * Individual native attempts and their backoff must never renew this budget.
 * A missing physical network is parked separately on Android's network callback
 * and therefore does not consume or expire the online recovery window.
 */
internal fun shouldTerminateExpiredCoreRecovery(
    recoveryInProgress: Boolean,
    userSessionActive: Boolean,
    underlyingNetworkAvailable: Boolean,
    elapsedMs: Long,
    timeoutMs: Long,
): Boolean = recoveryInProgress &&
    userSessionActive &&
    underlyingNetworkAvailable &&
    elapsedMs >= timeoutMs

internal fun isLiveTurncoatCarrier(
    rxProofCount: Long,
    activeSessions: Int,
): Boolean = activeSessions > 0 && rxProofCount > 0
