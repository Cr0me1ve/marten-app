import 'package:marten/core/logger/sensitive_data_redactor.dart';

/// Only native structural frames and fixed system-exit classification frames
/// are exempt from hostname filtering; surrounding text is still redacted.
String redactCrashDiagnostics(String value) {
  final identities = <String>[];
  var prefix = 'MCRASH';
  for (var suffix = 0; value.contains(prefix); suffix++) {
    prefix = 'MCRASHX$suffix';
  }
  String protect(String identity) {
    final marker = '$prefix${identities.length}Z';
    identities.add(identity);
    return marker;
  }

  final prepared = value
      .replaceAllMapped(
        RegExp(
          r'^MARTEN_LOCAL_EXCEPTION process_role=(?:app|core) timestamp_ms=[0-9]+ type=([A-Za-z_$][A-Za-z0-9_.$<>]{0,159}) sdk_covered=(?:true|false)$',
          multiLine: true,
        ),
        (match) => match[0]!.replaceFirst(match[1]!, protect(match[1]!)),
      )
      .replaceAllMapped(
        RegExp(
          r'^#[0-9]+ +[A-Za-z0-9_.$<>]+ \(package:marten/native_startup/native\.dart:[0-9]+:1\)$',
          multiLine: true,
        ),
        (match) => protect(match[0]!),
      )
      .replaceAllMapped(
        RegExp(
          '^#[0-9]+ +AndroidExit_(app|core|diagnostics)_'
          '(java_crash|native_crash|anr|low_memory|signaled|excessive_resource|dependency_died|initialization_failure|other) '
          r'\(package:marten/exit/\1/\2\.dart:1:1\)$',
          multiLine: true,
        ),
        (match) => protect(match[0]!),
      );
  return SensitiveDataRedactor.redact(
    prepared,
  ).replaceAllMapped(RegExp('$prefix([0-9]+)Z'), (match) => identities[int.parse(match[1]!)]);
}
