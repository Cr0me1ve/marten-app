import 'package:marten/core/model/directories.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:marten/singbox/model/core_status.dart';

sealed class BackgroundCoreSetupResult {
  const BackgroundCoreSetupResult();

  const factory BackgroundCoreSetupResult.readyToStart() = BackgroundCoreReadyToStart;

  const factory BackgroundCoreSetupResult.attached(CoreStatus status) = BackgroundCoreAttached;

  const factory BackgroundCoreSetupResult.failed(CoreStatus status) = BackgroundCoreSetupFailed;

  factory BackgroundCoreSetupResult.fromStatus(CoreStatus status) {
    return switch (status) {
      CoreStopped(alert: null) => const BackgroundCoreSetupResult.readyToStart(),
      CoreStarting() || CoreStarted() => BackgroundCoreSetupResult.attached(status),
      CoreStopping() || CoreStopped() => BackgroundCoreSetupResult.failed(status),
    };
  }
}

final class BackgroundCoreReadyToStart extends BackgroundCoreSetupResult {
  const BackgroundCoreReadyToStart();
}

final class BackgroundCoreAttached extends BackgroundCoreSetupResult {
  const BackgroundCoreAttached(this.status);

  final CoreStatus status;
}

final class BackgroundCoreSetupFailed extends BackgroundCoreSetupResult {
  const BackgroundCoreSetupFailed(this.status);

  final CoreStatus status;
}

class CoreInterface {
  late CoreClient fgClient;
  late CoreClient bgClient;

  /// Unary operations that must not share the long-lived log/status HTTP/2
  /// transport use this client after the background runtime has started.
  CoreClient get backgroundControlClient => bgClient;

  /// Monotonically identifies the Flutter-owned background lifecycle.
  int get backgroundLifecycleGeneration => 0;

  /// Invalidates observers from the previous manual route before the next
  /// route enables any control-plane features.
  void beginBackgroundLifecycle() {}

  Future<String> setup(Directories directories, bool debug, int mode) async {
    return "";
  }

  Future<BackgroundCoreSetupResult> setupBackground(String path, String name, {int? androidVpnStartEpoch}) async {
    return const BackgroundCoreSetupResult.readyToStart();
  }

  /// Establishes the platform fail-closed boundary before a VPN start may do
  /// any configuration or network-capable work.
  Future<int?> claimVpnStartLease() async => null;

  Future<void> cancelVpnStartLease(int token) async {}

  Future<int?> tryJoinVerifiedVpnAdmission() async => null;

  Future<int?> beginVpnStartAdmission({
    bool resumeSession = false,
    int? explicitStartLease,
    bool nativeHandoffClaim = false,
  }) async => null;

  Future<bool> restart(String path, String name) async {
    return false;
  }

  Future<bool> stop() async {
    return false;
  }

  Future<bool> isBgClientAvailable() async {
    return true;
  }

  /// Opens and validates a fresh control transport for the current background
  /// lifecycle. Non-mobile implementations keep their existing client.
  Future<CoreStatus?> refreshBackgroundControlSession(int expectedGeneration) async {
    return const CoreStatus.started();
  }

  bool isSingleChannel() {
    if (!isInitialized()) return false;
    return identical(fgClient, bgClient);
  }

  Future<bool> resetTunnel() async {
    return false;
  }

  Future<bool> notifyBackgroundStarted() async => true;

  Future<bool> storeNativeResumeConfig(String path, String name) async => true;

  Future<bool> clearNativeResumeConfig() async => true;

  Future<bool?> readPlatformStartedByUser() async {
    return null;
  }

  /// True only when an Android-native user entry point stopped this exact
  /// admitted VPN session. Null means native ownership could not be queried.
  Future<bool?> wasVpnUserSessionExplicitlyStopped(int epoch) async => false;

  Future<CoreStatus?> readPlatformServiceStatus() async {
    return null;
  }

  Future<bool> matchesActiveConfigGeneration(String path) async => false;

  Future<int?> tryBeginFlutterRestart() async {
    return 0;
  }

  Future<bool> validateFlutterRestart(int token) async {
    return true;
  }

  Future<void> endFlutterRestart(int token) async {}

  Future<bool> isActiveFg() async {
    return true;
  }

  Future<bool> isActiveBg() async {
    return true;
  }

  Stream<CoreStatus> watchServiceStatus() {
    return const Stream.empty();
  }

  bool isInitialized() {
    return _isForegroundClientInitialized() && _isBackgroundClientInitialized();
  }

  bool _isForegroundClientInitialized() {
    try {
      return _lateFieldInitialized(fgClient);
    } catch (_) {
      return false;
    }
  }

  bool _isBackgroundClientInitialized() {
    try {
      return _lateFieldInitialized(bgClient);
    } catch (_) {
      return false;
    }
  }

  bool _lateFieldInitialized(Object _) => true;
}
