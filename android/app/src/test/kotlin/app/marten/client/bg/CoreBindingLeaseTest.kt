package app.marten.client.bg

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreBindingLeaseTest {
    @Test
    fun `timeout before queued bind is issued retires only that lease and permits a new attempt`() {
        val delayed = CoreBindingLease()

        assertTrue(delayed.retire())
        assertEquals(CoreBindingLease.Phase.RETIRED_UNISSUED, delayed.phase)
        assertFalse("the queued runnable must not issue a retired bind", delayed.issue())

        val retry = CoreBindingLease()
        assertTrue("a never-issued bind cannot own a Binder or VPN process", retry.issue())
        assertEquals(CoreBindingLease.Phase.ISSUED, retry.phase)
    }

    @Test
    fun `timeout after issued bind keeps quarantine until late owner releases`() {
        val issued = CoreBindingLease()
        assertTrue(issued.issue())

        assertFalse("an issued bind may already own a process", issued.retire())
        assertEquals(CoreBindingLease.Phase.RETIRED_ISSUED, issued.phase)
        issued.attach()
        assertEquals("a late connection must not revive a retired owner", CoreBindingLease.Phase.RETIRED_ISSUED, issued.phase)

        issued.release()
        assertEquals(CoreBindingLease.Phase.RELEASED, issued.phase)
        val retry = CoreBindingLease()
        assertTrue("replacement is possible only after exact old owner release", retry.issue())
    }
}
