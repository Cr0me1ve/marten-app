import Foundation
import Darwin
import MartenCore
import NetworkExtension
import os.log

open class ExtensionProvider: NEPacketTunnelProvider {
    public static let errorFile = FilePath.workingDirectory.appendingPathComponent("network_extension_error.log")
    private let logger = Logger(subsystem: "app.marten.client.MartenPacketTunnel", category: "PacketTunnel")
    
//    private var commandServer: LibboxCommandServer!
    private var systemProxyAvailable = false
    private var systemProxyEnabled = false
    private var platformInterface: ExtensionPlatformInterface!
    private let nativeQueue = DispatchQueue(label: "app.marten.client.packet-tunnel.native")
    private let intentLock = NSLock()
    private var stopRequested = false
    private var resumeGeneration: String?

    private func requestStop() {
        intentLock.lock(); stopRequested = true; intentLock.unlock()
    }

    private func nativeOperation(phase: String, timeout: TimeInterval, body: @escaping () throws -> Void) async throws {
        let deadline = NativeOperationDeadline(timeout: timeout) { [weak self] in
            // Cancellation runs separately: a blocked Go cancel cannot prevent retirement.
            if let generation = self?.resumeGeneration {
                try? ResumeConfigStore.recordNativeDeadline(generation: generation)
            }
            _ = MobileCancelStart()
            self?.cancelTunnelWithError(NSError(domain: "MartenCoreDeadline", code: 1))
        }
        defer { deadline.finish() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nativeQueue.async { [self] in
                do {
                    intentLock.lock()
                    let cancelled = stopRequested && phase != "stop"
                    intentLock.unlock()
                    guard !cancelled else { throw CancellationError() }
                    try body()
                    intentLock.lock()
                    let stopped = stopRequested && phase != "stop"
                    intentLock.unlock()
                    guard !stopped && !deadline.hasExpired else { throw CancellationError() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    override open func startTunnel(options: [String: NSObject]?) async throws {
        // Clear previous logs
        try? FileManager.default.removeItem(at: ExtensionProvider.errorFile)
        try? FileManager.default.removeItem(at: FilePath.workingDirectory.appendingPathComponent("TestLog"))
        
        do {
            writeMessage("(packet-tunnel) starting")
            
            let expectedGeneration = options?["ResumeGeneration"] as? NSString as? String
            do {
                let config = options?["Config"] as? NSString as? String
                if config != nil || expectedGeneration != nil {
                    guard let config,
                          !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let expectedGeneration,
                          !expectedGeneration.isEmpty else {
                        throw ExtensionError.configurationMissing
                    }
                }
            }

            var snapshot = try ResumeConfigStore.load(expectedGeneration: expectedGeneration)
            guard (snapshot.nativeDeadlineFailures ?? 0) < 2 else {
                throw ExtensionError.serviceStartFailed
            }
            resumeGeneration = snapshot.generation
            defer { snapshot.config.resetBytes(in: 0..<snapshot.config.count) }
            if let optionPort = (options?["GrpcServiceModePort"] as? NSNumber)?.intValue,
               optionPort != snapshot.grpcServiceModePort {
                throw ExtensionError.configurationMismatch
            }
            if let optionDisableMemoryLimit = options?["DisableMemoryLimit"] as? NSString as? String,
               (optionDisableMemoryLimit == "YES") != snapshot.disableMemoryLimit {
                throw ExtensionError.configurationMismatch
            }

            try FileManager.default.createDirectory(at: FilePath.workingDirectory, withIntermediateDirectories: true)
            
            // Ensure directories exist
            try createRequiredDirectories()
            
            // Log directory paths for debugging
            let sharedDir = FilePath.sharedDirectory.relativePath
            let workDir = FilePath.workingDirectory.relativePath
            let cacheDir = FilePath.cacheDirectory.relativePath
            if platformInterface == nil {
                platformInterface = ExtensionPlatformInterface(self)
            }
            let configLease = try ResumeConfigStore.createPlaintextLease(for: snapshot)
            defer { ResumeConfigStore.deletePlaintextLease(configLease) }
            let config = configLease.path
            // Initialize mobile setup with error handling
            try await nativeOperation(phase: "setup", timeout: 15) { [self] in
                var setupError: NSError?
                MobileSetup(sharedDir, workDir, cacheDir, 4,
                    "127.0.0.1:\(snapshot.grpcServiceModePort)", "", false,
                    platformInterface, &setupError)
                if let setupError { throw setupError }
                LibboxSetMemoryLimit(!snapshot.disableMemoryLimit)
            }

            writeMessage("(packet-tunnel) setup completed successfully")
            try await startService1(config)
        } catch {
            logger.error("Tunnel setup failed: \(error.localizedDescription)")
            writeFatalError("(packet-tunnel) setup failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func startService1(_ config: String) async throws {
        writeMessage("Starting service")
        try await nativeOperation(phase: "start", timeout: 45) {
            var error: NSError?
            try MobileStart(config, "", &error)
            if let error { throw error }
        }
        writeMessage("(packet-tunnel) service started successfully")
    }
    
    private func createRequiredDirectories() throws {
        let directories = [
            FilePath.workingDirectory,
            FilePath.sharedDirectory,
            FilePath.cacheDirectory
        ]
        
        for directory in directories {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                logger.error("Failed to create directory at \(directory.path): \(error.localizedDescription)")
                throw error
            }
        }
    }
    
    func writeMessage(_ message: String) {
        logger.debug("\(message)")
        writeError(message)
    }
    
    func writeError(_ message: String) {
        let messageWithNewline = "[\(Date())] \(message)\n"
        do {
            if FileManager.default.fileExists(atPath: ExtensionProvider.errorFile.path) {
                if let fileHandle = try? FileHandle(forWritingTo: ExtensionProvider.errorFile) {
                    defer { fileHandle.closeFile() }
                    fileHandle.seekToEndOfFile()
                    if let data = messageWithNewline.data(using: .utf8) {
                        fileHandle.write(data)
                    }
                }
            } else {
                try messageWithNewline.write(to: ExtensionProvider.errorFile, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.error("Failed to write to error file: \(error.localizedDescription)")
        }
    }
    
    public func writeFatalError(_ message: String) {
        logger.fault("Fatal error: \(message)")
        writeError("FATAL: \(message)")
        cancelTunnelWithError(NSError(domain: "ExtensionProvider", code: 0, userInfo: [NSLocalizedDescriptionKey: message]))
    }
    
    override open func stopTunnel(with reason: NEProviderStopReason) async {
//        logger.debug("Stopping tunnel with reason: \(reason)")
        writeMessage("(packet-tunnel) stopping, reason: \(reason)")
        requestStop()
        DispatchQueue.global(qos: .utility).async { _ = MobileCancelStart() }
        do {
            try await nativeOperation(phase: "stop", timeout: 5) { [self] in try stopService() }
        } catch {
            writeError("(packet-tunnel) stop failed category=\(type(of: error))")
            Darwin.kill(Darwin.getpid(), SIGKILL)
        }
        
//        // Allow time for cleanup
//        try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
//        
//        if let server = commandServer {
//            try? server.close()
//            commandServer = nil
//        }
    }
    
    private func stopService() throws {
        logger.debug("Stopping service")
        var error: NSError?
        MobileClose(4, &error)
        if let error {
            writeError("(packet-tunnel) close failed category=\(type(of: error))")
            throw error
        }
        if let platformInterface {
            platformInterface.reset()
        }
    }
    
    func reloadService() async {
        logger.debug("Reloading service")
        writeMessage("(packet-tunnel) reloading service")
//        reasserting = true
//        defer { reasserting = false }
//        
//        stopService()
//        do {
//            guard let config = try? String(contentsOf: FilePath.configFile) else {
//                writeFatalError("(packet-tunnel) error: cannot read config file")
//                return
//            }
//            try await startService(config)
//        } catch {
//            writeFatalError("(packet-tunnel) error: reload service: \(error.localizedDescription)")
//        }
    }
    
    override open func handleAppMessage(_ messageData: Data) async -> Data? {
        logger.debug("Handling app message")
        return messageData
    }
    
    override open func sleep() async {
        logger.debug("Entering sleep mode")
//        MobilePause()
        // Add any sleep mode handling if needed
    }
    
    override open func wake() {
        logger.debug("Waking from sleep")
        Task {
            do {
                try await nativeOperation(phase: "reset", timeout: 8) {
                    var error: NSError?
                    MobileResetNetwork(&error)
                    if let error { throw error }
                }
            } catch {
                writeError("(packet-tunnel) reset failed category=\(type(of: error))")
            }
        }
    }
}

// Extension to support error handling
extension ExtensionProvider {
    enum ExtensionError: Error {
        case configurationMissing
        case configurationMismatch
        case directoryCreationFailed
        case serviceStartFailed
        
        var localizedDescription: String {
            switch self {
            case .configurationMissing:
                return "Configuration not provided"
            case .configurationMismatch:
                return "VPN recovery configuration does not match the requested connection"
            case .directoryCreationFailed:
                return "Failed to create required directories"
            case .serviceStartFailed:
                return "Failed to start the service"
            }
        }
    }
}


private final class NativeOperationDeadline {
    private let lock = NSLock()
    private var pending = true
    private var expired = false
    private let timer: DispatchSourceTimer
    private static let queue = DispatchQueue(label: "app.marten.client.packet-tunnel.deadline")

    init(timeout: TimeInterval, cancel: @escaping () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldCancel = self.pending
            if shouldCancel { self.expired = true }
            self.lock.unlock()
            guard shouldCancel else { return }
            DispatchQueue.global(qos: .utility).async(execute: cancel)
            Self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let mustRetire = self.pending
                self.lock.unlock()
                if mustRetire {
                    // This code is linked only into MartenPacketTunnel, never Runner.
                    // A replacement is admitted by NetworkExtension after process death.
                    Darwin.kill(Darwin.getpid(), SIGKILL)
                }
            }
        }
        timer.resume()
    }
    var hasExpired: Bool {
        lock.lock(); defer { lock.unlock() }
        return expired
    }
    func finish() {
        lock.lock(); pending = false; lock.unlock()
        timer.cancel()
    }
}
