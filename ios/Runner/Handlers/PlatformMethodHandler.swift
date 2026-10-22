//
//  PlatformMethodHandler.swift
//  Runner
//
//  Created by Marten on 12/27/23.
//

import Flutter
import Combine
import MartenCore

public class PlatformMethodHandler: NSObject, FlutterPlugin {
        
    public static let name = "\(Bundle.main.serviceIdentifier)/platform"
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: Self.name, binaryMessenger: registrar.messenger())
        let instance = PlatformMethodHandler()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance.channel = channel
    }
    
    private var channel: FlutterMethodChannel?
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "get_paths":
            do {
                result(try getPaths(args: call.arguments) as NSDictionary)
            } catch {
                result(FlutterError(code: "profile_storage_unavailable", message: "Profile storage is unavailable", details: nil))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    public func getPaths(args: Any?) throws -> [String:String] {
        _ = try FilePath.prepareProfileStorage(in: FilePath.sharedDirectory)
        return [
            "base": FilePath.sharedDirectory.path,
            "working": FilePath.workingDirectory.path,
            "temp": FilePath.cacheDirectory.path
        ]
    }
}
