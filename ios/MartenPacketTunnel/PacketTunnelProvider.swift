import NetworkExtension

// Lifecycle and control messages are owned by ExtensionProvider. Traffic
// statistics use the existing gRPC stream rather than periodic zero-value IPC.
class PacketTunnelProvider: ExtensionProvider {}
