import 'dart:async';

import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/notification/in_app_notification_controller.dart';
import 'package:marten/core/preferences/general_preferences.dart';
import 'package:marten/features/profile/data/profile_auto_update_service.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:meta/meta.dart';
import 'package:neat_periodic_task/neat_periodic_task.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profiles_update_notifier.g.dart';

typedef ProfileUpdateStatus = ({String name, bool success});

@Riverpod(keepAlive: true)
class ForegroundProfilesUpdateNotifier extends _$ForegroundProfilesUpdateNotifier with AppLogger {
  static const interval = Duration(minutes: 15);
  static const initialStartupDelay = Duration(seconds: 45);

  @override
  Stream<ProfileUpdateStatus?> build() {
    var cycleCount = 0;
    _scheduler = NeatPeriodicTaskScheduler(
      name: 'profiles update worker',
      interval: interval,
      timeout: const Duration(minutes: 5),
      task: () async {
        loggy.debug("cycle [${cycleCount++}]");
        await updateProfiles();
      },
    );

    ref.onDispose(() async {
      _initialStartTimer?.cancel();
      if (_schedulerStarted) {
        await _scheduler?.stop();
      }
      _scheduler = null;
    });

    if (ref.watch(Preferences.introCompleted)) {
      loggy.debug("intro done, deferring startup maintenance");
      _initialStartTimer = Timer(initialStartupDelay, () {
        final scheduler = _scheduler;
        if (scheduler == null || _schedulerStarted) return;
        _schedulerStarted = true;
        scheduler.start();
      });
    } else {
      loggy.debug("intro in process, skipping");
    }
    return const Stream.empty();
  }

  NeatPeriodicTaskScheduler? _scheduler;
  Timer? _initialStartTimer;
  bool _schedulerStarted = false;
  bool _forceNextRun = false;

  Future<void> trigger() async {
    loggy.debug("triggering update");
    _forceNextRun = true;
    if (_scheduler == null) {
      await updateProfiles();
      return;
    }
    await _scheduler!.trigger();
  }

  Future<void> checkDueNow() async {
    loggy.debug("triggering due update check");
    if (_scheduler == null) {
      await updateProfiles();
      return;
    }
    await _scheduler!.trigger();
  }

  @visibleForTesting
  Future<void> updateProfiles() async {
    var force = false;
    if (_forceNextRun) {
      force = true;
      _forceNextRun = false;
    }

    loggy.debug("${force ? "[FORCED] " : ""}running profile update check");
    final results = await ref.read(profileAutoUpdateServiceProvider).updateProfiles(force: force);
    if (!force) return;

    final t = ref.read(translationsProvider).requireValue;
    final notification = ref.read(inAppNotificationControllerProvider);
    for (final result in results) {
      switch (result.outcome) {
        case ProfileAutoUpdateOutcome.updated:
          notification.showSuccessToast(t.pages.profiles.msg.update.successNamed(name: result.name));
          state = AsyncData((name: result.name, success: true));
        case ProfileAutoUpdateOutcome.failed:
          notification.showErrorToast(t.pages.profiles.msg.update.failureNamed(name: result.name));
          state = AsyncData((name: result.name, success: false));
        case ProfileAutoUpdateOutcome.skipped:
          break;
      }
    }
  }
}
