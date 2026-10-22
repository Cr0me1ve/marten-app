package app.marten.client.bg

import app.marten.core.libbox.Libbox
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.joinAll

/**
 * Process-wide admission for physical pre-connect diagnostics.
 *
 * Flutter engines and MethodHandler instances can be replaced while a native
 * TLS/ICMP call is blocking. Keeping jobs and native resource gates here lets
 * a cold Quick Settings/notification Connect close the same resources even
 * when the handler that accepted them has already detached.
 */
internal object LocalProbeAdmission {
    internal data class BlockTransition(
        val epoch: Long,
        val jobs: List<Job>,
    )

    private val lock = Any()
    private val jobs = mutableSetOf<Job>()
    private var blocked = false
    private var blockEpoch = 0L

    /** Read-only snapshot used only to join an already admitted VPN route. */
    fun isAllowed(): Boolean = synchronized(lock) { !blocked }

    fun register(job: Job): Boolean = synchronized(lock) {
        if (blocked || job.isCompleted) {
            false
        } else {
            jobs.add(job)
            // A cancelled parent can complete a LAZY child concurrently with
            // registration. Never retain a job whose completion callback ran
            // before it was added to the process-wide set.
            if (job.isCompleted) {
                jobs.remove(job)
                false
            } else {
                true
            }
        }
    }

    fun unregister(job: Job) {
        synchronized(lock) {
            jobs.remove(job)
        }
    }

    /**
     * Closes all native admission gates before cancelling their coroutine
     * owners. This method itself does not wait and is safe in a synchronous
     * cold native Connect transaction; native contexts/sockets are already
     * closed when it returns.
     */
    fun blockAndCancel(): List<Job> = ensureBlockedAndCancel().jobs

    /**
     * Starts a new externally owned seal. A later release must present this
     * exact epoch, so a detached Flutter engine or an older terminal Stop can
     * never reopen native physical probes after a newer transition began.
     */
    fun beginBlockTransitionAndCancel(): BlockTransition = blockAndCancel(advanceEpoch = true)

    /** Native lifecycle code may strengthen an existing seal without changing its owner. */
    fun ensureBlockedAndCancel(): BlockTransition = blockAndCancel(advanceEpoch = false)

    private fun blockAndCancel(advanceEpoch: Boolean): BlockTransition {
        val transition = synchronized(lock) {
            if (advanceEpoch || !blocked) {
                blockEpoch += 1L
            }
            blocked = true
            // Serialize the complete local/native gate transition with both
            // job admission and allow(). A Connect must never observe local
            // admission closed while a concurrent terminal Stop reopens one
            // of the native physical-probe gates behind it.
            PhysicalTlsProbe.blockAndCancel()
            Libbox.blockICMPPings()
            BlockTransition(blockEpoch, jobs.toList())
        }
        val cancellation = CancellationException("local probes retired for strict VPN transition")
        transition.jobs.forEach { it.cancel(cancellation) }
        return transition
    }

    suspend fun beginBlockTransitionAndDrain(): Long {
        val transition = beginBlockTransitionAndCancel()
        transition.jobs.joinAll()
        return transition.epoch
    }

    fun allowIfCurrent(
        expectedBlockEpoch: Long,
        admission: () -> Boolean,
    ): Boolean = synchronized(lock) {
        if (blockEpoch != expectedBlockEpoch || !admission()) {
            return@synchronized false
        }
        if (!blocked) return@synchronized true
        // Keep job admission closed until both native gates are open, and
        // serialize the whole transition against the next Connect.
        PhysicalTlsProbe.allow()
        Libbox.allowICMPPings()
        blocked = false
        true
    }

}
