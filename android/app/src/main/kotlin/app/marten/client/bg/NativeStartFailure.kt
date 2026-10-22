package app.marten.client.bg

/** Fixed categories only: native error text may contain private profile data. */
internal fun nativeStartFailureCategory(error: Exception): String {
    val message = error.message.orEmpty()
    return when {
        message.contains("selected route preflight", ignoreCase = true) -> "route_preflight"
        message.contains("physical endpoint resolution", ignoreCase = true) -> "endpoint_dns"
        message.contains("local listener", ignoreCase = true) -> "local_listener"
        message.contains("configuration identity", ignoreCase = true) -> "config_identity"
        else -> "native_start"
    }
}
