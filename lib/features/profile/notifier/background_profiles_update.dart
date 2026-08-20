// ignore_for_file: unreachable_from_main

import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/app_info/app_info_provider.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/core/directories/directories_provider.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/features/connection/data/connection_data_providers.dart';
import 'package:marten/features/profile/data/background_profile_refresh_scope.dart';
import 'package:marten/features/profile/data/profile_auto_update_service.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/features/profile/data/subscription_compatibility.dart';
import 'package:marten/features/profile/notifier/active_profile_notifier.dart';
import 'package:workmanager/workmanager.dart';

const profilesBackgroundRefreshUniqueName = 'subscription-refresh';
const profilesBackgroundRefreshTask = 'app.marten.client.subscription.refresh';
const profilesBackgroundRefreshFrequency = Duration(hours: 1);
const profilesBackgroundRefreshFlex = Duration(minutes: 15);

@pragma('vm:entry-point')
void profilesBackgroundCallbackDispatcher() {
  Workmanager().executeTask(
    (taskName, inputData) async {
      if (!_isProfilesBackgroundRefreshTask(taskName)) return true;
      return _startProfilesBackgroundRefresh();
    },
    onTaskStopped: (taskName, stopReason) async {
      if (!_isProfilesBackgroundRefreshTask(taskName)) return;
      final execution = _activeProfilesBackgroundRefresh;
      if (execution == null) return;
      execution.cancel();
      await execution.result;
    },
  );
}

bool _isProfilesBackgroundRefreshTask(String taskName) =>
    taskName == profilesBackgroundRefreshTask || taskName == Workmanager.iOSBackgroundTask;

_ProfilesBackgroundRefreshExecution? _activeProfilesBackgroundRefresh;

Future<bool> _startProfilesBackgroundRefresh() {
  final activeExecution = _activeProfilesBackgroundRefresh;
  if (activeExecution != null) return activeExecution.result;

  final execution = _ProfilesBackgroundRefreshExecution();
  _activeProfilesBackgroundRefresh = execution;
  return execution.result = _runBackgroundRefresh(cancelToken: execution.cancelToken).whenComplete(() {
    if (identical(_activeProfilesBackgroundRefresh, execution)) {
      _activeProfilesBackgroundRefresh = null;
    }
  });
}

final class _ProfilesBackgroundRefreshExecution {
  final cancelToken = CancelToken();
  late final Future<bool> result;

  void cancel() {
    if (!cancelToken.isCancelled) cancelToken.cancel();
  }
}

Future<void> initializeProfilesBackgroundRefresh({required bool debug}) async {
  if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return;
  if (debug) debugPrint('initializing background subscription refresh');
  await SubscriptionCompatibility.primeAndroidMetadata();
  await Workmanager().initialize(profilesBackgroundCallbackDispatcher);
  await Workmanager().registerPeriodicTask(
    profilesBackgroundRefreshUniqueName,
    profilesBackgroundRefreshTask,
    frequency: profilesBackgroundRefreshFrequency,
    flexInterval: profilesBackgroundRefreshFlex,
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(minutes: 10),
  );
}

Future<bool> _runBackgroundRefresh({CancelToken? cancelToken}) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final scope = BackgroundProfileRefreshScope();
  final container = scope.container;
  try {
    await container.read(appDirectoriesProvider.future);
    await container.read(appInfoProvider.future);
    await container.read(sharedPreferencesProvider.future);
    await container.read(deviceIdentityProvider.future);
    await container.read(profileRepositoryProvider.future);

    final results = await container
        .read(profileAutoUpdateServiceProvider)
        .updateProfiles(validate: false, cancelToken: cancelToken);
    if (cancelToken?.isCancelled ?? false) return false;
    final resumeConfigSynchronized = await syncBackgroundNativeResumeConfig(container);
    return resumeConfigSynchronized && !results.any((result) => result.outcome == ProfileAutoUpdateOutcome.failed);
  } catch (err) {
    debugPrint('background subscription refresh failed (${err.runtimeType})');
    return false;
  } finally {
    await scope.close();
  }
}

Future<bool> syncBackgroundNativeResumeConfig(ProviderContainer container) async {
  if (!Platform.isAndroid) return true;
  try {
    final synchronizer = container.read(nativeResumeConfigSynchronizerProvider);
    final activeProfile = await container.read(activeProfileProvider.future);
    final result = await synchronizer.synchronize(activeProfile).run();
    return result.match((failure) {
      debugPrint('background native resume sync failed (${failure.runtimeType})');
      return false;
    }, (_) => true);
  } catch (error) {
    debugPrint('background native resume sync failed (${error.runtimeType})');
    return false;
  }
}
