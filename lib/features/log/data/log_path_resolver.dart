import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:marten/core/diagnostics/energy_report.dart';

import 'package:marten/core/logger/crash_diagnostics_redactor.dart';
import 'package:marten/core/logger/log_file_retention.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';
import 'package:path/path.dart' as p;

// Producer reports contain static code identities only. Preserve validated
// symbols while the general log filter redacts surrounding private context;
// otherwise its IPv6/domain/token patterns corrupt namespace and source names.
String redactProfilingReport(String value) {
  final identities = <String>[];
  var prefix = 'MPROFILE';
  for (var suffix = 0; value.contains(prefix); suffix++) {
    prefix = 'MPROFILEX$suffix';
  }
  String protect(String identity) {
    final marker = '$prefix${identities.length}Z';
    identities.add(identity);
    return marker;
  }

  bool codeIdentity(String name) =>
      name.isNotEmpty &&
      name.length <= 512 &&
      !name.startsWith('/') &&
      !name.contains('0x') &&
      !RegExp('[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').hasMatch(name) &&
      RegExp(r'^[a-zA-Z0-9_/:*$<>()\[\]-]+$').hasMatch(name);
  final withoutPaths = value
      .replaceAll(RegExp(r'/(?:data|apex|system|vendor|Users|home)/[^\s]+'), '[private-path]')
      .replaceAll(RegExp(r'\b0x[0-9a-fA-F]+\b'), '[native-address]');
  final guarded = withoutPaths
      .split('\n')
      .map((inputLine) {
        var line = inputLine;
        if (line.startsWith('FUNCTION ')) {
          line = line.replaceAllMapped(
            RegExp(r'(\bsymbol=)([^\s]+)'),
            (m) => '${m[1]}${codeIdentity(m[2]!) ? protect(m[2]!) : m[2]}',
          );
          line = line.replaceAllMapped(
            RegExp(r'(\bsource=)([a-zA-Z0-9_-]+\.(?:go|kt|java|dart|s|c|h):[0-9]+)'),
            (m) => '${m[1]}${protect(m[2]!)}',
          );
        } else if (line.startsWith('STACK ') && line.contains(' frames=')) {
          final start = line.indexOf(' frames=') + 8;
          final frames = line.substring(start);
          if (frames.split(' <- ').every(codeIdentity)) {
            line = '${line.substring(0, start)}${protect(frames)}';
          }
        }
        return line;
      })
      .join('\n');
  return SensitiveDataRedactor.redact(
    guarded,
  ).replaceAllMapped(RegExp('$prefix([0-9]+)Z'), (m) => identities[int.parse(m[1]!)]);
}

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
  const LogPathResolver(this._workingDir, {bool russian = false}) : _russian = russian;

  final Directory _workingDir;
  final bool _russian;

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

  List<File> connectionDiagnosticFiles() => [
    File(p.join(directory.path, "connection-diagnostics.log.old")),
    File(p.join(directory.path, "connection-diagnostics.log")),
  ];

  List<File> quickSettingsDiagnosticFiles() => [
    File(p.join(directory.path, "quick-settings.log.old")),
    File(p.join(directory.path, "quick-settings.log")),
  ];

  List<File> captchaDiagnosticFiles() => [
    File(p.join(directory.path, "captcha.log.old")),
    File(p.join(directory.path, "captcha.log")),
  ];

  List<File> energyDiagnosticFiles() => [
    for (final process in ['app', 'core', 'diagnostics']) ...[
      File(p.join(directory.path, 'energy-$process.log.old')),
      File(p.join(directory.path, 'energy-$process.log')),
    ],
    File(p.join(directory.path, 'profiling-work.log.old')),
    File(p.join(directory.path, 'profiling-work.log')),
  ];

  File shareFile() {
    return File(p.join(directory.path, "marten-logs.txt"));
  }

  Future<File> prepareShareFile({required LogExportMetadata metadata, String? crashDiagnostics}) async {
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

    if (crashDiagnostics != null && crashDiagnostics.isNotEmpty) {
      buffer
        ..writeln('===== Android crash diagnostics =====')
        ..writeln('Source: crash-diagnostics')
        ..writeln(crashDiagnostics)
        ..writeln();
    }
    await _appendLogFiles(buffer, title: "Core logs", source: "core", files: coreFiles());
    await _appendLogFile(buffer, title: "App logs", source: "app", file: appFile());
    await _appendLogFiles(
      buffer,
      title: "Android connection diagnostics",
      source: "connection-diagnostics",
      files: connectionDiagnosticFiles(),
    );
    await _appendLogFiles(
      buffer,
      title: "Quick Settings diagnostics",
      source: "quick-settings",
      files: quickSettingsDiagnosticFiles(),
    );
    await _appendLogFiles(buffer, title: "CAPTCHA diagnostics", source: "captcha", files: captchaDiagnosticFiles());
    await _appendLogFiles(
      buffer,
      title: "Android energy diagnostics",
      source: "energy",
      files: energyDiagnosticFiles(),
    );

    final rawExport = buffer.toString();
    final safeExport = await Isolate.run(() => redactCrashDiagnostics(rawExport));
    await file.writeAsString(safeExport, flush: true);
    if (const bool.fromEnvironment('energy_profiling')) {
      return prepareDiagnosticBundle(file);
    }
    return file;
  }

  Future<File> prepareDiagnosticBundle(File logSnapshot) async {
    final profileDirectory = Directory(p.join(directory.path, 'energy-profiles-v3'));
    final profileFiles = <File>[];
    // Explicit producer filename contract. Never include raw ART traces,
    // native stderr, configs, arbitrary neighbours, symlinks or pending writes.
    final allowed = RegExp(
      r'^(core-(cpu-[0-5]|cpu-peak|cpu-idle|heap|allocs|goroutine|block|mutex)\.pprof|core-report-([0-5]|peak|idle)\.txt|core-status\.txt|core-self-check\.txt|art-(report-[0-5]|report-peak|status)\.txt|dart-(report-[0-5]|report-peak|status)\.txt|(core|art|dart)-history(?:-status\.txt|\.txt\.gz(?:\.old)?))$',
    );
    if (await profileDirectory.exists()) {
      await for (final entry in profileDirectory.list(followLinks: false)) {
        if (entry is File && allowed.hasMatch(p.basename(entry.path)) && await entry.length() <= 8 * 1024 * 1024) {
          profileFiles.add(entry);
        }
      }
    }
    final output = File(p.join(directory.path, 'marten-diagnostics.zip'));
    final snapshotBytes = await logSnapshot.readAsBytes();
    final profiles = <String, List<int>>{};
    final historySnapshotFailures = <String>[];
    final russian = _russian;
    var total = 0;
    profileFiles.sort((a, b) => a.path.compareTo(b.path));
    for (final profile in profileFiles) {
      try {
        int? committed;
        if (profile.path.endsWith('-history.txt.gz')) {
          final committedFile = File(profile.path.replaceFirst('-history.txt.gz', '-history-length.txt'));
          // Read the committed boundary first. Reading it after the payload
          // could observe a newer append and silently omit a healthy history.
          if (await committedFile.exists()) {
            committed = int.tryParse(await committedFile.readAsString());
            if (committed == null || committed < 0) {
              historySnapshotFailures.add(p.basename(profile.path).split('-').first);
              continue;
            }
          }
        }
        var bytes = await profile.readAsBytes();
        if (committed != null) {
          if (committed > bytes.length) {
            historySnapshotFailures.add(p.basename(profile.path).split('-').first);
            continue;
          }
          bytes = bytes.sublist(0, committed);
        }
        total += bytes.length;
        if (total > 48 * 1024 * 1024) break;
        profiles[p.basename(profile.path)] = bytes;
      } on FileSystemException {
        if (profile.path.contains('-history.txt.gz')) {
          historySnapshotFailures.add(p.basename(profile.path).split('-').first);
        }
      }
    }
    final archiveBytes = await Isolate.run(() {
      final archive = Archive()..addFile(ArchiveFile('marten-logs.txt', snapshotBytes.length, snapshotBytes));
      final report = StringBuffer()
        ..write(buildEnergyReport(utf8.decode(snapshotBytes, allowMalformed: true), profiles, russian: russian))
        ..writeln()
        ..writeln('Marten automatic profiling report')
        ..writeln('CPU samples identify executing functions; inclusive costs overlap.')
        ..writeln('Calibration is a deliberate 200 ms core self-check, not user traffic.')
        ..writeln('Heap/allocs/block/mutex reports state current or cumulative scope.')
        ..writeln('Device battery/current is whole-phone; UID traffic is shared across app/core.')
        ..writeln(
          'Radio energy, system wake-lock attribution and native frames unrecognized by Go/ART/Dart are not measured by ordinary app permissions.',
        )
        ..writeln('Raw ART traces, private pprof labels, object contents and server/profile data are excluded.')
        ..writeln();
      for (final source in historySnapshotFailures) {
        report.writeln('HISTORY outcome=unavailable source=$source category=snapshot_changed');
      }
      for (final source in ['core', 'art', 'dart']) {
        final status = profiles['$source-status.txt'];
        report.writeln(
          status == null ? 'SOURCE $source outcome=not_yet_available' : utf8.decode(status, allowMalformed: true),
        );
      }
      for (final entry in profiles.entries) {
        if (entry.key.contains('-history.txt.gz')) {
          try {
            final compressed = redactCompressedProfileHistory(entry.value);
            archive.addFile(ArchiveFile('profiles/${entry.key}', compressed.length, compressed));
          } catch (error) {
            final category = error is _ProfileHistoryLimit ? error.category : 'invalid_history';
            report.writeln('HISTORY outcome=unavailable source=${entry.key.split('-').first} category=$category');
          }
        } else if (entry.key.endsWith('.txt')) {
          final safe = redactProfilingReport(utf8.decode(entry.value, allowMalformed: true));
          final bytes = utf8.encode(safe);
          archive.addFile(ArchiveFile('profiles/${entry.key}', bytes.length, bytes));
          report.writeln('===== ${entry.key} =====');
          report.writeln(safe);
        } else {
          // Native producer explicitly sanitizes parsed pprof before encoding:
          // no dynamic labels, object values, paths, build IDs or PC addresses.
          archive.addFile(ArchiveFile('profiles/${entry.key}', entry.value.length, entry.value));
        }
      }
      final safeReport = utf8.encode(redactProfilingReport(report.toString()));
      archive.addFile(ArchiveFile('profiling-report.txt', safeReport.length, safeReport));
      return ZipEncoder().encode(archive);
    });
    final pending = File('${output.path}.pending');
    await pending.writeAsBytes(archiveBytes, flush: true);
    return pending.rename(output.path);
  }

  Future<String> readProfilingReport() async {
    final profileDirectory = Directory(p.join(directory.path, 'energy-profiles-v3'));
    final profiles = <String, List<int>>{};
    if (await profileDirectory.exists()) {
      await for (final entry in profileDirectory.list(followLinks: false)) {
        if (entry is! File ||
            !RegExp(
              r'^(core|art|dart)-(report-([0-5]|peak|idle)|status|history-status)\.txt$',
            ).hasMatch(p.basename(entry.path))) {
          continue;
        }
        try {
          if (await entry.length() <= 256 * 1024) profiles[p.basename(entry.path)] = await entry.readAsBytes();
        } on FileSystemException {
          /* Atomic producer rotation. */
        }
      }
    }
    final logs = StringBuffer();
    for (final file in energyDiagnosticFiles()) {
      try {
        if (await file.length() <= 1024 * 1024) logs.writeln(await file.readAsString());
      } on FileSystemException {
        /* Missing/rotating source. */
      }
    }
    final scalars = logs.toString();
    final russian = _russian;
    final ready = await Isolate.run(() => buildEnergyReport(scalars, profiles, russian: russian));
    final buffer = StringBuffer(ready)..writeln('\nMarten — CPU function profiles\n');
    for (final source in ['core', 'art', 'dart']) {
      buffer.writeln('===== $source =====');
      final status = File(p.join(profileDirectory.path, '$source-status.txt'));
      try {
        buffer.writeln(await status.readAsString());
      } on FileSystemException {
        buffer.writeln('outcome=not_yet_available');
      }
      if (source == 'core') {
        final check = File(p.join(profileDirectory.path, 'core-self-check.txt'));
        try {
          buffer.writeln(await check.readAsString());
        } on FileSystemException {
          buffer.writeln('self_check=pending');
        }
      }
      if (!await profileDirectory.exists()) continue;
      final peak = File(p.join(profileDirectory.path, '$source-report-peak.txt'));
      try {
        if (await peak.length() <= 256 * 1024) {
          buffer.writeln('PEAK RECORDED LOAD');
          buffer.writeln(await peak.readAsString());
        }
      } on FileSystemException {
        /* No completed peak window yet. */
      }
      final reports = <({File file, DateTime modified})>[];
      await for (final entry in profileDirectory.list(followLinks: false)) {
        if (entry is! File ||
            !RegExp(
              '^$source-report-'
              r'[0-5]\.txt$',
            ).hasMatch(p.basename(entry.path))) {
          continue;
        }
        try {
          if (await entry.length() <= 256 * 1024) reports.add((file: entry, modified: await entry.lastModified()));
        } on FileSystemException {
          /* The producer may rotate between reads. */
        }
      }
      reports.sort((a, b) => b.modified.compareTo(a.modified));
      if (reports.isNotEmpty) {
        try {
          buffer.writeln('LATEST WINDOW');
          buffer.writeln(await reports.first.file.readAsString());
        } on FileSystemException {
          /* The producer may rotate between reads. */
        }
      }
    }
    final content = buffer.toString();
    return Isolate.run(() => redactProfilingReport(content));
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

// A day's highly compressible stacks can expand far beyond 64 MiB. Stream
// individual lines through the same fail-closed sanitizer: neither the expanded
// history nor its redacted copy is retained in memory. Runs in the export isolate.
List<int> redactCompressedProfileHistory(List<int> bytes) {
  // Dart's chunked zlib decoder can accept an unfinished short gzip header as
  // empty input. Require at least a complete header/trailer before decoding.
  if (bytes.length < 18 || bytes[0] != 0x1f || bytes[1] != 0x8b || bytes[2] != 8) {
    throw const FormatException('invalid profile history');
  }
  final output = _ProfileHistoryOutputSink();
  final compressed = gzip.encoder.startChunkedConversion(output);
  final lines = _ProfileHistoryLineSink(compressed);
  final text = utf8.decoder.startChunkedConversion(lines);
  final decoded = _ProfileHistoryDecodedSink(text);
  final input = gzip.decoder.startChunkedConversion(decoded);
  for (var i = 0; i < bytes.length; i += 8192) {
    input.add(bytes.sublist(i, (i + 8192).clamp(0, bytes.length)));
  }
  input.close();
  return output.bytes.takeBytes();
}

class _ProfileHistoryLimit implements Exception {
  const _ProfileHistoryLimit(this.category);
  final String category;
}

class _ProfileHistoryOutputSink implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > 8 * 1024 * 1024) {
      throw const _ProfileHistoryLimit('compressed_size_limit');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}

class _ProfileHistoryDecodedSink implements Sink<List<int>> {
  _ProfileHistoryDecodedSink(this.output);
  final Sink<List<int>> output;
  int decodedBytes = 0;

  @override
  void add(List<int> data) {
    decodedBytes += data.length;
    if (decodedBytes > 512 * 1024 * 1024) throw const _ProfileHistoryLimit('decoded_size_limit');
    output.add(data);
  }

  @override
  void close() => output.close();
}

class _ProfileHistoryLineSink implements Sink<String> {
  _ProfileHistoryLineSink(this.output);
  final Sink<List<int>> output;
  final pending = StringBuffer();
  final batch = StringBuffer();

  void flush() {
    if (batch.isEmpty) return;
    output.add(utf8.encode(redactProfilingReport(batch.toString())));
    batch.clear();
  }

  @override
  void add(String data) {
    var start = 0;
    while (start < data.length) {
      final newline = data.indexOf('\n', start);
      final end = newline < 0 ? data.length : newline;
      if (pending.length + end - start > 64 * 1024) throw const _ProfileHistoryLimit('line_size_limit');
      pending.write(data.substring(start, end));
      if (newline < 0) break;
      batch.writeln(pending);
      pending.clear();
      // Amortize sanitizer setup without retaining an expanded history.
      if (batch.length >= 128 * 1024) flush();
      start = newline + 1;
    }
  }

  @override
  void close() {
    if (pending.isNotEmpty) batch.write(pending);
    flush();
    output.close();
  }
}
