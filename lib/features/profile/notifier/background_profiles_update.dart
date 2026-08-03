// ignore_for_file: unreachable_from_main

import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/app_info/app_info_provider.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/core/directories/directories_provider.dart';
import 'package:marten/core/model/environment.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/features/profile/data/profile_auto_update_service.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/riverpod_observer.dart';
import 'package:workmanager/workmanager.dart';

const profilesBackgroundRefreshUniqueName = 'subscription-refresh';
const profilesBackgroundRefreshTask = 'app.marten.client.subscription.refresh';
const profilesBackgroundRefreshFrequency = Duration(hours: 1);
const profilesBackgroundRefreshFlex = Duration(minutes: 15);

@pragma('vm:entry-point')
void profilesBackgroundCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != profilesBackgroundRefreshTask && taskName != Workmanager.iOSBackgroundTask) {
      return true;
    }
    return _runBackgroundRefresh();
  });
}

Future<void> initializeProfilesBackgroundRefresh({required bool debug}) async {
  if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return;
  if (debug) debugPrint('initializing background subscription refresh');
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

Future<bool> _runBackgroundRefresh() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final container = ProviderContainer(
    overrides: [environmentProvider.overrideWithValue(Environment.prod)],
    observers: [RiverpodObserver()],
  );
  try {
    await container.read(appDirectoriesProvider.future);
    await container.read(appInfoProvider.future);
    await container.read(sharedPreferencesProvider.future);
    await container.read(deviceIdentityProvider.future);
    await container.read(profileRepositoryProvider.future);

    final results = await container.read(profileAutoUpdateServiceProvider).updateProfiles(validate: false);
    return !results.any((result) => result.outcome == ProfileAutoUpdateOutcome.failed);
  } catch (err) {
    debugPrint('background subscription refresh failed (${err.runtimeType})');
    return false;
  } finally {
    container.dispose();
  }
}
