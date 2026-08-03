package app.marten.client

import app.marten.client.constant.Status

/**
 * Service alerts describe a stopped service and are delivered as one-shot
 * events. A retained alert cannot override a currently bound, started VPN.
 */
internal fun shouldDeliverServiceAlert(
    event: ServiceEvent,
    boundStatus: Status?,
): Boolean {
    return event.status != Status.Stopped || boundStatus != Status.Started
}
