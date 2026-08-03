// ignore_for_file: parameter_assignments

import 'package:dartx/dartx.dart';
import 'package:marten/core/logger/log_file_retention.dart';
import 'package:marten/features/log/model/log_entity.dart';
import 'package:marten/features/log/model/log_level.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart' as pb;
import 'package:tint/tint.dart';

abstract class LogParser {
  static List<LogEntity> parsePersistedContent(String content) {
    return LogFileRetention.entries(content).map(parsePersistedEntry).toList();
  }

  static LogEntity parsePersistedEntry(List<String> entry) {
    final firstLine = entry.firstOrNull ?? '';
    final time = LogFileRetention.timestampFromLine(firstLine);
    final separator = firstLine.indexOf(' - ');
    var message = separator > 0 ? firstLine.substring(separator + 3) : firstLine;
    final level = _parsePersistedLevel(message);
    message = _stripPersistedLevel(message);
    if (entry.length > 1) {
      message = ([message] + entry.skip(1).toList()).join('\n').trimRight();
    }
    return LogEntity(level: level, time: time, message: message);
  }

  static LogEntity parseLogProto(pb.LogMessage message) {
    final level = switch (message.level) {
      pb.LogLevel.DEBUG => LogLevel.debug,
      pb.LogLevel.INFO => LogLevel.info,
      pb.LogLevel.WARNING => LogLevel.warn,
      pb.LogLevel.ERROR => LogLevel.error,
      pb.LogLevel.FATAL => LogLevel.fatal,
      _ => LogLevel.debug,
    };

    return LogEntity(level: level, time: message.time.toDateTime(), message: message.message);
  }

  static LogEntity parseSingbox(String log) {
    log = _stripAnsi(log).strip();
    DateTime? time;
    if (log.length > 25) {
      time = DateTime.tryParse(log.substring(6, 25));
    }
    if (time != null) {
      log = log.substring(26);
    }
    final level = LogLevel.values.firstOrNullWhere((e) {
      if (log.startsWith(e.name.toUpperCase())) {
        log = log.removePrefix(e.name.toUpperCase());
        return true;
      }
      return false;
    });
    return LogEntity(level: level, time: time, message: log.trim());
  }

  static LogEntity parseRawCoreLine(String log) {
    log = _stripAnsi(log).strip();
    final levelMatch = RegExp(r'^(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|PANIC)\s+').firstMatch(log);
    final level = _parseRawLevel(levelMatch?.group(1));
    if (levelMatch != null) log = log.substring(levelMatch.end).trim();
    return LogEntity(level: level, message: log);
  }

  static LogLevel? _parsePersistedLevel(String message) {
    final match = RegExp(r'^\[(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|PANIC|D|I|W|E|F)\]\s*').firstMatch(message);
    final raw = match?.group(1);
    return switch (raw) {
      'TRACE' => LogLevel.trace,
      'DEBUG' || 'D' => LogLevel.debug,
      'INFO' || 'I' => LogLevel.info,
      'WARN' || 'WARNING' || 'W' => LogLevel.warn,
      'ERROR' || 'E' => LogLevel.error,
      'FATAL' || 'F' => LogLevel.fatal,
      'PANIC' => LogLevel.panic,
      _ => null,
    };
  }

  static String _stripPersistedLevel(String message) {
    return message.replaceFirst(RegExp(r'^\[(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|PANIC|D|I|W|E|F)\]\s*'), '');
  }

  static LogLevel? _parseRawLevel(String? raw) {
    return switch (raw) {
      'TRACE' => LogLevel.trace,
      'DEBUG' => LogLevel.debug,
      'INFO' => LogLevel.info,
      'WARN' || 'WARNING' => LogLevel.warn,
      'ERROR' => LogLevel.error,
      'FATAL' => LogLevel.fatal,
      'PANIC' => LogLevel.panic,
      _ => null,
    };
  }

  static String _stripAnsi(String value) {
    return value.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
  }
}
