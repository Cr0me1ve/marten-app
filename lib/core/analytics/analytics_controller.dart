import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:marten/core/analytics/analytics_logger.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'analytics_controller.g.dart';

// Kept for preference migration compatibility. The setting now controls only
// privacy-safe Firebase Crashlytics reports; Firebase Analytics is not used.
const String enableAnalyticsPrefKey = 'enable_analytics';

@Riverpod(keepAlive: true)
class AnalyticsController extends _$AnalyticsController with AppLogger {
  @override
  Future<bool> build() async {
    if (!_supportsCrashlytics) {
      crashReporter.setContextCollectionEnabled(false);
      return false;
    }
    final enabled = _preferences.getBool(enableAnalyticsPrefKey) ?? false;
    crashReporter.setContextCollectionEnabled(enabled);
    return enabled;
  }

  SharedPreferences get _preferences => ref.read(sharedPreferencesProvider).requireValue;

  bool get _supportsCrashlytics => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  Future<void> enableAnalytics() async {
    if (!_supportsCrashlytics) {
      crashReporter.setContextCollectionEnabled(false);
      state = const AsyncData(false);
      return;
    }
    if (state case AsyncData(value: final enabled)) {
      loggy.debug('enabling privacy-safe crash reporting');
      state = const AsyncLoading();
      if (!enabled) {
        await _preferences.setBool(enableAnalyticsPrefKey, true);
      }
      crashReporter.setContextCollectionEnabled(true);

      try {
        if (Firebase.apps.isEmpty) await Firebase.initializeApp();
        await crashReporter.enable(discardExistingReports: !enabled);
      } catch (error, stackTrace) {
        loggy.warning('Firebase Crashlytics initialization failed (${error.runtimeType})', error, stackTrace);
      }

      state = const AsyncData(true);
    }
  }

  Future<void> disableAnalytics() async {
    if (state case AsyncData()) {
      loggy.debug('disabling crash reporting');
      state = const AsyncLoading();
      await _preferences.setBool(enableAnalyticsPrefKey, false);
      await crashReporter.disable();
      state = const AsyncData(false);
    }
  }

  Future<void> recordNonFatal(Object error, StackTrace stackTrace, {required String reason}) =>
      crashReporter.recordError(error, stackTrace, reason: reason);
}
