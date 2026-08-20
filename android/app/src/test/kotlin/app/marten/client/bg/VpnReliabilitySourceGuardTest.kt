package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnReliabilitySourceGuardTest {
    @Test
    fun `probe waits cancellably for Android to publish the active VPN before GET`() {
        val source = sourceFile("VpnDataPlaneProbe.kt")
        val run = functionBody(source, "run")
        val wait = functionBody(source, "awaitActiveVpnNetwork")

        val awaitNetwork = run.indexOf("awaitActiveVpnNetwork(")
        val vpnSocket = run.indexOf("val openedSocket = Socket()")
        val failClosed = run.indexOf("failure(\"caller_not_routed_to_vpn\")")
        assertTrue("GET must wait for the VPN Network published after core STARTED", awaitNetwork >= 0)
        assertTrue("GET must create an ordinary Socket() after VPN route is active", vpnSocket > awaitNetwork)
        assertFalse(
            "startup probe must stay on the app UID path, not explicit VPN socket factory",
            run.contains("vpnNetwork.socketFactory.createSocket()"),
        )
        assertTrue("timeout must remain fail-closed after the bounded wait", failClosed > awaitNetwork)
        assertTrue(
            "startup proof should publish the active VPN network handle",
            run.contains("vpnNetworkHandle = vpnNetwork.networkHandle"),
        )

        assertTrue(wait.contains("SystemClock.elapsedRealtime() + ACTIVE_VPN_WAIT_TIMEOUT_MS"))
        assertTrue(wait.contains("delay(ACTIVE_VPN_WAIT_POLL_MS)"))
        assertTrue("the wait must cooperate with cancellation", wait.contains("currentCoroutineContext().ensureActive()"))
        assertTrue("only a VPN Network can satisfy the wait", wait.contains("hasTransport(NetworkCapabilities.TRANSPORT_VPN)"))
        assertTrue("a bounded wait must not silently use Wi-Fi", wait.contains("return null"))
    }

    @Test
    fun `autoDetectInterfaceControl binds unconnected physical socket then protects fd and fails closed on any underlying failure`() {
        val source = sourceFile("VPNService.kt")
        val sourceWithoutLineComments = source
            .lines()
            .filter { !it.trimStart().startsWith("//") }
            .joinToString("\n")
        val autoDetect = functionBody(source, "autoDetectInterfaceControl")
        val protect = functionBody(source, "protectSocket")

        assertTrue(
            "autoDetectInterfaceControl should use the observed default Network or fail closed",
            autoDetect.contains("DefaultNetworkMonitor.defaultNetwork") &&
                autoDetect.contains("error(\"android: missing underlying network for socket\")"),
        )
        assertTrue(
            "autoDetectInterfaceControl should adopt a raw fd before binding to the physical Network",
            autoDetect.contains("val descriptor = ParcelFileDescriptor.adoptFd(fd)"),
        )
        assertTrue(
            "autoDetectInterfaceControl should bind the descriptor's fd before protection",
            autoDetect.contains("underlyingNetwork.bindSocket(descriptor.fileDescriptor)"),
        )
        assertTrue(
            "autoDetectInterfaceControl should protect the same fd after successful bind",
            autoDetect.contains("protectSocket(fd)"),
        )
        assertTrue(
            "autoDetectInterfaceControl should close socket binding even on success",
            autoDetect.contains("descriptor.detachFd()"),
        )
        assertTrue(
            "protection failure must still be an explicit check",
            protect.contains("if (!protect(fd))"),
        )
        assertTrue(
            "protection failure should be explicit",
            protect.contains("error(\"android: failed to protect socket from VPN\")"),
        )
        assertTrue(
            "bind failure should be fail-closed and surfaced",
            autoDetect.contains("throw IllegalStateException(") &&
                autoDetect.contains("failed to bind socket to underlying network"),
        )
        assertTrue(
            "bind must occur before protection to avoid socket rewrite races",
            autoDetect.indexOf("underlyingNetwork.bindSocket(descriptor.fileDescriptor)") <
                autoDetect.indexOf("protectSocket(fd)"),
        )
        assertFalse(
            "autoDetectInterfaceControl must not perform default-network refresh",
            sourceWithoutLineComments.contains("DefaultNetworkMonitor.refresh"),
        )
        assertFalse(
            "autoDetectInterfaceControl must not use legacy fail-open bindSocketToDefaultNetwork path",
            sourceWithoutLineComments.contains("bindSocketToDefaultNetwork"),
        )
    }

    @Test
    fun `openTun declares current default network and runtime network updates stay ownership-checked and deduped`() {
        val source = sourceFile("VPNService.kt")
        val openTun = functionBody(source, "openTun")
        val updateUnderlying = functionBody(source, "updateUnderlyingNetwork")
        val publishUnderlying = functionBody(source, "publishUnderlyingNetwork")

        val defaultNetworkCapture = openTun.indexOf("val initialUnderlyingNetwork = DefaultNetworkMonitor.defaultNetwork")
        val setInitial = openTun.indexOf("builder.setUnderlyingNetworks(arrayOf(initialUnderlyingNetwork))")
        val establish = openTun.indexOf("val pfd = builder.establish()")
        val publishAfterEstablish = openTun.indexOf("publishUnderlyingNetwork(")
        assertTrue(
            "openTun should read the current default network before building the VPN",
            defaultNetworkCapture >= 0 &&
                setInitial > defaultNetworkCapture &&
                establish > setInitial,
        )
        assertTrue(
            "openTun should reconcile initial declaration after establishing descriptor",
            publishAfterEstablish > establish,
        )

        assertTrue(
            "runtime update should forward callback network into publish helper",
            updateUnderlying.contains("publishUnderlyingNetwork(network, requireActiveVpn = true)"),
        )

        val dedupeGuard = publishUnderlying.indexOf("underlyingNetworkDeclarationInitialized &&")
        val dedupeEquals = publishUnderlying.indexOf("declaredUnderlyingNetwork == network")
        val ownershipCheck = publishUnderlying.indexOf("if (requireActiveVpn && !BoxService.isOwnVpnActive(this))")
        val acceptedCall = publishUnderlying.indexOf("runCatching {")
        val setUnderlying = publishUnderlying.indexOf("setUnderlyingNetworks(network?.let { arrayOf(it) } ?: emptyArray())")
        val markSet = publishUnderlying.indexOf("declaredUnderlyingNetwork = network")
        val monitorSnapshot = publishUnderlying.indexOf("DefaultNetworkMonitor.defaultNetwork")
        assertTrue("runtime update must check ownership before changing underlying network", ownershipCheck > dedupeEquals)
        assertTrue("runtime update should call setUnderlyingNetworks only after ownership check", setUnderlying > ownershipCheck)
        assertTrue(
            "accepted result should be required before state is advanced",
            acceptedCall < setUnderlying && markSet > setUnderlying,
        )
        assertTrue("runtime update should dedupe unchanged physical network callbacks", dedupeGuard >= 0 && dedupeEquals > dedupeGuard)
        assertTrue("runtime update should resolve current snapshot under the same lock", monitorSnapshot >= 0 && setUnderlying > monitorSnapshot)
    }

    @Test
    fun `socket-level probe path uses single protected Socket() connect without fallback bind or retry`() {
        val source = sourceFile("VpnDataPlaneProbe.kt")
        val run = functionBody(source, "run")
        val runWithoutLineComments = run
            .lines()
            .filter { !it.trimStart().startsWith("//") }
            .joinToString("\n")

        val firstConnect = run.indexOf("openedSocket.connect(")
        val secondConnect = if (firstConnect >= 0) run.indexOf("openedSocket.connect(", firstConnect + 1) else -1
        assertTrue("probe should explicitly open a normal Socket before connect", run.contains("Socket().apply {"))
        assertTrue("probe should include one and only one direct connect attempt", firstConnect >= 0 && secondConnect == -1)
        assertFalse(
            "per-socket path should never bind Socket() to default or tracked Network callbacks",
            runWithoutLineComments.contains("bindSocket("),
        )
        assertFalse(
            "per-socket path should not use ParcelFileDescriptor",
            runWithoutLineComments.contains("ParcelFileDescriptor"),
        )
        assertFalse(
            "per-socket path should not refresh default-network transport as part of probe connect",
            runWithoutLineComments.contains("defaultNetwork") && runWithoutLineComments.contains("refresh"),
        )
    }

    @Test
    fun `onUnderlyingNetworkObserved callback only forwards physical network updates into VPNService`() {
        val service = sourceFile("BoxService.kt")
        val monitorStart = service.indexOf("DefaultNetworkMonitor.start(serviceOwnerToken, ::onUnderlyingNetworkObserved)")
        val onObserved = functionBody(service, "onUnderlyingNetworkObserved")

        assertTrue(
            "BoxService must subscribe monitor through the onUnderlyingNetworkObserved callback",
            monitorStart >= 0,
        )
        assertTrue(
            "onUnderlyingNetworkObserved should be the monitor callback body",
            onObserved.contains("service.updateUnderlyingNetwork(network)") &&
                onObserved.contains("if (service is VPNService)")
        )
        assertFalse(
            "observed callback should not directly bypass VPNService ownership checks",
            onObserved.contains("setUnderlyingNetworks("),
        )
    }

    @Test
    fun `default network monitor and listener should not expose public refresh paths`() {
        val monitor = sourceFile("DefaultNetworkMonitor.kt")
        val listener = sourceFile("DefaultNetworkListener.kt")
        val monitorWithoutLineComments = monitor
            .lines()
            .filter { !it.trimStart().startsWith("//") }
            .joinToString("\n")
        val listenerWithoutLineComments = listener
            .lines()
            .filter { !it.trimStart().startsWith("//") }
            .joinToString("\n")

        assertFalse(
            "default network monitor should not provide refresh API",
            monitorWithoutLineComments.contains("fun refresh(") ||
                monitorWithoutLineComments.contains("suspend fun refresh("),
        )
        assertFalse(
            "default network listener should not define NetworkMessage.Refresh type",
            listenerWithoutLineComments.contains("NetworkMessage.Refresh"),
        )
        assertFalse(
            "default network listener should not expose public network-refresh helper",
            listenerWithoutLineComments.contains("fun refresh(") ||
                listenerWithoutLineComments.contains("suspend fun refresh("),
        )
    }

    @Test
    fun `Application onCreate sets Seq context before registering LocalResolver and does it before receiver bootstrap`() {
        val source = mainSourceFile("Application.kt")
        val onCreate = functionBody(source, "onCreate")
        val seqContext = onCreate.indexOf("Seq.setContext(this)")
        val registerTransport = onCreate.indexOf("Libbox.registerLocalDNSTransport(LocalResolver)")
        val registerReceiver = onCreate.indexOf("registerReceiver(AppChangeReceiver()")
        assertTrue("Application must initialize native sequence context first", seqContext >= 0)
        assertTrue("LocalResolver must be registered as local DNS transport", registerTransport >= 0)
        assertTrue("Seq.setContext must run before LocalResolver registration", seqContext < registerTransport)
        assertTrue("LocalResolver must be registered before registerReceiver bootstrap", registerTransport < registerReceiver)
    }

    @Test
    fun `LocalResolver queries always use physical DefaultNetworkMonitor require network and normal Android cache policy`() {
        val source = sourceFile("LocalResolver.kt")
        val exchange = functionBody(source, "exchange")
        val lookup = functionBody(source, "lookup")

        assertTrue(
            "exchange() must read the physical default network through DefaultNetworkMonitor.require",
            exchange.contains("DefaultNetworkMonitor.require()"),
        )
        assertTrue(
            "lookup() must read the physical default network through DefaultNetworkMonitor.require",
            lookup.contains("DefaultNetworkMonitor.require()"),
        )
        assertTrue(
            "rawQuery should execute against the physical default network",
            exchange.indexOf("defaultNetwork") <
                exchange.indexOf("DnsResolver.getInstance().rawQuery"),
        )
        assertTrue(
            "lookup query should execute against the physical default network",
            lookup.indexOf("defaultNetwork") <
                lookup.lastIndexOf("DnsResolver.getInstance().query("),
        )
        assertTrue(
            "lookup path must preserve Android normal DNS cache policy",
            lookup.contains("DnsResolver.FLAG_EMPTY"),
        )
        assertTrue(
            "exchange path must preserve Android normal DNS cache policy",
            exchange.contains("DnsResolver.FLAG_EMPTY"),
        )
        assertFalse(
            "DNS policy must not force no-retry behavior",
            source.contains("FLAG_NO_RETRY"),
        )
    }

    @Test
    fun `full startup proof resolves bootstrap on underlying Network then requires numeric VPN GET and VPN DNS`() {
        val source = sourceFile("VpnDataPlaneProbe.kt")
        val run = functionBody(source, "run")
        val vpnDns = functionBody(source, "verifyVpnDns")
        val resolveNetworkDnsAsync = functionBody(source, "resolveNetworkDnsAsync")

        val activeVpn = run.indexOf("awaitActiveVpnNetwork(")
        val underlyingNetwork = run.indexOf("val resolverNetwork = underlyingNetwork")
        val underlyingDns = run.indexOf("val underlyingDns = resolveNetworkDns(")
        val vpnSocket = run.indexOf("val openedSocket = Socket().apply {")
        val numericConnect = run.indexOf("connect(InetSocketAddress(probeAddress, PROBE_PORT), connectTimeoutMs)")
        val rawGet = run.indexOf("append(\"GET \$PROBE_PATH?marten=\$nonce HTTP/1.1")
        val hostHeader = run.indexOf("append(\"Host: \$PROBE_HOST")
        val responseCode = run.indexOf("val statusCode = statusLine.split")
        val expectedStatus = run.indexOf("if (statusCode != EXPECTED_STATUS_CODE)")
        val vpnDnsCall = run.indexOf("val dnsFailure = verifyVpnDns(vpnNetwork, dnsTimeoutMs)")
        val dnsFailureGate = run.indexOf("if (dnsFailure != null)", vpnDnsCall)
        val responseHeaders = run.indexOf("readResponseHeaders(BufferedInputStream(openedSocket.getInputStream()))")
        val healthyResult = run.indexOf("healthy = true")

        assertTrue("the probe must use the current active VPN Network", activeVpn >= 0)
        assertTrue("the pre-VPN default Network is required solely for DNS bootstrap", underlyingNetwork > activeVpn)
        assertTrue("the probe hostname must resolve through the underlying Network", underlyingDns > underlyingNetwork)
        assertTrue("the numeric probe must use the ordinary Socket() path after bootstrap", vpnSocket > underlyingDns)
        assertTrue("the VPN socket must connect to the resolved numeric address", numericConnect > vpnSocket)
        assertTrue("startup proof must write an HTTP GET over that socket", rawGet > numericConnect)
        assertTrue("the numeric request must preserve the expected Host header", hostHeader > rawGet)
        assertTrue("startup proof must read the HTTP response over the VPN socket", responseHeaders > hostHeader)
        assertTrue("startup proof must inspect the GET response", responseCode > responseHeaders)
        assertTrue("only HTTP 204 may satisfy startup", expectedStatus > responseCode)
        assertTrue("a successful numeric GET must be followed by a VPN-bound DNS proof", vpnDnsCall > expectedStatus)
        assertTrue("DNS proof failure must return before a healthy result", dnsFailureGate > vpnDnsCall && healthyResult > dnsFailureGate)

        assertTrue("DNS proof must include a bounded timeout before resolving through VPN", vpnDns.contains("boundedTimeoutMs"))
        assertTrue(
            "DNS proof must bind to the same VPN Network as the numeric GET",
            vpnDns.contains("resolveNetworkDns(vpnNetwork") && vpnDns.contains("bypassCache = true"),
        )
        assertTrue("DNS proof must delegate API 29+ to Android's no-cache resolver", resolveNetworkDnsAsync.contains("DnsResolver.getInstance().query("))
        assertTrue(
            "DNS proof must use the active VPN Network",
            vpnDns.contains("resolveNetworkDns(vpnNetwork") && resolveNetworkDnsAsync.contains("network,"),
        )
        assertTrue("DNS proof must query an A record through the TUN", resolveNetworkDnsAsync.contains("DnsResolver.TYPE_A"))
        assertTrue("DNS proof must bypass positive and negative cache state", resolveNetworkDnsAsync.contains("DnsResolver.FLAG_NO_CACHE_LOOKUP or DnsResolver.FLAG_NO_CACHE_STORE"))
        assertTrue("VPN DNS proof must have a bounded timeout", vpnDns.contains("VPN_DNS_TIMEOUT_MS") && resolveNetworkDnsAsync.contains("timeoutMs"))
        assertTrue("VPN DNS cancellation must cancel the Android resolver query", resolveNetworkDnsAsync.contains("cancellationSignal.cancel()"))

        assertFalse("bootstrap DNS must not be attempted through the unready VPN route", run.contains("vpnNetwork.getAllByName"))
        assertFalse("a URL connection would resolve its hostname through the VPN and reintroduce bootstrap deadlock", run.contains("openConnection"))
        assertFalse("the selected-route bootstrap must use a numeric socket, not URL DNS", run.contains("java.net.URL"))
        assertFalse("VALIDATED is not a substitute for the dedicated startup GET", source.contains("NET_CAPABILITY_VALIDATED"))
        assertFalse("initial startup must not have an Android validated fallback", source.contains("validatedFallback"))
        assertFalse("initial startup must not publish an android_validated proof", source.contains("android_validated"))

        val record = sourceFile("BoxService.kt")
        assertTrue(
            "Android proof must publish an active-network handle and replay-check it on record",
            run.contains("vpnNetworkHandle = vpnNetwork.networkHandle") &&
                record.contains("proofVpnNetworkHandle != vpnDataPlaneProbe.currentVpnNetworkHandle()") &&
                record.contains("it.vpnNetworkHandle == vpnDataPlaneProbe.currentVpnNetworkHandle()"),
        )
    }

    @Test
    fun `numeric GET or post-GET VPN DNS failures remain fail closed`() {
        val source = sourceFile("VpnDataPlaneProbe.kt")
        val run = functionBody(source, "run")
        val vpnDns = functionBody(source, "verifyVpnDns")
        val resolveNetworkDnsAsync = functionBody(source, "resolveNetworkDnsAsync")

        assertTrue("missing underlying DNS bootstrap must fail the proof", run.contains("failure(\"underlying_network_unavailable\")"))
        assertTrue(
            "failed underlying DNS must fail the proof",
            run.contains("underlyingDns.failure") && run.contains("\"underlying_dns_unavailable\""),
        )
        assertTrue("a malformed raw HTTP response must fail the proof", run.contains("failure(\"malformed_http_response\")"))
        assertTrue("a non-204 response must fail the proof", run.contains("return@withContext failure(\"unexpected_http_status\")"))
        assertTrue(
            "VPN DNS failure must fail the entire proof",
            run.contains("return@withContext failure(\"vpn_dns_\$dnsFailure\")"),
        )
        assertTrue(
            "DNS helper failures must stay distinct from a successful numeric GET",
            vpnDns.contains("result.failure") && resolveNetworkDnsAsync.contains("withTimeoutOrNull(timeoutMs)"),
        )
        assertTrue("GET timeout must fail the proof", run.contains("catch (_: SocketTimeoutException)") && run.contains("failure(\"timeout\")"))
        assertTrue(
            "GET IO failure must fail the proof via dedicated IOException branch",
            run.contains("catch (error: IOException)") && run.contains("failure(category)"),
        )
        assertTrue(
            "unexpected GET/body failure must fail the proof",
            run.contains("catch (error: Exception)") && run.contains("failure(category)"),
        )
        assertTrue(
            "raw socket must close on every result",
            run.contains("finally") && run.contains("socket.getAndSet(null)?.close()"),
        )
        assertTrue(
            "socket close ownership must be disposed through completion handler",
            run.contains("currentCoroutineContext().job.invokeOnCompletion") && run.contains("cancellationHandle.dispose()"),
        )
        assertTrue(
            "cancellation must rethrow through explicit CancellationException branch",
            run.contains("catch (error: CancellationException)") && run.contains("throw error"),
        )
        assertFalse(
            "failed GET category must not be remapped to a dedicated fallback token",
            run.contains("failure(\"fallback\")") || run.contains("failure(\"android_validated\")"),
        )
    }

    @Test
    fun `failed dedicated GET cannot race a stale start into Started`() {
        val service = sourceFile("BoxService.kt")
        val routeCheck = functionBody(service, "checkVpnDataPlaneRoute")
        val acknowledgement = functionBody(service, "acknowledgeVerifiedRouteFromFlutter")
        val retry = functionBody(service, "verifyNativeStartupRoute")
        val recoveryPolicy = sourceFile("ServiceRecoveryPolicy.kt")

        val probe = routeCheck.indexOf("val result = vpnDataPlaneProbe.run(")
        val probeNetwork = routeCheck.indexOf("DefaultNetworkMonitor.defaultNetwork", probe)
        val staleGeneration = routeCheck.indexOf("proofStartGeneration != currentStartGeneration()")
        val rejectStale = routeCheck.indexOf("invalidateVpnDataPlaneProof(\"stale probe generation\")")
        assertTrue("the probe input network must be the pre-start default network snapshot", probe >= 0 && probeNetwork > probe)
        assertTrue("the probe result must be generation-checked", staleGeneration > probeNetwork)
        assertTrue("stale proof must be rejected before it can be recorded", rejectStale > staleGeneration)

        val nativeRetry = acknowledgement.indexOf("val verified = verifyNativeStartupRoute(")
        val sameGeneration = acknowledgement.indexOf("generation = generation", nativeRetry)
        val failClosed = acknowledgement.indexOf("if (!verified) return false", nativeRetry)
        val started = acknowledgement.indexOf("markCoreRuntimeStarted", failClosed)
        assertTrue("acknowledgement must use the bounded native VPN-proof retry", nativeRetry >= 0)
        assertTrue("acknowledgement retry must stay in the same lifecycle generation", sameGeneration > nativeRetry)
        assertTrue("failed retry must return before Started can be published", failClosed > sameGeneration && started > failClosed)
        assertFalse("a failed GET must not admit Started directly", acknowledgement.contains("Status.Started"))
        assertFalse("acknowledgement must not terminally stop a transient route failure", acknowledgement.contains("stopAndAlert(Alert.StartService"))
        assertFalse("acknowledgement must not retain terminal route-stop control", acknowledgement.contains("stopServiceOnRouteFailure"))

        assertTrue("native retry must repeatedly perform the real VPN data-plane check", retry.contains("while (SystemClock.elapsedRealtime() < deadline)"))
        assertTrue(
            "native retry may only use the authoritative VPN data-plane request",
            retry.indexOf("checkSelectedRoute(") > -1 &&
                retry.indexOf("routeClient", retry.indexOf("checkSelectedRoute(")) > retry.indexOf("checkSelectedRoute(") &&
                retry.indexOf("requireVpnDataPlane = true", retry.indexOf("routeClient", retry.indexOf("checkSelectedRoute("))) > retry.indexOf("routeClient", retry.indexOf("checkSelectedRoute(")),
        )
        assertTrue("native retry must use bounded retry delay", retry.contains("delay(minOf(STARTUP_ROUTE_VERIFY_RETRY_MS, remainingMs))"))
        val exhausted = retry.indexOf("native startup route failed")
        val retryGate = retry.indexOf("shouldRetryFailedNativeStartup(", exhausted)
        val recoveryRequest = retry.indexOf("requestCoreRecovery(", retryGate)
        assertTrue("retry exhaustion must inspect whether this is still the current active session", retryGate > exhausted)
        assertTrue("only an active current failed route is handed to recovery", recoveryRequest > retryGate)
        assertTrue("stale or inactive route failure must be discarded", retry.contains("stale or inactive generation"))
        assertFalse("retry exhaustion must not terminally stop the service", retry.contains("stopAndAlert(Alert.StartService"))
        assertTrue(
            "retry eligibility must require both active user intent and current generation",
            recoveryPolicy.contains("): Boolean = !routeVerified && userSessionActive && startStillCurrent"),
        )
    }

    @Test
    fun `flutter startup timeout reserves route and Android proof grace`() {
        val service = sourceFile("BoxService.kt")
        val timeout = functionBody(service, "unverifiedStartupRecoveryTimeoutMs")

        assertTrue(service.contains("private const val STARTUP_ROUTE_VERIFY_TIMEOUT_MS = 12_000L"))
        assertTrue(service.contains("private const val CORE_UNVERIFIED_STARTUP_RECOVERY_GRACE_MS = 45_000L"))
        assertTrue(timeout.contains("return verificationTimeout + CORE_UNVERIFIED_STARTUP_RECOVERY_GRACE_MS"))
        assertTrue(
            "the independent data-plane bootstrap must allow a slow TURNcoat route",
            sourceFile("VpnDataPlaneProbe.kt").contains("private const val DEFAULT_PROBE_TIMEOUT_MS = 30_000L"),
        )
    }

    @Test
    fun `recovery cleanup retires framework VPN before strict quiescence while stop flow stays unchanged`() {
        val service = sourceFile("BoxService.kt")
        val cleanup = functionBody(service, "closeMobileCoreAndAwaitTunQuiescence")

        val admissionSealLock = cleanup.indexOf("synchronized(fileDescriptorLock)")
        val admissionSeal = cleanup.indexOf("tunDescriptorAdmissionClosed = true", admissionSealLock)
        val sharedDeadline = Regex(
            "val\\s+releaseDeadlineElapsedRealtimeMs\\s*=\\s*SystemClock\\.elapsedRealtime\\s*\\(\\s*\\)\\s*\\+\\s*TUN_RELEASE_TIMEOUT_MS",
        ).find(cleanup)?.range?.first ?: -1
        val descriptorClose = cleanup.indexOf("closeTunFileDescriptor()", sharedDeadline)
        val close = cleanup.indexOf("MobileCoreCloser.closeBlocking(reason)")
        val nonStoppingGate = cleanup.indexOf("!serviceStopping")
        val retirement = cleanup.indexOf("retirePlatformVpnSessionAfterCoreStop", nonStoppingGate)
        val retirementDeadline = cleanup.indexOf("releaseDeadlineElapsedRealtimeMs", retirement + 1)
        val quiescence = Regex(
            "awaitTunRuntimeQuiescence\\s*\\(\\s*reason\\s*,\\s*serviceStopping\\s*,\\s*releaseDeadlineElapsedRealtimeMs\\s*,?\\s*\\)",
        ).find(cleanup)?.range?.first ?: -1
        assertTrue("cleanup must seal TUN admission before its shared release deadline", admissionSealLock >= 0 && admissionSeal > admissionSealLock)
        assertTrue(
            "the shared deadline must begin before descriptor/native close so a stuck close adds no new grace interval",
            sharedDeadline > admissionSeal && descriptorClose > sharedDeadline && close > descriptorClose,
        )
        assertTrue("native close must finish before retirement", nonStoppingGate > close)
        assertTrue(
            "framework retirement must receive the shared release deadline before strict quiescence",
            retirement > sharedDeadline && retirementDeadline in (retirement + 1 until quiescence),
        )
        assertTrue(
            "recovery must retire framework VPN before waiting for strict quiescence",
            quiescence > retirement,
        )
        assertTrue(
            "cleanup must not create a second release deadline",
            Regex(
                "SystemClock\\.elapsedRealtime\\s*\\(\\s*\\)\\s*\\+\\s*TUN_RELEASE_TIMEOUT_MS",
            ).findAll(cleanup).count() == 1,
        )

        val stop = functionBody(service, "stopService")
        assertTrue("terminal service stop retains its existing tolerant cleanup mode", stop.contains("\"service stop\""))
        assertTrue("terminal service stop must still be marked serviceStopping", stop.contains("serviceStopping = true"))
    }

    private fun sourceFile(name: String): String {
        val source = File("src/main/kotlin/app/marten/client/bg/$name")
        check(source.isFile) { "missing production source ${source.path}" }
        return source.readText()
    }

    private fun mainSourceFile(name: String): String {
        val source = File("src/main/kotlin/app/marten/client/$name")
        check(source.isFile) { "missing production source ${source.path}" }
        return source.readText()
    }

    private fun functionBody(source: String, name: String): String {
        val declaration = source.indexOf("fun $name")
        check(declaration >= 0) { "function $name not found" }
        val start = source.indexOf('{', declaration)
        check(start >= 0) { "function $name has no body" }
        var depth = 0
        for (index in start until source.length) {
            when (source[index]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return source.substring(start, index + 1)
            }
        }
        error("function $name body does not close")
    }
}
