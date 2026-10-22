//
//  FilePath.swift
//  SingBoxPacketTunnel
//
//  Created by GFWFighter on 7/25/1402 AP.
//

import Foundation

public enum FilePath {
    public static let packageName = {
        Bundle.main.infoDictionary?["BASE_BUNDLE_IDENTIFIER"] as? String ?? "unknown"
    }()
}

public extension FilePath {
    static let groupName = "group.\(packageName)"

    private static let defaultSharedDirectory: URL! = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FilePath.groupName)

    static let sharedDirectory = defaultSharedDirectory!

    static let cacheDirectory = sharedDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Caches", isDirectory: true)

    static let workingDirectory = cacheDirectory.appendingPathComponent("Working", isDirectory: true)

    // Canonical profiles are durable; core scratch files remain in Caches.
    static func prepareProfileStorage(in sharedDirectory: URL) throws -> URL {
        let manager = FileManager.default
        let root = sharedDirectory
            .appendingPathComponent("Library/Application Support/Marten", isDirectory: true)
        let destination = root.appendingPathComponent("configs", isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let legacy = sharedDirectory.appendingPathComponent("Library/Caches/Working/configs", isDirectory: true)
        if manager.fileExists(atPath: legacy.path) {
            let sources = (try? manager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
            for source in sources {
                guard source.pathExtension == "json",
                      UUID(uuidString: source.deletingPathExtension().lastPathComponent) != nil,
                      (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let target = destination.appendingPathComponent(source.lastPathComponent)
                if manager.fileExists(atPath: target.path) { continue }
                do {
                    // moveItem refuses to replace a destination created by another
                    // initializer. Never overwrite a newer canonical generation.
                    try manager.moveItem(at: source, to: target)
                } catch {
                    // Keep the source on failure. One damaged cache entry must
                    // not block startup; the repository can restore its profile.
                    continue
                }
            }
        }
        return root
    }
}

public extension URL {
    var fileName: String {
        var path = relativePath
        if let index = path.lastIndex(of: "/") {
            path = String(path[path.index(index, offsetBy: 1)...])
        }
        return path
    }
}
