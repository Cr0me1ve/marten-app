import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/analytics/analytics_filter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  test('sanitizeSentryEvent removes sensitive payloads and identity context', () {
    final event = SentryEvent(
      message: SentryMessage('failed https://edge.example/sub/private-token?secret=yes'),
      user: SentryUser(id: 'device-id', email: 'person@example.com', ipAddress: '192.0.2.10'),
      request: SentryRequest(url: 'https://edge.example/sub/private-token'),
      // ignore: deprecated_member_use
      extra: const {'config': '{"uuid":"550e8400-e29b-41d4-a716-446655440000"}'},
      breadcrumbs: [
        Breadcrumb(
          message: 'captcha http://127.0.0.1:8765/captcha?token=private',
          data: const {'authorization': 'secret'},
        ),
      ],
      exceptions: [
        SentryException(
          type: 'StateError',
          value: 'X-Client-Secret=private-client-secret',
          stackTrace: SentryStackTrace(
            registers: const {'token': 'private-register'},
            frames: [
              SentryStackFrame(
                absPath: '/Users/private-user/project/main.dart',
                contextLine: 'const token = "private-context";',
                vars: const {'token': 'private-variable'},
              ),
            ],
          ),
        ),
      ],
      threads: [SentryThread(id: 1, name: 'private-thread-name', current: true)],
    );

    final sanitized = sanitizeSentryEvent(event);
    final encoded = sanitized.toJson().toString();

    expect(encoded, isNot(contains('private-token')));
    expect(encoded, isNot(contains('private-client-secret')));
    expect(encoded, isNot(contains('person@example.com')));
    expect(encoded, isNot(contains('192.0.2.10')));
    expect(encoded, isNot(contains('550e8400')));
    expect(encoded, isNot(contains('private-user')));
    expect(encoded, isNot(contains('private-context')));
    expect(encoded, isNot(contains('private-variable')));
    expect(encoded, isNot(contains('private-register')));
    expect(encoded, isNot(contains('private-thread-name')));
    expect(encoded, contains('[redacted]'));
    expect(sanitized.user, isNull);
    expect(sanitized.request, isNull);
    // ignore: deprecated_member_use
    expect(sanitized.extra, isNull);
    expect(sanitized.breadcrumbs!.single.data, isNull);
  });
}
