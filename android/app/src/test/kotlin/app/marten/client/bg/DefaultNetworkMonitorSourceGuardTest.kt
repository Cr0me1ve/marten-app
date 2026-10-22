package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DefaultNetworkMonitorSourceGuardTest {
    @Test
    fun `cold application registers the LocalResolver as the native endpoint resolver`() {
        val application = File("src/main/kotlin/app/marten/client/Application.kt").readText()
        val onCreate = functionBody(application, "onCreate")

        assertTrue(
            "cold Application startup must give marten-core the same Android LocalResolver for endpoint bootstrap",
            onCreate.contains("Mobile.setEndpointResolver(LocalResolver)"),
        )
        assertTrue(
            "the existing native local-DNS transport must keep using that LocalResolver as well",
            onCreate.contains("Libbox.registerLocalDNSTransport(LocalResolver)"),
        )
    }

    @Test
    fun `LocalResolver endpoint lookup uses an exact physical socket network without endpoint logging`() {
        val resolver = sourceFile("LocalResolver.kt")
        val endpointResolver = sourceSection(resolver, "override fun resolve", "override fun raw")
        val lookup = functionBody(resolver, "resolve")
        val platformLookup = functionBody(resolver, "resolveEndpointWithDnsResolver")

        assertTrue(
            "endpoint lookup must take the current physical network from the socket-admission path",
            lookup.contains("DefaultNetworkMonitor.networkForSocket()"),
        )
        assertTrue(
            "the platform resolver must resolve through Android's exact selected Network",
            lookup.contains("resolveEndpointWithDnsResolver(physicalNetwork, domain)") &&
                lookup.contains("physicalNetwork.getAllByName(domain)") &&
                platformLookup.contains("DnsResolver.getInstance().query(") &&
                platformLookup.contains("physicalNetwork,"),
        )
        listOf(
            "bindProcessToNetwork",
            "boundNetworkForProcess",
            "Log.",
            "ConnectionDiagnostics",
        ).forEach { forbidden ->
            assertFalse(
                "endpoint resolution must not use process-wide binding or log endpoint data through $forbidden",
                endpointResolver.contains(forbidden),
            )
        }
    }

    @Test
    fun `start uses timeout-or-null for initial network wait and does not absorb cancellation`() {
        val source = sourceFile("DefaultNetworkMonitor.kt")
        val start = functionBody(source, "start(ownerToken: Long, onNetworkChanged: ((Network?) -> Unit)? = null): Boolean")

        assertTrue(
            "start() must use withTimeoutOrNull for the initial network confirmation",
            start.contains("withTimeoutOrNull(MISSING_INTERFACE_CONFIRMATION_DELAY_MS)"),
        )
        assertFalse(
            "start() must not use cancellable timeout branch to determine nullness",
            start.contains("withTimeout(MISSING_INTERFACE_CONFIRMATION_DELAY_MS)"),
        )
        assertTrue(
            "start() should still call DefaultNetworkListener.get in the initial probe",
            start.contains("DefaultNetworkListener.get()"),
        )
        assertFalse(
            "start() must not mask outer cancellation through a getOrElse branch",
            start.contains("getOrElse"),
        )
        assertFalse(
            "start() must not explicitly swallow CancellationException as recoverable timeout",
            start.contains("if (it is CancellationException) throw it"),
        )
    }

    @Test
    fun `passive startup wait is callback driven and owner scoped through arrival and Stop`() {
        val source = sourceFile("DefaultNetworkMonitor.kt")
        val wait = sourceSection(source, "internal suspend fun awaitUsableNetwork(ownerToken: Long)", "internal fun observationRevision(")
        val publish = functionBody(source, "publishIfActive(")
        val stop = functionBody(source, "stop(ownerToken: Long)")
        val service = sourceFile("BoxService.kt")
        val serviceWait = functionBody(service, "awaitStartupNetwork(userSessionEpoch: Long)")

        assertTrue("startup wait must delegate to the suspending observation helper", wait.contains("awaitStartupNetworkObservation"))
        assertTrue("a replaced/stopped monitor owner must produce no observation", wait.contains("if (activeRegistration?.ownerToken != ownerToken) null"))
        assertTrue("an already usable callback network should release startup immediately", wait.contains("DefaultNetworkListener.isUsable(defaultNetwork)"))
        assertTrue("offline waiting must suspend on the current callback deferred without an online timeout", wait.contains("networkObservationWaiter"))
        assertFalse("offline waiting must not poll or expire on a retry timer", wait.contains("delay(") || wait.contains("withTimeout"))

        val ownerCheck = publish.indexOf("if (activeRegistration === registration)")
        val captureWaiter = publish.indexOf("observationWaiter = networkObservationWaiter")
        val wakeWaiter = publish.indexOf("observationWaiter?.complete(Unit)")
        assertTrue("network callback publication must verify exact monitor registration", ownerCheck >= 0)
        assertTrue("only the admitted callback captures the currently awaited event", captureWaiter > ownerCheck)
        assertTrue("arrival wakes the captured waiter after publication", wakeWaiter > captureWaiter)

        val stopOwner = stop.indexOf("activeRegistration?.takeIf { it.ownerToken == ownerToken }")
        val invalidate = stop.indexOf("activeRegistration = null")
        val wakeOnStop = stop.indexOf("previousObservationWaiter?.complete(Unit)")
        assertTrue("Stop may retire only its exact monitor owner", stopOwner >= 0)
        assertTrue("Stop invalidates the registration before waking its pending network wait", invalidate > stopOwner && wakeOnStop > invalidate)
        assertTrue("Stop wakes the previous observation without holding the ownership lock", stop.indexOf("\n        }", invalidate) < wakeOnStop)

        val activeChecks = serviceWait.indexOf("fun current(): Boolean")
        val waitStart = serviceWait.indexOf("DefaultNetworkMonitor.awaitUsableNetwork(owner.serviceOwnerToken)")
        val finalCheck = serviceWait.indexOf("return available && current()")
        assertTrue("BoxService requires its exact current service/start/session before waiting", activeChecks >= 0 && waitStart > activeChecks)
        assertTrue("the pre/post waiter predicate pins the same active service instance", serviceWait.contains("activeInstance === owner"))
        assertTrue("the pre/post waiter predicate pins the exact Android user-session epoch", serviceWait.contains("isUserSessionEpochCurrent(userSessionEpoch)"))
        assertTrue("the pre/post waiter predicate pins the exact service start generation", serviceWait.contains("owner.shouldContinueStart(generation)"))
        assertTrue("BoxService rechecks the same service/start/session after network arrival", finalCheck > waitStart)
    }

    @Test
    fun `socket admission keeps the callback cache authoritative then recovers a system snapshot`() {
        val source = sourceFile("DefaultNetworkMonitor.kt")
        val socketAdmission = functionBody(source, "networkForSocket(): Network?")

        val excluded = socketAdmission.indexOf("val excluded = quarantinedSocketNetwork()")
        val cached = socketAdmission.indexOf("val cached = defaultNetwork")
        val cachedUsable = socketAdmission.indexOf("cached != excluded && DefaultNetworkListener.isUsable(cached)")
        val snapshot = socketAdmission.indexOf("val recovered = DefaultNetworkListener.snapshot(excluded)")
        val registration = socketAdmission.indexOf("val registration = synchronized(ownershipLock) { activeRegistration }")
        val publication = socketAdmission.indexOf("val publication = publishIfActive(registration, recovered)")

        assertTrue("socket admission must retain a quarantined-network exclusion", excluded >= 0)
        assertTrue("socket admission must read the callback-owned cache first", cached > excluded)
        assertTrue("a usable non-quarantined callback cache must win without a system query", cachedUsable > cached)
        assertTrue("a missing cache must fall back to a system snapshot", snapshot > cachedUsable)
        assertTrue("snapshot publication must be scoped to the active registration", registration > snapshot)
        assertTrue("recovered snapshot must re-enter normal owner-gated publication", publication > registration)
        assertTrue(socketAdmission.contains("scheduleDefaultInterfaceUpdate(recovered)"))
        assertTrue(socketAdmission.contains("publication.observer?.invoke(recovered)"))

        val vpnService = File("src/main/kotlin/app/marten/client/bg/VPNService.kt").readText()
        val autoDetect = functionBody(vpnService, "autoDetectInterfaceControl(fd: Int)")
        assertTrue("VPN socket setup must use the cache/snapshot admission path", autoDetect.contains("DefaultNetworkMonitor.networkForSocket()"))
    }

    @Test
    fun `missing callback reconciliation is owner gated bounded and waits for a connectivity event after exhaustion`() {
        val source = sourceFile("DefaultNetworkMonitor.kt")
        val socketAdmission = functionBody(source, "networkForSocket(): Network?")
        val reconciliation = functionBody(source, "reconcileMissingNetwork(")
        val publication = functionBody(source, "publishIfActive(")
        val bindFailure = functionBody(source, "reportSocketBindFailure(rejectedNetwork: Network)")

        assertTrue(
            "a missing synchronous snapshot must initiate reconciliation instead of poisoning the cache",
            socketAdmission.contains("reconcileMissingNetwork(registration, null)"),
        )
        assertTrue(reconciliation.contains("monitorScope.launch"))
        assertTrue(
            "missing-network recovery must cap the 500 ms snapshot window",
            source.contains("private const val MISSING_NETWORK_RECONCILIATION_MAX_ATTEMPTS = 6"),
        )
        assertTrue(
            "recovery must make exactly a bounded number of attempts rather than polling forever",
            reconciliation.contains("repeat(MISSING_NETWORK_RECONCILIATION_MAX_ATTEMPTS)"),
        )
        assertFalse(
            "a null network must not retain an unbounded isActive polling loop",
            reconciliation.contains("while (isActive") || reconciliation.contains("while(isActive"),
        )
        assertTrue(reconciliation.contains("activeRegistration === registration && missingNetworkRecoveryToken == token"))
        assertTrue(
            "concurrent null callbacks must coalesce behind the in-flight/exhausted state",
            reconciliation.contains("if (missingNetworkRecoveryInFlight || missingNetworkRecoveryExhausted) return"),
        )
        assertTrue(
            "the bounded worker must mark itself exhausted and leave the next attempt to a callback",
            reconciliation.contains("missingNetworkRecoveryInFlight = false") &&
                reconciliation.contains("missingNetworkRecoveryExhausted = true") &&
                reconciliation.contains("waiting for connectivity callback"),
        )
        assertTrue(reconciliation.contains("delay(MISSING_NETWORK_RECONCILIATION_INTERVAL_MS)"))
        assertTrue(
            "a rejected socket is the explicit event that opens one fresh bounded window",
            bindFailure.contains("reconcileMissingNetwork(registration, null, restartWindow = true)"),
        )
        assertTrue(
            "resetting an exhausted window must happen under the same ownership lock before claim",
            reconciliation.contains("if (restartWindow)") &&
                reconciliation.contains("missingNetworkRecoveryExhausted = false") &&
                reconciliation.contains("missingNetworkRecoveryInFlight = true"),
        )
        assertTrue(
            "reconciliation must publish through the service owner token gate",
            publication.contains("ServiceLifecycleOwnership.runIfCurrent(registration.ownerToken)"),
        )
    }

    @Test
    fun `socket bind rejection refreshes the owner keyed network request and clears actor cache`() {
        val monitor = sourceFile("DefaultNetworkMonitor.kt")
        val listener = sourceFile("DefaultNetworkListener.kt")
        val rejection = functionBody(monitor, "reportSocketBindFailure(rejectedNetwork: Network)")
        val refreshStart = listener.indexOf("is NetworkMessage.Refresh ->")
        val refreshEnd = listener.indexOf("is NetworkMessage.Put ->", refreshStart)
        check(refreshStart >= 0 && refreshEnd > refreshStart) { "missing network refresh actor branch" }
        val refresh = listener.substring(refreshStart, refreshEnd)

        assertTrue(rejection.contains("monitorScope.launch"))
        assertTrue(
            "refresh must remain scoped to the active monitor registration",
            rejection.contains("if (!isActive(registration)) return@launch"),
        )
        assertTrue(
            "bind rejection must refresh the exact service owner request",
            rejection.contains("DefaultNetworkListener.refresh(registration)"),
        )
        assertTrue(listener.contains("class Refresh(val key: Any)"))
        assertTrue("refresh must reject a stale owner key", refresh.contains("listeners.containsKey(message.key)"))
        assertTrue("refresh must clear the actor network cache before re-registering", refresh.contains("network = null"))
        val unregister = refresh.indexOf("unregister()")
        val register = refresh.indexOf("register()")
        assertTrue("refresh must unregister the stale OEM request first", unregister >= 0)
        assertTrue("refresh must register a fresh request after unregistering", register > unregister)
        assertTrue(listener.contains("networkActor.send(this)"))
        assertTrue(listener.contains("response.await()"))
    }

    @Test
    fun `link-property changes notify the same owner-scoped network observers`() {
        val listener = sourceFile("DefaultNetworkListener.kt")
        val callbackStart = listener.indexOf("override fun onLinkPropertiesChanged")
        val callbackEnd = listener.indexOf("override fun onLost", callbackStart)
        check(callbackStart >= 0 && callbackEnd > callbackStart) { "missing LinkProperties callback" }
        val callback = listener.substring(callbackStart, callbackEnd)

        assertTrue("a LinkProperties readiness edge must enter the existing actor", callback.contains("networkActor.send(NetworkMessage.Update(network))"))
        assertFalse("a same-network DNS/route update must not replace listener ownership", callback.contains("register()") || callback.contains("unregister()"))
    }

    @Test
    fun `offline startup and route recovery park on the monitor callback without a retry timer`() {
        val service = File("src/main/kotlin/app/marten/client/bg/BoxService.kt").readText()
        val startupMonitor = functionBody(service, "startCoreRuntimeMonitor")
        val routeRecovery = functionBody(service, "recoverNetworkRoute")
        val observed = sourceSection(
            service,
            "private fun onUnderlyingNetworkObserved(",
            "private fun updateCoreRecoveryOnlineWindow(",
        )

        val startupOffline = startupMonitor.indexOf("underlyingNetworkInitialized && observedUnderlyingNetwork == null")
        val startupRequire = startupMonitor.indexOf("DefaultNetworkMonitor.require()", startupOffline)
        val startupContinue = startupMonitor.indexOf("continue", startupRequire)
        assertTrue(
            "startup must park on the owner-scoped callback when no physical network exists",
            startupOffline >= 0 && startupRequire > startupOffline && startupContinue > startupRequire,
        )
        val startupPark = startupMonitor.substring(startupOffline, startupContinue)
        assertFalse("offline startup must not wake on a retry timer", startupPark.contains("delay("))
        assertFalse("offline startup must not add a polling loop", startupPark.contains("withTimeout") || startupPark.contains("while ("))

        val recoveryOffline = routeRecovery.indexOf("underlyingNetworkInitialized && observedUnderlyingNetwork == null")
        val recoveryRequire = routeRecovery.indexOf("DefaultNetworkMonitor.require()", recoveryOffline)
        val recoveryReturn = routeRecovery.indexOf("return", recoveryRequire)
        assertTrue(
            "route recovery must park on the monitor callback before any reset/probe attempt",
            recoveryOffline >= 0 && recoveryRequire > recoveryOffline && recoveryReturn > recoveryRequire,
        )
        val recoveryPark = routeRecovery.substring(recoveryOffline, recoveryReturn)
        assertFalse("offline route recovery must not wake on a retry timer", recoveryPark.contains("delay("))

        assertTrue(
            "a usable callback after outage must schedule recovery immediately without an artificial settle delay",
            observed.contains(
                "settleDelayMs = if (previous == null && network != null) 0L else ROUTE_WAKE_CHECK_DELAY_MS",
            ),
        )
    }

    @Test
    fun `initial underlying callback publishes VPN network before init return and duplicates do not advance generation`() {
        val service = File("src/main/kotlin/app/marten/client/bg/BoxService.kt").readText()
        val observed = functionBody(service, "onUnderlyingNetworkObserved")
        val staleGuard = observed.indexOf("if (!ServiceLifecycleOwnership.isCurrent(serviceOwnerToken))")
        val staleReturn = observed.indexOf("return", staleGuard)
        val observedAssignment = observed.indexOf("val previous = observedUnderlyingNetwork", staleGuard)
        val cacheAssignment = observed.indexOf("observedUnderlyingNetwork = network", observedAssignment)
        val publishCall = observed.indexOf("service.updateUnderlyingNetwork(network)", cacheAssignment)
        val initGuard = observed.indexOf("if (!underlyingNetworkInitialized)", publishCall)
        val initReturn = observed.indexOf("return", initGuard)
        val duplicateReturn = observed.indexOf("if (previous == network) return", initReturn)
        val generation = observed.indexOf("val generation = ++networkGeneration", duplicateReturn)

        assertTrue("stale-owner branch must remain the first callback gate", staleGuard >= 0)
        assertTrue("stale-owner guard should return immediately", staleReturn > staleGuard)
        assertTrue("callback should cache previous network before publishing to VPN service", observedAssignment > staleGuard && cacheAssignment > observedAssignment)
        assertTrue("first callback must publish VPN underlying network before initialization-only return", publishCall > cacheAssignment && publishCall < initReturn)
        assertTrue(
            "initialization-only path must still execute publication branch and return cleanly",
            initGuard > publishCall && initReturn > initGuard,
        )
        assertTrue(
            "duplicate unchanged callback must skip generation increment and not bypass stale-owner/initialization",
            generation > duplicateReturn,
        )

        val vpnService = File("src/main/kotlin/app/marten/client/bg/VPNService.kt").readText()
        val publish = functionBody(vpnService, "publishUnderlyingNetwork")

        assertTrue(
            "vpn publication must re-read current monitor snapshot under lock",
            publish.contains("val network = DefaultNetworkMonitor.defaultNetwork"),
        )
        assertTrue(
            "vpn publication must return on duplicate same network, keeping callbacks idempotent",
            publish.contains("underlyingNetworkDeclarationInitialized") &&
                publish.contains("declaredUnderlyingNetwork == network") &&
                publish.contains("return"),
        )
        assertTrue(
            "vpn publication must require active vpn and keep callbacks safe for stale callbacks",
            publish.contains("if (requireActiveVpn && !BoxService.isOwnVpnActive(this)) return"),
        )
    }

    @Test
    fun `initial native interface publication uses a lane independent from core lifecycle`() {
        val source = sourceFile("DefaultNetworkMonitor.kt")
        val publish = functionBody(source, "publishInterfaceAddress(")

        assertTrue(
            "platform interface callbacks must serialize on their own lane while native Start is holding the core lifecycle mutex",
            source.contains("private val interfaceUpdateMutex = Mutex()") &&
                publish.contains("interfaceUpdateMutex.withLock"),
        )
        assertFalse(
            "a native route-preflight callback cannot wait for the lifecycle lock held by the Start that needs it",
            publish.contains("MobileCoreLifecycle.run"),
        )
        assertTrue(
            "owner and listener generation must still be checked before forwarding an interface update",
            publish.contains("ServiceLifecycleOwnership.runIfCurrent(expectedRegistration.ownerToken)") &&
                publish.contains("interfaceListenerRegistration === expectedRegistration") &&
                publish.contains("token == interfaceUpdateToken"),
        )
        assertTrue(
            "the event must be committed as delivered before invoking the native listener, with failed delivery made retryable",
            publish.indexOf("expectedRegistration.lastDelivered = address") < publish.indexOf("currentListener.updateDefaultInterface") &&
                publish.contains("expectedRegistration.lastDelivered = null"),
        )
    }

    private fun sourceFile(name: String): String {
        val source = File("src/main/kotlin/app/marten/client/bg/$name")
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
