import 'package:flutter/foundation.dart';
import 'package:loggy/loggy.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';

class Logger {
  static final app = Loggy('app');
  static final bootstrap = Loggy('bootstrap');

  static const int _flutterDiagnosticMessageLimit = 1800;
  static const int _flutterDiagnosticFragmentLimit = 360;
  static final RegExp _layoutOverflowPattern = RegExp(r'A Render\w*Flex overflowed by \d+(?:\.\d+)? pixels');
  static final RegExp _quotedDiagnosticValuePattern = RegExp(r'''(["']).*?\1''');

  static void logFlutterError(FlutterErrorDetails details) {
    if (details.silent) {
      return;
    }

    app.error(buildFlutterErrorMessage(details), details.exception, details.stack);
  }

  @visibleForTesting
  static String buildFlutterErrorMessage(FlutterErrorDetails details) {
    final description = _safeDiagnosticFragment(details.exceptionAsString());
    final layoutOverflow = isLayoutOverflow(details);
    final summary = <String>[
      if (details.library case final library?) 'library=${_safeDiagnosticFragment(library)}',
      if (details.context case final context?) 'context=${_safeDiagnosticFragment(context.toDescription())}',
      'stack=${details.stack == null ? 'unavailable' : 'available'}',
      ..._structuralDiagnostics(details),
    ].join(' | ');
    final prefix = layoutOverflow ? 'Flutter Layout Error' : 'Flutter Error';
    return _truncate('$prefix: $description${summary.isEmpty ? '' : ' | $summary'}', _flutterDiagnosticMessageLimit);
  }

  @visibleForTesting
  static bool isLayoutOverflow(FlutterErrorDetails details) {
    final description = details.exceptionAsString();
    return _layoutOverflowPattern.hasMatch(description) ||
        (description.contains('overflowed by') &&
            (details.library?.toLowerCase().contains('rendering') ?? false) &&
            (details.context?.toDescription().toLowerCase().contains('layout') ?? false));
  }

  static Iterable<String> _structuralDiagnostics(FlutterErrorDetails details) sync* {
    Iterable<DiagnosticsNode> diagnostics;
    try {
      diagnostics = details.informationCollector?.call() ?? const <DiagnosticsNode>[];
    } catch (_) {
      return;
    }

    final prioritized = <String>[];
    final remaining = <String>[];
    for (final node in diagnostics.take(16)) {
      String rendered;
      try {
        rendered = node.toString();
      } catch (_) {
        continue;
      }
      final safe = _safeDiagnosticFragment(rendered);
      if (safe.isEmpty) continue;
      final lower = safe.toLowerCase();
      if (lower.contains('creator:') ||
          lower.contains('renderflex') ||
          lower.contains('constraints:') ||
          lower.contains('orientation') ||
          lower.contains('mainaxis') ||
          lower.contains('crossaxis')) {
        prioritized.add(safe);
      } else {
        remaining.add(safe);
      }
    }

    final seen = <String>{};
    for (final diagnostic in <String>[...prioritized, ...remaining]) {
      if (seen.add(diagnostic)) {
        yield 'layout=${_truncate(diagnostic, _flutterDiagnosticFragmentLimit)}';
        if (seen.length == 6) return;
      }
    }
  }

  static String _safeDiagnosticFragment(String value) {
    final withoutQuotedValues = value.replaceAll(_quotedDiagnosticValuePattern, '[redacted-value]');
    final singleLine = withoutQuotedValues.replaceAll(RegExp(r'\s+'), ' ').trim();
    return SensitiveDataRedactor.redact(singleLine);
  }

  static String _truncate(String value, int maxLength) {
    if (value.length <= maxLength) return value;
    return '${value.substring(0, maxLength - 1)}…';
  }

  static bool logPlatformDispatcherError(Object error, StackTrace stackTrace) {
    app.error('PlatformDispatcherError: $error', error, stackTrace);
    return true;
  }
}
