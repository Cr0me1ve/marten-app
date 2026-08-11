import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/analytics/analytics_filter.dart';
import 'package:marten/core/model/failures.dart';

void main() {
  test('suppresses network and expected failures while retaining measured log failures', () {
    expect(canSendCrashReport(const SocketException('network unavailable')), isFalse);
    expect(canSendCrashReport(_ExpectedFailure()), isFalse);
    expect(canSendCrashReport(_ExpectedMeasuredFailure()), isFalse);
    expect(canSendCrashReport(_UnexpectedFailure(const SocketException('network unavailable'))), isFalse);

    expect(canReportLogRecord(_ExpectedFailure()), isFalse);
    expect(canReportLogRecord(_ExpectedMeasuredFailure()), isTrue);
  });

  test('sanitizes exception and stack trace values before crash reporting', () {
    const sensitive =
        'https://edge.example/sub/private-token?access_token=private-access-token person@example.com 192.0.2.10';
    final exception = sanitizeCrashException(StateError(sensitive));
    final stackTrace = sanitizeCrashStackTrace(StackTrace.fromString('at $sensitive'));

    final delivered = '$exception\n$stackTrace';
    expect(exception.sourceType, 'StateError');
    expect(delivered, isNot(contains('private-token')));
    expect(delivered, isNot(contains('private-access-token')));
    expect(delivered, isNot(contains('person@example.com')));
    expect(delivered, isNot(contains('192.0.2.10')));
    expect(delivered, contains('[redacted]'));
  });
}

class _ExpectedFailure extends Error with ExpectedFailure {}

class _ExpectedMeasuredFailure extends Error with ExpectedMeasuredFailure {}

class _UnexpectedFailure extends Error with UnexpectedFailure {
  _UnexpectedFailure(this.error);

  @override
  final Object? error;

  @override
  StackTrace? get stackTrace => null;
}
