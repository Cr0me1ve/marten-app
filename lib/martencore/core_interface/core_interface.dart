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

  Future<String> setup(Directories directories, bool debug, int mode) async {
    return "";
  }

  Future<BackgroundCoreSetupResult> setupBackground(String path, String name) async {
    return const BackgroundCoreSetupResult.readyToStart();
  }

  Future<bool> restart(String path, String name) async {
    return false;
  }

  Future<bool> stop() async {
    return false;
  }

  Future<bool> isBgClientAvailable() async {
    return true;
  }

  bool isSingleChannel() {
    // return true;
    return fgClient == bgClient;
  }

  Future<bool> resetTunnel() async {
    return false;
  }

  Future<bool> notifyBackgroundStarted() async => true;

  Future<bool?> readPlatformStartedByUser() async {
    return null;
  }

  Future<CoreStatus?> readPlatformServiceStatus() async {
    return null;
  }

  Future<int?> tryBeginFlutterRestart() async {
    return 0;
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
    try {
      return _lateFieldInitialized(bgClient);
    } catch (_) {
      return false;
    }
  }

  bool _lateFieldInitialized(Object _) => true;
}
