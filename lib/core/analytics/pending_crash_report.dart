import 'dart:convert';
import 'dart:io';

import 'package:marten/core/analytics/analytics_filter.dart';

const pendingCrashReportLimit = 16;

/// Only already-redacted, bounded data enters the local spool.
class PendingCrashReport {
  const PendingCrashReport({
    required this.error,
    required this.stack,
    required this.reason,
    required this.context,
    required this.fatal,
    this.timestampMs = 0,
  });

  final SanitizedCrashException error;
  final StackTrace stack;
  final String reason;
  final List<String> context;
  final bool fatal;
  final int timestampMs;

  Map<String, Object> toJson() => {
    'type': error.sourceType,
    'message': error.message,
    'stack': stack.toString(),
    'reason': reason,
    'context': context,
    'fatal': fatal,
    'timestamp_ms': timestampMs,
  };

  factory PendingCrashReport.fromJson(Map<String, dynamic> json) => PendingCrashReport(
    error: SanitizedCrashException(json['type'] as String, json['message'] as String),
    stack: StackTrace.fromString(json['stack'] as String),
    reason: json['reason'] as String,
    context: (json['context'] as List).cast<String>(),
    fatal: json['fatal'] as bool,
    timestampMs: json['timestamp_ms'] as int? ?? 0,
  );
}

abstract interface class PendingCrashReportStore {
  Future<Map<int, PendingCrashReport>> load();
  Future<void> write(int slot, PendingCrashReport report);
  Future<void> remove(int slot);
  Future<void> clear();
}

/// Fixed slots bound disk use and event-driven I/O. No timer, scan loop or SDK.
class FilePendingCrashReportStore implements PendingCrashReportStore {
  FilePendingCrashReportStore(this.directory);
  final Directory directory;
  // Includes worst-case JSON escaping of the bounded redacted fields.
  static const maxReportBytes = 256 * 1024;

  File _file(int slot) => File('${directory.path}/report_$slot.json');

  @override
  Future<Map<int, PendingCrashReport>> load() async {
    final reports = <int, PendingCrashReport>{};
    for (var slot = 0; slot < pendingCrashReportLimit; slot++) {
      final file = _file(slot);
      if (!await file.exists()) continue;
      try {
        if (await file.length() > maxReportBytes) throw const FormatException();
        reports[slot] = PendingCrashReport.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      } catch (_) {
        // A partial/corrupt report cannot block the rest of diagnostics.
        await remove(slot);
      }
    }
    return reports;
  }

  @override
  Future<void> write(int slot, PendingCrashReport report) async {
    final bytes = utf8.encode(jsonEncode(report.toJson()));
    if (bytes.length > maxReportBytes) return;
    await directory.create(recursive: true);
    final file = _file(slot);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }

  File get _lastFatal => File('${directory.path}/last-fatal.json');

  Future<void> retainFatal(PendingCrashReport report) async {
    if (!report.fatal) return;
    final bytes = utf8.encode(jsonEncode(report.toJson()));
    if (bytes.length > maxReportBytes) return;
    await directory.create(recursive: true);
    final temporary = File('${_lastFatal.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(_lastFatal.path);
  }

  Future<PendingCrashReport?> readLastFatal() async {
    if (!await _lastFatal.exists()) return null;
    if (await _lastFatal.length() > maxReportBytes) throw const FormatException();
    return PendingCrashReport.fromJson(jsonDecode(await _lastFatal.readAsString()) as Map<String, dynamic>);
  }

  @override
  Future<void> remove(int slot) async {
    for (final file in [_file(slot), File('${_file(slot).path}.tmp')]) {
      if (await file.exists()) await file.delete();
    }
  }

  @override
  Future<void> clear() async {
    for (var slot = 0; slot < pendingCrashReportLimit; slot++) {
      await remove(slot);
    }
    for (final file in [_lastFatal, File('${_lastFatal.path}.tmp')]) {
      if (await file.exists()) await file.delete();
    }
  }
}
