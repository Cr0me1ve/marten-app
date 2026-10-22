package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreProcessLifetimeTest {
    @Test
    fun `retirement blocks stale callbacks and replacement until exact process death`() {
        val lifetime = CoreProcessLifetime(controllerPid = 101)
        lifetime.attached(processPid = 202)

        assertTrue(lifetime.acceptsCallbacks())
        assertFalse("a live process cannot have a replacement", lifetime.replacementAllowed())

        val killPid = lifetime.beginRetirement(protectionPreserved = true)
        assertEquals("retirement targets the attached core process", 202, killPid)
        assertFalse("callbacks from the retired process cannot revive service state", lifetime.acceptsCallbacks())
        assertFalse("replacement must wait for confirmed Binder death", lifetime.replacementAllowed())

        lifetime.confirmDeath()
        assertFalse("dead process callbacks stay rejected", lifetime.acceptsCallbacks())
        assertTrue("a replacement is permitted only after death is confirmed", lifetime.replacementAllowed())
    }

    @Test
    fun `forced retirement requires preserved packet protection and refuses controller pid`() {
        val lifetime = CoreProcessLifetime(controllerPid = 101)
        lifetime.attached(processPid = 202)

        runCatching { lifetime.beginRetirement(protectionPreserved = false) }
            .onSuccess { throw AssertionError("retirement must fail closed if packet protection was not preserved") }
        assertTrue("failed retirement admission must leave the process live", lifetime.acceptsCallbacks())
        assertFalse(lifetime.replacementAllowed())

        val sameProcess = CoreProcessLifetime(controllerPid = 101)
        runCatching { sameProcess.attached(processPid = 101) }
            .onSuccess { throw AssertionError("the UI/controller process cannot be attached as the replaceable core") }
        assertFalse(sameProcess.replacementAllowed())
    }

    @Test
    fun `core process IPC keeps exact pid and file descriptors as Binder objects`() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        val remote = File("src/main/kotlin/app/marten/client/bg/RemoteMobile.kt").readText()
        val service = File("src/main/kotlin/app/marten/client/bg/CoreProcessService.kt").readText()
        val tunSpec = File("src/main/kotlin/app/marten/client/bg/CoreTunSpec.kt").readText()
        val vpn = File("src/main/kotlin/app/marten/client/bg/VPNService.kt").readText()
        val platformLease = File("src/main/kotlin/app/marten/client/bg/RemoteMobile.kt").readText()
        val platformAidl = File("src/main/aidl/app/marten/client/bg/ICorePlatform.aidl").readText()

        assertTrue("core service must run in its own non-exported process", Regex("<service[^>]*android:name=\".bg.CoreProcessService\"[^>]*android:process=\":core\"[^>]*android:exported=\"false\"").containsMatchIn(manifest))
        assertTrue("core work must reject UI-thread IPC", remote.contains("Looper.myLooper() != Looper.getMainLooper()"))
        val terminate = remote.substring(remote.indexOf("private fun terminate(owner: Session)"), remote.indexOf("private fun call("))
        val protectTraffic = terminate.indexOf("beforeForcedDeath?.invoke()")
        val cancelNative = terminate.indexOf("putString(\"op\", \"cancel\")")
        val boundedCancelWait = terminate.indexOf("cancelled.get(500L, TimeUnit.MILLISECONDS)")
        val deathRecheck = terminate.lastIndexOf("if (owner.died.count == 0L) return@synchronized")
        val beginRetirement = terminate.indexOf("owner.lifetime.beginRetirement(protectionPreserved)")
        val killProcess = terminate.indexOf("Process.killProcess(exactPid)")
        val deathBarrier = terminate.indexOf("owner.died.await(DEATH_TIMEOUT_MS")
        assertTrue("forced retirement must have one per-session serialization barrier", terminate.contains("synchronized(owner)"))
        assertTrue("traffic protection must be established before cancellation", protectTraffic >= 0 && cancelNative > protectTraffic)
        assertTrue("cancellation gets one bounded opportunity to stop native work", boundedCancelWait > cancelNative)
        assertEquals("concurrent deadlines must not send repeated cancel IPC", 1, terminate.split("putString(\"op\", \"cancel\")").size - 1)
        assertTrue("retirement and exact-PID kill happen only after cancellation and a death recheck", deathRecheck > boundedCancelWait && beginRetirement > deathRecheck && killProcess > beginRetirement)
        assertTrue("confirmed Binder death remains the replacement barrier after exact-PID kill", deathBarrier > killProcess)
        assertTrue("death confirmation is a barrier before returning from termination", terminate.indexOf("Process.killProcess(exactPid)") < terminate.indexOf("owner.died.await(DEATH_TIMEOUT_MS"))
        assertTrue("termination takes the exact attached process identity", terminate.contains("Process.killProcess(exactPid)"))
        assertFalse("the process controller must never kill its own UI process", Regex("killProcess\\(Process\\.myPid\\(\\)\\)").containsMatchIn(remote))
        val death = remote.substring(remote.indexOf("private fun death(owner: Session)"), remote.indexOf("private fun terminate(owner: Session)"))
        val transactionStart = death.indexOf("synchronized(lock)")
        val transactionEnd = death.indexOf("\n        }", transactionStart) + "\n        }".length
        val deathTransaction = death.substring(transactionStart, transactionEnd)
        val classification = deathTransaction.indexOf("val wasCurrent = current === owner")
        val retireOnce = deathTransaction.indexOf("val unexpected = !owner.retired.getAndSet(true)")
        val confirmDeath = deathTransaction.indexOf("owner.lifetime.confirmDeath()")
        val countDown = deathTransaction.indexOf("owner.died.countDown()")
        val removeCurrent = deathTransaction.indexOf("current = null")
        assertTrue("current-session check and one-time retirement classification happen inside one lock transaction", classification >= 0 && retireOnce > classification)
        assertTrue("death confirmation and wait release are part of the same transaction", confirmDeath > retireOnce && countDown > confirmDeath)
        assertTrue("the current session and its platform lease are removed atomically with death classification", removeCurrent > countDown && deathTransaction.contains("retiredLease = platformLease"))
        assertTrue("only the current session's winning unexpected death triggers recovery", deathTransaction.contains("wasCurrent && unexpected"))
        val unexpectedHook = death.indexOf("onUnexpectedDeath?.invoke()")
        val leaseCleanup = death.indexOf("runCatching { retiredLease?.close() }")
        assertTrue("authoritative unexpected-death notification runs after locked classification and before lease cleanup", unexpectedHook > transactionEnd && leaseCleanup > unexpectedHook)
        assertTrue("platform lease cleanup is contained so it cannot suppress recovery notification", death.contains("runCatching { retiredLease?.close() }"))
        assertTrue("core service reports its isolated PID", service.contains("return Process.myPid()"))
        assertTrue("native Mobile lifecycle executes in the core process", service.contains("import app.marten.core.mobile.Mobile"))
        listOf("BoxService.kt", "MobileCoreCloser.kt").forEach { fileName ->
            val owner = File("src/main/kotlin/app/marten/client/bg/$fileName").readText()
            assertFalse("$fileName must route native lifecycle through RemoteMobile", owner.contains("import app.marten.core.mobile.Mobile"))
        }
        assertTrue("core requests TUN with a value-only options Bundle", service.contains("remote.openTun(CoreTunSpec.from(options).toBundle())"))
        assertTrue("TUN crosses Binder as a ParcelFileDescriptor", platformAidl.contains("ParcelFileDescriptor openTun(in Bundle options)"))
        assertTrue("the core process retains the platform descriptor through its lifetime", service.contains("descriptors.add(descriptor)"))
        assertTrue("socket IPC passes a duplicated ParcelFileDescriptor object", service.contains("putParcelable(\"fd\", it)"))
        val platform = service.substring(service.indexOf("private class CorePlatform"))
        val socketTransfer = platform.substring(platform.indexOf("private fun socket"), platform.indexOf("override fun autoDetectInterfaceControl"))
        assertTrue("core socket transfer duplicates the borrowed descriptor without claiming its fd", socketTransfer.contains("ParcelFileDescriptor.fromFd(fd)"))
        assertTrue("core socket duplicate closes after the synchronous Binder transfer", socketTransfer.contains("duplicate.use { call(op)"))
        assertFalse("core socket transfer must not take ownership of libbox's original fd", socketTransfer.contains("adoptFd("))
        assertFalse("socket fd numbers must never cross Binder as integers", Regex("putInt\\(\\s*\"fd\"").containsMatchIn(platform))
        assertFalse("TUN specification must not transfer a raw fd integer", Regex("putInt\\(\\s*\"(?:fd|tunFd|tun_fd)\"").containsMatchIn(tunSpec))

        val bindPath = vpn.substring(vpn.indexOf("override fun autoDetectInterfaceControl"), vpn.indexOf("override fun protectSocket"))
        assertTrue("VPN bind duplicates the core socket fd", bindPath.contains("ParcelFileDescriptor.fromFd(fd)"))
        assertTrue("VPN closes its duplicate after physical bind and before protecting the original socket", bindPath.contains("finally") && bindPath.contains("descriptor.close()") && bindPath.indexOf("descriptor.close()") < bindPath.indexOf("protectSocket(fd)"))
        assertFalse("VPN socket bind must not adopt the core's original fd", bindPath.contains("adoptFd("))

        val tunTransfer = platformLease.substring(platformLease.indexOf("override fun openTun(options: Bundle)"), platformLease.indexOf("override fun call(request: Bundle)"))
        assertTrue("VPN service returns a duplicate TUN descriptor to Binder", tunTransfer.contains("ParcelFileDescriptor.fromFd(fd)"))
        assertFalse("TUN IPC must not adopt the VPN service's retained descriptor", tunTransfer.contains("adoptFd("))
        assertTrue("VPN service retains the established descriptor", vpn.contains("service.replaceTunFileDescriptor(pfd)"))
        assertTrue("VPN service passes only a CoreTunSpec to the isolated process", vpn.contains("openRemoteTun(CoreTunSpec.from(options))"))
        assertTrue("core process keeps the transferred TUN duplicate alive for native use", service.contains("descriptors.add(descriptor)"))
        assertTrue("native close precedes closing transferred TUN duplicates", service.indexOf("Mobile.close(request.getLong(\"mode\"))") < service.indexOf("platforms.forEach { it.closeDescriptors() }"))
        assertFalse("core calls must not be kept alive with idle polling", Regex("Thread\\.sleep\\(|SystemClock\\.sleep\\(|postDelayed\\(").containsMatchIn(remote))
    }
}
