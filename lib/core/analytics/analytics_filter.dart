import 'dart:io';

import 'package:dio/dio.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';
import 'package:marten/core/model/failures.dart';
import 'package:marten/features/proxy/model/proxy_failure.dart';

bool canSendCrashReport(dynamic throwable) {
  return switch (throwable) {
    UnexpectedFailure(:final error) => canSendCrashReport(error),
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

bool canReportLogRecord(dynamic throwable) => switch (throwable) {
  ExpectedMeasuredFailure _ => true,
  _ => canSendCrashReport(throwable),
};

SanitizedCrashException sanitizeCrashException(Object error) {
  final unwrapped = switch (error) {
    UnexpectedFailure(:final error) => error,
    _ => error,
  };
  return SanitizedCrashException(
    SensitiveDataRedactor.redact(unwrapped.runtimeType.toString()),
    SensitiveDataRedactor.redactObject(unwrapped),
  );
}

StackTrace sanitizeCrashStackTrace(StackTrace? stackTrace) {
  if (stackTrace == null) return StackTrace.current;
  return StackTrace.fromString(SensitiveDataRedactor.redact(stackTrace.toString()));
}

final class SanitizedCrashException implements Exception {
  const SanitizedCrashException(this.sourceType, this.message);

  final String sourceType;
  final String message;

  @override
  String toString() => message.isEmpty ? sourceType : '$sourceType: $message';
}
