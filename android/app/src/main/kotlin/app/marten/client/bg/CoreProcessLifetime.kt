package app.marten.client.bg

/** Exact process identity and the replacement barrier, independent of Android callbacks. */
internal class CoreProcessLifetime(private val controllerPid: Int) {
    private enum class State { BINDING, LIVE, RETIRING, DEAD }
    private var state = State.BINDING
    private var pid = 0
    @Synchronized fun attached(processPid: Int) {
        check(state == State.BINDING && processPid > 0 && processPid != controllerPid)
        pid = processPid
        state = State.LIVE
    }
    @Synchronized fun beginRetirement(protectionPreserved: Boolean): Int {
        check(protectionPreserved && pid > 0 && pid != controllerPid && state != State.DEAD)
        state = State.RETIRING
        return pid
    }
    @Synchronized fun confirmDeath() { state = State.DEAD }
    @Synchronized fun acceptsCallbacks(): Boolean = state == State.LIVE
    @Synchronized fun replacementAllowed(): Boolean = state == State.DEAD
}
