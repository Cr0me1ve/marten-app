package app.marten.client.bg

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnCoexistencePolicyTest {
    @Test
    fun `should reject non-explicit vpn generation when asymmetry policy blocks takeover`() {
        assertFalse(
            "Non-VPN mode always allows new generation",
            shouldRejectNewVpnGeneration(
                vpnMode = false,
                explicitUserStart = false,
                currentGenerationOwnsVpn = false,
                vpnNetworkVisibilityKnown = false,
                anyVpnNetworkActive = false,
                externalVpnNetworkActive = false,
            ),
        )

        assertFalse(
            "Current owned generation may continue while other networks are present",
            shouldRejectNewVpnGeneration(
                vpnMode = true,
                explicitUserStart = false,
                currentGenerationOwnsVpn = true,
                vpnNetworkVisibilityKnown = false,
                anyVpnNetworkActive = true,
                externalVpnNetworkActive = false,
            ),
        )

        assertTrue(
            "Automatic unknown ownership with an active foreign VPN stays blocked",
            shouldRejectNewVpnGeneration(
                vpnMode = true,
                explicitUserStart = false,
                currentGenerationOwnsVpn = false,
                vpnNetworkVisibilityKnown = true,
                anyVpnNetworkActive = false,
                externalVpnNetworkActive = true,
            ),
        )

        assertTrue(
            "Automatic unknown VPN ownership stays blocked",
            shouldRejectNewVpnGeneration(
                vpnMode = true,
                explicitUserStart = false,
                currentGenerationOwnsVpn = false,
                vpnNetworkVisibilityKnown = false,
                anyVpnNetworkActive = false,
                externalVpnNetworkActive = false,
            ),
        )

        assertTrue(
            "Any active known VPN blocks non-owned generation",
            shouldRejectNewVpnGeneration(
                vpnMode = true,
                explicitUserStart = false,
                currentGenerationOwnsVpn = false,
                vpnNetworkVisibilityKnown = true,
                anyVpnNetworkActive = true,
                externalVpnNetworkActive = false,
            ),
        )

        assertFalse(
            "Known owned descriptor continues without triggering fail-closed",
            shouldRejectNewVpnGeneration(
                vpnMode = true,
                explicitUserStart = false,
                currentGenerationOwnsVpn = true,
                vpnNetworkVisibilityKnown = true,
                anyVpnNetworkActive = true,
                externalVpnNetworkActive = false,
            ),
        )

        assertTrue(
            "Own-generation continuation should not be blocked by external activity",
            shouldRejectNewVpnGeneration(
                vpnMode = true,
                explicitUserStart = false,
                currentGenerationOwnsVpn = true,
                vpnNetworkVisibilityKnown = true,
                anyVpnNetworkActive = false,
                externalVpnNetworkActive = true,
            ),
        )

        assertFalse(
            "Explicit user start must bypass normal ownership rejection",
            shouldRejectNewVpnGeneration(
                vpnMode = true,
                explicitUserStart = true,
                currentGenerationOwnsVpn = false,
                vpnNetworkVisibilityKnown = true,
                anyVpnNetworkActive = true,
                externalVpnNetworkActive = true,
            ),
        )

        assertFalse(
            "Explicit user start must bypass unknown ownership checks too",
            shouldRejectNewVpnGeneration(
                vpnMode = true,
                explicitUserStart = true,
                currentGenerationOwnsVpn = false,
                vpnNetworkVisibilityKnown = false,
                anyVpnNetworkActive = false,
                externalVpnNetworkActive = false,
            ),
        )
    }

    @Test
    fun `should retire platform vpn only after completed safe marten core stop`() {
        assertFalse(
            "Missing coreStopped is always unsafe",
            shouldRetirePlatformVpnAfterCoreStop(
                coreStopped = false,
                vpnService = true,
                vpnOwnershipRevoked = false,
                externalVpnActive = false,
            ),
        )

        assertFalse(
            "Missing active VPN service is unsafe",
            shouldRetirePlatformVpnAfterCoreStop(
                coreStopped = true,
                vpnService = false,
                vpnOwnershipRevoked = false,
                externalVpnActive = false,
            ),
        )

        assertFalse(
            "Revoked ownership is treated as unsafe even with core stopped",
            shouldRetirePlatformVpnAfterCoreStop(
                coreStopped = true,
                vpnService = true,
                vpnOwnershipRevoked = true,
                externalVpnActive = false,
            ),
        )

        assertFalse(
            "External active VPN blocks Marten retirement",
            shouldRetirePlatformVpnAfterCoreStop(
                coreStopped = true,
                vpnService = true,
                vpnOwnershipRevoked = false,
                externalVpnActive = true,
            ),
        )

        assertTrue(
            "Boundary acceptance requires exactly all expected safe guards",
            shouldRetirePlatformVpnAfterCoreStop(
                coreStopped = true,
                vpnService = true,
                vpnOwnershipRevoked = false,
                externalVpnActive = false,
            ),
        )

        assertFalse(
            "Any one false flag is unsafe, including non-core stopped + revoked + external",
            shouldRetirePlatformVpnAfterCoreStop(
                coreStopped = false,
                vpnService = true,
                vpnOwnershipRevoked = true,
                externalVpnActive = true,
            ),
        )
    }

    @Test
    fun `Marten retirement network candidate policy is constrained to the marker VPN network`() {
        fun assertCandidate(
            vpnTransport: Boolean,
            ownerVerificationRequired: Boolean,
            ownerIsMarten: Boolean,
            hasRetirementAddress: Boolean,
            expected: Boolean,
            reason: String,
        ) {
            assertEquals(
                reason,
                expected,
                isMartenRetirementNetworkCandidate(
                    vpnTransport = vpnTransport,
                    ownerVerificationRequired = ownerVerificationRequired,
                    ownerIsMarten = ownerIsMarten,
                    hasRetirementAddress = hasRetirementAddress,
                ),
            )
        }

        // Marker address and VPN transport are mandatory.
        assertCandidate(
            false, false, false, false, false,
            "non-VPN transport cannot be a retirement candidate",
        )
        assertCandidate(
            false, false, false, true, false,
            "non-VPN transport cannot be a retirement candidate",
        )
        assertCandidate(
            false, false, true, false, false,
            "non-VPN transport cannot be a retirement candidate",
        )
        assertCandidate(
            false, true, false, false, false,
            "non-VPN transport cannot be a retirement candidate",
        )
        assertCandidate(
            false, true, true, false, false,
            "non-VPN transport cannot be a retirement candidate",
        )
        assertCandidate(
            false, true, true, true, false,
            "non-VPN transport cannot be a retirement candidate",
        )
        assertCandidate(
            true, false, false, false, false,
            "missing retirement address blocks candidate classification",
        )
        assertCandidate(
            true, false, true, false, false,
            "missing retirement address blocks candidate classification",
        )
        assertCandidate(
            true, true, false, false, false,
            "missing retirement address blocks candidate classification",
        )
        assertCandidate(
            true, true, true, false, false,
            "missing retirement address blocks candidate classification",
        )

        // Android 12+ requires a known Marten owner, so an unavailable or foreign owner is rejected.
        assertCandidate(
            true, true, false, true, false,
            "required owner verification must reject a foreign or unavailable owner",
        )

        // Android 12+ accepts only Marten's marker VPN; pre-S retains the address fallback.
        assertCandidate(
            true, true, true, true, true,
            "verified Marten marker network must be accepted",
        )
        assertCandidate(
            true, false, false, true, true,
            "pre-S marker fallback permits unavailable owner UID",
        )
        assertCandidate(
            true, false, true, true, true,
            "pre-S marker fallback also permits Marten owner when reported",
        )
    }
}
