package app.marten.client

import android.os.Looper
import app.marten.client.bg.ServiceLifecycleOwnership
import app.marten.client.bg.initialPlatformStatusForStickyReplacement
import app.marten.client.constant.Status
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.util.ArrayDeque
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
class NativeConnectRequestBridgeTest {
    @Before
    fun resetBridge() {
        resetBridgeState()
        resetTerminalSessionForTest()
        // Existing bridge tests model a visible, resumed Activity unless the
        // individual case explicitly transitions presentation to stopped.
        NativeConnectRequestBridge.onForegroundPresentationStarted()
    }

    @After
    fun clearBridge() {
        resetBridgeState()
        resetTerminalSessionForTest()
    }

    @Test
    fun `detach and replacement listener retain an unacknowledged native connect`() {
        val originalListener = RecordingSink()
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(originalListener)

        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 42L))
        flushMainLooper()
        val handoffId = originalListener.handoffIds.single()
        dispatchPendingAgainForTest()
        assertEquals("the same EventChannel listener must not receive an unacknowledged handoff twice", 1, originalListener.handoffIds.size)

        NativeConnectRequestBridge.onEngineDetached()
        val replacementListener = RecordingSink()
        NativeConnectRequestBridge.onForegroundPresentationStarted()
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(replacementListener)
        flushMainLooper()

        assertEquals(
            "engine detach must preserve the exact native gesture for the replacement Flutter listener",
            listOf(handoffId),
            replacementListener.handoffIds,
        )
        assertTrue(
            "only the exact satisfied acknowledgement may retire the retained gesture",
            NativeConnectRequestBridge.acknowledgeSatisfiedFlutterConnect(handoffId),
        )
        flushMainLooper()
        assertEquals(1, replacementListener.handoffIds.size)
    }

    @Test
    fun `failed EventChannel delivery retains request for a later listener`() {
        val failingListener = RecordingSink(throwOnSuccess = true)
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(failingListener)

        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("shortcut", 7L))
        flushMainLooper()
        val handoffId = failingListener.handoffIds.single()

        val retryListener = RecordingSink()
        NativeConnectRequestBridge.onListen(retryListener)
        flushMainLooper()

        assertEquals("a throwing EventSink must not drop its pending native request", listOf(handoffId), retryListener.handoffIds)
        assertTrue(NativeConnectRequestBridge.acknowledgeSatisfiedFlutterConnect(handoffId))
    }

    @Test
    fun `stopped presentation leaves Quick Settings Connect on the native service path despite retained engine and EventSink`() {
        val listener = RecordingSink()
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(listener)
        NativeConnectRequestBridge.onForegroundPresentationStopped()

        assertFalse(
            "a retained background Flutter engine must not claim a Quick Settings Connect",
            NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 81L),
        )
        flushMainLooper()
        assertTrue(
            "the stopped presentation must not receive a Flutter EventChannel handoff",
            listener.handoffIds.isEmpty(),
        )
    }

    @Test
    fun `foreground presentation re-enables Flutter Quick Settings handoff after fast stop start transitions`() {
        val listener = RecordingSink()
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(listener)

        NativeConnectRequestBridge.onForegroundPresentationStopped()
        assertFalse(NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 82L))
        NativeConnectRequestBridge.onForegroundPresentationStarted()
        assertTrue(
            "a resumed visible presentation must regain the strict-egress Flutter handoff",
            NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 83L),
        )
        flushMainLooper()
        assertEquals(
            "only the post-resume Quick Settings request may reach the live EventSink",
            1,
            listener.handoffIds.size,
        )
    }

    @Test
    fun `stale acknowledgement cannot retire a newer native gesture`() {
        val listener = RecordingSink()
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(listener)

        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("notification", 1L))
        flushMainLooper()
        val staleHandoffId = listener.handoffIds.single()

        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("notification", 2L))
        flushMainLooper()
        val currentHandoffId = listener.handoffIds.last()
        assertFalse(
            "an old Dart ack_satisfied must not retire the replacement pending request",
            NativeConnectRequestBridge.acknowledgeSatisfiedFlutterConnect(staleHandoffId),
        )
        assertTrue(
            "the current handoff remains owned until its exact ack_satisfied",
            NativeConnectRequestBridge.acknowledgeSatisfiedFlutterConnect(currentHandoffId),
        )
        flushMainLooper()
        assertEquals("one EventChannel listener receives each handoff at most once", 2, listener.handoffIds.size)
    }

    @Test
    fun `stopped or stopping resolver requires Connect and preserves the exact handoff for claim`() {
        val listener = RecordingSink()
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(listener)
        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 61L))
        flushMainLooper()
        val handoffId = listener.handoffIds.single()

        assertEquals(
            "a retained Flutter Connected frame cannot satisfy a service-owned Stopped handoff",
            "connect_required",
            NativeConnectRequestBridge.resolveSatisfiedFlutterConnect(handoffId, Status.Stopped),
        )
        assertEquals(
            "Stopping is likewise not authoritative proof that this exact native request is running",
            "connect_required",
            NativeConnectRequestBridge.resolveSatisfiedFlutterConnect(handoffId, Status.Stopping),
        )
        val lease = NativeConnectRequestBridge.claimFlutterConnect(handoffId)
        assertTrue("connect_required must retain the exact handoff for its later claim", lease != null && lease > 0L)
        assertTrue(NativeConnectRequestBridge.completeFlutterConnectClaim(lease!!))
    }

    @Test
    fun `started resolver completes only the exact handoff and stale or cancelled ids leave a replacement intact`() {
        val listener = RecordingSink()
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(listener)

        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 71L))
        flushMainLooper()
        val startedHandoffId = listener.handoffIds.single()
        assertEquals("satisfied", NativeConnectRequestBridge.resolveSatisfiedFlutterConnect(startedHandoffId, Status.Started))
        assertEquals("a completed id cannot be acknowledged twice", "cancelled", NativeConnectRequestBridge.resolveSatisfiedFlutterConnect(startedHandoffId, Status.Started))

        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 72L))
        flushMainLooper()
        val startingHandoffId = listener.handoffIds.last()
        assertEquals("satisfied", NativeConnectRequestBridge.resolveSatisfiedFlutterConnect(startingHandoffId, Status.Starting))

        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 73L))
        flushMainLooper()
        val cancelledHandoffId = listener.handoffIds.last()
        NativeConnectRequestBridge.cancelPendingFlutterConnect()
        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 74L))
        flushMainLooper()
        val replacementHandoffId = listener.handoffIds.last()

        assertEquals(
            "a cancelled exact id cannot satisfy or remove a newer request",
            "cancelled",
            NativeConnectRequestBridge.resolveSatisfiedFlutterConnect(cancelledHandoffId, Status.Started),
        )
        val replacementLease = NativeConnectRequestBridge.claimFlutterConnect(replacementHandoffId)
        assertTrue("the newer exact handoff remains claimable after stale resolution", replacementLease != null && replacementLease > 0L)
        assertTrue(NativeConnectRequestBridge.completeFlutterConnectClaim(replacementLease!!))
    }

    @Test
    fun `sticky replacement initializes Starting only for an adopted live TUN before observer replay`() {
        assertEquals(
            "a sticky handoff with incomplete platform shutdown remains non-terminal for its replacement owner",
            Status.Starting,
            initialPlatformStatusForStickyReplacement(
                adoptedStickyTunHandoff = true,
                platformShutdownCompleted = false,
            ),
        )
        assertEquals(
            "a terminally closed adopted handoff is quiescent",
            Status.Stopped,
            initialPlatformStatusForStickyReplacement(
                adoptedStickyTunHandoff = true,
                platformShutdownCompleted = true,
            ),
        )
        assertEquals(
            "without a sticky handoff the replacement starts stopped",
            Status.Stopped,
            initialPlatformStatusForStickyReplacement(
                adoptedStickyTunHandoff = false,
                platformShutdownCompleted = false,
            ),
        )

        val source = File("src/main/kotlin/app/marten/client/bg/BoxService.kt").readText()
        val initialStatus = source.indexOf("status.value = initialPlatformStatusForStickyReplacement(")
        val activeInstance = source.indexOf("activeInstance = this", initialStatus)
        val processObserver = source.indexOf("status.observeForever(processStatusObserver)", activeInstance)
        assertTrue(
            "the successor must seed sticky-replacement status before becoming active and before LiveData can replay a stale Stopped value",
            initialStatus >= 0 && activeInstance > initialStatus && processObserver > activeInstance,
        )
    }

    @Test
    fun `terminal cancellation retires pending handoff without replay and permits a fresh connect`() {
        val originalListener = RecordingSink()
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(originalListener)
        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 1L))
        flushMainLooper()
        val cancelledHandoffId = originalListener.handoffIds.single()

        val terminalClaim = NativeConnectRequestBridge.cancelPendingFlutterConnect()
        assertEquals(cancelledHandoffId, terminalClaim.cancelledHandoffId)
        assertTrue(ServiceLifecycleOwnership.isTerminalStopEpochCurrent(terminalClaim.terminalSessionEpoch))
        NativeConnectRequestBridge.onEngineDetached()
        val replacementListener = RecordingSink()
        NativeConnectRequestBridge.onForegroundPresentationStarted()
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(replacementListener)
        flushMainLooper()

        assertTrue("a terminal Stop must prevent the old native Connect from replaying", replacementListener.handoffIds.isEmpty())
        assertFalse(
            "a stale Dart ack_satisfied must not retire an already cancelled handoff",
            NativeConnectRequestBridge.acknowledgeSatisfiedFlutterConnect(cancelledHandoffId),
        )

        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 2L))
        flushMainLooper()
        val freshHandoffId = replacementListener.handoffIds.single()
        assertTrue("a later explicit Connect must receive a fresh exact handoff", freshHandoffId > cancelledHandoffId)
        assertTrue(NativeConnectRequestBridge.acknowledgeSatisfiedFlutterConnect(freshHandoffId))
    }

    @Test
    fun `claim is idempotent for one handoff and binds the exact explicit start lease`() {
        val listener = RecordingSink()
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(listener)
        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("shortcut", 9L))
        flushMainLooper()
        val handoffId = listener.handoffIds.single()

        val firstLease = NativeConnectRequestBridge.claimFlutterConnect(handoffId)
        val repeatedLease = NativeConnectRequestBridge.claimFlutterConnect(handoffId)
        assertTrue("a live native Connect handoff must claim an explicit lease", firstLease != null && firstLease > 0L)
        assertEquals("same-handoff redelivery must reuse rather than mint another explicit start lease", firstLease, repeatedLease)
        assertTrue("a duplicate native gesture during claim must coalesce instead of replacing the exact owner", NativeConnectRequestBridge.requestFlutterConnect("shortcut", 10L))
        assertEquals(
            "a coalesced native gesture cannot replace the in-flight handoff lease",
            firstLease,
            NativeConnectRequestBridge.claimFlutterConnect(handoffId),
        )
        assertTrue("the claimed lease must remain current until the exact handoff is completed", ServiceLifecycleOwnership.isExplicitStartLeaseCurrent(firstLease!!))

        assertTrue("only the exact claimed lease may complete its native handoff", NativeConnectRequestBridge.completeFlutterConnectClaim(firstLease))
        assertFalse("completion retires the exact lease", ServiceLifecycleOwnership.isExplicitStartLeaseCurrent(firstLease))
        assertFalse("a completed claim cannot be replayed", NativeConnectRequestBridge.completeFlutterConnectClaim(firstLease))
        assertFalse("ack_satisfied cannot retire a handoff that its exact completion already removed", NativeConnectRequestBridge.acknowledgeSatisfiedFlutterConnect(handoffId))
    }

    @Test
    fun `terminal stop atomically invalidates a claimed lease and rejects stale admission`() {
        val listener = RecordingSink()
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(listener)
        assertTrue(NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 11L))
        flushMainLooper()
        val handoffId = listener.handoffIds.single()
        val lease = NativeConnectRequestBridge.claimFlutterConnect(handoffId)
        assertTrue(lease != null && ServiceLifecycleOwnership.isExplicitStartLeaseCurrent(lease))

        val terminalClaim = NativeConnectRequestBridge.cancelPendingFlutterConnect()
        assertEquals(handoffId, terminalClaim.cancelledHandoffId)
        assertTrue(ServiceLifecycleOwnership.isTerminalStopEpochCurrent(terminalClaim.terminalSessionEpoch))
        assertFalse("terminal Stop must invalidate the currently claimed explicit-start lease", ServiceLifecycleOwnership.isExplicitStartLeaseCurrent(lease!!))
        var staleAdmissionRan = false
        assertFalse(
            "a stale native handoff lease must be rejected under the terminal session epoch",
            ServiceLifecycleOwnership.runExplicitUserSession(lease) { staleAdmissionRan = true },
        )
        assertFalse("the stale admission action must not publish a fresh user session", staleAdmissionRan)
        assertFalse("terminal Stop removes the pending bridge owner before it can complete", NativeConnectRequestBridge.completeFlutterConnectClaim(lease))
        assertEquals("the removed handoff cannot be re-claimed", null, NativeConnectRequestBridge.claimFlutterConnect(handoffId))
    }

    @Test
    fun `post-permission dispatch preserves one lease for a live engine and rejects an old callback after Stop`() {
        val promptLease = ServiceLifecycleOwnership.issueExplicitStartLease()
        val listener = RecordingSink()
        var nativeStarts = 0

        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(listener)
        assertEquals(
            "a Flutter engine attached while Android permission was visible must receive the existing prompt lease",
            NativeConnectDispatchResult.FLUTTER_HANDOFF,
            NativeConnectRequestBridge.dispatchExplicitConnect(
                source = "quick_settings",
                requestId = 23L,
                explicitStartLease = promptLease,
                nativeConnect = {
                    nativeStarts += 1
                    true
                },
            ),
        )
        assertEquals("live Flutter handoff must not start native work in parallel", 0, nativeStarts)
        flushMainLooper()
        val handoffId = listener.handoffIds.single()
        assertEquals(
            "claiming the permission-owned handoff must reuse the pre-prompt lease rather than mint another one",
            promptLease,
            NativeConnectRequestBridge.claimFlutterConnect(handoffId),
        )

        val terminalClaim = NativeConnectRequestBridge.cancelPendingFlutterConnect()
        assertEquals(handoffId, terminalClaim.cancelledHandoffId)
        assertTrue(ServiceLifecycleOwnership.isTerminalStopEpochCurrent(terminalClaim.terminalSessionEpoch))
        assertFalse("terminal Stop invalidates the lease held by the old permission Activity", ServiceLifecycleOwnership.isExplicitStartLeaseCurrent(promptLease))
        assertEquals(
            "an old RESULT_OK callback after Stop cannot start native VPN or replace the terminal epoch",
            NativeConnectDispatchResult.REJECTED,
            NativeConnectRequestBridge.dispatchExplicitConnect(
                source = "quick_settings",
                requestId = 23L,
                explicitStartLease = promptLease,
                nativeConnect = {
                    nativeStarts += 1
                    true
                },
            ),
        )
        assertEquals("a stale Activity callback must not start a second native owner", 0, nativeStarts)
    }

    @Test
    fun `attached engine without a Dart EventSink must use the native explicit-connect owner`() {
        val promptLease = ServiceLifecycleOwnership.issueExplicitStartLease()
        var nativeStarts = 0

        NativeConnectRequestBridge.onEngineAttached()

        assertEquals(
            "an attached Flutter engine is not a handoff owner until Dart has installed its EventSink",
            NativeConnectDispatchResult.NATIVE_STARTED,
            NativeConnectRequestBridge.dispatchExplicitConnect(
                source = "quick_settings",
                requestId = 31L,
                explicitStartLease = promptLease,
                nativeConnect = {
                    nativeStarts += 1
                    true
                },
            ),
        )
        assertEquals("the unattached Dart listener cannot receive or block a native command", 1, nativeStarts)
        assertFalse(
            "the ordinary bridge path likewise requires an installed EventSink",
            NativeConnectRequestBridge.requestFlutterConnect("quick_settings", 31L),
        )
    }

    @Test
    fun `permission-host cancellation is exact by source and requestId and cannot clear a newer handoff`() {
        val listener = RecordingSink()
        NativeConnectRequestBridge.onEngineAttached()
        NativeConnectRequestBridge.onListen(listener)

        val olderLease = ServiceLifecycleOwnership.issueExplicitStartLease()
        assertEquals(
            NativeConnectDispatchResult.FLUTTER_HANDOFF,
            NativeConnectRequestBridge.dispatchExplicitConnect(
                source = "quick_settings",
                requestId = 41L,
                explicitStartLease = olderLease,
            ),
        )
        flushMainLooper()

        val newerLease = ServiceLifecycleOwnership.issueExplicitStartLease()
        assertEquals(
            NativeConnectDispatchResult.FLUTTER_HANDOFF,
            NativeConnectRequestBridge.dispatchExplicitConnect(
                source = "notification",
                requestId = 42L,
                explicitStartLease = newerLease,
            ),
        )
        flushMainLooper()
        val newerHandoffId = listener.handoffIds.last()

        assertFalse(
            "an old permission host may not cancel the replacement request with a different source/requestId",
            NativeConnectRequestBridge.cancelPermissionHandoff("quick_settings", 41L),
        )
        assertEquals(
            "the replacement retains its exact pre-prompt lease after the old host is destroyed",
            newerLease,
            NativeConnectRequestBridge.claimFlutterConnect(newerHandoffId),
        )
        assertTrue(
            "only the host that owns the matching source/requestId can retire the live request",
            NativeConnectRequestBridge.cancelPermissionHandoff("notification", 42L),
        )
        assertFalse(ServiceLifecycleOwnership.isExplicitStartLeaseCurrent(newerLease))
    }

    @Test
    fun `terminal Stop invalidates every previously admitted exact user-session epoch`() {
        val firstEpoch = checkNotNull(
            ServiceLifecycleOwnership.admitExplicitUserSession(explicitStartLease = null) { },
        )
        assertTrue("a freshly admitted epoch must authorize its final dispatch", ServiceLifecycleOwnership.isUserSessionEpochCurrent(firstEpoch))

        ServiceLifecycleOwnership.invalidateFlutterRestartForTerminalStop()
        assertFalse("Stop must invalidate the first Connect epoch", ServiceLifecycleOwnership.isUserSessionEpochCurrent(firstEpoch))

        val newerEpoch = checkNotNull(
            ServiceLifecycleOwnership.admitExplicitUserSession(explicitStartLease = null) { },
        )
        assertTrue("a later explicit Connect receives the current epoch", newerEpoch > firstEpoch)
        assertTrue(ServiceLifecycleOwnership.isUserSessionEpochCurrent(newerEpoch))

        ServiceLifecycleOwnership.invalidateFlutterRestartForTerminalStop()
        assertFalse("a later Stop must still invalidate an older Connect epoch", ServiceLifecycleOwnership.isUserSessionEpochCurrent(firstEpoch))
        assertFalse("a later Stop must invalidate the newest Connect epoch too", ServiceLifecycleOwnership.isUserSessionEpochCurrent(newerEpoch))
        assertFalse(
            "neither stale epoch may execute a post-permission final service dispatch",
            ServiceLifecycleOwnership.runIfUserSessionEpochCurrent(newerEpoch) { error("stale epoch dispatched") },
        )
    }

    @Test
    fun `posted terminal Stop and stale admission abort cannot clear a newer Connect`() {
        val olderEpoch = checkNotNull(
            ServiceLifecycleOwnership.admitExplicitUserSession(explicitStartLease = null) { },
        )
        val postedStop = checkNotNull(
            NativeConnectRequestBridge.cancelPendingFlutterConnectIfUserSessionEpochCurrent(olderEpoch),
        )
        assertEquals(olderEpoch, postedStop.supersededUserSessionEpoch)
        assertTrue(ServiceLifecycleOwnership.isTerminalStopEpochCurrent(postedStop.terminalSessionEpoch))

        val newerEpoch = checkNotNull(
            ServiceLifecycleOwnership.admitExplicitUserSession(explicitStartLease = null) { },
        )
        assertEquals(
            "the Connect which supersedes a posted Stop must own that terminal generation",
            postedStop.terminalSessionEpoch,
            newerEpoch,
        )
        assertTrue(ServiceLifecycleOwnership.isUserSessionEpochCurrent(newerEpoch))

        var stalePostedStopRan = false
        assertFalse(
            "the stale posted Stop cannot persist or dispatch after a newer Connect wins",
            ServiceLifecycleOwnership.runIfTerminalStopEpochCurrent(postedStop.terminalSessionEpoch) {
                stalePostedStopRan = true
            },
        )
        assertFalse(stalePostedStopRan)
        assertEquals(
            "a delayed old admission abort cannot acquire a new terminal claim",
            null,
            NativeConnectRequestBridge.cancelPendingFlutterConnectIfUserSessionEpochCurrent(olderEpoch),
        )
        assertTrue("the newer Connect remains current after both stale continuations", ServiceLifecycleOwnership.isUserSessionEpochCurrent(newerEpoch))
    }

    @Test
    fun `KR-048 stale terminal Stop races quietly discard MainActivity foreground dispatch`() {
        val source = File("src/main/kotlin/app/marten/client/MainActivity.kt").readText()
        val start = source.indexOf("private fun startService0()")
        val end = source.indexOf("\n    private suspend fun prepare", start)
        assertTrue("MainActivity.startService0 must remain present", start >= 0 && end > start)
        val startService = source.substring(start, end)

        val exactEpoch = startService.indexOf("val requestedSessionEpoch = pendingStartSessionEpoch")
        val missingEpoch = startService.indexOf("if (requestedSessionEpoch == null)", exactEpoch)
        val missingEpochReturn = startService.indexOf("return", missingEpoch)
        val epochGate = startService.indexOf(
            "ServiceLifecycleOwnership.runIfUserSessionEpochCurrent(requestedSessionEpoch)",
        )
        val durableStop = startService.indexOf("if (!Settings.startedByUser)", epochGate)
        val durableStopLog = startService.indexOf(
            "discarding Android service dispatch after durable user intent stopped",
            durableStop,
        )
        val durableStopReturn = startService.indexOf("return@runIfUserSessionEpochCurrent", durableStopLog)
        val foregroundDispatch = startService.indexOf("ContextCompat.startForegroundService", durableStopReturn)
        val staleDispatch = startService.indexOf("if (!epochWasCurrent || !serviceDispatched)", foregroundDispatch)
        val staleDispatchLog = startService.indexOf(
            "discarding Android service dispatch superseded by terminal Stop",
            staleDispatch,
        )

        assertTrue(
            "MainActivity must retain the exact admitted epoch and reject a missing epoch before any asynchronous dispatch",
            exactEpoch >= 0 && missingEpoch > exactEpoch && missingEpochReturn > missingEpoch,
        )
        assertTrue(
            "a durable terminal Stop or stale user-session epoch must quietly skip foreground dispatch inside the exact epoch gate",
            epochGate > missingEpochReturn && durableStop > epochGate && durableStopLog > durableStop &&
                durableStopReturn > durableStopLog && foregroundDispatch > durableStopReturn &&
                staleDispatch > foregroundDispatch && staleDispatchLog > staleDispatch,
        )
        assertFalse(
            "expected terminal Stop races are control flow, never check/error/throw failures",
            startService.contains("check(") || startService.contains("error(") || startService.contains("throw "),
        )
    }

    @Test
    fun `EventHandler acknowledgement protocol uses process-owned status authoritative satisfaction and exact host completion`() {
        val source = File("src/main/kotlin/app/marten/client/EventHandler.kt").readText()
        val acknowledgements = source.substring(
            source.indexOf("connectRequestAcksChannel = MethodChannel"),
            source.indexOf("statusChannel!!.setStreamHandler"),
        )

        val claim = acknowledgements.indexOf("\"claim\" ->")
        val satisfied = acknowledgements.indexOf("\"ack_satisfied\" ->", claim)
        val cancelClaim = acknowledgements.indexOf("\"cancel_claim\" ->", satisfied)
        assertTrue("the native handoff protocol must expose an explicit exact claim", claim >= 0)
        assertTrue("an already-connected Flutter state must ask native to resolve its exact ack_satisfied request", satisfied > claim)
        assertTrue("unused exact leases must have an explicit cancellation path", cancelClaim > satisfied)
        assertTrue(acknowledgements.contains("NativeConnectRequestBridge.claimFlutterConnect(it.toLong())"))
        assertTrue(acknowledgements.contains("NativeConnectRequestBridge.resolveSatisfiedFlutterConnect("))
        assertTrue(acknowledgements.contains("platformStatus = BoxService.currentPlatformStatus()"))
        assertFalse("EventHandler must not let Dart directly acknowledge a retained handoff", acknowledgements.contains("NativeConnectRequestBridge.acknowledgeSatisfiedFlutterConnect("))
        assertTrue(acknowledgements.contains("NativeConnectRequestBridge.completeFlutterConnectClaim(startLease.toLong())"))
        assertTrue("all acknowledgement operations must extract the caller-provided exact id/lease", acknowledgements.contains("get(\"handoffId\")") && acknowledgements.contains("get(\"startLease\")"))

        val statusStart = source.indexOf("statusChannel!!.setStreamHandler")
        val alertsStart = source.indexOf("alertsChannel!!.setStreamHandler", statusStart)
        val statusHandler = source.substring(statusStart, alertsStart)
        assertTrue("the status EventChannel must subscribe to the process-owned BoxService state", statusHandler.contains("BoxService.observePlatformStatus(statusObserver!!)"))
        assertTrue("the status EventChannel must remove its process-owned observer on replacement or cancellation", statusHandler.contains("BoxService::removePlatformStatusObserver"))
        assertFalse("the status EventChannel must not read a MainActivity-bound service status", statusHandler.contains("MainActivity.instance.serviceStatus"))

        val acknowledgeStart = source.indexOf("fun acknowledgeSatisfiedFlutterConnect(handoffId: Long): Boolean")
        val resolveStart = source.indexOf("fun resolveSatisfiedFlutterConnect(handoffId: Long, platformStatus: Status)")
        val acknowledge = source.substring(acknowledgeStart, resolveStart)
        val acknowledged = acknowledge.indexOf("if (acknowledged)")
        val completion = acknowledge.indexOf("VpnPermissionActivity.completeSatisfiedFlutterHandoff(", acknowledged)
        assertTrue("a successful authoritative satisfied acknowledgement must close its exact permission host", acknowledged >= 0 && completion > acknowledged)
        assertTrue(acknowledge.contains("source = request.source"))
        assertTrue(acknowledge.contains("requestId = request.requestId"))
    }

    private fun flushMainLooper() {
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun dispatchPendingAgainForTest() {
        NativeConnectRequestBridge.javaClass.getDeclaredMethod("dispatchPendingOnMainThread").let { method ->
            method.isAccessible = true
            method.invoke(NativeConnectRequestBridge)
        }
        flushMainLooper()
    }

    private fun resetBridgeState() {
        NativeConnectRequestBridge.cancelPendingFlutterConnect()
        NativeConnectRequestBridge.onCancel()
        NativeConnectRequestBridge.onEngineDetached()
        @Suppress("UNCHECKED_CAST")
        val pending = NativeConnectRequestBridge.javaClass.getDeclaredField("pending").let { field ->
            field.isAccessible = true
            field.get(NativeConnectRequestBridge) as ArrayDeque<NativeConnectRequest>
        }
        pending.clear()
    }

    private fun resetTerminalSessionForTest() {
        ServiceLifecycleOwnership.runExplicitUserSession(explicitStartLease = null) {}
    }

    private class RecordingSink(
        private val throwOnSuccess: Boolean = false,
    ) : EventChannel.EventSink {
        val handoffIds = mutableListOf<Long>()

        override fun success(event: Any?) {
            val payload = event as Map<*, *>
            handoffIds += (payload["handoffId"] as Number).toLong()
            if (throwOnSuccess) throw IllegalStateException("EventChannel listener detached")
        }

        override fun error(code: String, message: String?, details: Any?) = Unit

        override fun endOfStream() = Unit
    }
}
