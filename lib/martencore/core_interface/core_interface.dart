import 'package:marten/core/model/directories.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:marten/singbox/model/core_status.dart';

class CoreInterface {
  late CoreClient fgClient;
  late CoreClient bgClient;

  Future<String> setup(Directories directories, bool debug, int mode) async {
    return "";
  }

  Future<CoreStatus> setupBackground(String path, String name) async {
    return const CoreStarted();
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
