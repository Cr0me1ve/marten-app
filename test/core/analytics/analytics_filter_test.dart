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

  test('removes leading analytics and Loggy frames while retaining the first real app frame', () {
    const secret = 'https://edge.example/sub/private-token?access_token=private-access-token';
    final sanitized = sanitizeCrashStackTrace(
      StackTrace.fromString('''
#0      sanitizeCrashStackTrace (package:marten/core/analytics/analytics_filter.dart:39:7)
#1      CrashlyticsLoggyIntegration.onLog (package:marten/core/analytics/analytics_logger.dart:120:9)
#2      LoggyLogger.error (package:loggy/src/loggy.dart:90:11)
#3      _refreshProfile ($secret package:marten/features/profile/notifier/profile_notifier.dart:87:5)
#4      _runApp (package:marten/bootstrap.dart:55:3)
'''),
    ).toString();

    expect(sanitized.trimLeft(), startsWith('#0      _refreshProfile'));
    expect(sanitized, contains('profile_notifier.dart'));
    expect(sanitized, isNot(contains('analytics_filter.dart')));
    expect(sanitized, isNot(contains('analytics_logger.dart')));
    expect(sanitized, isNot(contains('package:loggy/')));
    expect(sanitized, isNot(contains('private-token')));
    expect(sanitized, isNot(contains('private-access-token')));
  });

  test('uses distinct privacy-safe fallback stack identities for unrelated null-stack errors', () {
    const secret = 'https://edge.example/sub/private-token?access_token=private-access-token';
    final connection = fallbackCrashStackTrace(
      loggerName: 'connection.$secret',
      error: StateError('connection failed for $secret'),
    ).toString();
    final profile = fallbackCrashStackTrace(
      loggerName: 'profile.refresh.$secret',
      error: ArgumentError('profile failed for $secret'),
    ).toString();

    expect(connection.split('\n').first, isNot(profile.split('\n').first));
    expect(connection, isNot(contains('private-token')));
    expect(connection, isNot(contains('private-access-token')));
    expect(profile, isNot(contains('private-token')));
    expect(profile, isNot(contains('private-access-token')));
    expect(connection, isNot(contains('analytics_filter.dart')));
    expect(profile, isNot(contains('sanitizeCrashStackTrace')));
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
