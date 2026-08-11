import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:marten/core/logger/log_file_retention.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';
import 'package:path/path.dart' as p;

class LogExportMetadata {
  const LogExportMetadata({
    required this.generatedAt,
    required this.appName,
    required this.appVersion,
    required this.appBuildNumber,
    required this.platform,
    required this.timeZoneOffset,
    required this.timeZoneName,
  });

  factory LogExportMetadata.now({
    required String appName,
    required String appVersion,
    required String appBuildNumber,
    required String platform,
  }) {
    final generatedAt = DateTime.now();
    return LogExportMetadata(
      generatedAt: generatedAt,
      appName: appName,
      appVersion: appVersion,
      appBuildNumber: appBuildNumber,
      platform: platform,
      timeZoneOffset: generatedAt.timeZoneOffset,
      timeZoneName: generatedAt.timeZoneName,
    );
  }

  final DateTime generatedAt;
  final String appName;
  final String appVersion;
  final String appBuildNumber;
  final String platform;
  final Duration timeZoneOffset;
  final String timeZoneName;

  String get generatedAtUtc => generatedAt.toUtc().toIso8601String();

  String get generatedAtLocal {
    final shifted = generatedAt.toUtc().add(timeZoneOffset).toIso8601String();
    final wallClock = shifted.endsWith('Z') ? shifted.substring(0, shifted.length - 1) : shifted;
    return '$wallClock${_formatUtcOffset(timeZoneOffset)}';
  }

  String get formattedTimeZone => '$timeZoneName (UTC${_formatUtcOffset(timeZoneOffset)})';

  static String _formatUtcOffset(Duration offset) {
    final sign = offset.isNegative ? '-' : '+';
    final totalMinutes = offset.inMinutes.abs();
    final hours = (totalMinutes ~/ 60).toString().padLeft(2, '0');
    final minutes = (totalMinutes % 60).toString().padLeft(2, '0');
    return '$sign$hours:$minutes';
  }
}

class LogPathResolver {
  const LogPathResolver(this._workingDir);

  final Directory _workingDir;

  Directory get directory => _workingDir;

  File coreFile() {
    return File(p.join(directory.path, "box.log"));
  }

  File rawCoreFile() {
    return File(p.join(directory.path, "data", "box.log"));
  }

  List<File> coreFiles() {
    return [coreFile()];
  }

  List<File> unsafeRawFiles() => [
    rawCoreFile(),
    File(p.join(directory.path, "data", "stderrGRPC_BACKGROUND_INSECURE.log")),
    File(p.join(directory.path, "data", "stderrGRPC_NORMAL_INSECURE.log")),
    File(p.join(directory.path, "stderr.log")),
    File(p.join(directory.path, "stderr2.log")),
  ];

  Future<void> deleteUnsafeRawFiles() async {
    await Future.wait(
      unsafeRawFiles().map((file) async {
        if (await file.exists()) await file.delete();
      }),
    );
  }

  File appFile() {
    return File(p.join(directory.path, "app.log"));
  }

  File shareFile() {
    return File(p.join(directory.path, "marten-logs.txt"));
  }

  Future<File> prepareShareFile({required LogExportMetadata metadata}) async {
    await LogFileRetention.prepare(coreFile());
    await LogFileRetention.prepare(appFile());

    final file = shareFile();
    final buffer = StringBuffer()
      ..writeln("Marten logs")
      ..writeln("Generated local: ${metadata.generatedAtLocal}")
      ..writeln("Generated UTC: ${metadata.generatedAtUtc}")
      ..writeln("Time zone: ${metadata.formattedTimeZone}")
      ..writeln("App: ${metadata.appName} ${metadata.appVersion} (${metadata.appBuildNumber})")
      ..writeln("Platform: ${metadata.platform}")
      ..writeln("Log timestamps use local device time; legacy entries without an offset use the export time zone.")
      ..writeln();

    await _appendLogFiles(buffer, title: "Core logs", source: "core", files: coreFiles());
    await _appendLogFile(buffer, title: "App logs", source: "app", file: appFile());

    final rawExport = buffer.toString();
    final safeExport = await Isolate.run(() => SensitiveDataRedactor.redact(rawExport));
    await file.writeAsString(safeExport, flush: true);
    return file;
  }

  Future<void> _appendLogFiles(
    StringBuffer buffer, {
    required String title,
    required String source,
    required List<File> files,
  }) async {
    buffer
      ..writeln("===== $title =====")
      ..writeln();

    for (final file in files) {
      await _appendLogFile(buffer, source: source, file: file);
    }
  }

  Future<void> _appendLogFile(StringBuffer buffer, {String? title, required String source, required File file}) async {
    if (title != null) {
      buffer
        ..writeln("===== $title =====")
        ..writeln();
    }

    buffer.writeln("Source: $source");

    if (!await file.exists()) {
      buffer.writeln("(missing)");
    } else {
      final content = await _readShareContent(file);
      if (content.trim().isEmpty) {
        buffer.writeln("(empty)");
      } else {
        buffer.write(content);
        if (!content.endsWith("\n")) {
          buffer.writeln();
        }
      }
    }

    buffer.writeln();
  }

  Future<String> _readShareContent(File file) async {
    return utf8.decode(await file.readAsBytes(), allowMalformed: true);
  }
}
