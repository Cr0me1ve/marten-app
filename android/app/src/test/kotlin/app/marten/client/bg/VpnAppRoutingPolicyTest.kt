package app.marten.client.bg

import app.marten.client.constant.PerAppProxyMode
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnAppRoutingPolicyTest {
    @Test
    fun `include-only routing requires a successfully installed external app before establishing VPN`() {
        val vpnService = vpnServiceSource()
        val includeOnly = sourceSection(
            vpnService,
            "is VpnAppRoutingPlan.IncludeOnly -> {",
            "is VpnAppRoutingPlan.Exclude -> {",
        )

        val addIncludedPackage = includeOnly.indexOf("if (addIncludePackage(builder, routedPackage)) {")
        val successfulIncludeBranch = blockBody(includeOnly, addIncludedPackage)
        val countInstalledExternal = includeOnly.indexOf("installedExternalApplications += 1")
        val requireExternalApplication = includeOnly.indexOf("check(installedExternalApplications > 0)")
        val establishVpn = vpnService.indexOf("builder.establish()")

        assertTrue("external applications must be counted only after addAllowedApplication succeeds", addIncludedPackage >= 0)
        assertTrue("include-only routing must count installed external applications", countInstalledExternal >= 0)
        assertTrue("include-only routing must reject an empty installed-app set", requireExternalApplication >= 0)
        assertTrue("external applications must be counted inside the successful addIncludePackage branch", addIncludedPackage < countInstalledExternal)
        assertTrue("only external packages may satisfy include-only routing", successfulIncludeBranch.contains("if (routedPackage != packageName)"))
        assertTrue("only successfully added external packages may satisfy include-only routing", successfulIncludeBranch.contains("installedExternalApplications += 1"))
        assertTrue("include-only guard must run before VPN establishment", vpnService.indexOf("check(installedExternalApplications > 0)") < establishVpn)

        val includeHelper = functionBody(vpnService, "addIncludePackage")
        val excludeHelper = functionBody(vpnService, "addExcludePackage")
        assertFalse("include helper must not log per-package names", Regex("Log\\.[\\s\\S]*packageName").containsMatchIn(includeHelper))
        assertFalse("exclude helper must not log per-package names", Regex("Log\\.[\\s\\S]*packageName").containsMatchIn(excludeHelper))
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
