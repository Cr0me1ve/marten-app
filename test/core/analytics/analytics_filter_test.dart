import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/analytics/analytics_filter.dart';
import 'package:marten/core/analytics/analytics_logger.dart';
import 'package:marten/core/analytics/crash_reporting_backend.dart';
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

  test('preserves the synthetic native crash frame while scrubbing nearby secrets', () {
    const frame = '#0      app.marten.client.MainActivity.onCreate (package:marten/native_startup/native.dart:57:1)';
    const privateValues = 'endpoint=https://secret.example.com/path?access_token=private-token';

    final sanitized = sanitizeCrashStackTrace(StackTrace.fromString('$frame\n$privateValues')).toString();

    expect(sanitized, contains(frame));
    expect(sanitized, isNot(contains('secret.example.com')));
    expect(sanitized, isNot(contains('private-token')));
  });

  test('uses short allowlisted role and category paths for empty system exit stacks', () {
    const error = SanitizedCrashException('AndroidProcessExit', '');
    const javaCrashReason = 'android_process_exit_app_java_crash';
    const anrReason = 'android_process_exit_app_anr';

    final javaCrash = nativeCrashReportStackTrace(stack: '', reason: javaCrashReason, error: error).toString();
    final repeatedJavaCrash = nativeCrashReportStackTrace(stack: '', reason: javaCrashReason, error: error).toString();
    final anr = nativeCrashReportStackTrace(stack: '', reason: anrReason, error: error).toString();

    expect(javaCrash, isNotEmpty);
    expect(javaCrash, repeatedJavaCrash);
    expect(javaCrash, isNot(anr));
    expect(javaCrash, contains('(package:marten/exit/app/java_crash.dart:1:1)'));
    expect(anr, contains('(package:marten/exit/app/anr.dart:1:1)'));
    expect(javaCrash, isNot(contains('native_startup/native.dart')));
    expect(javaCrash, isNot(contains('pid=')));
  });

  test('allowlists supported exit roles and categories and rejects private reason paths', () {
    const error = SanitizedCrashException('AndroidProcessExit', '');
    const categories = <String>[
      'java_crash',
      'native_crash',
      'anr',
      'low_memory',
      'signaled',
      'excessive_resource',
      'dependency_died',
      'initialization_failure',
      'other',
    ];
    const roles = <String>['app', 'core', 'diagnostics'];

    for (final role in roles) {
      for (final category in categories) {
        final reason = 'android_process_exit_${role}_$category';
        final frame = nativeCrashReportStackTrace(stack: '', reason: reason, error: error).toString();
        expect(frame, contains('(package:marten/exit/$role/$category.dart:1:1)'), reason: reason);
      }
    }

    const privateReason = 'android_process_exit_app_https://private.example.com/token?access_token=secret';
    final privateFrame = nativeCrashReportStackTrace(stack: '', reason: privateReason, error: error).toString();
    expect(privateFrame, isNot(contains('private.example.com')));
    expect(privateFrame, isNot(contains('access_token')));
    expect(privateFrame, isNot(contains('secret')));
  });

  test('keeps a real native system stack unchanged when one is present', () {
    const realStack = 'native_exit_handler+0x123\nsignal_dispatcher+0x456';

    final crashStack = nativeCrashReportStackTrace(
      stack: realStack,
      reason: 'android_process_exit_app_native_crash',
      error: const SanitizedCrashException('AndroidProcessExit', ''),
    );

    expect(crashStack.toString(), realStack);
  });

  test('delivers distinct stable virtual frames for system exits through the reporting backend', () async {
    final backend = _StackRecordingBackend();
    final reporter = CrashlyticsLoggyIntegration(backend: backend);
    const error = SanitizedCrashException('AndroidProcessExit', '');
    const categories = <String>[
      'java_crash',
      'native_crash',
      'anr',
      'low_memory',
      'signaled',
      'excessive_resource',
      'dependency_died',
      'initialization_failure',
      'other',
    ];
    const roles = <String>['app', 'core', 'diagnostics'];
    final expectedReasons = <String>[];

    expect(await reporter.enable(), isTrue);
    for (final role in roles) {
      for (final category in categories) {
        final reason = 'android_process_exit_${role}_$category';
        expectedReasons.add(reason);
        await reporter.recordError(
          error,
          nativeCrashReportStackTrace(stack: '', reason: reason, error: error),
          reason: reason,
        );
      }
    }
    const repeatedJavaCrash = 'android_process_exit_app_java_crash';
    await reporter.recordError(
      error,
      nativeCrashReportStackTrace(stack: '', reason: repeatedJavaCrash, error: error),
      reason: repeatedJavaCrash,
    );
    const privateReason = 'android_process_exit_app_https://private.example.com/token?access_token=secret';
    await reporter.recordError(
      error,
      nativeCrashReportStackTrace(stack: '', reason: privateReason, error: error),
      reason: privateReason,
    );
    await reporter.flush();
    await reporter.disable();

    expect(backend.stacks, hasLength(expectedReasons.length + 2));
    for (var index = 0; index < expectedReasons.length; index++) {
      final parts = expectedReasons[index].split('_');
      final role = parts[3];
      final category = parts.sublist(4).join('_');
      final stack = backend.stacks[index];
      expect(stack, contains('AndroidExit_${role}_$category'));
      expect(stack, contains('(package:marten/exit/$role/$category.dart:1:1)'));
      expect(stack, isNot(contains(expectedReasons[index])));
    }
    expect(backend.stacks[0], backend.stacks[expectedReasons.length]);
    expect(backend.stacks[0], isNot(backend.stacks[1]));
    expect(backend.stacks.last, isNot(contains('private.example.com')));
    expect(backend.stacks.last, isNot(contains('access_token')));
    expect(backend.stacks.last, isNot(contains('secret')));
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

class _StackRecordingBackend implements CrashReportingBackend {
  final List<String> stacks = <String>[];

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
    stacks.add(stackTrace.toString());
  }

  @override
  Future<void> setCustomKey(String key, Object value) async {}

  @override
  Future<void> log(String message) async {}

  @override
  Future<void> deleteUnsentReports() async {}
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
