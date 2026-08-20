import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/app_update/data/play_in_app_update_api.dart';
import 'package:marten/features/app_update/notifier/play_in_app_update_notifier.dart';

void main() {
  group('PlayInAppUpdateNotifier', () {
    test('marks unavailable when Google Play has no update', () async {
      final api = _FakePlayInAppUpdateApi(info: _info());
      final notifier = PlayInAppUpdateNotifier(api);

      await notifier.checkOnLaunch();

      expect(notifier.state, PlayInAppUpdateState.unavailable);
      expect(api.checkCalls, 1);
    });

    test('accepts a flexible update and makes it ready to install', () async {
      final api = _FakePlayInAppUpdateApi(
        info: _info(updateAvailable: true, flexibleUpdateAllowed: true),
      );
      final notifier = PlayInAppUpdateNotifier(api);

      await notifier.checkOnLaunch();

      expect(notifier.state, PlayInAppUpdateState.readyToInstall);
      expect(api.flexibleCalls, 1);
    });

    for (final result in [PlayInAppUpdateStartResult.declined, PlayInAppUpdateStartResult.failed]) {
      test('preserves a flexible update $result result', () async {
        final api = _FakePlayInAppUpdateApi(
          info: _info(updateAvailable: true, flexibleUpdateAllowed: true),
          flexibleResult: result,
        );
        final notifier = PlayInAppUpdateNotifier(api);

        await notifier.checkOnLaunch();

        expect(
          notifier.state,
          result == PlayInAppUpdateStartResult.declined ? PlayInAppUpdateState.declined : PlayInAppUpdateState.failed,
        );
      });
    }

    test('restores a previously downloaded flexible update as ready to install', () async {
      final api = _FakePlayInAppUpdateApi(info: _info(readyToInstall: true));
      final notifier = PlayInAppUpdateNotifier(api);

      await notifier.checkOnLaunch();

      expect(notifier.state, PlayInAppUpdateState.readyToInstall);
      expect(api.flexibleCalls, 0);
      expect(api.immediateCalls, 0);
    });

    for (final scenario in [
      (name: 'falls back to immediate when flexible is unavailable', inProgress: false),
      (name: 'resumes an immediate update already in progress', inProgress: true),
    ]) {
      test(scenario.name, () async {
        final api = _FakePlayInAppUpdateApi(
          info: _info(
            updateAvailable: !scenario.inProgress,
            immediateUpdateAllowed: !scenario.inProgress,
            immediateUpdateInProgress: scenario.inProgress,
          ),
        );
        final notifier = PlayInAppUpdateNotifier(api);

        await notifier.checkOnLaunch();

        expect(notifier.state, PlayInAppUpdateState.installing);
        expect(api.immediateCalls, 1);
      });
    }

    test('does not check Google Play more than once per notifier lifetime', () async {
      final api = _FakePlayInAppUpdateApi(info: _info());
      final notifier = PlayInAppUpdateNotifier(api);

      await notifier.checkOnLaunch();
      await notifier.checkOnLaunch();

      expect(api.checkCalls, 1);
    });

    test('records immediate update declines and failures', () async {
      for (final result in [PlayInAppUpdateStartResult.declined, PlayInAppUpdateStartResult.failed]) {
        final api = _FakePlayInAppUpdateApi(
          info: _info(updateAvailable: true, immediateUpdateAllowed: true),
          immediateResult: result,
        );
        final notifier = PlayInAppUpdateNotifier(api);

        await notifier.checkOnLaunch();

        expect(
          notifier.state,
          result == PlayInAppUpdateStartResult.declined ? PlayInAppUpdateState.declined : PlayInAppUpdateState.failed,
        );
      }
    });

    test('completes a downloaded flexible update and keeps installing state on success', () async {
      final api = _FakePlayInAppUpdateApi(info: _info(readyToInstall: true));
      final notifier = PlayInAppUpdateNotifier(api);
      await notifier.checkOnLaunch();

      await notifier.completeFlexibleUpdate();

      expect(notifier.state, PlayInAppUpdateState.installing);
      expect(api.completeCalls, 1);
    });

    test('returns to ready state when completing a flexible update fails', () async {
      final api = _FakePlayInAppUpdateApi(info: _info(readyToInstall: true), completeError: Exception('failed'));
      final notifier = PlayInAppUpdateNotifier(api);
      await notifier.checkOnLaunch();

      await notifier.completeFlexibleUpdate();

      expect(notifier.state, PlayInAppUpdateState.readyToInstall);
      expect(api.completeCalls, 1);
    });
  });
}

PlayInAppUpdateInfo _info({
  bool updateAvailable = false,
  bool flexibleUpdateAllowed = false,
  bool immediateUpdateAllowed = false,
  bool readyToInstall = false,
  bool immediateUpdateInProgress = false,
}) => PlayInAppUpdateInfo(
  updateAvailable: updateAvailable,
  flexibleUpdateAllowed: flexibleUpdateAllowed,
  immediateUpdateAllowed: immediateUpdateAllowed,
  readyToInstall: readyToInstall,
  immediateUpdateInProgress: immediateUpdateInProgress,
);

class _FakePlayInAppUpdateApi implements PlayInAppUpdateApi {
  _FakePlayInAppUpdateApi({
    required this.info,
    this.flexibleResult = PlayInAppUpdateStartResult.accepted,
    this.immediateResult = PlayInAppUpdateStartResult.accepted,
    this.completeError,
  });

  final PlayInAppUpdateInfo info;
  final PlayInAppUpdateStartResult flexibleResult;
  final PlayInAppUpdateStartResult immediateResult;
  final Object? completeError;
  int checkCalls = 0;
  int flexibleCalls = 0;
  int immediateCalls = 0;
  int completeCalls = 0;

  @override
  Future<PlayInAppUpdateInfo> checkForUpdate() async {
    checkCalls++;
    return info;
  }

  @override
  Future<void> completeFlexibleUpdate() async {
    completeCalls++;
    if (completeError != null) throw completeError!;
  }

  @override
  Future<PlayInAppUpdateStartResult> performImmediateUpdate() async {
    immediateCalls++;
    return immediateResult;
  }

  @override
  Future<PlayInAppUpdateStartResult> startFlexibleUpdate() async {
    flexibleCalls++;
    return flexibleResult;
  }
}
