// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:loggy/loggy.dart';
import 'package:marten/core/logger/buffered_file_writer.dart';
import 'package:marten/core/logger/log_file_retention.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';

class ConsolePrinter extends LoggyPrinter {
  const ConsolePrinter({this.showColors = false, this.minLevel = LogLevel.debug});

  final bool showColors;
  final LogLevel minLevel;

  static final _levelColors = {
    LogLevel.debug: AnsiColor(foregroundColor: AnsiColor.grey(0.5), italic: true),
    LogLevel.info: AnsiColor(foregroundColor: 35),
    LogLevel.warning: AnsiColor(foregroundColor: 214),
    LogLevel.error: AnsiColor(foregroundColor: 196),
  };

  @override
  void onLog(LogRecord record) {
    if (record.level.priority < minLevel.priority) return;
    final colorize = showColors && stdout.supportsAnsiEscapes;
    final time = record.time.toIso8601String().split('T')[1];
    final callerFrame = record.callerFrame == null ? ' ' : ' (${record.callerFrame?.location}) ';

    final String logLevel;
    if (colorize) {
      logLevel = record.level.name.toUpperCase().padRight(8);
    } else {
      logLevel = "[${record.level.name.toUpperCase()}]".padRight(10);
    }

    final color = showColors ? levelColor(record.level) ?? AnsiColor() : AnsiColor();

    print(color('$time $logLevel [${record.loggerName}]$callerFrame${SensitiveDataRedactor.redact(record.message)}'));

    if (record.stackTrace != null) {
      print(SensitiveDataRedactor.redactObject(record.stackTrace));
    }
  }

  AnsiColor? levelColor(LogLevel level) {
    return _levelColors[level];
  }
}

class FileLogPrinter extends LoggyPrinter {
  FileLogPrinter(String filePath, {this.minLevel = LogLevel.debug}) : _writer = BufferedFileWriter(File(filePath));

  final BufferedFileWriter _writer;
  final LogLevel minLevel;

  @override
  void onLog(LogRecord record) {
    if (record.level.priority < minLevel.priority) return;
    final safeMessage = SensitiveDataRedactor.redact(record.message);
    final buffer = StringBuffer()
      ..writeln(
        '${LogFileRetention.formatTimestamp(record.time)} - '
        '[${record.level.toString().substring(0, 1)}] ${record.loggerName}: $safeMessage',
      );
    if (record.error != null) {
      buffer.writeln(SensitiveDataRedactor.redactObject(record.error));
    }
    if (record.stackTrace != null) {
      buffer.writeln(SensitiveDataRedactor.redactObject(record.stackTrace));
    }
    _writer.add(buffer.toString(), timestamp: record.time);
  }

  Future<T> runSynchronized<T>(Future<T> Function() operation) => _writer.runSynchronized(operation);

  Future<void> dispose() => _writer.close();
}
