package app.marten.client.bg

/** Distinguishes a queued bind from an OS request that can own a core process. */
internal class CoreBindingLease {
    enum class Phase { SCHEDULED, ISSUED, ATTACHED, RETIRED_UNISSUED, RETIRED_ISSUED, RELEASED }
    var phase = Phase.SCHEDULED
        private set

    @Synchronized fun issue(): Boolean {
        if (phase != Phase.SCHEDULED) return false
        phase = Phase.ISSUED
        return true
    }

    /** Only true means no process could have been requested by this lease. */
    @Synchronized fun retire(): Boolean = when (phase) {
        Phase.SCHEDULED, Phase.RETIRED_UNISSUED -> {
            phase = Phase.RETIRED_UNISSUED
            true
        }
        Phase.RELEASED -> false
        else -> { phase = Phase.RETIRED_ISSUED; false }
    }

    @Synchronized fun attach() {
        if (phase == Phase.ISSUED) phase = Phase.ATTACHED
    }

    @Synchronized fun release() { phase = Phase.RELEASED }
}
