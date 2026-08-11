import 'package:firebase_crashlytics/firebase_crashlytics.dart';

abstract interface class CrashReportingBackend {
  Future<void> setCollectionEnabled(bool enabled);

  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required String reason,
    required Iterable<Object> information,
    required bool fatal,
  });

  Future<void> setCustomKey(String key, Object value);

  Future<void> deleteUnsentReports();
}

class FirebaseCrashReportingBackend implements CrashReportingBackend {
  FirebaseCrashReportingBackend([FirebaseCrashlytics? crashlytics])
    : _crashlytics = crashlytics ?? FirebaseCrashlytics.instance;

  final FirebaseCrashlytics _crashlytics;

  @override
  Future<void> setCollectionEnabled(bool enabled) => _crashlytics.setCrashlyticsCollectionEnabled(enabled);

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required String reason,
    required Iterable<Object> information,
    required bool fatal,
  }) => _crashlytics.recordError(
    error,
    stackTrace,
    reason: reason,
    information: information,
    fatal: fatal,
    printDetails: false,
  );

  @override
  Future<void> setCustomKey(String key, Object value) => _crashlytics.setCustomKey(key, value);

  @override
  Future<void> deleteUnsentReports() => _crashlytics.deleteUnsentReports();
}
