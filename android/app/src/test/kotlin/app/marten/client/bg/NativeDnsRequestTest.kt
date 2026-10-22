package app.marten.client.bg

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeDnsRequestTest {
    @Test
    fun `native cancellation releases request whose resolver never calls back`() {
        val registered = CountDownLatch(1)
        val submitted = CountDownLatch(1)
        val cancelNative = AtomicReference<(() -> Unit)?>(null)
        val cancelRequestCount = AtomicInteger()
        val executor = Executors.newSingleThreadExecutor()
        try {
            val result = executor.submit<Throwable?> {
                try {
                    runNativeDnsRequest(
                        registerCancellation = { cancel ->
                            cancelNative.set(cancel)
                            registered.countDown()
                        },
                    ) {
                        awaitNativeDnsAnswer<String>(
                            cancelRequest = { cancelRequestCount.incrementAndGet() },
                            submit = {
                                // Android resolver never invokes this callback.
                                submitted.countDown()
                            },
                        )
                    }
                    null
                } catch (error: Throwable) {
                    error
                }
            }

            assertTrue("native cancellation hook was not registered", registered.await(1, TimeUnit.SECONDS))
            assertTrue("DNS request was not submitted", submitted.await(1, TimeUnit.SECONDS))
            assertNotNull(cancelNative.get())
            cancelNative.get()!!.invoke()

            val error = result.get(1, TimeUnit.SECONDS)
            assertTrue("request should finish as cancelled, got $error", error is CancellationException)
            assertEquals("pending resolver request must be cancelled exactly once", 1, cancelRequestCount.get())
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `cancellation while waiting for physical network skips DNS submission`() {
        val registered = CountDownLatch(1)
        val networkWaitStarted = CountDownLatch(1)
        val cancelNative = AtomicReference<(() -> Unit)?>(null)
        val submitCount = AtomicInteger()
        val missingNetwork = CompletableDeferred<Unit>()
        val executor = Executors.newSingleThreadExecutor()
        try {
            val result = executor.submit<Throwable?> {
                try {
                    runNativeDnsRequest(
                        registerCancellation = { cancel ->
                            cancelNative.set(cancel)
                            registered.countDown()
                        },
                    ) {
                        // DefaultNetworkListener.get() waits on a pending response.await().
                        networkWaitStarted.countDown()
                        missingNetwork.await()
                        awaitNativeDnsAnswer<String>(
                            cancelRequest = {},
                            submit = { submitCount.incrementAndGet() },
                        )
                    }
                    null
                } catch (error: Throwable) {
                    error
                }
            }

            assertTrue("native cancellation hook was not registered", registered.await(1, TimeUnit.SECONDS))
            assertTrue("physical network wait did not start", networkWaitStarted.await(1, TimeUnit.SECONDS))
            cancelNative.get()!!.invoke()

            val error = result.get(1, TimeUnit.SECONDS)
            assertTrue("network wait should be cancelled, got $error", error is CancellationException)
            assertEquals("DNS must not be submitted after cancellation during network acquisition", 0, submitCount.get())
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `request timeout cancels pending resolver and returns without callback`() {
        val cancelRequestCount = AtomicInteger()
        val submitCount = AtomicInteger()
        val started = System.nanoTime()

        val error = captureFailure {
            runNativeDnsRequest(
                registerCancellation = {},
                timeoutMs = 50,
            ) {
                awaitNativeDnsAnswer<String>(
                    cancelRequest = { cancelRequestCount.incrementAndGet() },
                    submit = { submitCount.incrementAndGet() },
                )
            }
        }

        assertTrue("expected timeout cancellation, got $error", error is CancellationException)
        assertEquals(1, submitCount.get())
        assertEquals("timeout must cancel the unresolved native request", 1, cancelRequestCount.get())
        assertTrue("timed out request took too long to release", elapsedMillisSince(started) < 1_000)
    }

    @Test
    fun `native cancellation before request starts skips submission`() {
        val submitCount = AtomicInteger()

        val error = captureFailure {
            runNativeDnsRequest(
                registerCancellation = { cancel -> cancel() },
            ) {
                awaitNativeDnsAnswer<String>(
                    cancelRequest = {},
                    submit = { submitCount.incrementAndGet() },
                )
            }
        }

        assertTrue("expected cancellation before operation start, got $error", error is CancellationException)
        assertEquals("DNS request should not be submitted after an already delivered cancellation", 0, submitCount.get())
    }

    @Test
    fun `late resolver callback after cancellation is ignored`() {
        val registered = CountDownLatch(1)
        val cancelNative = AtomicReference<(() -> Unit)?>(null)
        val callback = AtomicReference<((Result<String>) -> Unit)?>(null)
        val cancelRequestCount = AtomicInteger()
        val executor = Executors.newSingleThreadExecutor()
        try {
            val result = executor.submit<Throwable?> {
                try {
                    runNativeDnsRequest(
                        registerCancellation = { cancel ->
                            cancelNative.set(cancel)
                            registered.countDown()
                        },
                    ) {
                        awaitNativeDnsAnswer(
                            cancelRequest = { cancelRequestCount.incrementAndGet() },
                            submit = { callback.set(it) },
                        )
                    }
                    null
                } catch (error: Throwable) {
                    error
                }
            }

            assertTrue("native cancellation hook was not registered", registered.await(1, TimeUnit.SECONDS))
            waitUntilCallbackStored(callback)
            cancelNative.get()!!.invoke()
            val error = result.get(1, TimeUnit.SECONDS)
            assertTrue("request should finish as cancelled, got $error", error is CancellationException)

            callback.get()!!.invoke(Result.success("too late"))
            callback.get()!!.invoke(Result.failure(IllegalStateException("late resolver error")))
            assertEquals(1, cancelRequestCount.get())
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `first callback wins when resolver calls back more than once`() {
        val answer = runNativeDnsRequest(registerCancellation = {}) {
            awaitNativeDnsAnswer<String>(
                cancelRequest = {},
                submit = { callback ->
                    callback(Result.success("first"))
                    callback(Result.success("duplicate"))
                },
            )
        }

        assertEquals("first", answer)
    }

    @Test
    fun `healthy resolver callback returns answer`() {
        val answer = runNativeDnsRequest(registerCancellation = {}) {
            awaitNativeDnsAnswer<String>(
                cancelRequest = {},
                submit = { callback -> callback(Result.success("192.0.2.42")) },
            )
        }

        assertEquals("192.0.2.42", answer)
    }

    @Test
    fun `synchronous submission failure cancels native request`() {
        val cancelRequestCount = AtomicInteger()
        val expected = IllegalStateException("resolver registration failed")

        val error = captureFailure {
            runNativeDnsRequest(registerCancellation = {}) {
                awaitNativeDnsAnswer<String>(
                    cancelRequest = { cancelRequestCount.incrementAndGet() },
                    submit = { throw expected },
                )
            }
        }

        assertTrue("submission failure should propagate, got $error", error is IllegalStateException)
        assertEquals(expected.message, error.message)
        assertEquals("failed submission must release its native request", 1, cancelRequestCount.get())
    }

    @Test
    fun `answer racing native cancellation completes once and stays bounded`() {
        repeat(20) { iteration ->
            val registered = CountDownLatch(1)
            val submitted = CountDownLatch(1)
            val startRace = CountDownLatch(1)
            val cancelNative = AtomicReference<(() -> Unit)?>(null)
            val callback = AtomicReference<((Result<String>) -> Unit)?>(null)
            val cancelRequestCount = AtomicInteger()
            val worker = Executors.newSingleThreadExecutor()
            val racers = Executors.newFixedThreadPool(2)
            try {
                val result = worker.submit<Any?> {
                    try {
                        runNativeDnsRequest(
                            registerCancellation = { cancel ->
                                cancelNative.set(cancel)
                                registered.countDown()
                            },
                        ) {
                            awaitNativeDnsAnswer<String>(
                                cancelRequest = { cancelRequestCount.incrementAndGet() },
                                submit = {
                                    callback.set(it)
                                    submitted.countDown()
                                },
                            )
                        }
                    } catch (error: Throwable) {
                        error
                    }
                }

                assertTrue("iteration $iteration: cancellation hook was not registered", registered.await(1, TimeUnit.SECONDS))
                assertTrue("iteration $iteration: DNS request was not submitted", submitted.await(1, TimeUnit.SECONDS))
                val cancelTask = racers.submit { startRace.await(); cancelNative.get()!!.invoke() }
                val answerTask = racers.submit { startRace.await(); callback.get()!!.invoke(Result.success("answer")) }
                startRace.countDown()
                cancelTask.get(1, TimeUnit.SECONDS)
                answerTask.get(1, TimeUnit.SECONDS)

                val outcome = result.get(1, TimeUnit.SECONDS)
                assertTrue(
                    "iteration $iteration: result must be either the answer or cancellation, got $outcome",
                    outcome == "answer" || outcome is CancellationException,
                )
                assertTrue(
                    "iteration $iteration: request cancellation may run at most once",
                    cancelRequestCount.get() in 0..1,
                )
                callback.get()!!.invoke(Result.success("late duplicate"))
                callback.get()!!.invoke(Result.failure(IllegalStateException("late duplicate error")))
            } finally {
                worker.shutdownNow()
                racers.shutdownNow()
            }
        }
    }

    private fun waitUntilCallbackStored(callback: AtomicReference<((Result<String>) -> Unit)?>) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(1)
        while (callback.get() == null && System.nanoTime() < deadline) {
            Thread.yield()
        }
        assertNotNull("resolver callback was not installed", callback.get())
    }

    private fun captureFailure(block: () -> Unit): Throwable {
        try {
            block()
        } catch (error: Throwable) {
            return error
        }
        throw AssertionError("expected the native DNS request to fail")
    }

    private fun elapsedMillisSince(startedNanos: Long): Long =
        TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedNanos)
}
