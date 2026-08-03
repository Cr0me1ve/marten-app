import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';
import 'package:marten/core/model/failures.dart';
import 'package:marten/features/proxy/model/proxy_failure.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

FutureOr<SentryEvent?> sentryBeforeSend(SentryEvent event, Hint hint) {
  if (!canSendEvent(event.throwable)) return null;
  return sanitizeSentryEvent(event);
}

SentryEvent sanitizeSentryEvent(SentryEvent event) {
  final message = event.message;
  return SentryEvent(
    eventId: event.eventId,
    timestamp: event.timestamp,
    platform: event.platform,
    logger: event.logger,
    release: event.release,
    dist: event.dist,
    environment: event.environment,
    level: event.level,
    type: event.type,
    message: message == null
        ? null
        : SentryMessage(
            SensitiveDataRedactor.redact(message.formatted),
            template: message.template == null ? null : SensitiveDataRedactor.redact(message.template!),
          ),
    breadcrumbs: event.breadcrumbs
        ?.map(
          (breadcrumb) => Breadcrumb(
            message: breadcrumb.message == null ? null : SensitiveDataRedactor.redact(breadcrumb.message!),
            timestamp: breadcrumb.timestamp,
            category: breadcrumb.category,
            level: breadcrumb.level,
            type: breadcrumb.type,
          ),
        )
        .toList(growable: false),
    exceptions: event.exceptions
        ?.map(
          (exception) => SentryException(
            type: _redactNullable(exception.type),
            value: exception.value == null ? null : SensitiveDataRedactor.redact(exception.value!),
            module: _redactNullable(exception.module),
            stackTrace: _sanitizeStackTrace(exception.stackTrace),
            threadId: exception.threadId,
          ),
        )
        .toList(growable: false),
    threads: event.threads
        ?.map(
          (thread) => SentryThread(
            id: thread.id,
            crashed: thread.crashed,
            current: thread.current,
            stacktrace: _sanitizeStackTrace(thread.stacktrace),
          ),
        )
        .toList(growable: false),
  );
}

String? _redactNullable(String? value) => value == null ? null : SensitiveDataRedactor.redact(value);

SentryStackTrace? _sanitizeStackTrace(SentryStackTrace? stackTrace) {
  if (stackTrace == null) return null;
  return SentryStackTrace(
    lang: stackTrace.lang,
    snapshot: stackTrace.snapshot,
    frames: stackTrace.frames
        .map(
          (frame) => SentryStackFrame(
            absPath: _redactNullable(frame.absPath),
            fileName: _redactNullable(frame.fileName),
            function: _redactNullable(frame.function),
            module: _redactNullable(frame.module),
            lineNo: frame.lineNo,
            colNo: frame.colNo,
            inApp: frame.inApp,
            package: _redactNullable(frame.package),
            native: frame.native,
            platform: frame.platform,
            imageAddr: frame.imageAddr,
            symbolAddr: frame.symbolAddr,
            instructionAddr: frame.instructionAddr,
            rawFunction: _redactNullable(frame.rawFunction),
            stackStart: frame.stackStart,
            symbol: _redactNullable(frame.symbol),
          ),
        )
        .toList(growable: false),
  );
}

bool canSendEvent(dynamic throwable) {
  return switch (throwable) {
    UnexpectedFailure(:final error) => canSendEvent(error),
    DioException _ => false,
    SocketException _ => false,
    UnknownIp _ => false,
    HttpException _ => false,
    HandshakeException _ => false,
    ExpectedFailure _ => false,
    ExpectedMeasuredFailure _ => false,
    _ => true,
  };
}

bool canLogEvent(dynamic throwable) => switch (throwable) {
  ExpectedMeasuredFailure _ => true,
  _ => canSendEvent(throwable),
};
