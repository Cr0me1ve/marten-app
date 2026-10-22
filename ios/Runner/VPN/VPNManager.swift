//
//  VPNManager.swift
//  Runner
//
//  Created by GFWFighter on 7/25/1402 AP.
//

import Foundation
import Combine
import NetworkExtension

enum VPNManagerAlertType: String {
    case RequestVPNPermission
    case RequestNotificationPermission
    case EmptyConfiguration
    case StartCommandServer
    case CreateService
    case StartService
}

struct VPNManagerAlert {
    let alert: VPNManagerAlertType?
    let message: String?
}

class VPNManager: ObservableObject {
    private var observer: NSObjectProtocol?
    private var manager = NEVPNManager.shared()
    private var loaded: Bool = false
            
    static let shared: VPNManager = VPNManager()
        
    @Published private(set) var state: NEVPNStatus = .invalid
    @Published private(set) var alert: VPNManagerAlert = .init(alert: nil, message: nil)
    
    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: nil) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            self?.state = connection.status
        }
        
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    func setup() async throws {
        guard !loaded else { return }
        try await loadVPNPreference()
        loaded = true
    }
    
    @discardableResult
    private func loadVPNPreference(createIfMissing: Bool = true) async throws -> Bool {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let expectedProvider = Bundle.main.baseBundleIdentifier + ".MartenPacketTunnel"
        if let manager = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == expectedProvider
        }) {
            self.manager = manager
            return true
        }
        guard createIfMissing else { return false }
        let newManager = NETunnelProviderManager()
        let `protocol` = NETunnelProviderProtocol()
        `protocol`.providerBundleIdentifier = Bundle.main.baseBundleIdentifier + ".MartenPacketTunnel"
        `protocol`.serverAddress = "localhost"
        `protocol`.includeAllNetworks = true
        `protocol`.excludeLocalNetworks = false
        newManager.protocolConfiguration = `protocol`
        newManager.localizedDescription = "Marten"
        try await newManager.saveToPreferences()
        try await newManager.loadFromPreferences()
        self.manager = newManager
        return true
    }
    
    private func enableVPNManager() async throws {
        guard let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw VPNManagerError.connectionFailed
        }
        configuration.includeAllNetworks = true
        configuration.excludeLocalNetworks = false
        manager.protocolConfiguration = configuration
        manager.isEnabled = true
        manager.onDemandRules = []
        manager.isOnDemandEnabled = false

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }

    private func enableOnDemand() async throws {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        manager.onDemandRules = [rule]
        manager.isOnDemandEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }

    private func disableOnDemand() async throws {
        guard manager.isOnDemandEnabled || !(manager.onDemandRules ?? []).isEmpty else { return }
        manager.isOnDemandEnabled = false
        manager.onDemandRules = []
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }
    
    func reset() async throws {
        if !loaded {
            try await loadVPNPreference()
            loaded = true
        }
        if manager.connection.status != .disconnected && manager.connection.status != .invalid {
            try await disconnect()
            try await waitForDisconnected()
        } else {
            try await disableOnDemand()
            try ResumeConfigStore.clear()
        }

        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        for manager in managers ?? [] {
            try await manager.removeFromPreferences()
        }
        loaded = false
        manager = .shared()
        try await loadVPNPreference()
        loaded = true
    }
    
    
    func connect(with config: String, grpcServiceModePort:Int, disableMemoryLimit: Bool = false) async throws {
        switch manager.connection.status {
        case .connected:
            if ResumeConfigStore.matchesActiveConfig(configPath: config, grpcServiceModePort: grpcServiceModePort) {
                try await enableOnDemand()
                return
            }
            try await disconnect()
        case .connecting, .reasserting:
            try await waitForConnected()
            if ResumeConfigStore.matchesActiveConfig(configPath: config, grpcServiceModePort: grpcServiceModePort) {
                try await enableOnDemand()
                return
            }
            try await disconnect()
        case .disconnecting:
            try await waitForDisconnected()
        default:
            break
        }

        try await enableVPNManager()
        let resumeGeneration = try ResumeConfigStore.store(
            configPath: config,
            grpcServiceModePort: grpcServiceModePort,
            disableMemoryLimit: disableMemoryLimit
        )
        do {
            try manager.connection.startVPNTunnel(options: [
                "Config": config as NSString,
                "GrpcServiceModePort": NSNumber(value: grpcServiceModePort),
                "DisableMemoryLimit": (disableMemoryLimit ? "YES" : "NO") as NSString,
                "ResumeGeneration": resumeGeneration as NSString,
            ])
            try await waitForConnected()
            try await enableOnDemand()
        } catch {
            manager.connection.stopVPNTunnel()
            try? await disableOnDemand()
            try? ResumeConfigStore.clear()
            throw error
        }
    }

    func disconnect() async throws {
        if !loaded {
            // Cleanup must never create a VPN profile or present permission UI.
            guard try await loadVPNPreference(createIfMissing: false) else {
                try ResumeConfigStore.clear()
                    return
            }
            loaded = true
        }

        var firstError: Error?
        do {
            try await disableOnDemand()
        } catch {
            firstError = error
        }
        do {
            try ResumeConfigStore.clear()
        } catch {
            if firstError == nil { firstError = error }
        }
        manager.connection.stopVPNTunnel()
        do {
            try await waitForDisconnected()
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    private func waitForConnected() async throws {
        var transitionStartedAt: Date?
        for _ in 0..<300 {
            switch manager.connection.status {
            case .connected:
                return
            case .connecting, .reasserting:
                if transitionStartedAt == nil { transitionStartedAt = .now }
            case .disconnected, .invalid:
                if let transitionStartedAt, Date().timeIntervalSince(transitionStartedAt) >= 2 {
                    throw VPNManagerError.connectionFailed
                }
            default:
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VPNManagerError.connectionTimedOut
    }

    private func waitForDisconnected() async throws {
        for _ in 0..<100 {
            if manager.connection.status == .disconnected || manager.connection.status == .invalid {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VPNManagerError.disconnectionTimedOut
    }

    private enum VPNManagerError: LocalizedError {
        case connectionFailed
        case connectionTimedOut
        case disconnectionTimedOut

        var errorDescription: String? {
            switch self {
            case .connectionFailed:
                return "The VPN extension failed to start"
            case .connectionTimedOut:
                return "The VPN extension did not start in time"
            case .disconnectionTimedOut:
                return "The VPN extension did not stop in time"
            }
        }
    }
}
