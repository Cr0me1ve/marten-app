import 'package:in_app_update/in_app_update.dart';

class PlayInAppUpdateInfo {
  const PlayInAppUpdateInfo({
    required this.updateAvailable,
    required this.flexibleUpdateAllowed,
    required this.immediateUpdateAllowed,
    required this.readyToInstall,
    required this.immediateUpdateInProgress,
  });

  final bool updateAvailable;
  final bool flexibleUpdateAllowed;
  final bool immediateUpdateAllowed;
  final bool readyToInstall;
  final bool immediateUpdateInProgress;
}

enum PlayInAppUpdateStartResult { accepted, declined, failed }

abstract interface class PlayInAppUpdateApi {
  Future<PlayInAppUpdateInfo> checkForUpdate();

  Future<PlayInAppUpdateStartResult> startFlexibleUpdate();

  Future<PlayInAppUpdateStartResult> performImmediateUpdate();

  Future<void> completeFlexibleUpdate();
}

class GooglePlayInAppUpdateApi implements PlayInAppUpdateApi {
  const GooglePlayInAppUpdateApi();

  @override
  Future<PlayInAppUpdateInfo> checkForUpdate() async {
    final info = await InAppUpdate.checkForUpdate();
    return PlayInAppUpdateInfo(
      updateAvailable: info.updateAvailability == UpdateAvailability.updateAvailable,
      flexibleUpdateAllowed: info.flexibleUpdateAllowed,
      immediateUpdateAllowed: info.immediateUpdateAllowed,
      readyToInstall: info.installStatus == InstallStatus.downloaded,
      immediateUpdateInProgress: info.updateAvailability == UpdateAvailability.developerTriggeredUpdateInProgress,
    );
  }

  @override
  Future<PlayInAppUpdateStartResult> startFlexibleUpdate() async {
    return _mapResult(await InAppUpdate.startFlexibleUpdate());
  }

  @override
  Future<PlayInAppUpdateStartResult> performImmediateUpdate() async {
    return _mapResult(await InAppUpdate.performImmediateUpdate());
  }

  @override
  Future<void> completeFlexibleUpdate() => InAppUpdate.completeFlexibleUpdate();

  PlayInAppUpdateStartResult _mapResult(AppUpdateResult result) => switch (result) {
    AppUpdateResult.success => PlayInAppUpdateStartResult.accepted,
    AppUpdateResult.userDeniedUpdate => PlayInAppUpdateStartResult.declined,
    AppUpdateResult.inAppUpdateFailed => PlayInAppUpdateStartResult.failed,
  };
}
