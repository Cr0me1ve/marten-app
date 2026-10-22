import UIKit
import Flutter
import MartenCore
import UserNotifications
import workmanager_apple

enum AppBadge {
    static func clear() {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        setupFileManager()
        registerBackgroundRefresh()
        AppBadge.clear()
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
        registerHandlers(with: engineBridge.pluginRegistry)
    }
    
    func setupFileManager() {
        try? FileManager.default.createDirectory(at: FilePath.workingDirectory, withIntermediateDirectories: true)
        FileManager.default.changeCurrentDirectoryPath(FilePath.sharedDirectory.path)
    }
    
    func registerHandlers(with registry: FlutterPluginRegistry) {
        MethodHandler.register(with: registry.registrar(forPlugin: MethodHandler.name)!)
        PlatformMethodHandler.register(with: registry.registrar(forPlugin: PlatformMethodHandler.name)!)
        FileMethodHandler.register(with: registry.registrar(forPlugin: FileMethodHandler.name)!)
        StatusEventHandler.register(with: registry.registrar(forPlugin: StatusEventHandler.name)!)
        AlertsEventHandler.register(with: registry.registrar(forPlugin: AlertsEventHandler.name)!)
//        LogsEventHandler.register(with: self.registrar(forPlugin: LogsEventHandler.name)!)
//        GroupsEventHandler.register(with: self.registrar(forPlugin: GroupsEventHandler.name)!)
//        ActiveGroupsEventHandler.register(with: self.registrar(forPlugin: ActiveGroupsEventHandler.name)!)
//        StatsEventHandler.register(with: self.registrar(forPlugin: StatsEventHandler.name)!)
    }

    func registerBackgroundRefresh() {
        WorkmanagerPlugin.setPluginRegistrantCallback { registry in
            GeneratedPluginRegistrant.register(with: registry)
        }
        WorkmanagerPlugin.registerPeriodicTask(
            withIdentifier: "app.marten.client.subscription.refresh",
            frequency: NSNumber(value: 60 * 60)
        )
    }
}
