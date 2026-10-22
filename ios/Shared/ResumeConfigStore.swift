import CryptoKit
import Foundation
import Darwin
import Security

struct ResumeConfigSnapshot: Codable {
    let version: Int
    let generation: String
    let grpcServiceModePort: Int
    let disableMemoryLimit: Bool
    var config: Data
    var nativeDeadlineFailures: Int? = nil
}

enum ResumeConfigStore {
    private static let currentVersion = 1
    private static let header = Data("MARTEN_IOS_RECOVERY_V1\n".utf8)
    private static let keychainService = "app.marten.client.ios-resume"
    private static let keychainAccount = "encryption-key-v1"
    private static let keychainAccessGroupInfoKey = "MartenKeychainAccessGroup"
    private static let storeDirectoryName = "MartenRecovery"
    private static let storeFileName = "session.v1.enc"
    private static let leasePrefix = "marten-resume-"

    enum StoreError: LocalizedError {
        case invalidAccessGroup
        case missingConfiguration
        case invalidSnapshot
        case staleGeneration
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidAccessGroup:
                return "Secure VPN recovery storage is unavailable"
            case .missingConfiguration:
                return "VPN recovery configuration is missing"
            case .invalidSnapshot:
                return "VPN recovery configuration is invalid"
            case .staleGeneration:
                return "VPN recovery configuration is stale"
            case .keychain:
                return "Secure VPN recovery storage failed"
            }
        }
    }

    private static func withStoreLock<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let lockPath = storeDirectory.appendingPathComponent("lifecycle.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StoreError.invalidSnapshot }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw StoreError.invalidSnapshot }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }

    static func recordNativeDeadline(generation: String) throws {
        try withStoreLock {
            var snapshot = try load(expectedGeneration: generation)
            defer { snapshot.config.resetBytes(in: 0..<snapshot.config.count) }
            snapshot.nativeDeadlineFailures = (snapshot.nativeDeadlineFailures ?? 0) + 1
            var plaintext = try JSONEncoder().encode(snapshot)
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            let sealed = try AES.GCM.seal(plaintext, using: loadExistingKey())
            guard let combined = sealed.combined else { throw StoreError.invalidSnapshot }
            var payload = header
            payload.append(combined)
            defer { payload.resetBytes(in: 0..<payload.count) }
            try payload.write(to: storeFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func store(configPath: String, grpcServiceModePort: Int, disableMemoryLimit: Bool) throws -> String {
        try withStoreLock {
            try storeUnlocked(configPath: configPath, grpcServiceModePort: grpcServiceModePort,
                disableMemoryLimit: disableMemoryLimit)
        }
    }

    private static func storeUnlocked(
        configPath: String,
        grpcServiceModePort: Int,
        disableMemoryLimit: Bool
    ) throws -> String {
        guard (1...65_535).contains(grpcServiceModePort) else {
            throw StoreError.invalidSnapshot
        }

        var config = try Data(contentsOf: URL(fileURLWithPath: configPath))
        guard !config.isEmpty else {
            throw StoreError.missingConfiguration
        }
        defer { config.resetBytes(in: 0..<config.count) }

        let generation = UUID().uuidString.lowercased()
        var snapshotData = try JSONEncoder().encode(
            ResumeConfigSnapshot(
                version: currentVersion,
                generation: generation,
                grpcServiceModePort: grpcServiceModePort,
                disableMemoryLimit: disableMemoryLimit,
                config: config
            )
        )
        defer { snapshotData.resetBytes(in: 0..<snapshotData.count) }

        let sealed = try AES.GCM.seal(snapshotData, using: loadOrCreateKey())
        guard let combined = sealed.combined else {
            throw StoreError.invalidSnapshot
        }
        var payload = header
        payload.append(combined)
        defer { payload.resetBytes(in: 0..<payload.count) }

        let directory = storeDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try payload.write(
            to: storeFile,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: storeFile.path
        )
        cleanupPlaintextLeases()
        return generation
    }

    static func load(expectedGeneration: String? = nil) throws -> ResumeConfigSnapshot {
        var payload: Data
        do {
            payload = try Data(contentsOf: storeFile)
        } catch {
            throw StoreError.missingConfiguration
        }
        defer { payload.resetBytes(in: 0..<payload.count) }

        guard payload.count > header.count, payload.starts(with: header) else {
            throw StoreError.invalidSnapshot
        }
        let combined = Data(payload.dropFirst(header.count))
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw StoreError.invalidSnapshot
        }

        var snapshotData: Data
        do {
            snapshotData = try AES.GCM.open(box, using: loadExistingKey())
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.invalidSnapshot
        }
        defer { snapshotData.resetBytes(in: 0..<snapshotData.count) }

        let snapshot: ResumeConfigSnapshot
        do {
            snapshot = try JSONDecoder().decode(ResumeConfigSnapshot.self, from: snapshotData)
        } catch {
            throw StoreError.invalidSnapshot
        }
        guard snapshot.version == currentVersion,
              !snapshot.generation.isEmpty,
              (1...65_535).contains(snapshot.grpcServiceModePort),
              !snapshot.config.isEmpty else {
            throw StoreError.invalidSnapshot
        }
        if let expectedGeneration, expectedGeneration != snapshot.generation {
            throw StoreError.staleGeneration
        }
        return snapshot
    }

    static func matchesActiveConfig(configPath: String, grpcServiceModePort: Int? = nil) -> Bool {
        guard let snapshot = try? load(),
              let config = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              !config.isEmpty else {
            return false
        }
        return snapshot.config == config &&
            (grpcServiceModePort == nil || snapshot.grpcServiceModePort == grpcServiceModePort)
    }

    static func createPlaintextLease(for snapshot: ResumeConfigSnapshot) throws -> URL {
        cleanupPlaintextLeases()
        try FileManager.default.createDirectory(
            at: FilePath.workingDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let lease = FilePath.workingDirectory.appendingPathComponent(
            "\(leasePrefix)\(snapshot.generation).json",
            isDirectory: false
        )
        try snapshot.config.write(
            to: lease,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        return lease
    }

    static func deletePlaintextLease(_ lease: URL?) {
        guard let lease else { return }
        try? FileManager.default.removeItem(at: lease)
    }

    static func clear() throws {
        try withStoreLock { try clearUnlocked() }
    }

    private static func clearUnlocked() throws {
        cleanupPlaintextLeases()
        var firstError: Error?
        if FileManager.default.fileExists(atPath: storeFile.path) {
            do {
                try FileManager.default.removeItem(at: storeFile)
            } catch {
                firstError = error
            }
        }
        let status = SecItemDelete(try keychainQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound && firstError == nil {
            firstError = StoreError.keychain(status)
        }
        if let firstError { throw firstError }
    }

    static func cleanupPlaintextLeases() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: FilePath.workingDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(leasePrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static var storeDirectory: URL {
        FilePath.sharedDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(storeDirectoryName, isDirectory: true)
    }

    private static var storeFile: URL {
        storeDirectory.appendingPathComponent(storeFileName, isDirectory: false)
    }

    private static func loadOrCreateKey() throws -> SymmetricKey {
        do {
            return try loadExistingKey()
        } catch StoreError.keychain(let status) where status == errSecItemNotFound {
            var keyData = Data(count: 32)
            let randomStatus = keyData.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            guard randomStatus == errSecSuccess else {
                throw StoreError.keychain(randomStatus)
            }
            defer { keyData.resetBytes(in: 0..<keyData.count) }

            var attributes = try keychainQuery()
            attributes[kSecValueData as String] = keyData
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                return try loadExistingKey()
            }
            guard addStatus == errSecSuccess else {
                throw StoreError.keychain(addStatus)
            }
            return SymmetricKey(data: keyData)
        }
    }

    private static func loadExistingKey() throws -> SymmetricKey {
        var query = try keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw StoreError.keychain(status)
        }
        guard var keyData = result as? Data, keyData.count == 32 else {
            throw StoreError.invalidSnapshot
        }
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        return SymmetricKey(data: keyData)
    }

    private static func keychainQuery() throws -> [String: Any] {
        guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: keychainAccessGroupInfoKey) as? String,
              !accessGroup.isEmpty,
              !accessGroup.contains("$(") else {
            throw StoreError.invalidAccessGroup
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: accessGroup
        ]
    }
}
