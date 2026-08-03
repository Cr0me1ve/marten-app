import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:marten/core/logger/log_file_retention.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';
import 'package:path/path.dart' as p;

class LogPathResolver {
  const LogPathResolver(this._workingDir);

  static const _shareTailBytes = 512 * 1024;

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

  Future<File> prepareShareFile() async {
    await LogFileRetention.prepare(coreFile());
    await LogFileRetention.prepare(appFile());

    final file = shareFile();
    final buffer = StringBuffer()
      ..writeln("Marten logs")
      ..writeln();

    await _appendLogFiles(buffer, title: "Core logs", files: coreFiles());
    await _appendLogFile(buffer, title: "App logs", file: appFile());

    await file.writeAsString(SensitiveDataRedactor.redact(buffer.toString()), flush: true);
    return file;
  }

  Future<void> _appendLogFiles(StringBuffer buffer, {required String title, required List<File> files}) async {
    buffer
      ..writeln("===== $title =====")
      ..writeln();

    for (final file in files) {
      await _appendLogFile(buffer, file: file);
    }
  }

  Future<void> _appendLogFile(StringBuffer buffer, {String? title, required File file}) async {
    if (title != null) {
      buffer
        ..writeln("===== $title =====")
        ..writeln();
    }

    buffer.writeln("Source: ${p.relative(file.path, from: directory.path)}");

    if (!await file.exists()) {
      buffer.writeln("(missing)");
    } else {
      final content = SensitiveDataRedactor.redact(await _readShareTail(file));
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

  Future<String> _readShareTail(File file) async {
    final length = await file.length();
    if (length <= _shareTailBytes) {
      return utf8.decode(await file.readAsBytes(), allowMalformed: true);
    }

    final raf = await file.open();
    try {
      final start = length - _shareTailBytes;
      await raf.setPosition(start);
      final bytes = await raf.read(math.min(_shareTailBytes, length));
      final content = utf8.decode(bytes, allowMalformed: true);
      final newline = content.indexOf('\n');
      final tail = newline >= 0 ? content.substring(newline + 1) : content;
      return '[truncated to last $_shareTailBytes bytes]\n$tail';
    } finally {
      await raf.close();
    }
  }
}
