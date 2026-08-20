import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/features/app_update/data/play_in_app_update_api.dart';
import 'package:marten/utils/utils.dart';

enum PlayInAppUpdateState { idle, checking, downloading, readyToInstall, installing, unavailable, declined, failed }

final playInAppUpdateApiProvider = Provider<PlayInAppUpdateApi>((ref) => const GooglePlayInAppUpdateApi());

final playInAppUpdateNotifierProvider = StateNotifierProvider<PlayInAppUpdateNotifier, PlayInAppUpdateState>(
  (ref) => PlayInAppUpdateNotifier(ref.watch(playInAppUpdateApiProvider)),
);

class PlayInAppUpdateNotifier extends StateNotifier<PlayInAppUpdateState> with AppLogger {
  PlayInAppUpdateNotifier(this._api) : super(PlayInAppUpdateState.idle);

  final PlayInAppUpdateApi _api;
  bool _hasChecked = false;

  Future<void> checkOnLaunch() async {
    if (_hasChecked) return;
    _hasChecked = true;
    state = PlayInAppUpdateState.checking;

    try {
      final info = await _api.checkForUpdate();
      if (info.readyToInstall) {
        state = PlayInAppUpdateState.readyToInstall;
        return;
      }

      if (info.immediateUpdateInProgress) {
        await _runImmediateUpdate();
        return;
      }

      if (!info.updateAvailable) {
        state = PlayInAppUpdateState.unavailable;
        return;
      }

      if (info.flexibleUpdateAllowed) {
        state = PlayInAppUpdateState.downloading;
        final result = await _api.startFlexibleUpdate();
        state = switch (result) {
          PlayInAppUpdateStartResult.accepted => PlayInAppUpdateState.readyToInstall,
          PlayInAppUpdateStartResult.declined => PlayInAppUpdateState.declined,
          PlayInAppUpdateStartResult.failed => PlayInAppUpdateState.failed,
        };
        return;
      }

      if (info.immediateUpdateAllowed) {
        await _runImmediateUpdate();
        return;
      }

      state = PlayInAppUpdateState.unavailable;
    } catch (error, stackTrace) {
      loggy.warning('Google Play in-app update check failed', error, stackTrace);
      state = PlayInAppUpdateState.failed;
    }
  }

  Future<void> completeFlexibleUpdate() async {
    if (state != PlayInAppUpdateState.readyToInstall) return;
    state = PlayInAppUpdateState.installing;
    try {
      await _api.completeFlexibleUpdate();
    } catch (error, stackTrace) {
      loggy.warning('Google Play in-app update installation failed', error, stackTrace);
      state = PlayInAppUpdateState.readyToInstall;
    }
  }

  Future<void> _runImmediateUpdate() async {
    state = PlayInAppUpdateState.installing;
    final result = await _api.performImmediateUpdate();
    state = switch (result) {
      PlayInAppUpdateStartResult.accepted => PlayInAppUpdateState.installing,
      PlayInAppUpdateStartResult.declined => PlayInAppUpdateState.declined,
      PlayInAppUpdateStartResult.failed => PlayInAppUpdateState.failed,
    };
  }
}
