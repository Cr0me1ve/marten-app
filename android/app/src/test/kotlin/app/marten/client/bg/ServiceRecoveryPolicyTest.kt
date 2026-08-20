package app.marten.client.bg

import app.marten.client.constant.Status
import app.marten.core.api.v2.hcore.CoreStates
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class ServiceRecoveryPolicyTest {
    @Test
    fun `get service status is owned by the live BoxService instance rather than Activity caches`() {
        val boxService = sourceFile("BoxService.kt")
        val platformStatus = sourceSection(
            boxService,
            "fun currentPlatformStatus(): Status",
            "fun isExternalVpnActive",
        )
        assertTrue(platformStatus.contains("activeInstance?.status?.value ?: Status.Stopped"))

        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val getServiceStatus = sourceSection(
            methodHandler,
            "Trigger.GetServiceStatus.method -> {",
            "Trigger.TryBeginFlutterRestart.method -> {",
        )
        assertTrue(getServiceStatus.contains("result.success(BoxService.currentPlatformStatus().name)"))
        assertFalse(getServiceStatus.contains("MainActivity.instance"))
        assertFalse(getServiceStatus.contains("boundServiceStatus"))
        assertFalse(getServiceStatus.contains("serviceStatus.value"))
    }

    @Test
    fun `MethodHandler exposes tls_ping trigger and routes to PhysicalTlsProbe`() {
        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")

        assertTrue(methodHandler.contains("TLSPing(\"tls_ping\")"))

        val tlsPingSection = sourceSection(
            methodHandler,
            "Trigger.TLSPing.method -> {",
            "Trigger.GetStableDeviceID.method -> {",
        )

        assertTrue(tlsPingSection.contains("success(PhysicalTlsProbe.measure("))
        assertTrue(tlsPingSection.contains("val args = call.arguments as? Map<*, *>"))
        assertTrue(tlsPingSection.contains("val host = args[\"host\"] as? String"))
        assertTrue(tlsPingSection.contains("val port = (args[\"port\"] as? Number)"))
        assertTrue(tlsPingSection.contains("val serverName = args[\"serverName\"] as? String"))
        assertTrue(tlsPingSection.contains("val allowUntrusted = args[\"allowUntrusted\"] as? Boolean ?: false"))
        assertTrue(tlsPingSection.contains("val timeoutMs = (args[\"timeoutMs\"] as? Number)"))
    }

    @Test
    fun `PhysicalTlsProbe prefers active VPN network then physical fallback`() {
        val source = sourceFile("PhysicalTlsProbe.kt")
        val selectSection = sourceSection(
            source,
            "private suspend fun selectProbeNetwork(): Network {",
            "private fun String.isIpLiteral(): Boolean",
        )

        val hasActiveVpnSelection =
            selectSection.contains("val activeNetwork = Application.connectivity.activeNetwork") &&
                selectSection.contains("val activeCapabilities = activeNetwork?.let(Application.connectivity::getNetworkCapabilities)") &&
                selectSection.contains("activeCapabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true") &&
                selectSection.contains("return activeNetwork")
        assertTrue(
            "PhysicalTlsProbe must check active network transport VPN and return it before physical fallback",
            hasActiveVpnSelection,
        )

        val activeNetworkLog = selectSection.indexOf("TLS probe route=active_vpn")
        val physicalNetworkLog = selectSection.indexOf("TLS probe route=physical")
        assertTrue(activeNetworkLog >= 0)
        assertTrue(physicalNetworkLog >= 0)
        assertTrue(activeNetworkLog < physicalNetworkLog)
        assertTrue(selectSection.contains("return DefaultNetworkMonitor.require()"))
    }

    @Test
    fun `PhysicalTlsProbe enforces bounded timeout and waits for TLS handshake with SNI`() {
        val source = sourceFile("PhysicalTlsProbe.kt")
        val measureSection = sourceSection(
            source,
            "withTimeout(boundedTimeoutMs) {",
            "private suspend fun selectProbeNetwork(): Network {",
        )

        assertTrue(source.contains("private const val MIN_TIMEOUT_MS ="))
        assertTrue(source.contains("private const val MAX_TIMEOUT_MS ="))
        assertTrue(source.contains("val boundedTimeoutMs = timeoutMs.coerceIn(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)"))
        assertTrue(source.contains("withTimeout(boundedTimeoutMs)"))
        assertTrue(measureSection.contains("val network = selectProbeNetwork()"))
        assertTrue(measureSection.contains("val addresses = network.getAllByName(endpointHost)"))
        assertTrue(measureSection.contains("val plainSocket = network.socketFactory.createSocket()"))
        assertTrue(source.contains("val tlsFactory = if (allowUntrusted) {"))
        assertTrue(source.contains("realityFallbackTlsFactory"))
        assertTrue(source.contains("} else {"))
        assertTrue(source.contains("SSLSocketFactory.getDefault() as SSLSocketFactory"))
        assertTrue(source.contains("val tlsSocket = (tlsFactory.createSocket("))
        assertTrue(source.contains("plainSocket,"))
        assertTrue(source.contains("peerName,"))
        assertTrue(source.contains("true"))
        assertTrue(source.contains("val peerName = serverName?.trim()"))
        assertTrue(source.contains("parameters.endpointIdentificationAlgorithm = if (allowUntrusted) null else \"HTTPS\""))
        assertTrue(source.contains("if (!peerName.isIpLiteral())"))
        assertTrue(source.contains("parameters.serverNames = listOf(SNIHostName(peerName))"))
        assertTrue(source.contains("it.startHandshake()"))
        assertTrue(
            "healthy result should be returned only after handshake",
            source.indexOf("return@withTimeout") > source.indexOf("it.startHandshake()"),
        )
    }

    @Test
    fun `platform release waits for cleanup before polling VPN and accepts a release after 750ms`() = runBlocking {
        var nowNanos = 0L
        val events = mutableListOf<String>()
        val cleanupTimeouts = mutableListOf<Long>()

        val state = awaitPlatformStopRelease(
            coreStopped = true,
            timeoutMs = 5_000L,
            isQuiescentBoundOwner = { false },
            awaitCleanupAfterStop = { timeoutMs ->
                events += "cleanup"
                cleanupTimeouts += timeoutMs
                nowNanos += 200_000_000L
                true
            },
            isOwnVpnActive = {
                events += "vpn"
                nowNanos < 900_000_000L
            },
            pollIntervalMs = 250L,
            nowNanos = { nowNanos },
            pause = { delayMs ->
                events += "pause:$delayMs"
                nowNanos += delayMs * 1_000_000L
            },
        )

        assertEquals(listOf(5_000L), cleanupTimeouts)
        assertEquals("cleanup", events.first())
        assertTrue(events.indexOf("vpn") > events.indexOf("cleanup"))
        assertTrue(nowNanos >= 900_000_000L)
        assertTrue(state.cleanupFinished)
        assertTrue(state.vpnReleased)
    }

    @Test
    fun `quiescent bound owner skips cleanup and returns once VPN is absent`() = runBlocking {
        var cleanupCalls = 0

        val state = awaitPlatformStopRelease(
            coreStopped = true,
            timeoutMs = 5_000L,
            isQuiescentBoundOwner = { true },
            awaitCleanupAfterStop = {
                cleanupCalls++
                false
            },
            isOwnVpnActive = { false },
            pollIntervalMs = 50L,
        )

        assertEquals(0, cleanupCalls)
        assertTrue(state.quiescentBoundOwner)
        assertTrue(state.cleanupFinished)
        assertTrue(state.vpnReleased)
    }

    @Test
    fun `platform release shares one deadline across cleanup and VPN polling`() = runBlocking {
        var nowNanos = 0L
        val pauses = mutableListOf<Long>()
        val cleanupTimeouts = mutableListOf<Long>()

        val state = awaitPlatformStopRelease(
            coreStopped = true,
            timeoutMs = 5_000L,
            isQuiescentBoundOwner = { false },
            awaitCleanupAfterStop = { timeoutMs ->
                cleanupTimeouts += timeoutMs
                nowNanos += 4_200_000_000L
                true
            },
            isOwnVpnActive = { true },
            pollIntervalMs = 1_000L,
            nowNanos = { nowNanos },
            pause = { delayMs ->
                pauses += delayMs
                nowNanos += delayMs * 1_000_000L
            },
        )

        assertEquals(listOf(5_000L), cleanupTimeouts)
        assertEquals(listOf(800L), pauses)
        assertEquals(5_000_000_000L, nowNanos)
        assertTrue(state.cleanupFinished)
        assertFalse(state.vpnReleased)
    }

    @Test
    fun `completed core cleanup remains a successful user disconnect while framework VPN release is deferred`() {
        assertTrue(isPlatformStopSafeForUser(coreStopped = true, cleanupFinished = true))
        assertFalse(isPlatformStopSafeForUser(coreStopped = false, cleanupFinished = true))
        assertFalse(isPlatformStopSafeForUser(coreStopped = true, cleanupFinished = false))

        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val stoppedRelease = sourceSection(
            methodHandler,
            "private suspend fun awaitStoppedPlatformServiceRelease",
            "private fun stableDeviceId",
        )
        val strictRelease = stoppedRelease.indexOf("isPlatformStopReleaseComplete(")
        val userSafeRelease = stoppedRelease.indexOf("isPlatformStopSafeForUser(")
        val deferredLog = stoppedRelease.indexOf("framework VPN release is deferred")
        val userSuccess = stoppedRelease.indexOf("return true", userSafeRelease)

        assertTrue(strictRelease >= 0)
        assertTrue(userSafeRelease > strictRelease)
        assertTrue(deferredLog > userSafeRelease)
        assertTrue("a service-only framework delay must not surface as a user disconnect failure", userSuccess > deferredLog)
    }

    @Test
    fun `bound stopped service is considered safe only without an active stop operation`() {
        assertEquals(true, isQuiescentBoundServiceState(Status.Stopped, coreShutdownCompleted = true, stopOperationActive = false))
        assertEquals(false, isQuiescentBoundServiceState(Status.Stopped, coreShutdownCompleted = true, stopOperationActive = true))
        assertEquals(false, isQuiescentBoundServiceState(Status.Started, coreShutdownCompleted = true, stopOperationActive = false))

        val quiescentOwner = isQuiescentBoundServiceState(
            status = Status.Stopped,
            coreShutdownCompleted = true,
            stopOperationActive = false,
        )
        assertTrue(quiescentOwner)
    }

    @Test
    fun `completed retained stop job is quiescent but active stop job is not`() {
        val completedRetainedJob = isQuiescentBoundServiceState(
            status = Status.Stopped,
            coreShutdownCompleted = true,
            stopOperationActive = false,
        )
        val activeRetainedJob = isQuiescentBoundServiceState(
            status = Status.Stopped,
            coreShutdownCompleted = true,
            stopOperationActive = true,
        )

        assertTrue(completedRetainedJob)
        assertFalse(activeRetainedJob)

        val boxServiceSource = sourceFile("BoxService.kt")
        val quiescentOwner = sourceSection(
            boxServiceSource,
            "fun isQuiescentBoundOwner(ownerToken: Long)",
            "\n        }\n\n\n    }",
        )
        assertTrue(quiescentOwner.contains("stopOperationActive = instance.serviceStopJob?.isActive == true"))
        assertFalse(quiescentOwner.contains("stopOperationActive = instance.serviceStopJob != null"))
    }

    @Test
    fun `platform stop uses bound-owner quiescence to skip extra cleanup wait when already stopped`() {
        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val stoppedRelease = sourceSection(
            methodHandler,
            "private suspend fun awaitStoppedPlatformServiceRelease",
            "private fun stableDeviceId",
        )

        assertTrue(stoppedRelease.contains("val releaseState = awaitPlatformStopRelease("))
        assertTrue(stoppedRelease.contains("isQuiescentBoundOwner = { BoxService.isQuiescentBoundOwner(ownerToken) }"))
        assertTrue(stoppedRelease.contains("ServiceLifecycleOwnership.awaitCleanupAfterStop(ownerToken, timeoutMs)"))
        assertTrue(stoppedRelease.contains("releaseState.quiescentBoundOwner"))
        assertTrue(stoppedRelease.contains("bound Android service is already quiescent; skipping destroy-only cleanup wait"))
    }

    @Test
    fun `manual stop captures stop owner token from active BoxService instance`() {
        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val stopSection = sourceSection(
            methodHandler,
            "Trigger.Stop.method -> {",
            "Trigger.MarkStarted.method -> {",
        )
        val stoppedOwnerLine = stopSection.lineSequence().firstOrNull { it.contains("val stoppedOwnerToken") }

        assertNotNull("manual stop should declare stoppedOwnerToken from active service owner lookup", stoppedOwnerLine)
        assertFalse(
            "manual stop should not use global lifecycle token",
            stopSection.contains("ServiceLifecycleOwnership.currentToken()"),
        )
        assertTrue(
            "manual stop should use BoxService-owned token source",
            stoppedOwnerLine!!.contains("BoxService"),
        )
    }

    @Test
    fun `platform release stays in the ordinary app process without a cold-reset helper`() {
        val manifest = sourceAt("src/main/AndroidManifest.xml")
        val lifecycleSources = listOf(
            manifest,
            sourceAt("src/main/kotlin/app/marten/client/MainActivity.kt"),
            sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt"),
            sourceFile("BoxService.kt"),
        )

        assertTrue(manifest.contains("android:name=\".MainActivity\""))
        lifecycleSources.forEach { source ->
            assertFalse(source.contains("DisconnectRestartActivity"))
            assertFalse(source.contains("DisconnectProcessRestart"))
            assertFalse(source.contains("Process.killProcess"))
            assertFalse(source.contains("exitProcess("))
        }

        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val stoppedRelease = sourceSection(
            methodHandler,
            "private suspend fun awaitStoppedPlatformServiceRelease",
            "private fun stableDeviceId",
        )
        assertFalse(stoppedRelease.contains("shouldResetProcessAfterPlatformStop"))
        assertFalse(stoppedRelease.contains("startActivity("))
        assertFalse(stoppedRelease.contains("recreate("))
    }

    @Test
    fun `absent stop owner token is treated as already stopped cleanup-safe`() = runBlocking {
        assertTrue(ServiceLifecycleOwnership.awaitCleanupAfterStop(0L, timeoutMs = 20L))
    }

    @Test
    fun `owner-known TUN checks ignore foreign global interfaces but preserve own generation barriers`() {
        assertTrue(
            isOwnedTunRuntimeQuiescent(
                descriptorValid = false,
                ownVpnActive = false,
                ownershipKnown = true,
                globalCandidateCount = 2,
            ),
        )
        assertTrue(
            isOwnedTunReleaseCompleteForCleanup(
                descriptorValid = false,
                ownVpnActive = false,
                ownershipKnown = true,
                globalCandidateCount = 2,
                serviceStopping = false,
            ),
        )
        assertFalse(
            "own vpn ownership blocks re-entry unless replacement is explicitly allowed",
            isOwnedTunRuntimeQuiescent(
                descriptorValid = false,
                ownVpnActive = true,
                ownershipKnown = true,
                globalCandidateCount = 2,
                allowPlatformVpnReplacement = false,
            ),
        )
        assertTrue(
            "explicit user-start replacement should allow re-entry even if ownership is still active",
            isOwnedTunRuntimeQuiescent(
                descriptorValid = false,
                ownVpnActive = true,
                ownershipKnown = true,
                globalCandidateCount = 2,
                allowPlatformVpnReplacement = true,
            ),
        )
        assertFalse(isOwnedTunRuntimeQuiescent(true, false, true, 0))
        assertFalse(isOwnedTunRuntimeQuiescent(false, true, true, 0))
        assertFalse(
            isOwnedTunReleaseCompleteForCleanup(
                descriptorValid = false,
                ownVpnActive = true,
                ownershipKnown = true,
                globalCandidateCount = 0,
                serviceStopping = false,
            ),
        )

        assertFalse(isOwnedTunRuntimeQuiescent(false, false, false, 1))
        assertFalse(
            isOwnedTunReleaseCompleteForCleanup(
                descriptorValid = false,
                ownVpnActive = false,
                ownershipKnown = false,
                globalCandidateCount = 1,
                serviceStopping = false,
            ),
        )
    }

    @Test
    fun `Started accepts exactly one Marten-owned TUN and keeps pre-S fallback conservative`() {
        assertTrue(
            isOwnedTunRuntimeHealthy(
                descriptorValid = true,
                ownVpnActive = true,
                ownershipKnown = true,
                interfaceUp = true,
                ownedCandidateCount = 1,
                globalCandidateCount = 2,
            ),
        )
        assertFalse(isOwnedTunRuntimeHealthy(true, true, true, true, 0, 1))
        assertFalse(isOwnedTunRuntimeHealthy(true, true, true, true, 2, 2))
        assertFalse(isOwnedTunRuntimeHealthy(false, true, true, true, 1, 1))
        assertFalse(isOwnedTunRuntimeHealthy(true, false, true, true, 1, 1))
        assertFalse(isOwnedTunRuntimeHealthy(true, true, true, false, 1, 1))
        assertFalse(isOwnedTunRuntimeHealthy(true, true, false, true, 1, 2))
    }

    @Test
    fun `VPN ownership loss requires an external revoke or two confirmed own misses`() {
        assertTrue(
            shouldStopForLostVpnOwnership(
                externalVpnActive = true,
                authorizationRevoked = false,
                ownershipKnown = true,
                ownVpnActive = true,
                consecutiveOwnVpnMisses = 0,
                requiredMisses = 2,
            ),
        )
        assertTrue(
            shouldStopForLostVpnOwnership(
                externalVpnActive = false,
                authorizationRevoked = true,
                ownershipKnown = true,
                ownVpnActive = true,
                consecutiveOwnVpnMisses = 0,
                requiredMisses = 2,
            ),
        )
        assertFalse(
            shouldStopForLostVpnOwnership(false, false, true, false, consecutiveOwnVpnMisses = 1, requiredMisses = 2),
        )
        assertTrue(
            shouldStopForLostVpnOwnership(false, false, true, false, consecutiveOwnVpnMisses = 2, requiredMisses = 2),
        )
        assertFalse(
            shouldStopForLostVpnOwnership(false, false, false, false, consecutiveOwnVpnMisses = 5, requiredMisses = 2),
        )
    }

    @Test
    fun `TUN handoff keeps established framework descriptor as VPN lifetime owner`() {
        // ParcelFileDescriptor is final and backed by Android framework state, so this
        // resource-free JVM suite checks the production handoff contract directly.
        val vpnSource = sourceFile("VPNService.kt")
        val openTun = sourceSection(vpnSource, "override fun openTun", "override fun writePlatformLog")
        val builderDescriptor = openTun.indexOf("val pfd = builder.establish()")
        val retainFrameworkDescriptor = openTun.indexOf("service.replaceTunFileDescriptor(pfd)")
        val nativeDescriptor = openTun.indexOf("val nativeFd = pfd.fd")
        val returnNativeDescriptor = openTun.indexOf("return nativeFd")

        assertTrue(builderDescriptor >= 0)
        assertTrue(retainFrameworkDescriptor > builderDescriptor)
        assertTrue(nativeDescriptor > retainFrameworkDescriptor)
        assertTrue(returnNativeDescriptor > nativeDescriptor)
        assertFalse(openTun.contains("ParcelFileDescriptor.dup("))
        assertFalse(openTun.contains("detachFd()"))

        val rejection = openTun.indexOf("if (!service.replaceTunFileDescriptor(pfd))")
        val rejectedReturn = openTun.indexOf("error(\"android: VPN service stopped while creating TUN\")", rejection)
        assertTrue(rejection >= 0)
        assertTrue(rejectedReturn > rejection)

        val serviceSource = sourceFile("BoxService.kt")
        val stopService = sourceSection(serviceSource, "private fun stopService", "fun replaceTunFileDescriptor")
        val stopAdmissionLock = stopService.indexOf("synchronized(fileDescriptorLock)")
        val stopAdmissionSeal = stopService.indexOf("tunDescriptorAdmissionClosed = true")
        val stopVisibleTransition = stopService.indexOf("status.value = Status.Stopping")
        assertTrue(stopAdmissionLock >= 0)
        assertTrue(stopAdmissionSeal > stopAdmissionLock)
        assertTrue(stopVisibleTransition > stopAdmissionSeal)

        val replaceDescriptor = sourceSection(serviceSource, "fun replaceTunFileDescriptor", "private fun closeTunFileDescriptor")
        val replacementAdmissionLock = replaceDescriptor.indexOf("synchronized(fileDescriptorLock)")
        val replacementAdmissionSeal = replaceDescriptor.indexOf("!tunDescriptorAdmissionClosed")
        val frameworkDescriptorStored = replaceDescriptor.indexOf("fileDescriptor = pfd")
        val rejectedFrameworkClose = replaceDescriptor.indexOf("runCatching { pfd.close() }")
        val rejectedNativeCloseRequest = replaceDescriptor.indexOf("MobileCoreCloser.closeAsync(\"late tun after service stop\")")
        val rejectedReturnFalse = replaceDescriptor.indexOf("return false")
        assertTrue(replacementAdmissionLock >= 0)
        assertTrue(replacementAdmissionSeal > replacementAdmissionLock)
        assertTrue(frameworkDescriptorStored > replacementAdmissionSeal)
        assertTrue(rejectedFrameworkClose >= 0)
        assertTrue(rejectedNativeCloseRequest > rejectedFrameworkClose)
        assertTrue(rejectedReturnFalse > rejectedNativeCloseRequest)

        val onDestroy = sourceSection(serviceSource, "fun onDestroy", "fun onRevoke")
        val destroyAdmissionLock = onDestroy.indexOf("synchronized(fileDescriptorLock)")
        val destroyAdmissionSeal = onDestroy.indexOf("tunDescriptorAdmissionClosed = true")
        val destroyFrameworkClose = onDestroy.indexOf("closeTunFileDescriptor()")
        assertTrue(destroyAdmissionLock >= 0)
        assertTrue(destroyAdmissionSeal > destroyAdmissionLock)
        assertTrue(destroyFrameworkClose > destroyAdmissionSeal)
    }

    @Test
    fun `authoritative platform stop awaits core acknowledgement before releasing framework service exactly once`() = runBlocking {
        val calls = mutableListOf<String>()
        var coreStopCalls = 0
        var frameworkReleaseCalls = 0
        val coreStopAcknowledged = CompletableDeferred<Boolean>()

        val stop = async(start = CoroutineStart.UNDISPATCHED) {
            requestAuthoritativePlatformStop(
            requestCoreStop = {
                coreStopCalls++
                calls += "core-stop"
            },
            awaitCoreStop = {
                calls += "core-stop-ack"
                coreStopAcknowledged.await()
            },
            releaseFrameworkService = {
                frameworkReleaseCalls++
                calls += "framework-release"
            },
            )
        }

        assertEquals(listOf("core-stop", "core-stop-ack"), calls)
        assertEquals(0, frameworkReleaseCalls)

        coreStopAcknowledged.complete(true)
        assertTrue(stop.await())

        assertEquals(listOf("core-stop", "core-stop-ack", "framework-release"), calls)
        assertEquals(1, coreStopCalls)
        assertEquals(1, frameworkReleaseCalls)
    }

    @Test
    fun `manual active stop awaits its pinned owner before framework release and passes computed core result to release barrier`() {
        val methodHandler = sourceAt("src/main/kotlin/app/marten/client/MethodHandler.kt")
        val stopSection = sourceSection(
            methodHandler,
            "Trigger.Stop.method -> {",
            "Trigger.MarkStarted.method -> {",
        )
        val activeStop = stopSection.indexOf("val coreStopped = requestAuthoritativePlatformStop(")
        val request = stopSection.substring(activeStop)
        val await = request.indexOf("BoxService.awaitAuthoritativeStop(")
        val release = request.indexOf("releaseFrameworkService = { releaseStoppedPlatformService(mainActivity) }")
        val releaseBarrier = request.indexOf("val platformReleased = awaitStoppedPlatformServiceRelease(")
        val coreStoppedArgument = request.indexOf("coreStopped = coreStopped,", releaseBarrier)

        assertTrue(activeStop >= 0)
        assertTrue("active stop must await the exact BoxService owner", await >= 0)
        assertTrue("framework release must stay inside the two-phase stop protocol", release > await)
        assertTrue("release barrier must run after framework release", releaseBarrier > release)
        assertTrue(
            "release barrier must receive the core result already computed by the authoritative wait",
            coreStoppedArgument > releaseBarrier,
        )
    }

    @Test
    fun `mobile core lifecycle coordinator never overlaps foreground setup and close`() = runBlocking {
        val coordinator = MobileCoreLifecycleCoordinator()
        val setupEntered = CompletableDeferred<Unit>()
        val releaseSetup = CompletableDeferred<Unit>()
        val closeEntered = CompletableDeferred<Unit>()
        val operations = mutableListOf<String>()

        val setup = async(start = CoroutineStart.UNDISPATCHED) {
            coordinator.run {
                operations += "setup-entered"
                setupEntered.complete(Unit)
                releaseSetup.await()
                operations += "setup-finished"
            }
        }
        setupEntered.await()

        val close = async(start = CoroutineStart.UNDISPATCHED) {
            coordinator.run {
                operations += "close-entered"
                closeEntered.complete(Unit)
            }
        }

        assertFalse(closeEntered.isCompleted)

        releaseSetup.complete(Unit)
        setup.await()
        close.await()

        assertEquals(
            listOf("setup-entered", "setup-finished", "close-entered"),
            operations,
        )
    }

    @Test
    fun `late tun callback is accepted only by current active service owner`() {
        assertTrue(shouldAcceptTunFileDescriptor(true, true, Status.Starting))
        assertTrue(shouldAcceptTunFileDescriptor(true, true, Status.Started))

        assertFalse(shouldAcceptTunFileDescriptor(false, true, Status.Started))
        assertFalse(shouldAcceptTunFileDescriptor(true, false, Status.Started))
        assertFalse(shouldAcceptTunFileDescriptor(true, true, Status.Stopping))
        assertFalse(shouldAcceptTunFileDescriptor(true, true, Status.Stopped))
    }

    @Test
    fun `selects up interface when newer higher-index tun is up`() {
        val interfaces = listOf(
            TunInterfaceState("tun26", 26, up = false, mtu = 1400, addressCount = 0),
            TunInterfaceState("tun27", 27, up = true, mtu = 1500, addressCount = 1),
        )
        val selected = selectTunRuntimeInterface(interfaces)
        assertEquals(27, selected?.index)
        assertEquals(true, selected?.up)
    }

    @Test
    fun `selects highest index when multiple tun interfaces are up`() {
        val interfaces = listOf(
            TunInterfaceState("tun20", 20, up = true, mtu = 1400, addressCount = 1),
            TunInterfaceState("tun23", 23, up = true, mtu = 1400, addressCount = 2),
            TunInterfaceState("tun21", 21, up = false, mtu = 1400, addressCount = 3),
        )
        val selected = selectTunRuntimeInterface(interfaces)
        assertEquals(23, selected?.index)
        assertEquals(true, selected?.up)
    }

    @Test
    fun `selects highest index snapshot when no interfaces are up`() {
        val interfaces = listOf(
            TunInterfaceState("tun20", 20, up = false, mtu = 1400, addressCount = 1),
            TunInterfaceState("tun21", 21, up = false, mtu = 1500, addressCount = 0),
            TunInterfaceState("tun19", 19, up = false, mtu = 1300, addressCount = 2),
        )
        val selected = selectTunRuntimeInterface(interfaces)
        assertEquals(21, selected?.index)
        assertEquals(false, selected?.up)
    }

    @Test
    fun `returns null when no interfaces exist`() {
        assertNull(selectTunRuntimeInterface(emptyList()))
    }

    @Test
    fun `route recovery retry delay is constant 2 seconds`() {
        assertEquals(2_000L, coreRecoveryRetryDelayMs(-1))
        assertEquals(2_000L, coreRecoveryRetryDelayMs(0))
        assertEquals(2_000L, coreRecoveryRetryDelayMs(1))
        assertEquals(2_000L, coreRecoveryRetryDelayMs(2))
        assertEquals(2_000L, coreRecoveryRetryDelayMs(4))
        assertEquals(2_000L, coreRecoveryRetryDelayMs(20))
    }

    @Test
    fun `current route proof requires healthy current generation and active user session`() {
        assertTrue(
            isCurrentNetworkRouteProof(
                proofGeneration = 12L,
                currentGeneration = 12L,
                routeHealthy = true,
                userSessionActive = true,
            ),
        )
    }

    @Test
    fun `terminal cleanup can complete when descriptor is released even with lingering TUN candidates`() {
        assertTrue(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 0, serviceStopping = true))
        assertTrue(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 1, serviceStopping = true))
        assertTrue(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 2, serviceStopping = true))
        assertTrue(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = -1, serviceStopping = true))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = true, candidateCount = 0, serviceStopping = true))
    }

    @Test
    fun `reconnect cleanup still requires strict zero-candidate TUN quiescence`() {
        assertTrue(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 0, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 1, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 2, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 3, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = -1, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = true, candidateCount = 0, serviceStopping = false))
    }

    @Test
    fun `reconnect and recovery cleanup must stay non-terminal`() {
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 1, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 2, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 3, serviceStopping = false))
        assertFalse(isTunReleaseCompleteForCleanup(descriptorValid = true, candidateCount = 0, serviceStopping = false))
        assertTrue(isTunReleaseCompleteForCleanup(descriptorValid = false, candidateCount = 1, serviceStopping = true))
    }

    @Test
    fun `core cleanup escalates unless native close and TUN quiescence both complete`() {
        assertFalse(requiresCoreCleanupEscalation(closeCompleted = true, tunQuiescent = true))
        assertTrue(requiresCoreCleanupEscalation(closeCompleted = false, tunQuiescent = true))
        assertTrue(requiresCoreCleanupEscalation(closeCompleted = true, tunQuiescent = false))
        assertTrue(requiresCoreCleanupEscalation(closeCompleted = false, tunQuiescent = false))
    }

    @Test
    fun `system and process recovery restore only an active configured user session`() {
        assertTrue(
            shouldRestoreUserSessionFromServiceCommand(
                restartedBySystem = true,
                processRecoveryRequested = false,
                connectFromNotification = false,
                userSessionActive = true,
                activeConfigAvailable = true,
            ),
        )
        assertTrue(
            shouldRestoreUserSessionFromServiceCommand(
                restartedBySystem = false,
                processRecoveryRequested = true,
                connectFromNotification = false,
                userSessionActive = true,
                activeConfigAvailable = true,
            ),
        )

        assertFalse(
            shouldRestoreUserSessionFromServiceCommand(
                restartedBySystem = false,
                processRecoveryRequested = false,
                connectFromNotification = false,
                userSessionActive = true,
                activeConfigAvailable = true,
            ),
        )
        assertFalse(
            shouldRestoreUserSessionFromServiceCommand(
                restartedBySystem = true,
                processRecoveryRequested = false,
                connectFromNotification = true,
                userSessionActive = true,
                activeConfigAvailable = true,
            ),
        )
        assertFalse(
            shouldRestoreUserSessionFromServiceCommand(
                restartedBySystem = false,
                processRecoveryRequested = true,
                connectFromNotification = false,
                userSessionActive = false,
                activeConfigAvailable = true,
            ),
        )
        assertFalse(
            shouldRestoreUserSessionFromServiceCommand(
                restartedBySystem = true,
                processRecoveryRequested = false,
                connectFromNotification = false,
                userSessionActive = true,
                activeConfigAvailable = false,
            ),
        )
    }

    @Test
    fun `TUN is quiescent only after descriptor and every candidate are gone`() {
        assertTrue(isTunRuntimeQuiescent(descriptorValid = false, candidateCount = 0))
        assertFalse(isTunRuntimeQuiescent(descriptorValid = true, candidateCount = 0))
        assertFalse(isTunRuntimeQuiescent(descriptorValid = false, candidateCount = 1))
        assertFalse(isTunRuntimeQuiescent(descriptorValid = false, candidateCount = -1))
        assertFalse(isTunRuntimeQuiescent(descriptorValid = true, candidateCount = 2))
    }

    @Test
    fun `TUN is healthy only with one up candidate and a valid descriptor`() {
        assertTrue(isTunRuntimeHealthy(descriptorValid = true, interfaceUp = true, candidateCount = 1))
        assertFalse(isTunRuntimeHealthy(descriptorValid = false, interfaceUp = true, candidateCount = 1))
        assertFalse(isTunRuntimeHealthy(descriptorValid = true, interfaceUp = false, candidateCount = 1))
        assertFalse(isTunRuntimeHealthy(descriptorValid = true, interfaceUp = true, candidateCount = 0))
        assertFalse(isTunRuntimeHealthy(descriptorValid = true, interfaceUp = true, candidateCount = -1))
        assertFalse(isTunRuntimeHealthy(descriptorValid = true, interfaceUp = true, candidateCount = 2))
    }

    @Test
    fun `route recovery stays in place below its bounded failure threshold`() {
        assertFalse(shouldEscalateRouteRecovery(failedChecks = 0, threshold = 3))
        assertFalse(shouldEscalateRouteRecovery(failedChecks = 2, threshold = 3))
    }

    @Test
    fun `ICMP uses the same bounded fallback at and after three consecutive failures`() {
        assertTrue(shouldEscalateRouteRecovery(failedChecks = 3, threshold = 3))
        assertTrue(shouldEscalateRouteRecovery(failedChecks = 4, threshold = 3))
    }

    @Test
    fun `live turncoat carrier requires both real backend RX and active sessions`() {
        assertTrue(isLiveTurncoatCarrier(rxProofCount = 1, activeSessions = 1))
        assertTrue(isLiveTurncoatCarrier(rxProofCount = 3, activeSessions = 10))
    }

    @Test
    fun `health-only or inactive turncoat evidence does not mask a dead backend`() {
        assertFalse(isLiveTurncoatCarrier(rxProofCount = 1, activeSessions = 0))
        assertFalse(isLiveTurncoatCarrier(rxProofCount = 0, activeSessions = 10))
        assertFalse(isLiveTurncoatCarrier(rxProofCount = 0, activeSessions = 0))
    }

    @Test
    fun `current route proof rejects stale failed or inactive evidence`() {
        assertFalse(
            isCurrentNetworkRouteProof(
                proofGeneration = 11L,
                currentGeneration = 12L,
                routeHealthy = true,
                userSessionActive = true,
            ),
        )
        assertFalse(
            isCurrentNetworkRouteProof(
                proofGeneration = 12L,
                currentGeneration = 12L,
                routeHealthy = false,
                userSessionActive = true,
            ),
        )
        assertFalse(
            isCurrentNetworkRouteProof(
                proofGeneration = 12L,
                currentGeneration = 12L,
                routeHealthy = true,
                userSessionActive = false,
            ),
        )
    }

    @Test
    fun `service cleanup survives cancellation of its caller`() = runBlocking {
        val jobReference = CompletableDeferred<Job>()
        var cleanupFinished = false
        val caller = launch {
            runNonCancellableServiceCleanup {
                jobReference.await().cancel()
                yield()
                cleanupFinished = true
            }
        }
        jobReference.complete(caller)

        caller.join()

        assertTrue(caller.isCancelled)
        assertTrue(cleanupFinished)
    }

    @Test
    fun `core runtime is healthy only when started`() {
        assertEquals(true, isCoreRuntimeHealthy(CoreStates.STARTED))
        assertEquals(false, isCoreRuntimeHealthy(CoreStates.STOPPED))
        assertEquals(false, isCoreRuntimeHealthy(CoreStates.STARTING))
        assertEquals(false, isCoreRuntimeHealthy(CoreStates.STOPPING))
        assertEquals(false, isCoreRuntimeHealthy(null))
    }

    @Test
    fun `stalled native recovery fails closed only after its bounded timeout while the user session remains active`() {
        assertTrue(
            shouldFailStalledCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = true,
                coreState = CoreStates.STOPPED,
                elapsedMs = 1_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertTrue(
            shouldFailStalledCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = true,
                coreState = CoreStates.STARTING,
                elapsedMs = 5_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertFalse(
            shouldFailStalledCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = true,
                coreState = CoreStates.STARTED,
                elapsedMs = 5_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertFalse(
            shouldFailStalledCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = true,
                coreState = CoreStates.STOPPING,
                elapsedMs = 999L,
                timeoutMs = 1_000L,
            ),
        )
        assertFalse(
            shouldFailStalledCoreRecovery(
                recoveryInProgress = false,
                userSessionActive = true,
                coreState = CoreStates.STOPPED,
                elapsedMs = 5_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertFalse(
            shouldFailStalledCoreRecovery(
                recoveryInProgress = true,
                userSessionActive = false,
                coreState = CoreStates.STOPPED,
                elapsedMs = 5_000L,
                timeoutMs = 1_000L,
            ),
        )
    }

    @Test
    fun `network reset never executes under lifecycle ownership and fails into core recovery`() {
        val recovery = sourceSection(
            sourceFile("BoxService.kt"),
            "private suspend fun recoverNetworkRoute(",
            "private fun requestRouteWatchdogCheck",
        )
        val reset = recovery.indexOf("Mobile.resetNetwork")
        val failure = recovery.indexOf("if (resetResult.isFailure)", reset)
        val recoveryRequest = recovery.indexOf("requestCoreRecovery(", failure)

        assertTrue("network recovery must call the native reset", reset >= 0)
        assertFalse(
            "transport reset must not monopolize the lifecycle coordinator needed by Stop/Close",
            recovery.contains("MobileCoreLifecycle.run"),
        )
        assertFalse(
            "transport reset must not hold the lifecycle lock while crossing into native code",
            recovery.substring(maxOf(0, reset - 400), reset).contains("synchronized(lifecycleLock)"),
        )
        assertTrue("a bounded native reset failure must fail closed into core recovery", failure > reset)
        assertTrue("failed reset must request recovery instead of retrying the stuck transport", recoveryRequest > failure)
    }

    @Test
    fun `failed native startup should retry only when route failed, session is active, and start is current`() {
        assertTrue(shouldRetryFailedNativeStartup(false, true, true))
        assertFalse(shouldRetryFailedNativeStartup(true, true, true))
        assertFalse(shouldRetryFailedNativeStartup(false, false, true))
        assertFalse(shouldRetryFailedNativeStartup(false, true, false))
    }

    @Test
    fun `overlapping mobile close start and blocking waiter share one native close`() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closeCalls = AtomicInteger()
        val coordinator = MobileCloseCoordinator("test-mobile-close") {
            closeCalls.incrementAndGet()
            entered.countDown()
            release.await()
        }

        assertTrue(coordinator.start())
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        assertFalse(coordinator.start())

        val waiterResult = AtomicReference<MobileCloseResult>()
        val waiter = thread {
            waiterResult.set(coordinator.closeBlocking(1_000L))
        }
        Thread.sleep(20L)
        assertTrue(waiter.isAlive)

        release.countDown()
        waiter.join(1_000L)

        assertFalse(waiter.isAlive)
        assertEquals(1, closeCalls.get())
        assertTrue(waiterResult.get().finished)
        assertEquals(null, waiterResult.get().error)
    }

    @Test
    fun `mobile close wait is bounded while the coalesced native close continues`() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closeCalls = AtomicInteger()
        val coordinator = MobileCloseCoordinator("test-mobile-close-timeout") {
            closeCalls.incrementAndGet()
            entered.countDown()
            release.await()
        }

        assertTrue(coordinator.start())
        assertTrue(entered.await(1, TimeUnit.SECONDS))

        val timedOut = coordinator.closeBlocking(10L)
        assertFalse("caller must regain control at the bounded deadline", timedOut.finished)
        assertEquals(1, closeCalls.get())
        assertFalse("a waiter must join the existing close rather than start another", coordinator.start())

        release.countDown()
        val completed = coordinator.waitForClose(1_000L)
        assertTrue(completed.finished)
        assertEquals(1, closeCalls.get())
    }

    @Test
    fun `completed mobile close error remains visible until one later successful retry clears it`() {
        val closeCalls = AtomicInteger()
        val expectedFailure = IllegalStateException("first native close failed")
        val coordinator = MobileCloseCoordinator("test-mobile-close-retained-error") {
            if (closeCalls.incrementAndGet() == 1) throw expectedFailure
        }

        val failed = coordinator.closeBlocking(1_000L)
        assertTrue("first close must finish", failed.finished)
        assertEquals(expectedFailure, failed.error)
        assertEquals(1, closeCalls.get())

        val lateWaiter = coordinator.waitForClose(1_000L)
        assertTrue("late waiter must observe completed operation", lateWaiter.finished)
        assertEquals("completed close error must not disappear with active-operation cleanup", expectedFailure, lateWaiter.error)
        assertEquals(1, closeCalls.get())

        val retried = coordinator.closeBlocking(1_000L)
        assertTrue("the next closeBlocking call must admit one new retry", retried.finished)
        assertEquals(null, retried.error)
        assertEquals(2, closeCalls.get())

        val afterSuccess = coordinator.waitForClose(1_000L)
        assertTrue(afterSuccess.finished)
        assertEquals("successful retry must clear retained completed error", null, afterSuccess.error)
        assertEquals(2, closeCalls.get())
    }

    @Test
    fun `core lifecycle work only continues for its current active session`() {
        assertTrue(shouldContinueCoreLifecycleOperation(8L, 8L, true))
        assertFalse(shouldContinueCoreLifecycleOperation(7L, 8L, true))
        assertFalse(shouldContinueCoreLifecycleOperation(8L, 8L, false))
    }

    @Test
    fun `failed native startup route retries only for the current active user session`() {
        assertTrue(
            shouldRetryFailedNativeStartup(
                routeVerified = false,
                userSessionActive = true,
                startStillCurrent = true,
            ),
        )
        assertFalse(
            shouldRetryFailedNativeStartup(
                routeVerified = false,
                userSessionActive = true,
                startStillCurrent = false,
            ),
        )
        assertFalse(
            shouldRetryFailedNativeStartup(
                routeVerified = false,
                userSessionActive = false,
                startStillCurrent = true,
            ),
        )
        assertFalse(
            shouldRetryFailedNativeStartup(
                routeVerified = true,
                userSessionActive = true,
                startStillCurrent = true,
            ),
        )

        val request = sourceSection(
            sourceFile("BoxService.kt"),
            "private fun requestCoreRecovery(",
            "private suspend fun recoverMobileCore",
        )
        assertTrue(request.contains("shouldContinueCoreLifecycleOperation("))
        assertTrue(request.contains("while (currentCoroutineContext().isActive && shouldWatchCore(generation))"))
        assertTrue(request.contains("core recovery admission remains pending"))

        val nativeProof = sourceSection(
            sourceFile("BoxService.kt"),
            "private suspend fun verifyNativeStartupRoute(",
            "fun onBind(intent: Intent)",
        )
        assertTrue(nativeProof.contains("shouldRetryFailedNativeStartup("))
        assertTrue(nativeProof.contains("requestCoreRecovery("))
        assertTrue(nativeProof.contains("discarding failed native startup route for stale or inactive generation"))
    }

    @Test
    fun `Flutter restart and native recovery leases arbitrate ownership atomically`() {
        val owner = ServiceLifecycleOwnership.acquire()
        var flutterRestartLease: Long? = null
        var nativeRecoveryAcquired = false

        try {
            flutterRestartLease = ServiceLifecycleOwnership.tryAcquireFlutterRestart()
            assertNotNull(flutterRestartLease)
            assertFalse(ServiceLifecycleOwnership.tryAcquireNativeRecovery(owner))

            ServiceLifecycleOwnership.releaseFlutterRestart(flutterRestartLease!!)
            flutterRestartLease = null

            assertTrue(ServiceLifecycleOwnership.tryAcquireNativeRecovery(owner))
            nativeRecoveryAcquired = true
            assertNull(ServiceLifecycleOwnership.tryAcquireFlutterRestart())

            ServiceLifecycleOwnership.releaseNativeRecovery(owner)
            nativeRecoveryAcquired = false

            flutterRestartLease = ServiceLifecycleOwnership.tryAcquireFlutterRestart()
            assertNotNull(flutterRestartLease)
        } finally {
            flutterRestartLease?.let(ServiceLifecycleOwnership::releaseFlutterRestart)
            if (nativeRecoveryAcquired) {
                ServiceLifecycleOwnership.releaseNativeRecovery(owner)
            }
        }
    }

    @Test
    fun `replacement owner waits for admitted predecessor cleanup without cancelling it`() = runBlocking {
        val cleanupStarted = CompletableDeferred<Unit>()
        val releaseCleanup = CompletableDeferred<Unit>()
        val cleanupFinished = CompletableDeferred<Unit>()
        val originalOwner = ServiceLifecycleOwnership.acquire()
        var cleanupRegistered = false

        try {
            cleanupRegistered = ServiceLifecycleOwnership.beginCleanup(originalOwner) {
                cleanupStarted.complete(Unit)
                releaseCleanup.await()
                cleanupFinished.complete(Unit)
            }
            assertTrue(cleanupRegistered)
            cleanupStarted.await()

            val replacementOwner = ServiceLifecycleOwnership.acquire()
            assertFalse(ServiceLifecycleOwnership.awaitPendingCleanup(replacementOwner, timeoutMs = 20L))

            releaseCleanup.complete(Unit)
            cleanupFinished.await()
            assertTrue(ServiceLifecycleOwnership.awaitPendingCleanup(replacementOwner, timeoutMs = 1_000L))
        } finally {
            releaseCleanup.complete(Unit)
            if (cleanupRegistered) {
                cleanupFinished.await()
            }
        }
    }

    @Test
    fun `manual stop waits for onDestroy cleanup registration and completion`() = runBlocking {
        val cleanupStarted = CompletableDeferred<Unit>()
        val releaseCleanup = CompletableDeferred<Unit>()
        val owner = ServiceLifecycleOwnership.acquire()
        val waiter = async(start = CoroutineStart.UNDISPATCHED) {
            ServiceLifecycleOwnership.awaitCleanupAfterStop(owner, timeoutMs = 1_000L)
        }

        try {
            yield()
            assertFalse(waiter.isCompleted)

            assertTrue(
                ServiceLifecycleOwnership.beginCleanup(owner) {
                    cleanupStarted.complete(Unit)
                    releaseCleanup.await()
                },
            )
            cleanupStarted.await()
            yield()
            assertFalse(waiter.isCompleted)

            releaseCleanup.complete(Unit)
            assertTrue(waiter.await())
        } finally {
            releaseCleanup.complete(Unit)
            waiter.await()
        }
    }

    @Test
    fun `manual stop cleanup wait times out when onDestroy never registers cleanup`() = runBlocking {
        val owner = ServiceLifecycleOwnership.acquire()

        assertFalse(ServiceLifecycleOwnership.awaitCleanupAfterStop(owner, timeoutMs = 20L))
    }

    @Test
    fun `stale owner cannot mutate a shared resource after replacement acquire`() {
        val staleOwner = ServiceLifecycleOwnership.acquire()
        val replacementOwner = ServiceLifecycleOwnership.acquire()
        var resourceOwner: Long? = null

        assertFalse(
            ServiceLifecycleOwnership.runIfCurrent(staleOwner) {
                resourceOwner = staleOwner
            },
        )
        assertNull(resourceOwner)

        assertTrue(
            ServiceLifecycleOwnership.runIfCurrent(replacementOwner) {
                resourceOwner = replacementOwner
            },
        )
        assertEquals(replacementOwner, resourceOwner)
    }

    @Test
    fun `await pending cleanup rejects an owner that became stale`() = runBlocking {
        val staleOwner = ServiceLifecycleOwnership.acquire()
        ServiceLifecycleOwnership.acquire()

        assertFalse(ServiceLifecycleOwnership.awaitPendingCleanup(staleOwner, timeoutMs = 1_000L))
    }

    @Test
    fun `startup core remains waiting until route verification before recovery request`() {
        assertEquals(false, shouldRecoverUnverifiedStartedCore(sawStartedCore = false, coreState = null, userSessionActive = true))
        assertEquals(
            false,
            shouldRecoverUnverifiedStartedCore(
                sawStartedCore = true,
                coreState = CoreStates.STARTED,
                userSessionActive = true,
            ),
        )
    }

    @Test
    fun `startup recovery is requested after unverified core later stops while session is active`() {
        assertEquals(
            true,
            shouldRecoverUnverifiedStartedCore(
                sawStartedCore = true,
                coreState = CoreStates.STOPPED,
                userSessionActive = true,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedStartedCore(
                sawStartedCore = true,
                coreState = null,
                userSessionActive = true,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedStartedCore(
                sawStartedCore = true,
                coreState = CoreStates.STOPPED,
                userSessionActive = false,
            ),
        )
    }

    @Test
    fun `never-started core recovery is requested after 5s grace when session is active`() {
        assertEquals(
            true,
            shouldRecoverNeverStartedCore(
                sawStartedCore = false,
                coreState = CoreStates.STOPPED,
                userSessionActive = true,
                elapsedMs = 5_001L,
                timeoutMs = 5_000L,
            ),
        )
        assertEquals(
            true,
            shouldRecoverNeverStartedCore(
                sawStartedCore = false,
                coreState = null,
                userSessionActive = true,
                elapsedMs = 5_001L,
                timeoutMs = 5_000L,
            ),
        )
    }

    @Test
    fun `never-started core recovery is rejected before 5s for STARTING and STARTED inactive, or with prior STARTED`() {
        assertEquals(
            false,
            shouldRecoverNeverStartedCore(
                sawStartedCore = false,
                coreState = CoreStates.STOPPED,
                userSessionActive = true,
                elapsedMs = 4_999L,
                timeoutMs = 5_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverNeverStartedCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTING,
                userSessionActive = true,
                elapsedMs = 5_001L,
                timeoutMs = 5_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverNeverStartedCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTED,
                userSessionActive = true,
                elapsedMs = 5_001L,
                timeoutMs = 5_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverNeverStartedCore(
                sawStartedCore = false,
                coreState = CoreStates.STOPPED,
                userSessionActive = false,
                elapsedMs = 5_001L,
                timeoutMs = 5_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverNeverStartedCore(
                sawStartedCore = true,
                coreState = null,
                userSessionActive = true,
                elapsedMs = 5_001L,
                timeoutMs = 5_000L,
            ),
        )
    }

    @Test
    fun `stalled starting core recovery is requested after 45s only for STARTING when session is active`() {
        assertEquals(
            true,
            shouldRecoverStalledStartingCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTING,
                userSessionActive = true,
                elapsedMs = 45_001L,
                timeoutMs = 45_000L,
            ),
        )
    }

    @Test
    fun `stalled starting core recovery is rejected before 45s or for other states inactive and started core`() {
        assertEquals(
            false,
            shouldRecoverStalledStartingCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTING,
                userSessionActive = true,
                elapsedMs = 44_999L,
                timeoutMs = 45_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverStalledStartingCore(
                sawStartedCore = false,
                coreState = CoreStates.STOPPED,
                userSessionActive = true,
                elapsedMs = 45_001L,
                timeoutMs = 45_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverStalledStartingCore(
                sawStartedCore = false,
                coreState = null,
                userSessionActive = true,
                elapsedMs = 45_001L,
                timeoutMs = 45_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverStalledStartingCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTED,
                userSessionActive = true,
                elapsedMs = 45_001L,
                timeoutMs = 45_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverStalledStartingCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTING,
                userSessionActive = false,
                elapsedMs = 45_001L,
                timeoutMs = 45_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverStalledStartingCore(
                sawStartedCore = true,
                coreState = CoreStates.STARTING,
                userSessionActive = true,
                elapsedMs = 45_001L,
                timeoutMs = 45_000L,
            ),
        )
    }

    @Test
    fun `running core recovery runs after timeout only when still started and session is active`() {
        assertEquals(
            true,
            shouldRecoverUnverifiedRunningCore(
                sawStartedCore = true,
                coreState = CoreStates.STARTED,
                userSessionActive = true,
                elapsedMs = 1_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedRunningCore(
                sawStartedCore = false,
                coreState = CoreStates.STARTED,
                userSessionActive = true,
                elapsedMs = 1_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedRunningCore(
                sawStartedCore = true,
                coreState = CoreStates.STOPPED,
                userSessionActive = true,
                elapsedMs = 1_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedRunningCore(
                sawStartedCore = true,
                coreState = CoreStates.STARTING,
                userSessionActive = true,
                elapsedMs = 1_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedRunningCore(
                sawStartedCore = true,
                coreState = CoreStates.STARTED,
                userSessionActive = false,
                elapsedMs = 1_000L,
                timeoutMs = 1_000L,
            ),
        )
        assertEquals(
            false,
            shouldRecoverUnverifiedRunningCore(
                sawStartedCore = true,
                coreState = CoreStates.STARTED,
                userSessionActive = true,
                elapsedMs = 999L,
                timeoutMs = 1_000L,
            ),
        )
    }

    private fun sourceFile(name: String): String {
        return sourceAt("src/main/kotlin/app/marten/client/bg/$name")
    }

    private fun sourceAt(path: String): String {
        val source = File(path)
        check(source.isFile) { "missing production source ${source.path}" }
        return source.readText()
    }

    private fun sourceSection(source: String, startMarker: String, endMarker: String): String {
        val start = source.indexOf(startMarker)
        check(start >= 0) { "source marker not found: $startMarker" }
        val end = source.indexOf(endMarker, start + startMarker.length)
        check(end > start) { "source end marker not found after $startMarker: $endMarker" }
        return source.substring(start, end)
    }
}
