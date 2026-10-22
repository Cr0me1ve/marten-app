package app.marten.client.bg

import app.marten.client.constant.PerAppProxyMode
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnAppRoutingPolicyTest {
    @Test
    fun `VPN establishment applies resolved split routing without bypass or package-name logs`() {
        val vpnService = vpnServiceSource()
        val openTun = functionBody(vpnService, "openRemoteTun")
        val codeOnly = vpnService.lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")

        assertTrue("openTun must reduce Settings and core options to one routing plan", openTun.contains("resolveVpnAppRoutingPlan("))
        assertTrue(openTun.contains("ownPackageName = packageName"))
        assertTrue(openTun.contains("perAppProxyMode = Settings.perAppProxyMode"))
        assertTrue(openTun.contains("perAppProxyPackages = Settings.perAppProxyList"))
        assertTrue(openTun.contains("optionIncludePackages = optionIncludePackages"))
        assertTrue(openTun.contains("optionExcludePackages = optionExcludePackages"))
        assertTrue(openTun.contains("val optionIncludePackages = options.includePackage"))
        assertTrue(openTun.contains("val optionExcludePackages = options.excludePackage"))

        val includeHelper = blockBody(vpnService, vpnService.indexOf("private fun addIncludePackage"))
        val excludeHelper = blockBody(vpnService, vpnService.indexOf("private fun addExcludePackage"))
        val includePlan = blockBody(openTun, openTun.indexOf("is VpnAppRoutingPlan.IncludeOnly"))
        val excludePlan = blockBody(openTun, openTun.indexOf("is VpnAppRoutingPlan.Exclude"))
        assertTrue("IncludeOnly must apply Android allowed-app routing", includeHelper.contains("builder.addAllowedApplication(packageName)"))
        assertTrue("IncludeOnly must invoke its allowed-app helper", includePlan.contains("addIncludePackage(builder, routedPackage)"))
        assertTrue("Exclude must apply Android disallowed-app routing", excludeHelper.contains("builder.addDisallowedApplication(packageName)"))
        assertTrue("Exclude must invoke its disallowed-app helper", excludePlan.contains("addExcludePackage(builder, bypassedPackage)"))

        assertFalse("VPN routing must never enable physical-network bypass", codeOnly.contains("allowBypass("))
        assertFalse("split-routing logs must not reveal an allowed package name", openTun.contains("\$routedPackage"))
        assertFalse("split-routing logs must not reveal an excluded package name", openTun.contains("\$bypassedPackage"))

        assertTrue(includePlan.contains("var installedExternalApplications = 0"))
        assertTrue("only successfully added non-own apps may satisfy IncludeOnly establishment", includePlan.contains("if (routedPackage != packageName)"))
        assertTrue(includePlan.contains("installedExternalApplications += 1"))
        assertTrue(includePlan.contains("check(installedExternalApplications > 0)"))

        assertTrue(openTun.contains("check(hasInet4Address || hasInet6Address)"))
        assertTrue(openTun.contains("if (!hasInet4Address)"))
        assertTrue(openTun.contains("builder.addAddress(STRICT_UNSUPPORTED_IPV4_ADDRESS"))
        assertTrue(openTun.contains("if (!hasInet6Address)"))
        assertTrue(openTun.contains("builder.addAddress(STRICT_UNSUPPORTED_IPV6_ADDRESS"))
        assertTrue(openTun.contains("builder.addRoute(\"0.0.0.0\", 0)"))
        assertTrue(openTun.contains("builder.addRoute(\"::\", 0)"))
    }

    @Test
    fun `INCLUDE mode keeps only own package when no explicit app selection exists`() {
        val plan = resolveVpnAppRoutingPlan(
            ownPackageName = "app.marten.client",
            perAppProxyMode = PerAppProxyMode.INCLUDE,
            perAppProxyPackages = emptyList(),
            optionIncludePackages = emptyList(),
            optionExcludePackages = emptyList(),
        )

        assertTrue(plan is VpnAppRoutingPlan.IncludeOnly)
        assertEquals(listOf("app.marten.client"), (plan as VpnAppRoutingPlan.IncludeOnly).packages)
    }

    @Test
    fun `INCLUDE mode trims, deduplicates and removes subscription-bypassed packages but keeps own`() {
        val plan = resolveVpnAppRoutingPlan(
            ownPackageName = "com.marten",
            perAppProxyMode = PerAppProxyMode.INCLUDE,
            perAppProxyPackages = listOf(
                "com.pkg.one",
                " ",
                "com.pkg.two",
                "com.pkg.one",
                "com.pkg.three",
            ),
            optionIncludePackages = emptyList(),
            optionExcludePackages = listOf("com.pkg.three", "  ", "com.marten", "com.pkg.two"),
        )

        assertTrue(plan is VpnAppRoutingPlan.IncludeOnly)
        assertEquals(
            listOf("com.pkg.one", "com.marten"),
            (plan as VpnAppRoutingPlan.IncludeOnly).packages,
        )
    }

    @Test
    fun `EXCLUDE mode merges selected and subscription excludes while removing own package`() {
        val plan = resolveVpnAppRoutingPlan(
            ownPackageName = "app.marten.client",
            perAppProxyMode = PerAppProxyMode.EXCLUDE,
            perAppProxyPackages = listOf("app.marten.client", "com.blocked.one", "com.blocked.one", "com.blocked.two"),
            optionIncludePackages = listOf("ignored", "ignored"),
            optionExcludePackages = listOf("com.marten.client", "com.blocked.two", "com.blocked.two"),
        )

        assertTrue(plan is VpnAppRoutingPlan.Exclude)
        assertEquals(
            setOf("com.blocked.one", "com.blocked.two", "com.marten.client"),
            (plan as VpnAppRoutingPlan.Exclude).packages.toSet(),
        )
    }

    @Test
    fun `OFF mode uses subscription include list with bypass semantics when include list is populated`() {
        val plan = resolveVpnAppRoutingPlan(
            ownPackageName = "com.marten",
            perAppProxyMode = PerAppProxyMode.OFF,
            perAppProxyPackages = listOf("ignored"),
            optionIncludePackages = listOf("com.direct.one", "com.direct.one", "com.both", "com.both"),
            optionExcludePackages = listOf("com.both", "com.blocked"),
        )

        assertTrue(plan is VpnAppRoutingPlan.IncludeOnly)
        assertEquals(
            listOf("com.direct.one", "com.marten"),
            (plan as VpnAppRoutingPlan.IncludeOnly).packages,
        )
    }

    @Test
    fun `OFF mode without subscription include falls back to subscription excludes`() {
        val plan = resolveVpnAppRoutingPlan(
            ownPackageName = "com.marten",
            perAppProxyMode = PerAppProxyMode.OFF,
            perAppProxyPackages = listOf("com.user", "com.user"),
            optionIncludePackages = emptyList(),
            optionExcludePackages = listOf(" ", "com.blocked.one", "com.marten", "com.blocked.one"),
        )

        assertTrue(plan is VpnAppRoutingPlan.Exclude)
        assertEquals(
            listOf("com.blocked.one"),
            (plan as VpnAppRoutingPlan.Exclude).packages,
        )
    }

    @Test
    fun `invalid mode fails closed`() {
        try {
            resolveVpnAppRoutingPlan(
                ownPackageName = "com.marten",
                perAppProxyMode = "invalid-mode",
                perAppProxyPackages = emptyList(),
                optionIncludePackages = emptyList(),
                optionExcludePackages = emptyList(),
            )
            assertTrue(false)
        } catch (error: IllegalStateException) {
            assertEquals("android: invalid per-app VPN routing mode", error.message)
        }
    }

    private fun vpnServiceSource(): String {
        val source = File("src/main/kotlin/app/marten/client/bg/VPNService.kt")
        check(source.isFile) { "missing production source ${source.path}" }
        return source.readText()
    }

    private fun sourceSection(source: String, startMarker: String, endMarker: String): String {
        val start = source.indexOf(startMarker)
        val end = source.indexOf(endMarker, start + startMarker.length)
        require(start >= 0 && end >= 0) { "missing source section: $startMarker" }
        return source.substring(start, end)
    }

    private fun functionBody(source: String, name: String): String {
        val declaration = source.indexOf("fun $name")
        require(declaration >= 0) { "missing function $name" }
        val start = source.indexOf('{', declaration)
        require(start >= 0) { "function $name has no body" }
        var depth = 0
        for (index in start until source.length) {
            when (source[index]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return source.substring(start + 1, index)
            }
        }
        error("function $name body does not close")
    }

    private fun blockBody(source: String, declaration: Int): String {
        require(declaration >= 0) { "missing block declaration" }
        val start = source.indexOf('{', declaration)
        var depth = 0
        for (index in start until source.length) {
            when (source[index]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return source.substring(start + 1, index)
            }
        }
        error("block does not close")
    }
}
