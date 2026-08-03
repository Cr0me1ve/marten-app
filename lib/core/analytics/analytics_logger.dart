import 'package:loggy/loggy.dart';
import 'package:marten/core/analytics/analytics_filter.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

// modified version of https://github.com/getsentry/sentry-dart/tree/main/logging
class SentryLoggyIntegration extends LoggyPrinter implements Integration<SentryOptions> {
  SentryLoggyIntegration({LogLevel minBreadcrumbLevel = LogLevel.info, LogLevel minEventLevel = LogLevel.error})
    : _minBreadcrumbLevel = minBreadcrumbLevel,
      _minEventLevel = minEventLevel;

  final LogLevel _minBreadcrumbLevel;
  final LogLevel _minEventLevel;

  Hub? _hub;

  @override
  void call(Hub hub, SentryOptions options) {
    _hub = hub;
    options.sdk.addIntegration('LoggyIntegration');
  }

  @override
  Future<void> close() async {}

  bool _shouldLog(LogLevel logLevel, LogLevel minLevel) {
    if (logLevel == LogLevel.off) {
      return false;
    }
    return logLevel.priority >= minLevel.priority;
  }

  @override
  Future<void> onLog(LogRecord record) async {
    if (!canLogEvent(record.error)) return;

    final hub = _hub;
    if (hub == null) return;

    try {
      if (_shouldLog(record.level, _minEventLevel)) {
        await hub.captureEvent(record.toEvent(), stackTrace: record.stackTrace);
      }

      if (_shouldLog(record.level, _minBreadcrumbLevel)) {
        await hub.addBreadcrumb(record.toBreadcrumb());
      }
    } catch (_) {
      // Logging must never become a new app error, especially during early
      // startup when Sentry is still being initialized.
    }
  }
}

extension LogRecordX on LogRecord {
  Breadcrumb toBreadcrumb() {
    return Breadcrumb(
      category: 'log',
      type: 'debug',
      timestamp: time.toUtc(),
      level: level.toSentryLevel(),
      message: SensitiveDataRedactor.redact(message),
      data: <String, Object>{'LogRecord.loggerName': loggerName, 'LogRecord.sequenceNumber': sequenceNumber},
    );
  }

  SentryEvent toEvent() {
    return SentryEvent(
      timestamp: time.toUtc(),
      logger: loggerName,
      level: level.toSentryLevel(),
      message: SentryMessage(SensitiveDataRedactor.redact(message)),
      // ignore: deprecated_member_use
      extra: <String, Object>{'LogRecord.sequenceNumber': sequenceNumber},
    );
  }
}

extension LogLevelX on LogLevel {
  SentryLevel? toSentryLevel() => switch (this) {
    LogLevel.all || LogLevel.debug => SentryLevel.debug,
    LogLevel.info => SentryLevel.info,
    LogLevel.warning => SentryLevel.warning,
    LogLevel.error => SentryLevel.error,
    _ => null,
  };
}
