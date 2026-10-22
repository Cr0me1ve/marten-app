import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:marten/core/analytics/analytics_filter.dart';
import 'package:marten/core/analytics/analytics_logger.dart';
import 'package:marten/core/analytics/crash_diagnostics.dart';
import 'package:marten/core/network/strict_vpn_egress_gate.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'analytics_controller.g.dart';

// Kept for preference migration compatibility. The setting now controls only
// privacy-safe Firebase Crashlytics reports; Firebase Analytics is not used.
const String enableAnalyticsPrefKey = 'enable_analytics';
const String strictVpnRouteVerifiedPrefKey = 'strict_vpn_route_verified';

bool readCrashReportingEnabledPreference(SharedPreferences preferences) {
  // Missing means the user has never opted out. This deliberately applies to
  // both clean installs and upgrades from the former disabled-by-default
  // behavior. An explicit false remains authoritative.
  return preferences.getBool(enableAnalyticsPrefKey) ?? true;
}

@Riverpod(keepAlive: true)
class AnalyticsController extends _$AnalyticsController with AppLogger {
  static const _platform = MethodChannel('app.marten.client/platform');
  Future<void>? _initialization;
  bool _disposed = false;
  bool _discardExistingReports = false;
  bool _earlyReportsChecked = false;
  bool _optedOut = false;
  @override
  Future<bool> build() async {
    if (!_supportsCrashlytics) {
      crashReporter.setContextCollectionEnabled(false);
      return false;
    }
    _disposed = false;
    crashReporter.onResume = ensureInitialized;
    ref.onDispose(() {
      _disposed = true;
      crashReporter.onResume = null;
    });
    final enabled = readCrashReportingEnabledPreference(_preferences);
    _optedOut = !enabled;
    crashReporter.setContextCollectionEnabled(enabled);
    return enabled;
  }

  SharedPreferences get _preferences => ref.read(sharedPreferencesProvider).requireValue;

  bool get _supportsCrashlytics => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  Future<void> _updateAndroidCoreCollection(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await const MethodChannel('app.marten.client/platform').invokeMethod<void>('set_core_crash_reporting', enabled);
    } catch (_) {
      // Diagnostics availability never changes connection or the saved opt-out.
    }
  }

  Future<void> enableAnalytics() async {
    if (!_supportsCrashlytics) {
      crashReporter.setContextCollectionEnabled(false);
      state = const AsyncData(false);
      return;
    }
    final wasEnabled = readCrashReportingEnabledPreference(_preferences);
    state = const AsyncLoading();
    if (!await _preferences.setBool(enableAnalyticsPrefKey, true)) {
      state = AsyncData(wasEnabled);
      return;
    }
    if (!wasEnabled && Platform.isAndroid) {
      await _platform.invokeMethod<void>('discard_early_crash_reports');
    }
    _optedOut = false;
    _earlyReportsChecked = false;
    _discardExistingReports = _discardExistingReports || !wasEnabled;
    crashReporter.setContextCollectionEnabled(true);
    await _updateAndroidCoreCollection(true);
    await ensureInitialized();
    if (!_disposed && !_optedOut) state = const AsyncData(true);
  }

  /// A single attempt per admission/resume; failures release the future for the
  /// next event. No retry timer, background worker, polling or wake lock.
  Future<void> ensureInitialized({bool refreshNativeReports = false}) {
    if (refreshNativeReports) _earlyReportsChecked = false;
    final active = _initialization;
    if (active != null) return active;
    final start = _initializeReporting();
    _initialization = start;
    return start.whenComplete(() {
      if (identical(_initialization, start)) _initialization = null;
    });
  }

  bool get _canInitialize =>
      !_disposed && !_optedOut && _supportsCrashlytics && readCrashReportingEnabledPreference(_preferences);

  Future<void> _initializeReporting() async {
    if (!_canInitialize || (crashReporter.isEnabled && _earlyReportsChecked)) return;
    try {
      // Persisted route preference alone is not authority after Stop/recovery.
      // Native checks the exact currently verified owner before any SDK access.
      if (Platform.isAndroid && await _platform.invokeMethod<bool>('is_crash_reporting_admitted') != true) {
        await CrashDiagnostics.notePhase('awaiting_verified_vpn');
        return;
      }
      if (!_canInitialize) return;
      await _updateAndroidCoreCollection(true);
      await CrashDiagnostics.notePhase('firebase_initializing');
      await strictVpnEgressGate.run('crash reporting initialization', () async {
        if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      });
      if (!_canInitialize) return;
      await CrashDiagnostics.notePhase('sdk_initializing');
      final ready = await crashReporter.enable(discardExistingReports: _discardExistingReports);
      if (!ready || !_canInitialize) {
        if (_canInitialize) await CrashDiagnostics.notePhase('sdk_enable_failed');
        return;
      }
      await CrashDiagnostics.notePhase('sdk_ready');
      _discardExistingReports = false;
      if (Platform.isAndroid) {
        await _platform.invokeMethod<void>('mark_crash_reporting_ready');
        final early = await _platform.invokeListMethod<dynamic>('read_early_crash_reports') ?? const [];
        final acknowledged = <String>[];
        for (final entry in early) {
          if (!_canInitialize) return;
          final report = Map<String, dynamic>.from(entry as Map);
          final error = SanitizedCrashException(report['type'] as String, report['message'] as String? ?? '');
          final reason = report['reason'] as String;
          await crashReporter.recordError(
            error,
            nativeCrashReportStackTrace(stack: report['stack'] as String, reason: reason, error: error),
            reason: reason,
            fatal: report['fatal'] as bool,
          );
          // Keep native evidence if the SDK failed. A later admission retries.
          if (!crashReporter.isEnabled) return;
          acknowledged.add(report['id'] as String);
        }
        if (_canInitialize) await _platform.invokeMethod<void>('acknowledge_early_crash_reports', acknowledged);
      }
      if (_canInitialize) _earlyReportsChecked = true;
    } catch (error, stackTrace) {
      await CrashDiagnostics.notePhase('initialization_failed');
      loggy.warning('Firebase Crashlytics initialization failed (${error.runtimeType})', error, stackTrace);
    }
  }

  Future<void> disableAnalytics() async {
    if (!_supportsCrashlytics) return;
    // Stop local capture synchronously, before persistence/platform round trips.
    _optedOut = true;
    state = const AsyncLoading();
    final disabling = crashReporter.disable();
    await _preferences.setBool(enableAnalyticsPrefKey, false);
    await _updateAndroidCoreCollection(false);
    await disabling;
    if (!_disposed) state = const AsyncData(false);
  }

  Future<void> recordNonFatal(Object error, StackTrace stackTrace, {required String reason}) =>
      crashReporter.recordError(error, stackTrace, reason: reason);
}
