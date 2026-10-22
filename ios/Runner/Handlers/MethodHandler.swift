//
//  MethodHandler.swift
//  Runner
//
//  Created by GFWFighter on 10/23/23.
//

import Flutter
import Combine
import MartenCore

public class MethodHandler: NSObject, FlutterPlugin {
    
    private var cancelBag: Set<AnyCancellable> = []
    
    public static let name = "\(Bundle.main.serviceIdentifier)/method"
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: Self.name, binaryMessenger: registrar.messenger())
        let instance = MethodHandler()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance.channel = channel
    }
    
    private var channel: FlutterMethodChannel?
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        @Sendable func mainResult(_ res: Any?) async -> Void {
            await MainActor.run {
                result(res)
            }
        }
        
        switch call.method {
        case "get_grpc_server_public_key":
            result("")
        case "add_grpc_client_public_key":
            result("")
        case "parse_config":
            guard
                let args = call.arguments as? [String:Any?],
                let path = args["path"] as? String,
                let tempPath = args["tempPath"] as? String,
                let debug = (args["debug"] as? NSNumber)?.boolValue
            else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            var error: NSError?
            //MobileParse(path, tempPath, debug, &error)
            if let error {
                result(FlutterError(code: String(error.code), message: error.description, details: nil))
                return
            }
            result("")
        case "change_marten_options":
            guard let options = call.arguments as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            VPNConfig.shared.configOptions = options
            result(true)
        case "matches_active_config_generation":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(false)
                return
            }
            result(ResumeConfigStore.matchesActiveConfig(configPath: path))
        case "setup":
                Task {
                    guard
                        let args = call.arguments as? [String: Any?],
                        let baseDir = args["baseDir"] as? String,
                        let workingDir = args["workingDir"] as? String,
                        let tempDir = args["tempDir"] as? String,
                        let mode = args["mode"] as? Int,
                        let grpcPort = args["grpcPort"] as? Int,
                        let debug = (args["debug"] as? NSNumber)?.boolValue
                    else {
                        result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                        return
                    }
                    VPNConfig.shared.baseDir=baseDir
                    VPNConfig.shared.workingDir=workingDir
                    VPNConfig.shared.tempDir=tempDir
                    var error: NSError?
                    MobileSetup(
                        baseDir,
                        workingDir,
                        tempDir,
                        mode,
                        "127.0.0.1:\(grpcPort)",
                        "",
                        debug,
                        nil,
                        &error
                    )
                    
                    if let error {
                        result(FlutterError(code: String(error.code), message: error.localizedDescription, details: nil))
                        return
                    }
                    // Foreground core setup is also required for import and
                    // refresh. NetworkExtension preferences are loaded lazily
                    // by an explicit Connect so an unavailable VPN service
                    // cannot disable the rest of the iOS app.
                    result(true)
                }
        case "prepare_vpn_permission":
            Task {
                do {
                    try await VPNManager.shared.setup()
                    await mainResult(true)
                } catch {
                    await mainResult(FlutterError(code: "VPN_PERMISSION", message: error.localizedDescription, details: nil))
                }
            }
        case "start":
            Task {
                guard
                    let args = call.arguments as? [String:Any?],
                    let path = args["path"] as? String,
                    let name = args["name"] as? String,
                    let grpcPort=args["grpcPort"] as? Int
                else {
                    await mainResult(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                    return
                }
                VPNConfig.shared.activeConfigPath = path
                VPNConfig.shared.activeProfileName = name
                VPNConfig.shared.grpcServiceModePort=grpcPort
                
                var error: NSError?
                //let configstr=MobileBuildConfig(path,&error) as String
                if let error {
                    await mainResult(FlutterError(code: String(error.code), message: error.description, details: nil))
                    return
                }
                #if targetEnvironment(simulator)
                // iOS Simulator uses the host networking stack and cannot run
                // an iPhone Packet Tunnel provider. Fail before touching
                // NetworkExtension so the UI does not surface raw IPC errors
                // or wait for a background core that cannot be launched.
                await mainResult(
                    FlutterError(
                        code: "NETWORK_EXTENSION_UNAVAILABLE",
                        message: "marten:network-extension-unavailable",
                        details: nil
                    )
                )
                return
                #else
                do {
                    try await VPNManager.shared.setup()
                    try await VPNManager.shared.connect(with: path, grpcServiceModePort: grpcPort, disableMemoryLimit: VPNConfig.shared.disableMemoryLimit)
                } catch {
                    await mainResult(FlutterError(code: "SETUP_CONNECTION", message: error.localizedDescription, details: nil))
                    return
                }
                await mainResult(true)
                #endif
            }
//        case "restart":
//            Task { [unowned self] in
//                guard
//                    let args = call.arguments as? [String:Any?],
//                    let path = args["path"] as? String,
//                    let name = args["name"] as? String,
//                    let grpcPort=args["grpcPort"] as? Int
//                else {
//                    await mainResult(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
//                    return
//                }
//                VPNConfig.shared.activeConfigPath = path
//                VPNConfig.shared.activeProfileName = name
//                VPNConfig.shared.grpcServiceModePort=grpcPort
//                
//                
//                VPNManager.shared.disconnect()
//                await waitForStop().value
//                var error: NSError?
//                do {
//                    try await VPNManager.shared.setup()
//                    try await VPNManager.shared.connect(with: path, disableMemoryLimit: VPNConfig.shared.disableMemoryLimit)
//                } catch {
//                    await mainResult(FlutterError(code: "SETUP_CONNECTION", message: error.localizedDescription, details: nil))
//                    return
//                }
//                await mainResult(true)
//            }
        case "stop":
            Task {
                do {
                    try await VPNManager.shared.disconnect()
                    await mainResult(true)
                } catch {
                    await mainResult(FlutterError(code: "STOP_CONNECTION", message: error.localizedDescription, details: nil))
                }
            }
        case "reset":
            Task {
                do {
                    try await VPNManager.shared.reset()
                    await mainResult(true)
                } catch {
                    await mainResult(FlutterError(code: "RESET_CONNECTION", message: error.localizedDescription, details: nil))
                }
            }
        case "url_test":
            guard
                let args = call.arguments as? [String:Any?]
            else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            let group = args["groupTag"] as? String
            FileManager.default.changeCurrentDirectoryPath(FilePath.sharedDirectory.path)
            do {
                try LibboxNewStandaloneCommandClient()?.urlTest(group)
            } catch {
                result(FlutterError(code: "URL_TEST", message: error.localizedDescription, details: nil))
                return
            }
            result(true)
        case "select_outbound":
            guard
                let args = call.arguments as? [String:Any?],
                let group = args["groupTag"] as? String,
                let outbound = args["outboundTag"] as? String
            else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            FileManager.default.changeCurrentDirectoryPath(FilePath.sharedDirectory.path)
            do {
                try LibboxNewStandaloneCommandClient()?.selectOutbound(group, outboundTag: outbound)
            } catch {
                result(FlutterError(code: "SELECT_OUTBOUND", message: error.localizedDescription, details: nil))
                return
            }
            result(true)
        case "generate_config":
            guard
                let args = call.arguments as? [String:Any?],
                let path = args["path"] as? String
            else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            var error: NSError?
//            let config = MobileBuildConfig(path, VPNConfig.shared.configOptions, &error)
//            if let error {
//                result(FlutterError(code: "BUILD_CONFIG", message: error.localizedDescription, details: nil))
//                return
//            }
//            result(config)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func waitForStop() -> Future<Void, Never> {
        return Future { promise in
            var cancellable: AnyCancellable? = nil
            cancellable = VPNManager.shared.$state
                .filter { $0 == .disconnected }
                .first()
                .delay(for: 0.5, scheduler: RunLoop.current)
                .sink(receiveValue: { _ in
                    promise(.success(()))
                    cancellable?.cancel()
                })
        }
    }
}
