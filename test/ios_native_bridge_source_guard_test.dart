import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/connection/model/connection_failure.dart';
import 'package:marten/features/profile/notifier/background_profiles_update.dart';

void main() {
  test('iOS native bridge source guard asserts the compatibility API surface', () {
    final extensionPlatformInterfaceSource = File(
      'ios/MartenPacketTunnel/SingBox/ExtensionPlatformInterface.swift',
    ).readAsStringSync();
    final extensionProviderSource = File('ios/MartenPacketTunnel/SingBox/ExtensionProvider.swift').readAsStringSync();
    final methodHandlerSource = File('ios/Runner/Handlers/MethodHandler.swift').readAsStringSync();
    final appDelegateSource = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final vpnManagerSource = File('ios/Runner/VPN/VPNManager.swift').readAsStringSync();
    final sceneDelegate = File('ios/Runner/SceneDelegate.swift');
    final infoPlistSource = File('ios/Runner/Info.plist').readAsStringSync();
    final baseXcconfigSource = File('ios/Base.xcconfig').readAsStringSync();
    final projectPbxSource = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final backgroundRefreshSource = File(
      'lib/features/profile/notifier/background_profiles_update.dart',
    ).readAsStringSync();
    final mobileCoreInterfaceSource = File(
      'lib/martencore/core_interface/core_interface_mobile.dart',
    ).readAsStringSync();
    final pubspecLockSource = File('pubspec.lock').readAsStringSync();

    final compactInterfaceSource = _stripWhitespaceAndComments(extensionPlatformInterfaceSource);
    final compactProviderSource = _stripWhitespaceAndComments(extensionProviderSource);
    final compactMethodSource = _stripWhitespaceAndComments(methodHandlerSource);
    final compactAppDelegateSource = _stripWhitespaceAndComments(appDelegateSource);
    final allSources = '$compactInterfaceSource\n$compactProviderSource\n$compactMethodSource';
    final compactBaseXcconfigSource = _stripWhitespaceAndComments(baseXcconfigSource);

    // Obsolete or build-breaking APIs.
    expect(
      allSources,
      isNot(contains('MobileSetupOptions')),
      reason: 'MobileSetupOptions should be removed from iOS bridge sources',
    );
    expect(allSources, isNot(contains('MobileWake')), reason: 'MobileWake must not remain in the bridge path');
    expect(
      allSources,
      isNot(contains('LibboxConnectionOwner')),
      reason: 'LibboxConnectionOwner should not be referenced in bridge sources',
    );
    expect(
      compactInterfaceSource,
      isNot(
        matches(
          RegExp(
            r'updateDefaultInterface\((?:[^)]*interfaceIndex:[^)]*isExpensive:[^)]*isConstrained:[^)]*)\)',
            multiLine: true,
          ),
        ),
      ),
      reason: 'Old four-argument updateDefaultInterface must be migrated',
    );

    // Obsolete Objective-C-shaped witness declarations must not remain.
    for (final forbidden in const [
      'autoDetectInterfaceControl',
      'usePlatformAutoDetectInterfaceControl',
      'usePlatformInterfaceGetter',
      'sendNotification',
      'packageNameByUid',
      'uidByPackageName',
    ]) {
      expect(
        _hasWitnessDeclaration(compactInterfaceSource, forbidden),
        isFalse,
        reason: 'Obsolete Objective-C-shaped witness should be absent: $forbidden',
      );
    }

    // Current MobileSetup positional API is expected.
    expect(
      _hasMobileSetupWithAtLeastFourArgs(compactMethodSource),
      isTrue,
      reason: 'MethodHandler must call MobileSetup with positional arguments',
    );
    expect(
      _mobileSetupUsesIncomingMode(compactMethodSource),
      isTrue,
      reason: "The setup bridge must pass Flutter's incoming mode to MobileSetup, never a hard-coded background mode",
    );
    expect(
      _hasMobileSetupWithAtLeastFourArgs(compactProviderSource),
      isTrue,
      reason: 'ExtensionProvider must call MobileSetup with positional arguments',
    );

    // Required Libbox platform-interface method names.
    for (final required in const [
      'autoDetectControl',
      'usePlatformAutoDetectControl',
      'usePlatformDefaultInterfaceMonitor',
      'useGetter',
      'send',
      'protectSocket',
      'packageName',
      'uid',
    ]) {
      expect(
        _hasWitnessDeclaration(compactInterfaceSource, required),
        isTrue,
        reason: 'ExtensionPlatformInterface.swift must include required method: $required',
      );
    }

    expect(
      compactBaseXcconfigSource,
      contains('#include"Flutter/Generated.xcconfig"'),
      reason: 'ios/Base.xcconfig must include Flutter/Generated.xcconfig to expose FLUTTER_* variables',
    );

    expect(
      projectPbxSource,
      isNot(contains('DEVELOPMENT_TEAM =')),
      reason: 'public Xcode project must leave the signing team to the developer environment',
    );
    expect(
      projectPbxSource,
      isNot(contains('iPhone Developer')),
      reason: 'Legacy iPhone Developer signing identities must not be hardcoded',
    );
    expect(
      RegExp(
        r'EXCLUDED_ARCHS\s*\[\s*sdk\s*=\s*iphonesimulator\*\s*\]\s*=\s*[^;]*\barm64\b[^;]*;',
        caseSensitive: false,
      ).hasMatch(projectPbxSource),
      isFalse,
      reason: 'Simulator builds must retain arm64; only legacy i386 may be excluded',
    );

    // iOS uses the scheduler identifier itself; Android retains its old WorkManager
    // unique name so updating the iOS identifier does not replace Android work.
    const refreshIdentifier = 'app.marten.client.subscription.refresh';
    const androidLegacyUniqueName = 'subscription-refresh';
    expect(
      _stringConstantValue(backgroundRefreshSource, 'profilesBackgroundRefreshTask'),
      refreshIdentifier,
      reason: 'The Dart background task identifier must match the iOS permitted identifier',
    );
    expect(
      _stringConstantValue(backgroundRefreshSource, 'profilesBackgroundRefreshUniqueName'),
      androidLegacyUniqueName,
      reason: 'Android WorkManager must retain its legacy unique name',
    );
    expect(
      profilesBackgroundRefreshRegistrationName(isIOS: true),
      refreshIdentifier,
      reason: 'iOS must register its background refresh using the exact permitted identifier',
    );
    expect(
      profilesBackgroundRefreshRegistrationName(isIOS: false),
      androidLegacyUniqueName,
      reason: 'Android WorkManager must retain the legacy unique name',
    );
    expect(
      _usesBackgroundRefreshRegistrationHelper(backgroundRefreshSource),
      isTrue,
      reason: 'Workmanager registration must use the platform-specific registration-name helper',
    );
    expect(
      _plistStringArrayValues(infoPlistSource, 'BGTaskSchedulerPermittedIdentifiers'),
      contains(refreshIdentifier),
      reason: 'Info.plist must permit the exact iOS background refresh identifier',
    );
    expect(
      appDelegateSource,
      contains('withIdentifier: "$refreshIdentifier"'),
      reason: 'The native iOS background registration must use the permitted identifier verbatim',
    );

    // Flutter's UIScene lifecycle requires the implicit-engine delegate callback:
    // registration performed against AppDelegate's legacy registrar is not attached
    // to scene-created engines.
    expect(
      compactAppDelegateSource,
      contains('FlutterImplicitEngineDelegate'),
      reason: 'AppDelegate must adopt FlutterImplicitEngineDelegate for UIScene engines',
    );
    expect(
      compactAppDelegateSource,
      contains('didInitializeImplicitFlutterEngine'),
      reason: 'AppDelegate must register plugins when Flutter initializes an implicit engine',
    );
    expect(
      _usesImplicitEngineRegistryForRegistrations(compactAppDelegateSource),
      isTrue,
      reason: 'Generated plugins and Marten handlers must register through the implicit engine registry',
    );
    expect(sceneDelegate.existsSync(), isTrue, reason: 'Runner must provide a SceneDelegate for its UIScene manifest');
    final sceneDelegateSource = sceneDelegate.readAsStringSync();
    expect(
      RegExp(
        r'class\s+SceneDelegate\s*:\s*(?:FlutterSceneDelegate|UIResponder\s*,\s*UIWindowSceneDelegate)',
      ).hasMatch(sceneDelegateSource),
      isTrue,
      reason: 'SceneDelegate.swift must declare the scene delegate named by Info.plist',
    );
    expect(
      _plistHasSceneDelegateManifest(infoPlistSource),
      isTrue,
      reason: 'Info.plist must map the application scene configuration to SceneDelegate',
    );

    expect(
      _lockedPackageVersion(pubspecLockSource, 'file_picker'),
      _isVersionInRange(minimum: const [10, 3, 8], exclusiveMaximumMajor: 11),
      reason: 'file_picker must resolve to 10.3.8 or later but remain below the breaking 11.x API',
    );
    expect(
      _lockedPackageVersion(pubspecLockSource, 'app_links'),
      _isVersionAtLeast(const [7, 0, 0]),
      reason: 'app_links 7+ is required for the UIScene lifecycle integration',
    );

    // KR-124: setup failures must reach MethodHandler so Flutter can report a
    // failed setup/start rather than claiming that a tunnel was created.
    final setupBody = _swiftFunctionBody(vpnManagerSource, 'setup');
    final loadPreferenceBody = _swiftFunctionBody(vpnManagerSource, 'loadVPNPreference');
    final enableManagerBody = _swiftFunctionBody(vpnManagerSource, 'enableVPNManager');
    final connectBody = _swiftFunctionBody(vpnManagerSource, 'connect');
    for (final entry in {
      'setup': setupBody,
      'loadVPNPreference': loadPreferenceBody,
      'enableVPNManager': enableManagerBody,
      'connect': connectBody,
    }.entries) {
      expect(entry.value, isNotEmpty, reason: 'VPNManager must retain its ${entry.key} implementation');
      expect(
        _allSwiftCatchBlocksRethrow(entry.value),
        isTrue,
        reason: 'VPNManager.${entry.key} must propagate, not merely log, critical VPN failures',
      );
    }
    expect(setupBody, contains('try await loadVPNPreference()'));
    expect(loadPreferenceBody, contains('try await NETunnelProviderManager.loadAllFromPreferences()'));
    expect(loadPreferenceBody, contains('try await newManager.saveToPreferences()'));
    expect(loadPreferenceBody, contains('try await newManager.loadFromPreferences()'));
    expect(enableManagerBody, contains('try await manager.saveToPreferences()'));
    expect(enableManagerBody, contains('try await manager.loadFromPreferences()'));
    expect(connectBody, contains('try await enableVPNManager()'));
    expect(connectBody, contains('try manager.connection.startVPNTunnel('));
    final compactConnectBody = _stripWhitespaceAndComments(connectBody);
    final startTunnelPosition = compactConnectBody.indexOf('trymanager.connection.startVPNTunnel(');
    final connectedWaitPosition = compactConnectBody.indexOf('tryawaitwaitForConnected()', startTunnelPosition);
    expect(startTunnelPosition, isNonNegative);
    expect(
      connectedWaitPosition,
      greaterThan(startTunnelPosition),
      reason: 'connect must wait for the observed connected state after issuing the tunnel start',
    );
    expect(
      _stripWhitespaceAndComments(vpnManagerSource),
      contains('NotificationCenter.default.addObserver(forName:.NEVPNStatusDidChange'),
      reason: 'VPN status must come from NetworkExtension state-change notifications',
    );
    expect(
      _stripWhitespaceAndComments(vpnManagerSource),
      contains('self?.state=connection.status'),
      reason: 'the published connection state must mirror the actual NEVPNConnection status',
    );
    expect(
      compactConnectBody.indexOf('tryawaitenableOnDemand()', connectedWaitPosition),
      greaterThan(connectedWaitPosition),
      reason: 'on-demand routing is enabled only after connection state reports connected',
    );
    expect(
      _stripWhitespaceAndComments(mobileCoreInterfaceSource),
      contains('CoreClient(_coreChannel(_portFront,channelOption))'),
      reason: 'the iOS core bridge must retain its gRPC client over the configured foreground channel',
    );

    // A physical NEPacketTunnel must start exactly the config passed from the
    // app.  Treating a missing config as success leaves iOS showing a connected
    // VPN while the core was never started.
    final startTunnelBody = _swiftFunctionBody(extensionProviderSource, 'startTunnel');
    final startServiceBody = _swiftFunctionBody(extensionProviderSource, 'startService1');
    final createDirectoriesBody = _swiftFunctionBody(extensionProviderSource, 'createRequiredDirectories');
    expect(startTunnelBody, isNotEmpty, reason: 'Packet Tunnel must implement startTunnel');
    expect(startServiceBody, isNotEmpty, reason: 'Packet Tunnel must retain the MobileStart bridge');
    expect(
      _packetTunnelRequiresNonEmptyConfig(startTunnelBody),
      isTrue,
      reason: 'Missing or empty Config must throw and fail Packet Tunnel startup',
    );
    expect(
      _countOccurrences(_stripWhitespaceAndComments(extensionProviderSource), 'MobileStart('),
      1,
      reason: 'Packet Tunnel must invoke MobileStart exactly once',
    );
    expect(
      _stripWhitespaceAndComments(startTunnelBody),
      contains('tryawaitstartService1(config)'),
      reason: 'The validated Config must be forwarded to the service startup path',
    );
    expect(
      _stripWhitespaceAndComments(startServiceBody),
      contains('MobileStart(config,'),
      reason: 'The supplied Config must be passed directly to MobileStart',
    );
    expect(
      _stripWhitespaceAndComments(startTunnelBody),
      isNot(matches(RegExp(r'if\(?config==""\)?\{[^}]*startService'))),
      reason: 'An empty Config must never be the condition that starts the service',
    );
    final compactExtensionProviderSource = _stripWhitespaceAndComments(extensionProviderSource);
    expect(
      compactExtensionProviderSource,
      isNot(contains('false&&')),
      reason: 'DisableMemoryLimit must not be permanently masked off',
    );
    expect(
      _stripWhitespaceAndComments(startTunnelBody),
      contains('options?["DisableMemoryLimit"]'),
      reason: 'Packet Tunnel must read DisableMemoryLimit from start options',
    );
    expect(
      _allSwiftCatchBlocksRethrow(startTunnelBody),
      isTrue,
      reason: 'startTunnel directory and MobileSetup failures must throw to NetworkExtension',
    );
    expect(
      _allSwiftCatchBlocksRethrow(createDirectoriesBody),
      isTrue,
      reason: 'createRequiredDirectories must throw instead of cancelling and returning success',
    );
    expect(
      _stripWhitespaceAndComments(startTunnelBody),
      contains('ifletsetupError{throwsetupError}'),
      reason: 'MobileSetup errors must fail Packet Tunnel startup',
    );

    final martenPacketTunnelConfigs = _extractTargetConfigurationIds(projectPbxSource, 'MartenPacketTunnel');
    expect(
      martenPacketTunnelConfigs.length,
      3,
      reason: 'MartenPacketTunnel must define exactly 3 build configurations',
    );

    for (final configId in martenPacketTunnelConfigs) {
      final configBody = _extractObjectBlock(projectPbxSource, configId);
      final buildSettings = _extractBuildSettings(configBody);
      expect(
        buildSettings,
        contains('CURRENT_PROJECT_VERSION = "\$(FLUTTER_BUILD_NUMBER)";'),
        reason: 'MartenPacketTunnel config $configId must use FLUTTER_BUILD_NUMBER',
      );
      expect(
        buildSettings,
        contains('MARKETING_VERSION = "\$(FLUTTER_BUILD_NAME)";'),
        reason: 'MartenPacketTunnel config $configId must use FLUTTER_BUILD_NAME',
      );
    }
  });

  test('iOS launch image variants use the Marten orange mark instead of the legacy blue asset', () async {
    const imageSetPath = 'ios/Runner/Assets.xcassets/LaunchImage.imageset';
    final contents = File('$imageSetPath/Contents.json').readAsStringSync();
    const variants = {'LaunchImage.png': 256, 'LaunchImage@2x.png': 512, 'LaunchImage@3x.png': 768};

    for (final entry in variants.entries) {
      final path = '$imageSetPath/${entry.key}';
      final bytes = File(path).readAsBytesSync();
      expect(bytes.take(8), orderedEquals(const [137, 80, 78, 71, 13, 10, 26, 10]), reason: '$path must be a PNG');
      expect(
        contents,
        contains('"filename" : "${entry.key}"'),
        reason: '$path must be registered by the asset catalog',
      );

      final pixelStats = await _launchImagePixelStats(bytes);
      expect(
        pixelStats.width,
        entry.value,
        reason: '$path must have the expected @${entry.value ~/ 256 + 0}x raster size',
      );
      expect(pixelStats.height, entry.value, reason: '$path must be square at its declared scale');
      expect(
        pixelStats.orangePixels,
        greaterThan(pixelStats.opaquePixels ~/ 20),
        reason: '$path must contain a material amount of Marten orange',
      );
      expect(
        pixelStats.orangePixels,
        greaterThan(pixelStats.bluePixels * 8),
        reason: '$path must not regress to the legacy blue upstream launch asset',
      );
    }
  });

  test('KR-134 privacy manifests are embedded by their owning iOS targets', () {
    final projectPbxSource = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final runnerManifestSource = File('ios/Runner/PrivacyInfo.xcprivacy').readAsStringSync();
    final packetTunnelManifestSource = File('ios/MartenPacketTunnel/PrivacyInfo.xcprivacy').readAsStringSync();

    // The two files intentionally share a display name. Verify their PBX file
    // references and resource build files remain distinct before checking each
    // owning target's resources phase.
    expect(
      _pbxBuildFileReferencesFileRef(
        projectPbxSource,
        buildFileId: 'C1A501102E8D000000000001',
        fileRefId: '68DCEB772BD7DA3F0081FF65',
      ),
      isTrue,
      reason: 'Runner PrivacyInfo.xcprivacy must keep its own PBXBuildFile reference',
    );
    expect(
      _targetResourcesContainBuildFile(projectPbxSource, 'Runner', 'C1A501102E8D000000000001'),
      isTrue,
      reason: 'Runner PrivacyInfo.xcprivacy must be embedded in Runner resources',
    );
    expect(
      _pbxBuildFileReferencesFileRef(
        projectPbxSource,
        buildFileId: 'C1A501112E8D000000000001',
        fileRefId: '68DCEB762BD7D7590081FF65',
      ),
      isTrue,
      reason: 'MartenPacketTunnel PrivacyInfo.xcprivacy must keep its own PBXBuildFile reference',
    );
    expect(
      _targetResourcesContainBuildFile(projectPbxSource, 'MartenPacketTunnel', 'C1A501112E8D000000000001'),
      isTrue,
      reason: 'MartenPacketTunnel PrivacyInfo.xcprivacy must be embedded in extension resources',
    );

    for (final entry in {
      'ios/Runner/PrivacyInfo.xcprivacy': runnerManifestSource,
      'ios/MartenPacketTunnel/PrivacyInfo.xcprivacy': packetTunnelManifestSource,
    }.entries) {
      expect(
        _plistHasTopLevelKey(entry.value, 'NSPrivacyAccessedAPITypes'),
        isTrue,
        reason: '${entry.key} must declare the privacy API-use manifest key',
      );
    }
  });

  test('Network Extension unavailable sentinel does not absorb ordinary connection failures', () {
    expect(looksLikeNetworkExtensionUnavailable('marten:network-extension-unavailable'), isTrue);
    expect(looksLikeNetworkExtensionUnavailable('NETWORK_EXTENSION_UNAVAILABLE'), isTrue);

    expect(looksLikeNetworkExtensionUnavailable('startService failed'), isFalse);
    expect(looksLikeNetworkExtensionUnavailable('network is unreachable'), isFalse);
    expect(looksLikeNetworkExtensionUnavailable('connection timed out while starting core'), isFalse);
  });

  test('iOS permission preparation is separate from start and Stop does not create a VPN profile', () {
    final vpnManagerSource = File('ios/Runner/VPN/VPNManager.swift').readAsStringSync();
    final methodHandlerSource = File('ios/Runner/Handlers/MethodHandler.swift').readAsStringSync();
    final coreInterfaceSource = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();

    final disconnectBody = _stripWhitespaceAndComments(_swiftFunctionBody(vpnManagerSource, 'disconnect'));
    expect(disconnectBody, contains('loadVPNPreference(createIfMissing:false)'));
    expect(
      disconnectBody,
      isNot(contains('NETunnelProviderManager()')),
      reason: 'Stop must not create a NetworkExtension profile',
    );
    expect(
      disconnectBody,
      isNot(contains('saveToPreferences()')),
      reason: 'Stop must not persist a newly created NetworkExtension profile',
    );

    final prepareStart = methodHandlerSource.indexOf('case "prepare_vpn_permission":');
    final startCase = methodHandlerSource.indexOf('case "start":', prepareStart);
    expect(prepareStart, isNonNegative);
    expect(startCase, greaterThan(prepareStart));
    final prepareBody = _stripWhitespaceAndComments(methodHandlerSource.substring(prepareStart, startCase));
    expect(prepareBody, contains('VPNManager.shared.setup()'));
    expect(prepareBody, isNot(contains('VPNManager.shared.connect(')));
    expect(prepareBody, isNot(contains('startVPNTunnel(')));

    final setupBackground = _stripWhitespaceAndComments(_dartFunctionBody(coreInterfaceSource, 'setupBackground'));
    final generationGuard = setupBackground.indexOf('if(startGeneration!=_backgroundLifecycleGeneration)');
    final permissionGate = setupBackground.indexOf('_iosVpnPermission.prepare(');
    final permissionResultGuard = setupBackground.indexOf(
      'if(!allowed||startGeneration!=_backgroundLifecycleGeneration)',
    );
    final startDispatch = setupBackground.indexOf('await_invokeBackgroundStartAndWait(');
    final readinessWait = setupBackground.indexOf('await_waitForBackgroundServiceReady(');
    expect(generationGuard, isNonNegative, reason: 'The start generation must be current before iOS permission UI');
    expect(permissionGate, greaterThan(generationGuard));
    expect(permissionResultGuard, greaterThan(permissionGate));
    expect(startDispatch, greaterThan(permissionResultGuard));
    expect(readinessWait, greaterThan(startDispatch));
  });

  test('iOS native operations have independent deadlines and cannot publish success after Stop', () {
    final extensionSource = File('ios/MartenPacketTunnel/SingBox/ExtensionProvider.swift').readAsStringSync();
    final managerSource = File('ios/Runner/VPN/VPNManager.swift').readAsStringSync();
    final resumeStoreSource = File('ios/Shared/ResumeConfigStore.swift').readAsStringSync();
    final provider = _stripWhitespaceAndComments(extensionSource);
    final manager = _stripWhitespaceAndComments(managerSource);
    final resumeStore = _stripWhitespaceAndComments(resumeStoreSource);
    final operation = _stripWhitespaceAndComments(_swiftFunctionBody(extensionSource, 'nativeOperation'));
    final stop = _stripWhitespaceAndComments(_swiftFunctionBody(extensionSource, 'stopTunnel'));
    final requestStop = _stripWhitespaceAndComments(_swiftFunctionBody(extensionSource, 'requestStop'));
    final deadline = provider.substring(provider.indexOf('privatefinalclassNativeOperationDeadline'));
    final disconnect = _stripWhitespaceAndComments(_swiftFunctionBody(managerSource, 'disconnect'));
    final startTunnel = _stripWhitespaceAndComments(_swiftFunctionBody(extensionSource, 'startTunnel'));
    final recordDeadline = _stripWhitespaceAndComments(_swiftFunctionBody(resumeStoreSource, 'recordNativeDeadline'));
    final store = _stripWhitespaceAndComments(_swiftFunctionBody(resumeStoreSource, 'store'));
    final clear = _stripWhitespaceAndComments(_swiftFunctionBody(resumeStoreSource, 'clear'));

    expect(provider, contains('DispatchQueue(label:"app.marten.client.packet-tunnel.native")'));
    expect(operation, contains('defer{deadline.finish()}'));
    expect(operation, contains('nativeQueue.async'));
    expect(operation, contains('stopRequested&&phase!="stop"'));
    expect(operation, contains('!stopped&&!deadline.hasExpired'));
    expect(provider, contains('nativeOperation(phase:"setup",timeout:15)'));
    expect(provider, contains('nativeOperation(phase:"start",timeout:45)'));
    expect(provider, contains('nativeOperation(phase:"stop",timeout:5)'));
    expect(provider, contains('nativeOperation(phase:"reset",timeout:8)'));
    expect(requestStop, contains('stopRequested=true'));
    expect(stop.indexOf('requestStop()'), lessThan(stop.indexOf('nativeOperation(phase:"stop"')));
    expect(stop, contains('Darwin.kill(Darwin.getpid(),SIGKILL)'));

    expect(deadline, contains('DispatchSource.makeTimerSource'));
    expect(deadline, contains('timer.schedule(deadline:.now()+timeout)'));
    expect(deadline, contains('DispatchQueue.global(qos:.utility).async(execute:cancel)'));
    expect(deadline, contains('Self.queue.asyncAfter(deadline:.now()+1.5)'));
    expect(deadline, contains('Darwin.kill(Darwin.getpid(),SIGKILL)'));
    expect(deadline, contains('ifmustRetire'));
    expect(
      operation.indexOf('ResumeConfigStore.recordNativeDeadline(generation:generation)'),
      lessThan(operation.indexOf('MobileCancelStart()')),
      reason: 'each deadline records its exact recovery generation before asking native code to cancel',
    );
    expect(
      manager,
      isNot(contains('Darwin.kill(')),
      reason: 'deadline retirement may kill the Packet Tunnel extension, never the Runner process',
    );

    expect(manager, contains('providerBundleIdentifier==expectedProvider'));
    expect(manager, contains('configuration.includeAllNetworks=true'));
    expect(manager, contains('configuration.excludeLocalNetworks=false'));
    expect(disconnect.indexOf('awaitdisableOnDemand()'), lessThan(disconnect.indexOf('stopVPNTunnel()')));
    expect(disconnect.indexOf('ResumeConfigStore.clear()'), lessThan(disconnect.indexOf('stopVPNTunnel()')));

    expect(resumeStore, contains('varnativeDeadlineFailures:Int?=nil'));
    expect(recordDeadline, contains('withStoreLock'));
    expect(recordDeadline, contains('nativeDeadlineFailures=(snapshot.nativeDeadlineFailures??0)+1'));
    expect(recordDeadline, contains('AES.GCM.seal(plaintext,using:loadExistingKey())'));
    expect(store, contains('withStoreLock'));
    expect(clear, contains('withStoreLock'));
    expect(startTunnel, contains('(snapshot.nativeDeadlineFailures??0)<2'));
    expect(startTunnel, contains('resumeGeneration=snapshot.generation'));
    expect(resumeStore, contains('letgeneration=UUID().uuidString.lowercased()'));
  });
}

final class _LaunchImagePixelStats {
  const _LaunchImagePixelStats({
    required this.width,
    required this.height,
    required this.opaquePixels,
    required this.orangePixels,
    required this.bluePixels,
  });

  final int width;
  final int height;
  final int opaquePixels;
  final int orangePixels;
  final int bluePixels;
}

Future<_LaunchImagePixelStats> _launchImagePixelStats(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final rawRgba = await image.toByteData();
    if (rawRgba == null) throw StateError('Unable to read decoded launch-image pixels');
    var opaquePixels = 0;
    var orangePixels = 0;
    var bluePixels = 0;
    for (var offset = 0; offset < rawRgba.lengthInBytes; offset += 4) {
      final alpha = rawRgba.getUint8(offset + 3);
      if (alpha < 0x80) continue;
      opaquePixels++;
      final red = rawRgba.getUint8(offset);
      final green = rawRgba.getUint8(offset + 1);
      final blue = rawRgba.getUint8(offset + 2);
      if (red >= 180 && green >= 55 && green <= 190 && blue <= 100 && red > green * 1.25) {
        orangePixels++;
      }
      if (blue >= 130 && blue > red * 1.35 && blue > green * 1.15) {
        bluePixels++;
      }
    }
    return _LaunchImagePixelStats(
      width: image.width,
      height: image.height,
      opaquePixels: opaquePixels,
      orangePixels: orangePixels,
      bluePixels: bluePixels,
    );
  } finally {
    image.dispose();
    codec.dispose();
  }
}

String _swiftFunctionBody(String source, String name) {
  final declaration = source.indexOf('func $name(');
  if (declaration < 0) return '';
  final openingBrace = source.indexOf('{', declaration);
  return _extractBalancedBlock(source, openingBrace);
}

String _dartFunctionBody(String source, String name) {
  final declaration = RegExp('\\b${RegExp.escape(name)}\\s*\\(').firstMatch(source);
  if (declaration == null) return '';
  final bodyMarker = source.indexOf('async {', declaration.end);
  if (bodyMarker < 0) return '';
  final openingBrace = source.indexOf('{', bodyMarker);
  return _extractBalancedBlock(source, openingBrace);
}

bool _allSwiftCatchBlocksRethrow(String functionBody) {
  return RegExp(r'\bcatch\b[^\{]*\{').allMatches(functionBody).every((catchMatch) {
    final openingBrace = functionBody.indexOf('{', catchMatch.start);
    return RegExp(r'\bthrow\b').hasMatch(_extractBalancedBlock(functionBody, openingBrace));
  });
}

bool _packetTunnelRequiresNonEmptyConfig(String startTunnelBody) {
  final compactBody = _stripWhitespaceAndComments(startTunnelBody);
  if (!compactBody.contains('options?["Config"]')) return false;
  return RegExp(r'guard[^{};]*config[^{};]*isEmpty[^{};]*else\{[^}]*throw').hasMatch(compactBody) ||
      RegExp(r'ifconfig[^{};]*isEmpty\{[^}]*throw').hasMatch(compactBody);
}

int _countOccurrences(String source, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var start = 0;
  while (true) {
    final found = source.indexOf(needle, start);
    if (found < 0) return count;
    count++;
    start = found + needle.length;
  }
}

String _stripWhitespaceAndComments(String source) {
  final noBlockComments = source.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final noLineComments = noBlockComments.replaceAll(RegExp('//.*', multiLine: true), '');
  return noLineComments.replaceAll(RegExp(r'\s+'), '');
}

bool _hasWitnessDeclaration(String compactSource, String methodName) {
  return compactSource.contains('func$methodName(');
}

bool _hasMobileSetupWithAtLeastFourArgs(String compactSource) {
  final callPattern = RegExp(r'MobileSetup\(([^\)]*)\)', multiLine: true);
  return callPattern.allMatches(compactSource).any((match) {
    final args = match.group(1) ?? '';
    final argCount = args.split(',').where((part) => part.trim().isNotEmpty).length;
    return argCount >= 4;
  });
}

bool _mobileSetupUsesIncomingMode(String compactSource) {
  final callPattern = RegExp(r'MobileSetup\(([^\)]*)\)', multiLine: true);
  return callPattern.allMatches(compactSource).any((match) {
    final arguments = (match.group(1) ?? '').split(',');
    return arguments.length >= 4 && arguments[3] == 'mode';
  });
}

String? _stringConstantValue(String source, String identifier) {
  final match = RegExp("const\\s+$identifier\\s*=\\s*'([^']+)'\\s*;").firstMatch(source);
  return match?.group(1);
}

bool _usesBackgroundRefreshRegistrationHelper(String source) {
  final compactSource = _stripWhitespaceAndComments(source);
  final registration = RegExp(r'registerPeriodicTask\(([^;]+)\);').firstMatch(compactSource)?.group(1) ?? '';
  return registration.contains('profilesBackgroundRefreshRegistrationName(isIOS:Platform.isIOS)');
}

List<String> _plistStringArrayValues(String plistSource, String key) {
  final match = RegExp('<key>${RegExp.escape(key)}</key>\\s*<array>([\\s\\S]*?)</array>').firstMatch(plistSource);
  if (match == null) return const [];
  return RegExp('<string>([^<]+)</string>').allMatches(match.group(1)!).map((entry) => entry.group(1)!.trim()).toList();
}

bool _usesImplicitEngineRegistryForRegistrations(String compactSource) {
  return compactSource.contains('GeneratedPluginRegistrant.register(with:engineBridge.pluginRegistry)') &&
      compactSource.contains('registerHandlers(with:engineBridge.pluginRegistry)') &&
      RegExp(r'funcregisterHandlers\(withregistry:FlutterPluginRegistry\)').hasMatch(compactSource) &&
      compactSource.contains('registry.registrar(forPlugin:MethodHandler.name)') &&
      compactSource.contains('registry.registrar(forPlugin:PlatformMethodHandler.name)') &&
      compactSource.contains('registry.registrar(forPlugin:FileMethodHandler.name)');
}

bool _plistHasSceneDelegateManifest(String plistSource) {
  return RegExp(
    r'<key>UIApplicationSceneManifest</key>[\s\S]*?<key>UISceneConfigurations</key>[\s\S]*?'
    r'<key>UIWindowSceneSessionRoleApplication</key>[\s\S]*?<key>UISceneDelegateClassName</key>\s*'
    r'<string>\$\(PRODUCT_MODULE_NAME\)\.SceneDelegate</string>',
  ).hasMatch(plistSource);
}

bool _pbxBuildFileReferencesFileRef(String projectSource, {required String buildFileId, required String fileRefId}) {
  final buildFile = _extractObjectBlock(projectSource, buildFileId);
  return buildFile.contains('isa = PBXBuildFile;') && buildFile.contains('fileRef = $fileRefId ');
}

bool _targetResourcesContainBuildFile(String projectSource, String targetName, String buildFileId) {
  final targetMatch = RegExp(
    r'([0-9A-F]{24}) /\* ' + RegExp.escape(targetName) + r' \*/ = \{\s*isa = PBXNativeTarget;',
  ).firstMatch(projectSource);
  if (targetMatch == null) return false;
  final targetBody = _extractObjectBlock(projectSource, targetMatch.group(1)!);
  final resourcesMatch = RegExp(r'([0-9A-F]{24}) /\* Resources \*/').firstMatch(targetBody);
  if (resourcesMatch == null) return false;
  return _extractResourcesBuildPhase(
    projectSource,
    resourcesMatch.group(1)!,
  ).contains('$buildFileId /* PrivacyInfo.xcprivacy in Resources */');
}

String _extractResourcesBuildPhase(String projectSource, String phaseId) {
  final definition = '$phaseId /* Resources */ = {';
  final definitionStart = projectSource.indexOf(definition);
  if (definitionStart < 0) return '';
  return _extractBalancedBlock(projectSource, projectSource.indexOf('{', definitionStart));
}

bool _plistHasTopLevelKey(String plistSource, String key) {
  final plistDictionary = RegExp(r'<plist\b[^>]*>\s*<dict>([\s\S]*?)</dict>\s*</plist>').firstMatch(plistSource);
  return plistDictionary != null && RegExp('<key>${RegExp.escape(key)}</key>').hasMatch(plistDictionary.group(1)!);
}

Matcher _isVersionInRange({required List<int> minimum, required int exclusiveMaximumMajor}) {
  return predicate<String?>((version) {
    final parsed = _parseVersion(version);
    if (parsed == null || parsed[0] >= exclusiveMaximumMajor) return false;
    for (var index = 0; index < minimum.length; index++) {
      if (parsed[index] != minimum[index]) return parsed[index] > minimum[index];
    }
    return true;
  });
}

Matcher _isVersionAtLeast(List<int> minimum) {
  return predicate<String?>((version) {
    final parsed = _parseVersion(version);
    if (parsed == null) return false;
    for (var index = 0; index < minimum.length; index++) {
      if (parsed[index] != minimum[index]) return parsed[index] > minimum[index];
    }
    return true;
  });
}

List<int>? _parseVersion(String? version) {
  if (version == null) return null;
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$').firstMatch(version);
  return match == null ? null : [for (var index = 1; index <= 3; index++) int.parse(match.group(index)!)];
}

String? _lockedPackageVersion(String lockSource, String package) {
  final match = RegExp(
    '^  ${RegExp.escape(package)}:' + r'\n(?:    .*\n)*?    version: "?([^"\n]+)"?$',
    multiLine: true,
  ).firstMatch(lockSource);
  return match?.group(1);
}

List<String> _extractTargetConfigurationIds(String source, String targetName) {
  final targetListRegex = RegExp(
    r'([0-9A-F]{24}) /\* Build configuration list for PBXNativeTarget "' +
        RegExp.escape(targetName) +
        r'" \*/ = \{([\s\S]*?)\n[ \t]*\};',
    multiLine: true,
  );
  final targetListMatch = targetListRegex.firstMatch(source);
  if (targetListMatch == null) {
    return const [];
  }
  final listBlock = targetListMatch.group(2) ?? '';
  return RegExp(r'([0-9A-F]{24}) /\*').allMatches(listBlock).map((m) => m.group(1)!).toList();
}

String _extractObjectBlock(String source, String objectId) {
  final objectStart = source.indexOf('$objectId /*');
  if (objectStart < 0) {
    return '';
  }
  final braceStart = source.indexOf('{', objectStart);
  if (braceStart < 0) {
    return '';
  }
  return _extractBalancedBlock(source, braceStart);
}

String _extractBuildSettings(String objectBody) {
  final buildSettingsStart = objectBody.indexOf('buildSettings = {');
  if (buildSettingsStart < 0) {
    return '';
  }
  final braceStart = objectBody.indexOf('{', buildSettingsStart);
  return _extractBalancedBlock(objectBody, braceStart);
}

String _extractBalancedBlock(String source, int startBraceIndex) {
  if (startBraceIndex < 0) {
    return '';
  }
  var depth = 0;
  for (var i = startBraceIndex; i < source.length; i++) {
    if (source.codeUnitAt(i) == 0x7B) {
      depth++;
    } else if (source.codeUnitAt(i) == 0x7D) {
      depth--;
      if (depth == 0) {
        return source.substring(startBraceIndex, i + 1);
      }
    }
  }
  return '';
}
