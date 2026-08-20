import 'dart:io';

import 'package:dio/dio.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';
import 'package:marten/core/model/failures.dart';
import 'package:marten/features/proxy/model/proxy_failure.dart';

final RegExp _dartStackFramePattern = RegExp(r'^#\d+\s+');
const List<String> _crashReportingFrameLocations = <String>[
  'package:loggy/',
  'package:marten/core/analytics/analytics_filter.dart',
  'package:marten/core/analytics/analytics_logger.dart',
];

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
  null => false,
  ExpectedMeasuredFailure _ => true,
  _ => canSendCrashReport(throwable),
};

SanitizedCrashException sanitizeCrashException(Object error) {
  final unwrapped = _unwrapCrashError(error);
  return SanitizedCrashException(
    SensitiveDataRedactor.redact(unwrapped.runtimeType.toString()),
    SensitiveDataRedactor.redactObject(unwrapped),
  );
}

StackTrace sanitizeCrashStackTrace(StackTrace stackTrace) {
  final redacted = SensitiveDataRedactor.redact(stackTrace.toString());
  final lines = redacted.split('\n').where((line) => line.isNotEmpty).toList(growable: false);
  final firstExternalFrame = _firstExternalCrashFrame(lines);
  final visibleLines = firstExternalFrame == null ? lines : lines.sublist(firstExternalFrame);
  var frameNumber = 0;
  final normalized = visibleLines
      .map((line) {
        if (!_dartStackFramePattern.hasMatch(line)) return line;
        return line.replaceFirst(RegExp(r'^#\d+'), '#${frameNumber++}');
      })
      .join('\n');
  return StackTrace.fromString(normalized);
}

StackTrace fallbackCrashStackTrace({required String loggerName, required Object error}) {
  final sourceType = _safeStackSymbol(_unwrapCrashError(error).runtimeType.toString());
  final loggerIdentity = _stableCrashIdentity(SensitiveDataRedactor.redact(loggerName));
  return StackTrace.fromString(
    '#0      CrashGroup.$sourceType.logger_$loggerIdentity '
    '(package:marten/crash_group/${sourceType.toLowerCase()}_$loggerIdentity.dart:1:1)',
  );
}

Object? _unwrapCrashError(Object error) {
  return switch (error) {
    UnexpectedFailure(:final error) => error,
    _ => error,
  };
}

int? _firstExternalCrashFrame(List<String> lines) {
  var leadingInternalFrameSeen = false;
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (!_dartStackFramePattern.hasMatch(line)) continue;
    if (_crashReportingFrameLocations.any(line.contains)) {
      leadingInternalFrameSeen = true;
      continue;
    }
    return leadingInternalFrameSeen ? index : null;
  }
  return null;
}

String _safeStackSymbol(String value) {
  final symbol = value.replaceAll(RegExp('[^A-Za-z0-9_]'), '_');
  if (symbol.isEmpty) return 'UnknownError';
  return RegExp('^[0-9]').hasMatch(symbol) ? 'Error_$symbol' : symbol;
}

String _stableCrashIdentity(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

final class SanitizedCrashException implements Exception {
  const SanitizedCrashException(this.sourceType, this.message);

  final String sourceType;
  final String message;

  @override
  String toString() => message.isEmpty ? sourceType : '$sourceType: $message';
}
