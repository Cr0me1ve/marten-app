import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loggy/loggy.dart';
import 'package:marten/core/analytics/analytics_filter.dart';
import 'package:marten/core/analytics/analytics_logger.dart';
import 'package:marten/core/analytics/crash_reporting_backend.dart';
import 'package:marten/core/analytics/pending_crash_report.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('marten-crash-reports-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('persists redacted early errors and replays after reporter recreation', () async {
    final store = FilePendingCrashReportStore(directory);
    final first = CrashlyticsLoggyIntegration();
    await first.configureLocalCapture(store: store, enabled: true);
    first.onLog(
      LogRecord(
        LogLevel.error,
        'Flutter Error: failed for person@example.com token=${'s' * 40}',
        'app',
        StateError('failure for person@example.com token=${'s' * 40}'),
      ),
    );
    await first.flush();

    final persisted = await FilePendingCrashReportStore(directory).load();
    expect(persisted, hasLength(1));
    expect(persisted.values.single.timestampMs, greaterThan(0));
    final reportFile = File('${directory.path}/report_0.json');
    final onDisk = await reportFile.readAsString();
    expect(onDisk, isNot(contains('person@example.com')));
    expect(onDisk, isNot(contains('s' * 40)));
    expect(onDisk, contains('[redacted-email]'));
    expect(onDisk, contains('[redacted-token]'));

    final backend = RecordingBackend();
    final recreated = CrashlyticsLoggyIntegration(backend: backend);
    await recreated.configureLocalCapture(store: store, enabled: true);
    expect(await recreated.enable(), isTrue);
    await recreated.flush();

    expect(backend.reports, hasLength(1));
    final report = backend.reports.single;
    final delivered = '${report.error} ${report.reason} ${report.information.join(' ')}';
    expect(delivered, isNot(contains('person@example.com')));
    expect(delivered, isNot(contains('s' * 40)));
    expect(delivered, contains('[redacted-email]'));
    expect(delivered, contains('[redacted-token]'));
    expect(await store.load(), isEmpty);
  });

  test('bounds the persistent queue and ignores errors beyond its capacity', () async {
    final store = FilePendingCrashReportStore(directory);
    final reporter = CrashlyticsLoggyIntegration();
    await reporter.configureLocalCapture(store: store, enabled: true);

    for (var index = 0; index < pendingCrashReportLimit + 3; index++) {
      reporter.onLog(LogRecord(LogLevel.error, 'early failure $index', 'test', StateError('failure $index')));
    }
    await reporter.flush();

    final reports = await store.load();
    expect(reports, hasLength(pendingCrashReportLimit));
    expect(reports.values.map((report) => report.error.message), contains('Bad state: failure 0'));
    expect(reports.values.map((report) => report.error.message), isNot(contains('Bad state: failure 16')));
    expect(await directory.list().length, pendingCrashReportLimit);
  });

  test('retains one bounded fatal record after pending delivery removal and clears it on opt-out', () async {
    final store = FilePendingCrashReportStore(directory);
    final report = PendingCrashReport(
      error: const SanitizedCrashException('StateError', 'fatal marker'),
      stack: StackTrace.fromString('#0      native frame'),
      reason: 'fatal test',
      context: const <String>['context line'],
      fatal: true,
      timestampMs: 123456,
    );
    final oversized = PendingCrashReport(
      error: const SanitizedCrashException('StateError', 'oversized fatal marker'),
      stack: StackTrace.fromString('x'),
      reason: 'oversized',
      context: const <String>[],
      fatal: true,
      timestampMs: 987654,
    );
    final oversizedReport = PendingCrashReport(
      error: oversized.error,
      stack: StackTrace.fromString('x' * FilePendingCrashReportStore.maxReportBytes),
      reason: oversized.reason,
      context: oversized.context,
      fatal: oversized.fatal,
      timestampMs: oversized.timestampMs,
    );

    await store.write(0, report);
    await store.retainFatal(report);
    await store.remove(0);

    final lastFatalFile = File('${directory.path}/last-fatal.json');
    expect(await store.load(), isEmpty);
    expect(await lastFatalFile.exists(), isTrue);
    expect(await lastFatalFile.length(), lessThanOrEqualTo(FilePendingCrashReportStore.maxReportBytes));
    expect((await store.readLastFatal())?.timestampMs, report.timestampMs);

    await store.retainFatal(oversizedReport);
    expect((await store.readLastFatal())?.timestampMs, report.timestampMs);

    await store.clear();
    expect(await store.readLastFatal(), isNull);
    expect(await lastFatalFile.exists(), isFalse);
  });

  test('archives a fatal report locally while an enabled SDK backend also receives it', () async {
    final store = FilePendingCrashReportStore(directory);
    final backend = RecordingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);
    await reporter.configureLocalCapture(store: store, enabled: true);
    expect(await reporter.enable(), isTrue);

    await reporter.recordError(
      StateError('fatal marker'),
      StackTrace.fromString(
        '#0      app.marten.client.MainActivity.onCreate (package:marten/native_startup/native.dart:57:1)',
      ),
      reason: 'fatal evidence test',
      fatal: true,
    );
    await reporter.flush();

    expect(backend.reports, hasLength(1));
    expect(backend.reports.single.fatal, isTrue);
    expect(await store.load(), isEmpty);
    final retained = await store.readLastFatal();
    expect(retained, isNotNull);
    expect(retained!.timestampMs, greaterThan(0));
    expect(retained.stack.toString(), contains('app.marten.client.MainActivity.onCreate'));

    final snapshot = await reporter.localEvidenceSnapshot();
    expect(snapshot, contains('MARTEN_FLUTTER_LOCAL_FATAL status=available timestamp_ms=${retained.timestampMs}'));
    expect(snapshot, contains('type=StateError'));
    expect(snapshot, contains('app.marten.client.MainActivity.onCreate'));

    await reporter.configureLocalCapture(store: store, enabled: false);
    expect(await reporter.localEvidenceSnapshot(), 'MARTEN_FLUTTER_LOCAL_FATAL status=disabled');
    expect(await store.readLastFatal(), isNull);
  });

  test('opt-out clears saved reports and cancels queued local captures', () async {
    final store = FilePendingCrashReportStore(directory);
    final reporter = CrashlyticsLoggyIntegration();
    await reporter.configureLocalCapture(store: store, enabled: true);
    reporter.onLog(LogRecord(LogLevel.error, 'queued failure', 'test', StateError('queued failure')));
    await reporter.configureLocalCapture(store: store, enabled: false);
    await reporter.flush();

    expect(await store.load(), isEmpty);
    expect(reporter.contextSnapshot, isEmpty);
  });

  test('failed backend admission is retryable and concurrent admission coalesces', () async {
    final backend = RecordingBackend(failCollectionEnableOnce: true);
    final reporter = CrashlyticsLoggyIntegration(backend: backend);
    await reporter.configureLocalCapture(store: FilePendingCrashReportStore(directory), enabled: true);
    reporter.onLog(LogRecord(LogLevel.error, 'saved while backend is down', 'test', StateError('offline')));
    await reporter.flush();

    expect(await reporter.enable(), isFalse);
    expect(reporter.isEnabled, isFalse);
    final firstEnable = reporter.enable();
    final secondEnable = reporter.enable();
    expect(await Future.wait(<Future<bool>>[firstEnable, secondEnable]), everyElement(isTrue));
    await reporter.flush();

    expect(backend.collectionEnableCalls, 2);
    expect(backend.reports, hasLength(1));
    expect(reporter.isEnabled, isTrue);
  });

  test('resume retries failed admission without a timer or polling loop', () async {
    final backend = RecordingBackend(failCollectionEnableOnce: true);
    final reporter = CrashlyticsLoggyIntegration(backend: backend);
    await reporter.configureLocalCapture(store: FilePendingCrashReportStore(directory), enabled: true);
    reporter.onResume = () => reporter.enable();

    expect(await reporter.enable(), isFalse);
    reporter.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await reporter.flush();

    expect(reporter.isEnabled, isTrue);
    expect(backend.collectionEnableCalls, 2);
  });

  test('failed delivery remains local and is replayed by the next explicit admission', () async {
    final backend = RecordingBackend(failRecordOnce: true);
    final store = FilePendingCrashReportStore(directory);
    final reporter = CrashlyticsLoggyIntegration(backend: backend);
    await reporter.configureLocalCapture(store: store, enabled: true);
    expect(await reporter.enable(), isTrue);

    reporter.onLog(LogRecord(LogLevel.error, 'Flutter Error: delivery failed once', 'app', StateError('retain me')));
    await reporter.flush();

    expect(reporter.isEnabled, isFalse);
    expect(await store.load(), hasLength(1));
    expect(await reporter.enable(), isTrue);
    await reporter.flush();

    expect(backend.reports, hasLength(1));
    expect(backend.reports.single.error.toString(), contains('retain me'));
    expect(backend.reports.single.fatal, isTrue);
    expect(await store.load(), isEmpty);
  });

  test('opt-out during backend initialization cancels admission and purges the spool', () async {
    final backend = RecordingBackend(blockCustomKeys: true);
    final store = FilePendingCrashReportStore(directory);
    final reporter = CrashlyticsLoggyIntegration(backend: backend);
    await reporter.configureLocalCapture(store: store, enabled: true);
    reporter.onLog(LogRecord(LogLevel.error, 'queued before opt out', 'test', StateError('must purge')));
    await reporter.flush();

    final enabling = reporter.enable();
    await backend.customKeyStarted.future;
    final disabling = reporter.disable();
    backend.releaseCustomKeys.complete();
    expect(await enabling, isFalse);
    await disabling;

    expect(reporter.isEnabled, isFalse);
    expect(backend.reports, isEmpty);
    expect(backend.collectionEnabled.last, isFalse);
    expect(await store.load(), isEmpty);
  });
}

class RecordingBackend implements CrashReportingBackend {
  RecordingBackend({this.failCollectionEnableOnce = false, this.failRecordOnce = false, this.blockCustomKeys = false});

  final bool failCollectionEnableOnce;
  final bool failRecordOnce;
  final bool blockCustomKeys;
  final List<RecordedReport> reports = <RecordedReport>[];
  final List<bool> collectionEnabled = <bool>[];
  final Completer<void> customKeyStarted = Completer<void>();
  final Completer<void> releaseCustomKeys = Completer<void>();
  int collectionEnableCalls = 0;
  bool _recordFailed = false;

  @override
  Future<void> deleteUnsentReports() async {}

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required String reason,
    required Iterable<Object> information,
    required bool fatal,
  }) async {
    if (failRecordOnce && !_recordFailed) {
      _recordFailed = true;
      throw StateError('backend record failed');
    }
    reports.add(RecordedReport(error, reason, List<Object>.of(information), fatal));
  }

  @override
  Future<void> setCollectionEnabled(bool enabled) async {
    collectionEnabled.add(enabled);
    if (!enabled) return;
    collectionEnableCalls++;
    if (failCollectionEnableOnce && collectionEnableCalls == 1) {
      throw StateError('backend initialization failed');
    }
  }

  @override
  Future<void> setCustomKey(String key, Object value) async {
    if (!blockCustomKeys || releaseCustomKeys.isCompleted) return;
    if (!customKeyStarted.isCompleted) customKeyStarted.complete();
    await releaseCustomKeys.future;
  }

  @override
  Future<void> log(String message) async {}
}

class RecordedReport {
  const RecordedReport(this.error, this.reason, this.information, this.fatal);

  final Object error;
  final String reason;
  final List<Object> information;
  final bool fatal;
}
