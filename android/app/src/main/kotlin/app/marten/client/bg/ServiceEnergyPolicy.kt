package app.marten.client.bg

private const val CORE_RECOVERY_INTERACTIVE_POLL_MS = 5_000L
private const val CORE_RECOVERY_BACKGROUND_POLL_MS = 15_000L
private const val CORE_STARTUP_POLL_MS = 15_000L
private const val ROUTE_DEGRADED_INTERACTIVE_POLL_MS = 5_000L
private const val ROUTE_DEGRADED_BACKGROUND_POLL_MS = 15_000L
private const val CAPTCHA_CONTROL_RETRY_MIN_MS = 2_000L
private const val CAPTCHA_CONTROL_RETRY_BACKGROUND_MIN_MS = 15_000L
private const val CAPTCHA_CONTROL_RETRY_MAX_MS = 60_000L

/**
 * Only bounded startup/recovery uses this cadence. Stable supervision belongs
 * to the single route monitor, with process death delivered by Binder events.
 */
internal fun coreWatchdogPollDelayMs(
    recoveryInProgress: Boolean,
    deviceInteractive: Boolean,
): Long = when {
    !recoveryInProgress -> CORE_STARTUP_POLL_MS
    deviceInteractive -> CORE_RECOVERY_INTERACTIVE_POLL_MS
    else -> CORE_RECOVERY_BACKGROUND_POLL_MS
}

/**
 * Contended lifecycle admission normally wakes from its ownership event. The
 * timeout is only a liveness fallback for an owner that cannot publish one;
 * make that fallback exponential and screen-aware so a fail-closed outage
 * cannot become a permanent two-second CPU/log loop.
 */
internal fun coreRecoveryAdmissionRetryDelayMs(
    rejectedAttempts: Int,
    deviceInteractive: Boolean,
): Long = maxOf(
    coreRecoveryRetryDelayMs(rejectedAttempts.coerceAtLeast(0) + 1),
    coreWatchdogPollDelayMs(
        recoveryInProgress = true,
        deviceInteractive = deviceInteractive,
    ),
)

internal fun selectedRouteWatchdogPollDelayMs(
    degraded: Boolean,
    deviceInteractive: Boolean,
): Long = when {
    degraded && deviceInteractive -> ROUTE_DEGRADED_INTERACTIVE_POLL_MS
    degraded -> ROUTE_DEGRADED_BACKGROUND_POLL_MS
    else -> stableRouteProbeIntervalMs(deviceInteractive)
}

/**
 * A missing local background gRPC server must not turn a service-owned CAPTCHA
 * listener into a permanent short retry loop. Interactive recovery remains
 * responsive, while screen-off failures start sparse and both modes converge
 * on one attempt per minute.
 */
internal fun serviceCaptchaControlRetryDelayMs(
    consecutiveFailures: Int,
    deviceInteractive: Boolean,
): Long {
    val exponent = consecutiveFailures.coerceIn(0, 5)
    val exponential = minOf(
        CAPTCHA_CONTROL_RETRY_MAX_MS,
        CAPTCHA_CONTROL_RETRY_MIN_MS * (1L shl exponent),
    )
    return if (deviceInteractive) {
        exponential
    } else {
        maxOf(CAPTCHA_CONTROL_RETRY_BACKGROUND_MIN_MS, exponential)
    }
}
