import 'package:flutter_test/flutter_test.dart';
import 'package:loggy/loggy.dart';
import 'package:marten/core/analytics/analytics_logger.dart';

void main() {
  test('Sentry log printer ignores records before Sentry hub is ready', () async {
    final printer = SentryLoggyIntegration();

    await expectLater(
      printer.onLog(LogRecord(LogLevel.error, 'early startup error', 'test')),
      completes,
    );
  });
}
