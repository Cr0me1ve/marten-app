import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

class LogFileRetention {
  const LogFileRetention._();

  static const standardRetention = Duration(hours: 1);
  static const errorRetention = Duration(days: 1);
  static const errorContextEntries = 20;
  static final _legacyTimePrefix = RegExp(r'^(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(?:\s+-|\s)');
  static final _persistedLevelPrefix = RegExp(r'^\[(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|PANIC|D|I|W|E|F)\]\s*');

  static Future<void> prepare(File file) async {
    await ensureExists(file);
    await prune(file);
  }

  static Future<void> ensureExists(File file) async {
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
  }

  static void prepareSync(File file) {
    ensureExistsSync(file);
    pruneSync(file);
  }

  static void ensureExistsSync(File file) {
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    if (!file.existsSync()) {
      file.createSync(recursive: true);
    }
  }

  static Future<void> prune(File file, {DateTime? now}) async {
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final reference = now ?? DateTime.now();
    final result = await Isolate.run(() {
      final logFile = _decodeLogBytes(bytes);
      final trimmed = trimToRetention(logFile.content, now: reference);
      return (content: trimmed, changed: trimmed != logFile.content || logFile.malformed);
    });
    if (result.changed) {
      await file.writeAsString(result.content, flush: true);
    }
  }

  static void pruneSync(File file, {DateTime? now}) {
    if (!file.existsSync()) return;
    final logFile = _readLogFileSync(file);
    final trimmed = trimToRetention(logFile.content, now: now);
    if (trimmed != logFile.content || logFile.malformed) {
      file.writeAsStringSync(trimmed, flush: true);
    }
  }

  static String trimToRetention(String content, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final retained = retainItems<List<String>>(
      entries(content),
      timestampOf: (entry) => timestampFromLine(entry.first, now: reference),
      levelOf: (entry) => _levelFromPersistedLine(entry.first),
      now: reference,
    );
    final exactTimestampedEntries = <String>{};
    final kept = <String>[];
    for (final entry in retained) {
      final serialized = entry.join('\n').trimRight();
      final timestamped = timestampFromLine(entry.first, now: reference) != null;
      if (!timestamped || exactTimestampedEntries.add(serialized)) {
        kept.add(serialized);
      }
    }
    return kept.isEmpty ? '' : '${kept.join('\n')}\n';
  }

  /// Retains timestamped items in chronological order according to their
  /// severity. Warning/error/fatal/panic entries live for a day, ordinary
  /// entries live for an hour, and a live error/fatal/panic protects the 20
  /// entries immediately before it for as long as the error itself is retained.
  static List<T> retainItems<T>(
    Iterable<T> items, {
    required DateTime? Function(T item) timestampOf,
    required String? Function(T item) levelOf,
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    final standardCutoff = reference.subtract(standardRetention);
    final errorCutoff = reference.subtract(errorRetention);
    final values = items.toList(growable: false);
    final keep = List<bool>.filled(values.length, false);

    for (var index = 0; index < values.length; index++) {
      final item = values[index];
      final timestamp = timestampOf(item);
      if (timestamp == null) {
        keep[index] = true;
        continue;
      }
      final cutoff = _isErrorRelatedLevel(levelOf(item)) ? errorCutoff : standardCutoff;
      keep[index] = !timestamp.isBefore(cutoff);
    }

    for (var index = 0; index < values.length; index++) {
      final item = values[index];
      if (!_isErrorTriggerLevel(levelOf(item))) continue;
      final timestamp = timestampOf(item);
      if (timestamp != null && timestamp.isBefore(errorCutoff)) continue;

      keep[index] = true;
      final contextStart = index > errorContextEntries ? index - errorContextEntries : 0;
      for (var contextIndex = contextStart; contextIndex < index; contextIndex++) {
        keep[contextIndex] = true;
      }
    }

    return [
      for (var index = 0; index < values.length; index++)
        if (keep[index]) values[index],
    ];
  }

  static List<List<String>> entries(String content) {
    final lines = content.replaceAll('\u0000', '').split('\n');
    final entries = <List<String>>[];
    var current = <String>[];
    for (final line in lines) {
      if (line.isEmpty && current.isEmpty) continue;
      if (timestampFromLine(line) != null) {
        if (current.isNotEmpty) entries.add(current);
        current = [line];
      } else if (current.isNotEmpty) {
        current.add(line);
      } else if (line.isNotEmpty) {
        current = [line];
      }
    }
    if (current.isNotEmpty) entries.add(current);
    return entries;
  }

  static DateTime? timestampFromLine(String line, {DateTime? now}) {
    final separator = line.indexOf(' - ');
    if (separator > 0) {
      final parsed = DateTime.tryParse(line.substring(0, separator).trim());
      if (parsed != null) return parsed.toLocal();
    }

    final match = _legacyTimePrefix.firstMatch(line);
    if (match == null) return null;

    final reference = now ?? DateTime.now();
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    final second = int.parse(match.group(3)!);
    final fraction = (match.group(4) ?? '').padRight(6, '0');
    final micros = fraction.isEmpty ? 0 : int.parse(fraction);
    var timestamp = DateTime(
      reference.year,
      reference.month,
      reference.day,
      hour,
      minute,
      second,
      micros ~/ 1000,
      micros % 1000,
    );
    if (timestamp.difference(reference) > const Duration(minutes: 1)) {
      timestamp = timestamp.subtract(const Duration(days: 1));
    }
    return timestamp;
  }

  static String formatTimestamp(DateTime time) {
    final local = time.toLocal();
    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final totalMinutes = offset.inMinutes.abs();
    final hours = (totalMinutes ~/ 60).toString().padLeft(2, '0');
    final minutes = (totalMinutes % 60).toString().padLeft(2, '0');
    return '${local.toIso8601String()}$sign$hours:$minutes';
  }

  static String? _levelFromPersistedLine(String line) {
    final separator = line.indexOf(' - ');
    final message = separator > 0 ? line.substring(separator + 3) : line;
    return _persistedLevelPrefix.firstMatch(message)?.group(1);
  }

  static bool _isErrorRelatedLevel(String? level) {
    return switch (_normalizeLevel(level)) {
      'WARNING' || 'ERROR' || 'FATAL' || 'PANIC' => true,
      _ => false,
    };
  }

  static bool _isErrorTriggerLevel(String? level) {
    return switch (_normalizeLevel(level)) {
      'ERROR' || 'FATAL' || 'PANIC' => true,
      _ => false,
    };
  }

  static String? _normalizeLevel(String? level) {
    return switch (level?.toUpperCase()) {
      'D' => 'DEBUG',
      'I' => 'INFO',
      'W' || 'WARN' => 'WARNING',
      'E' => 'ERROR',
      'F' => 'FATAL',
      final value => value,
    };
  }

  static ({String content, bool malformed}) _readLogFileSync(File file) {
    final bytes = file.readAsBytesSync();
    return _decodeLogBytes(bytes);
  }

  static ({String content, bool malformed}) _decodeLogBytes(List<int> bytes) {
    try {
      return (content: utf8.decode(bytes), malformed: false);
    } on FormatException {
      return (content: utf8.decode(bytes, allowMalformed: true), malformed: true);
    }
  }
}
