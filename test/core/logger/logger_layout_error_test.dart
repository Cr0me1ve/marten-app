import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loggy/loggy.dart';

import 'package:marten/core/analytics/analytics_logger.dart';
import 'package:marten/core/analytics/crash_reporting_backend.dart';
import 'package:marten/core/logger/logger.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';

void main() {
  test('Logger.logFlutterError stores layout context, preserves provided stack trace, and stays non-fatal', () async {
    final backend = _RecordingCrashBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);

    Loggy.initLoggy(logPrinter: reporter);
    await reporter.enable();

    const sensitiveHost = 'private.example.com';
    const sensitiveToken = 'secret-token';
    const sensitiveEmail = 'user@example.com';
    const layoutMarker = 'LAYOUT_ERROR_MARKER';

    const layoutStack = '''
#0      test  (package:marten/test.dart:1:1)
  #1      framework  (package:flutter/src/widgets/..:0:0)''';
    final providedStack = StackTrace.fromString(layoutStack);

    final details = FlutterErrorDetails(
      exception: FlutterError('A RenderFlex overflowed by 12 pixels on the right. $layoutMarker'),
      library: 'rendering/library',
      context: ErrorSummary('while laying out diagnostics for layout test'),
      informationCollector: () sync* {
        yield ErrorDescription('layout_context_marker=$layoutMarker');
        yield ErrorDescription('layout diagnostics available via debugPath');
        yield StringProperty('lookup_url', 'https://$sensitiveHost/sub/$sensitiveToken?email=$sensitiveEmail');
      },
      stack: providedStack,
    );

    Logger.logFlutterError(details);
    await reporter.disable();

    expect(backend.reports, hasLength(1));
    final report = backend.reports.single;
    expect(report.fatal, isFalse);

    final delivered = <String>[
      report.error.toString(),
      report.reason,
      ...backend.reports.single.information.map((item) => item.toString()),
      report.stackTrace.toString(),
    ].join('\n');

    expect(
      delivered,
      allOf(
        contains('rendering/library'),
        contains('while laying out diagnostics for layout test'),
        contains('layout_context_marker=$layoutMarker'),
        contains('LAYOUT_ERROR_MARKER'),
      ),
    );
    expect(report.stackTrace.toString(), equals(SensitiveDataRedactor.redact(layoutStack)));
    expect(report.error.toString(), isNot(contains(sensitiveHost)));
    expect(report.error.toString(), isNot(contains(sensitiveToken)));
    expect(report.error.toString(), isNot(contains(sensitiveEmail)));
    expect(report.reason, isNot(contains(sensitiveHost)));
    expect(report.reason, isNot(contains(sensitiveToken)));
    expect(report.reason, isNot(contains(sensitiveEmail)));
    expect(report.information.where((entry) => entry.toString().contains(sensitiveHost)), isEmpty);
  });
}

class _RecordingCrashBackend implements CrashReportingBackend {
  final List<_RecordedCrashReport> reports = <_RecordedCrashReport>[];

  @override
  Future<void> setCollectionEnabled(bool enabled) async {}

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required String reason,
    required Iterable<Object> information,
    required bool fatal,
  }) async {
    reports.add(
      _RecordedCrashReport(
        error: error,
        stackTrace: stackTrace,
        reason: reason,
        information: List<Object>.of(information),
        fatal: fatal,
      ),
    );
  }

  @override
  Future<void> setCustomKey(String key, Object value) async {}

  @override
  Future<void> log(String message) async {}

  @override
  Future<void> deleteUnsentReports() async {}
}

class _RecordedCrashReport {
  const _RecordedCrashReport({
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
