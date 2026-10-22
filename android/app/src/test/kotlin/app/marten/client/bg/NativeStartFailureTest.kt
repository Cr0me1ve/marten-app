package app.marten.client.bg

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeStartFailureTest {
    @Test
    fun `known native startup failures map to fixed diagnostic categories`() {
        assertEquals("route_preflight", nativeStartFailureCategory(IllegalStateException("Selected ROUTE PREFLIGHT failed")))
        assertEquals("endpoint_dns", nativeStartFailureCategory(Exception("PHYSICAL ENDPOINT RESOLUTION timed out")))
        assertEquals("local_listener", nativeStartFailureCategory(Exception("local listener bind failed")))
        assertEquals("config_identity", nativeStartFailureCategory(Exception("configuration identity mismatch")))
    }

    @Test
    fun `route preflight category takes precedence when multiple known phrases appear`() {
        val error = Exception("configuration identity check failed after physical endpoint resolution during selected route preflight")

        assertEquals("route_preflight", nativeStartFailureCategory(error))
    }

    @Test
    fun `unknown private exception details are replaced by an allowlisted category`() {
        val privateDetails = "server=secret.example token=private-token profile=private-profile"
        val result = nativeStartFailureCategory(IllegalArgumentException(privateDetails))
        val allowed = setOf("route_preflight", "endpoint_dns", "local_listener", "config_identity", "native_start")

        assertEquals("native_start", result)
        assertTrue("every returned diagnostic category must be allowlisted", result in allowed)
        assertFalse("the result must not disclose private exception details", result.contains("secret.example"))
        assertFalse("the result must not disclose credentials", result.contains("private-token"))
        assertFalse("the result must not disclose profile data", result.contains("private-profile"))
    }

    @Test
    fun `every category result is a fixed token and never includes exception text`() {
        val privateText = "secret-host token=abc profile=xyz"
        val errors = listOf(
            Exception("selected route preflight $privateText"),
            Exception("physical endpoint resolution $privateText"),
            Exception("local listener $privateText"),
            Exception("configuration identity $privateText"),
            Exception(privateText),
        )
        val allowed = setOf("route_preflight", "endpoint_dns", "local_listener", "config_identity", "native_start")

        errors.map(::nativeStartFailureCategory).forEach { category ->
            assertTrue("category should come from the fixed allowlist", category in allowed)
            assertFalse("category must never contain exception payload", category.contains(privateText))
            assertFalse("category must never contain a private host", category.contains("secret-host"))
            assertFalse("category must never contain credentials", category.contains("token=abc"))
        }
    }
}
