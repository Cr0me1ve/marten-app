import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loggy/loggy.dart';
import 'package:marten/core/analytics/analytics_logger.dart';
import 'package:marten/core/analytics/crash_reporting_backend.dart';
import 'package:marten/features/proxy/model/proxy_failure.dart';

void main() {
  test('disabled reporting keeps context local and uploads nothing', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);

    reporter.onLog(LogRecord(LogLevel.error, 'early startup error', 'test', StateError('not uploaded')));
    reporter.setContextCollectionEnabled(true);
    reporter.onLog(LogRecord(LogLevel.info, 'local diagnostic', 'test'));
    await reporter.recordError(StateError('disabled'), StackTrace.current, reason: 'disabled');

    expect(reporter.isEnabled, isFalse);
    expect(reporter.contextSnapshot.single, contains('local diagnostic'));
    expect(backend.collectionEnabled, isEmpty);
    expect(backend.customKeyUpdates, isEmpty);
    expect(backend.loggedMessages, isEmpty);
    expect(backend.reports, isEmpty);
  });

  test('enabled privacy-safe reporter redacts and logs each unique context message', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);

    reporter.setContextCollectionEnabled(true);
    await reporter.enable();
    reporter.onLog(LogRecord(LogLevel.info, 'user=alice@example.com token=${'a' * 40} ip=203.0.113.5', 'app'));
    reporter.onLog(
      LogRecord(
        LogLevel.error,
        'expected failure for outbound/icmp[SECRET PROFILE]',
        'app',
        StateError('private token should be redacted'),
      ),
    );
    await reporter.recordError(
      StateError('recorded failure for person@example.com'),
      StackTrace.fromString('stack with 198.51.100.10'),
      reason: 'fatal error with token',
    );

    await reporter.disable();

    expect(backend.loggedMessages.length, greaterThanOrEqualTo(2));
    expect(backend.loggedMessages.join('\n'), isNot(contains('alice@example.com')));
    expect(backend.loggedMessages.join('\n'), isNot(contains('a' * 40)));
    expect(backend.loggedMessages.join('\n'), isNot(contains('203.0.113.5')));
    expect(backend.loggedMessages.join('\n'), isNot(contains('person@example.com')));
    expect(backend.loggedMessages.join('\n'), isNot(contains('198.51.100.10')));
    expect(backend.loggedMessages.join('\n'), isNot(contains('SECRET PROFILE')));
    expect(backend.customKeys, containsPair('last_logger', 'app'));
    expect(backend.customKeys, containsPair('last_level', 'Error'));
    expect(backend.customKeys, containsPair('error_context_records', 2));
  });

  test('optionally discards unsent reports before enabling collection', () async {
    final discardingBackend = FakeCrashReportingBackend();
    final discardingReporter = CrashlyticsLoggyIntegration(backend: discardingBackend);

    await discardingReporter.enable(discardExistingReports: true);

    expect(discardingBackend.deleteUnsentReportsCalls, 1);
    expect(discardingBackend.operations.take(2), <String>['deleteUnsentReports', 'collection:true']);

    final retainingBackend = FakeCrashReportingBackend();
    final retainingReporter = CrashlyticsLoggyIntegration(backend: retainingBackend);

    await retainingReporter.enable();

    expect(retainingBackend.deleteUnsentReportsCalls, 0);
    expect(retainingBackend.operations.first, 'collection:true');

    await discardingReporter.disable();
    await retainingReporter.disable();
  });

  test('accepts allowlisted state keys and ignores arbitrary PII-like keys', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);

    await reporter.enable();
    reporter.setContext('environment', 'production');
    reporter.setContext('last_action', 'connect');
    reporter.setContext('account_email', 'person@example.com');
    await reporter.disable();

    expect(backend.customKeys['environment'], 'production');
    expect(backend.customKeys['last_action'], 'connect');
    expect(backend.customKeys, isNot(contains('account_email')));
    expect(backend.customKeys.values.join('\n'), isNot(contains('person@example.com')));
  });

  test('keeps a bounded rolling context in exactly forty native context slots', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);

    await reporter.enable();

    for (var index = 0; index <= crashContextRecordLimit; index++) {
      reporter.onLog(LogRecord(LogLevel.info, 'context-$index', 'test'));
    }

    expect(reporter.contextSnapshot, hasLength(crashContextRecordLimit));
    expect(reporter.contextSnapshot.join('\n'), isNot(contains('context-0')));
    expect(reporter.contextSnapshot.first, contains('context-1'));
    expect(reporter.contextSnapshot.last, contains('context-$crashContextRecordLimit'));

    await reporter.disable();

    final nativeSlots = <String, Object>{};
    for (final update in backend.customKeyUpdates) {
      if (_isNativeContextSlot(update.key) && update.value != '') {
        nativeSlots[update.key] = update.value;
      }
    }
    final nativeContext = nativeSlots.values.join('\n');

    expect(nativeSlots.keys, unorderedEquals(_contextSlotKeys));
    expect(nativeContext, isNot(contains('context-0')));
    expect(nativeContext, contains('context-1'));
    expect(nativeContext, contains('context-$crashContextRecordLimit'));
  });

  test('buffers context before enable and seeds it during collection start', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);

    reporter.setContextCollectionEnabled(true);
    reporter.onLog(LogRecord(LogLevel.info, 'buffered before enable', 'app'));
    reporter.onLog(LogRecord(LogLevel.warning, 'buffered warning before enable', 'app'));
    await reporter.enable();

    expect(backend.customKeys['context_00'], contains('buffered before enable'));
    expect(backend.customKeys['context_01'], contains('buffered warning before enable'));

    await reporter.disable();
  });

  test('redacts sensitive context and crash data before delivery and bounds line length', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend, contextLineLengthLimit: 120);
    const secret =
        'https://edge.example/sub/private-token?access_token=private-access-token person@example.com 192.0.2.10';

    await reporter.enable();
    reporter.onLog(LogRecord(LogLevel.info, '$secret ${'x' * 200}', 'test'));
    await reporter.recordError(StateError(secret), StackTrace.fromString('at $secret'), reason: 'failed $secret');

    final delivered = <String>[
      ...backend.customKeys.values.map((value) => value.toString()),
      ...backend.reports.expand(
        (report) => <String>[
          report.error.toString(),
          report.stackTrace.toString(),
          report.reason,
          ...report.information.map((item) => item.toString()),
        ],
      ),
    ].join('\n');

    expect(backend.customKeys['context_00'].toString().length, lessThanOrEqualTo(120));
    expect(delivered, isNot(contains('private-token')));
    expect(delivered, isNot(contains('private-access-token')));
    expect(delivered, isNot(contains('person@example.com')));
    expect(delivered, isNot(contains('192.0.2.10')));
    expect(delivered, contains('[redacted]'));

    await reporter.disable();
  });

  test('writes log context to native slots and attaches neighboring context to an error', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);

    await reporter.enable();
    reporter.onLog(LogRecord(LogLevel.info, 'connection started', 'connection'));
    reporter.onLog(LogRecord(LogLevel.warning, 'handshake retry', 'connection'));
    reporter.onLog(LogRecord(LogLevel.error, 'connection failed', 'connection', StateError('failure')));

    await reporter.disable();

    expect(backend.reports, hasLength(1));
    final information = backend.reports.single.information.join('\n');
    expect(information, contains('connection started'));
    expect(information, contains('handshake retry'));
    expect(information, contains('connection failed'));
    expect(information.indexOf('connection started'), lessThan(information.indexOf('handshake retry')));
    expect(information.indexOf('handshake retry'), lessThan(information.indexOf('connection failed')));
    expect(backend.reports.single.fatal, isFalse);
    expect(
      backend.customKeyUpdates
          .where((update) => _isNativeContextSlot(update.key) && update.value != '')
          .map((update) => update.value)
          .join('\n'),
      contains('connection started'),
    );
  });

  test('logs lifecycle transitions as context updates', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);

    reporter.setContextCollectionEnabled(true);
    await reporter.enable();
    reporter.didChangeAppLifecycleState(AppLifecycleState.resumed);
    reporter.didChangeAppLifecycleState(AppLifecycleState.paused);

    await reporter.disable();

    expect(backend.loggedMessages.where((line) => line.contains('[lifecycle]') && line.contains('app=')).length, 2);
  });

  test('keeps explicit recordError working after enabling', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);

    await reporter.enable();
    await reporter.recordError(StateError('manual report failure'), StackTrace.current, reason: 'manual');

    await reporter.disable();

    expect(backend.reports, hasLength(1));
    expect(backend.reports.single.fatal, isFalse);
    expect(backend.reports.single.reason, contains('manual'));
  });

  test('treats error-level logs without error objects as context-only for core log lines', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);

    await reporter.enable();
    reporter.onLog(
      LogRecord(LogLevel.error, 'verifying startup route outbound/icmp[SECRET PROFILE]', 'MartenCoreService'),
    );
    reporter.onLog(LogRecord(LogLevel.error, 'peer(1USf…2wVA) authentication warning', 'raw'));
    reporter.onLog(LogRecord(LogLevel.info, 'context after core error', 'MartenCoreService'));

    expect(reporter.contextSnapshot.any((line) => line.contains('verifying startup route')), isTrue);
    expect(
      reporter.contextSnapshot.any((line) => line.contains('peer(') && line.contains('authentication warning')),
      isTrue,
    );
    expect(reporter.contextSnapshot.any((line) => line.contains('context after core error')), isTrue);

    await reporter.disable();

    expect(backend.reports, isEmpty);
  });

  test('does not create non-fatal events for network or expected failures', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);
    final networkError = DioException(requestOptions: RequestOptions(path: '/subscription'));
    const expectedError = ProxyFailure.serviceNotRunning();

    await reporter.enable();
    reporter.onLog(LogRecord(LogLevel.error, 'network failed', 'connection', networkError));
    reporter.onLog(LogRecord(LogLevel.error, 'expected failed', 'connection', expectedError));
    await reporter.recordError(networkError, StackTrace.current, reason: 'network');
    await reporter.recordError(expectedError, StackTrace.current, reason: 'expected');
    await reporter.disable();

    expect(backend.reports, isEmpty);
  });

  test('marks layout overflow Flutter errors as non-fatal while keeping general Flutter errors fatal', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);

    await reporter.enable();
    reporter.onLog(
      LogRecord(
        LogLevel.error,
        'Flutter Error: A RenderFlex overflowed by 24 pixels on the right.',
        'app',
        FlutterError('A RenderFlex overflowed by 24 pixels on the right.'),
      ),
    );
    reporter.onLog(
      LogRecord(
        LogLevel.error,
        'Flutter Error: widget build failed for app startup',
        'app',
        StateError('startup failure'),
      ),
    );
    await reporter.disable();

    expect(backend.reports, hasLength(2));
    expect(backend.reports.first.fatal, isFalse);
    expect(backend.reports.last.fatal, isTrue);
  });

  test('classifies controlled Flutter and platform dispatcher errors as fatal', () async {
    final backend = FakeCrashReportingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);

    await reporter.enable();
    reporter.onLog(LogRecord(LogLevel.error, 'Flutter Error: widget build failed', 'app', StateError('flutter')));
    reporter.onLog(
      LogRecord(LogLevel.error, 'PlatformDispatcherError: unhandled callback', 'app', StateError('dispatcher')),
    );
    await reporter.disable();

    expect(backend.reports, hasLength(2));
    expect(backend.reports.map((report) => report.fatal), everyElement(isTrue));
  });

  test('backend failures are fail-safe and disabling clears context and collection', () async {
    final failingBackend = FakeCrashReportingBackend(shouldFail: true);
    final reporter = CrashlyticsLoggyIntegration(backend: failingBackend);

    await expectLater(reporter.enable(), completes);
    reporter.onLog(LogRecord(LogLevel.error, 'backend unavailable', 'test', StateError('failure')));
    await expectLater(reporter.recordError(StateError('failure'), StackTrace.current, reason: 'failure'), completes);
    await expectLater(reporter.disable(), completes);

    expect(reporter.isEnabled, isFalse);
    expect(reporter.contextSnapshot, isEmpty);

    final backend = FakeCrashReportingBackend();
    final enabledReporter = CrashlyticsLoggyIntegration(backend: backend);
    await enabledReporter.enable();
    enabledReporter.onLog(LogRecord(LogLevel.info, 'will be cleared', 'test'));
    await enabledReporter.disable();
    enabledReporter.onLog(LogRecord(LogLevel.error, 'after disable', 'test', StateError('ignored')));

    expect(enabledReporter.contextSnapshot, isEmpty);
    expect(backend.collectionEnabled, <bool>[true, false]);
    expect(backend.reports, isEmpty);
    expect(backend.deleteUnsentReportsCalls, 1);
    expect(backend.operations.last, 'deleteUnsentReports');
    expect(_contextSlotKeys.map((key) => backend.customKeys[key]), everyElement(''));
  });
}

final Set<String> _contextSlotKeys = Set<String>.unmodifiable(
  List<String>.generate(crashContextRecordLimit, (slot) => 'context_${slot.toString().padLeft(2, '0')}'),
);

final RegExp _nativeContextSlotPattern = RegExp(r'^context_\d{2}$');

bool _isNativeContextSlot(String key) => _nativeContextSlotPattern.hasMatch(key);

class FakeCrashReportingBackend implements CrashReportingBackend {
  FakeCrashReportingBackend({this.shouldFail = false});

  final bool shouldFail;
  final List<bool> collectionEnabled = <bool>[];
  final Map<String, Object> customKeys = <String, Object>{};
  final List<({String key, Object value})> customKeyUpdates = <({String key, Object value})>[];
  final List<String> loggedMessages = <String>[];
  final List<RecordedCrashReport> reports = <RecordedCrashReport>[];
  final List<String> operations = <String>[];
  int deleteUnsentReportsCalls = 0;

  @override
  Future<void> deleteUnsentReports() async {
    _throwIfNeeded();
    deleteUnsentReportsCalls++;
    operations.add('deleteUnsentReports');
  }

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required String reason,
    required Iterable<Object> information,
    required bool fatal,
  }) async {
    _throwIfNeeded();
    reports.add(
      RecordedCrashReport(
        error: error,
        stackTrace: stackTrace,
        reason: reason,
        information: List<Object>.of(information),
        fatal: fatal,
      ),
    );
  }

  @override
  Future<void> setCollectionEnabled(bool enabled) async {
    _throwIfNeeded();
    collectionEnabled.add(enabled);
    operations.add('collection:$enabled');
  }

  @override
  Future<void> setCustomKey(String key, Object value) async {
    _throwIfNeeded();
    customKeys[key] = value;
    customKeyUpdates.add((key: key, value: value));
    operations.add('key:$key');
  }

  @override
  Future<void> log(String message) async {
    _throwIfNeeded();
    loggedMessages.add(message);
    operations.add('log');
  }

  void _throwIfNeeded() {
    if (shouldFail) throw StateError('Crash reporting backend unavailable');
  }
}

class RecordedCrashReport {
  const RecordedCrashReport({
    required this.error,
    required this.stackTrace,
    required this.reason,
    required this.information,
    required this.fatal,
  });

  final Object error;
  final StackTrace stackTrace;
  final String reason;
  final List<Object> information;
  final bool fatal;
}
