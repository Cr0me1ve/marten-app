package app.marten.client.bg

import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProbeSocketLeaseTest {
    @Test
    fun `parent cancellation closes a socket while its read is blocked`() {
        runBlocking<Unit> {
            ServerSocket(0).use { server ->
                val connected = CompletableDeferred<Unit>()
                val socketRef = AtomicReference<Socket>()
                val peerRef = AtomicReference<Socket>()
                val accepted = async(Dispatchers.IO) { server.accept().also(peerRef::set) }
                // Keep the blocking socket read directly on Dispatchers.IO, matching
                // the probe's production execution path and exercising lease cleanup
                // without an extra withContext cancellation boundary.
                val probe = launch(Dispatchers.IO) {
                    withBoundedProbeSockets(timeoutMs = 10_000L) { lease ->
                        val socket = Socket()
                        socketRef.set(socket)
                        assertTrue(lease.own(socket))
                        socket.connect(server.localSocketAddress)
                        connected.complete(Unit)
                        socket.getInputStream().read()
                    }
                }

                try {
                    withTimeout(2_000L) { connected.await() }
                    val peer = withTimeout(2_000L) { accepted.await() }
                    withTimeout(2_000L) { probe.cancelAndJoin() }
                    assertTrue("cancellation should close the raw socket", socketRef.get().isClosed)
                    assertTrue("closing the client should make the peer observe EOF", withContext(Dispatchers.IO) {
                        peer.getInputStream().read()
                    } == -1)
                } finally {
                    probe.cancel()
                    accepted.cancel()
                    peerRef.get()?.close()
                }
            }
        }
    }

    @Test
    fun `total deadline interrupts a slow drip read even when every read makes progress`() {
        runBlocking<Unit> {
            ServerSocket(0).use { server ->
                val keepWriting = AtomicBoolean(true)
                val peerRef = AtomicReference<Socket>()
                val accepted = async(Dispatchers.IO) { server.accept().also(peerRef::set) }
                val writer = async(Dispatchers.IO) {
                    accepted.await().use { peer ->
                        val output = peer.getOutputStream()
                        while (keepWriting.get()) {
                            try {
                                output.write(1)
                                output.flush()
                                Thread.sleep(20L)
                            } catch (_: IOException) {
                                break
                            }
                        }
                    }
                }
                val socketRef = AtomicReference<Socket>()
                val leaseRef = AtomicReference<ProbeSocketLease>()
                val startedAt = System.nanoTime()

                var readFailed = false
                try {
                    withBoundedProbeSockets(timeoutMs = 250L) { lease ->
                        leaseRef.set(lease)
                        val socket = Socket()
                        socketRef.set(socket)
                        assertTrue(lease.own(socket))
                        socket.connect(server.localSocketAddress)
                        socket.soTimeout = 2_000
                        withContext(Dispatchers.IO) {
                            val input = socket.getInputStream()
                            while (true) input.read()
                        }
                    }
                } catch (_: IOException) {
                    readFailed = true
                } finally {
                    keepWriting.set(false)
                    socketRef.get()?.close()
                    writer.cancelAndJoin()
                    accepted.cancel()
                    peerRef.get()?.close()
                }

                val elapsedMs = (System.nanoTime() - startedAt) / 1_000_000L
                assertTrue("the deadline must close the socket and interrupt its read", readFailed)
                assertTrue("the lease should record its deadline expiry", leaseRef.get()?.expired == true)
                assertTrue("the read must stop near the total deadline", elapsedMs < 2_000L)
                assertTrue(socketRef.get().isClosed)
            }
        }
    }

    @Test
    fun `fast winner can cancel a blocked loser and finish the race promptly`() {
        runBlocking<Unit> {
            ServerSocket(0).use { server ->
                val connected = CompletableDeferred<Unit>()
                val loserSocket = AtomicReference<Socket>()
                val peerRef = AtomicReference<Socket>()
                val accepted = async(Dispatchers.IO) { server.accept().also(peerRef::set) }
                try {
                    val winner = withTimeout(2_000L) {
                        coroutineScope {
                            val loser = launch(Dispatchers.IO) {
                                withBoundedProbeSockets(timeoutMs = 10_000L) { lease ->
                                    val socket = Socket()
                                    loserSocket.set(socket)
                                    assertTrue(lease.own(socket))
                                    socket.connect(server.localSocketAddress)
                                    connected.complete(Unit)
                                    socket.getInputStream().read()
                                }
                            }
                            withTimeout(1_000L) { connected.await() }
                            val result = async { delay(20L); "healthy" }.await()
                            loser.cancelAndJoin()
                            result
                        }
                    }

                    assertEquals("healthy", winner)
                    assertTrue("the canceled loser must release its socket", loserSocket.get().isClosed)
                } finally {
                    loserSocket.get()?.close()
                    accepted.cancel()
                    peerRef.get()?.close()
                }
            }
        }
    }

    @Test
    fun `expiry closes registered raw and tls sockets once in ownership order and rejects late sockets`() {
        val closeOrder = Collections.synchronizedList(mutableListOf<String>())
        val lease = ProbeSocketLease()
        val raw = RecordingSocket("raw", closeOrder)
        val tls = RecordingSocket("tls", closeOrder)

        assertTrue(lease.own(raw))
        assertTrue(lease.own(tls))
        lease.expire()
        lease.expire()
        lease.close()
        lease.close()

        assertTrue(lease.expired)
        assertEquals(listOf("raw", "tls"), closeOrder.toList())
        assertFalse("a late socket must not become owned after expiry", lease.own(RecordingSocket("late", closeOrder)))
        assertEquals(listOf("raw", "tls", "late"), closeOrder.toList())
    }

    @Test
    fun `late tls publication after raw expiry is closed immediately`() {
        val closeOrder = Collections.synchronizedList(mutableListOf<String>())
        val lease = ProbeSocketLease()
        val raw = RecordingSocket("raw", closeOrder)
        val tls = RecordingSocket("tls", closeOrder)

        assertTrue(lease.own(raw))
        lease.expire()
        assertFalse(lease.own(tls))
        lease.close()
        lease.expire()

        assertEquals(listOf("raw", "tls"), closeOrder.toList())
    }

    @Test
    fun `normal completion cancels the deadline timer`() {
        runBlocking<Unit> {
            val leaseRef = AtomicReference<ProbeSocketLease>()
            val value = withBoundedProbeSockets(timeoutMs = 120L) { lease ->
                leaseRef.set(lease)
                "complete"
            }

            assertEquals("complete", value)
            assertNotNull(leaseRef.get())
            delay(250L)
            assertFalse("a completed operation's timer must no longer expire its lease", leaseRef.get().expired)
        }
    }

    private class RecordingSocket(
        private val label: String,
        private val closeOrder: MutableList<String>,
    ) : Socket() {
        override fun close() {
            closeOrder.add(label)
            super.close()
        }
    }
}
