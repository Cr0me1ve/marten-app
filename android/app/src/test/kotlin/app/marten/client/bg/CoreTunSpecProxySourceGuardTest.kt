package app.marten.client.bg

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreTunSpecProxySourceGuardTest {
    @Test
    fun `optional HTTP proxy getters are read only when proxy is enabled`() {
        val source = File("src/main/kotlin/app/marten/client/bg/CoreTunSpec.kt").readText()
        val fromTunOptions = source.substringAfter("fun from(options: TunOptions): CoreTunSpec {")
            .substringBefore("\n        fun from(bundle: Bundle): CoreTunSpec {")

        assertTrue("proxy enablement is captured before constructing the cross-process value", fromTunOptions.indexOf("val proxyEnabled = options.isHTTPProxyEnabled") in 0 until fromTunOptions.indexOf("return CoreTunSpec("))
        assertEquals("the optional enablement getter is evaluated once", 1, Regex("options\\.isHTTPProxyEnabled").findAll(fromTunOptions).count())
        assertTrue("the spec carries the captured proxy state", Regex("\\n\\s+proxyEnabled,").containsMatchIn(fromTunOptions))

        // The gomobile getters dereference an optional Go proxy config. Keep every such read
        // behind the captured enablement check so disabled options never touch a nil config.
        assertEquals("the optional proxy host getter appears only in its guarded branch", 1, Regex("if \\(proxyEnabled\\) options\\.httpProxyServer else \"\"").findAll(fromTunOptions).count())
        assertEquals("the optional proxy port getter appears only in its guarded branch", 1, Regex("if \\(proxyEnabled\\) options\\.httpProxyServerPort else 0").findAll(fromTunOptions).count())
        assertEquals("the host getter has no unguarded reads", 1, Regex("options\\.httpProxyServer(?!Port)").findAll(fromTunOptions).count())
        assertEquals("the port getter has no unguarded reads", 1, Regex("options\\.httpProxyServerPort").findAll(fromTunOptions).count())
    }
}
