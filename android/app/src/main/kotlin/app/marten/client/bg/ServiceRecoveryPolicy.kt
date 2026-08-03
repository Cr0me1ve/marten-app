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
): Boolean =
    !descriptorValid &&
        if (ownershipKnown) {
            !ownVpnActive
        } else {
            globalCandidateCount == 0
        }

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

internal fun coreRecoveryRetryDelayMs(@Suppress("UNUSED_PARAMETER") failedAttempts: Int): Long = 2_000L

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

internal fun shouldRestartProcessForStalledCoreRecovery(
    recoveryInProgress: Boolean,
    userSessionActive: Boolean,
    coreState: CoreStates?,
    elapsedMs: Long,
    timeoutMs: Long,
): Boolean = recoveryInProgress &&
    userSessionActive &&
    coreState != CoreStates.STARTED &&
    elapsedMs >= timeoutMs

internal fun isLiveTurncoatCarrier(
    rxProofCount: Long,
    healthReportCount: Long,
    activeSessions: Int,
): Boolean = activeSessions > 0 && (rxProofCount > 0 || healthReportCount > 0)
