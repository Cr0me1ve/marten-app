import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/log/data/log_path_resolver.dart';

void main() {
  group('LogPathResolver', () {
    late Directory tempDir;
    late LogPathResolver resolver;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('marten-logs-test-');
      resolver = LogPathResolver(tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    LogExportMetadata metadata(DateTime generatedAt) => LogExportMetadata(
      generatedAt: generatedAt,
      appName: 'Marten',
      appVersion: '0.6.8',
      appBuildNumber: '608',
      platform: 'android',
      timeZoneOffset: const Duration(hours: 3),
      timeZoneName: 'MSK',
    );

    const longStaticSymbol =
        'generated::VeryLongAotFunctionIdentifierThatLooksLikeAnOpaqueTokenButIsStaticCodeIdentityVeryLongAotFunctionIdentifierThatLooksLikeAnOpaqueTokenButIsStaticCodeIdentity';
    const profilingIdentityReport =
        '''
FUNCTION flat=1 inclusive=4 symbol=runtime::cgo source=cpu.go:78
FUNCTION flat=2 inclusive=3 symbol=marten-core/platform/mobile::energyProfileCalibration source=energy_profiling.go:123
FUNCTION flat=0 inclusive=2 symbol=$longStaticSymbol source=generated.go:456
STACK samples=1 frames=runtime::cgo:0 <- marten-core/platform/mobile::energyProfileCalibration:0
DETAIL marker=MPROFILE0Z url=https://private.example.test/sensitive/path uuid=123e4567-e89b-12d3-a456-426614174000 password=private-password native_path=/data/app/~~private-install-id==/app.marten.client/base.apk native_pc=0x7f123456
''';

    void expectSanitizedProfilingIdentities(String content) {
      for (final identity in [
        'symbol=runtime::cgo source=cpu.go:78',
        'symbol=marten-core/platform/mobile::energyProfileCalibration source=energy_profiling.go:123',
        'symbol=$longStaticSymbol source=generated.go:456',
        'frames=runtime::cgo:0 <- marten-core/platform/mobile::energyProfileCalibration:0',
        'marker=MPROFILE0Z',
      ]) {
        expect(content, contains(identity), reason: identity);
      }
      for (final privateValue in [
        'private.example.test',
        'sensitive/path',
        '123e4567-e89b-12d3-a456-426614174000',
        'private-password',
        '/data/app/',
        'private-install-id',
        '0x7f123456',
      ]) {
        expect(content, isNot(contains(privateValue)), reason: privateValue);
      }
    }

    test('prepares a fresh, redacted combined text file with diagnostic metadata', () async {
      await resolver.coreFile().writeAsString('core line dns.private.example\n');
      await resolver.rawCoreFile().parent.create(recursive: true);
      await resolver.rawCoreFile().writeAsString('raw core line\n');
      await resolver.appFile().writeAsString('app line');

      final file = await resolver.prepareShareFile(metadata: metadata(DateTime.utc(2026, 8, 10, 20, 5, 57, 123)));
      final content = await file.readAsString();

      expect(file.path, endsWith('marten-logs.txt'));
      expect(content, contains('Marten logs'));
      expect(content, contains('Generated local: 2026-08-10T23:05:57.123+03:00'));
      expect(content, contains('Generated UTC: 2026-08-10T20:05:57.123Z'));
      expect(content, contains('Time zone: MSK (UTC+03:00)'));
      expect(content, contains('App: Marten 0.6.8 (608)'));
      expect(content, contains('Platform: android'));
      expect(content, contains('===== Core logs ====='));
      expect(content, contains('Source: core'));
      expect(content, contains('core line'));
      expect(content, isNot(contains('dns.private.example')));
      expect(content, isNot(contains('Source: box.log')));
      expect(content, isNot(contains('raw core line')));
      expect(content, contains('===== App logs ====='));
      expect(content, contains('Source: app'));
      expect(content, contains('app line'));
    });

    test('places crash diagnostics before logs in the exported share file', () async {
      await resolver.coreFile().writeAsString('core log marker\n');
      const crashDiagnostics =
          'MARTEN_CRASH_DIAGNOSTICS schema=1 collection=enabled history_status=unsupported\n'
          'MARTEN_LOCAL_EXCEPTION process_role=app timestamp_ms=123 type=java.lang.IllegalStateException sdk_covered=true\n'
          '#0      app.marten.client.MainActivity.onCreate (package:marten/native_startup/native.dart:57:1)\n'
          'endpoint=https://secret.example.com/path?access_token=private-token';

      final file = await resolver.prepareShareFile(
        metadata: metadata(DateTime.utc(2026, 8, 10, 20, 5)),
        crashDiagnostics: crashDiagnostics,
      );
      final content = await file.readAsString();

      final diagnostics = content.indexOf('===== Android crash diagnostics =====');
      final core = content.indexOf('===== Core logs =====');
      expect(diagnostics, greaterThan(0));
      expect(content.indexOf('MARTEN_LOCAL_EXCEPTION'), greaterThan(diagnostics));
      expect(core, greaterThan(diagnostics));
      expect(content, contains('type=java.lang.IllegalStateException'));
      expect(
        content,
        contains('#0      app.marten.client.MainActivity.onCreate (package:marten/native_startup/native.dart:57:1)'),
      );
      expect(content, isNot(contains('secret.example.com')));
      expect(content, isNot(contains('private-token')));
      expect(content, contains('core log marker'));
    });

    test('recreates the share file with the current export timestamp', () async {
      await resolver.coreFile().writeAsString('first core line\n');

      final first = await resolver.prepareShareFile(metadata: metadata(DateTime.utc(2026, 8, 10, 20, 5)));
      final firstContent = await first.readAsString();
      expect(firstContent, contains('Generated UTC: 2026-08-10T20:05:00.000Z'));

      await resolver.coreFile().writeAsString('second core line\n');
      final second = await resolver.prepareShareFile(metadata: metadata(DateTime.utc(2026, 8, 11, 20, 5)));
      final secondContent = await second.readAsString();

      expect(second.path, first.path);
      expect(secondContent, contains('Generated UTC: 2026-08-11T20:05:00.000Z'));
      expect(secondContent, isNot(contains('Generated UTC: 2026-08-10T20:05:00.000Z')));
      expect(secondContent, contains('second core line'));
      expect(secondContent, isNot(contains('first core line')));
    });

    test('exports complete core and app logs larger than the former share tail limit', () async {
      final filler = 'x' * (600 * 1024);
      await resolver.coreFile().writeAsString('core early marker\n$filler\ncore late marker\n');
      await resolver.appFile().writeAsString('app early marker\n$filler\napp late marker\n');

      final file = await resolver.prepareShareFile(metadata: metadata(DateTime.utc(2026, 8, 10, 20, 5)));
      final content = await file.readAsString();

      for (final marker in ['core early marker', 'core late marker', 'app early marker', 'app late marker']) {
        expect(content, contains(marker));
      }
      expect(content, isNot(contains('[truncated to last')));
    });

    test('exports rotated Android diagnostics in chronological sections through shared redaction', () async {
      final diagnostics = <(List<File>, List<String>)>[
        (
          resolver.connectionDiagnosticFiles(),
          [
            'connection old https://secret.example.test/path?access_token=old-secret\n',
            'connection current client_secret=current-secret\n',
          ],
        ),
        (
          resolver.quickSettingsDiagnosticFiles(),
          [
            'quick settings old https://secret.example.test/old\n',
            'quick settings current session_token=current-secret\n',
          ],
        ),
        (
          resolver.captchaDiagnosticFiles(),
          ['captcha old http://127.0.0.1:8765/?token=old-secret\n', 'captcha current access_token=current-secret\n'],
        ),
      ];
      for (final entry in diagnostics) {
        for (var index = 0; index < entry.$1.length; index++) {
          await entry.$1[index].writeAsString(entry.$2[index]);
        }
      }

      final file = await resolver.prepareShareFile(metadata: metadata(DateTime.utc(2026, 8, 10, 20, 5)));
      final content = await file.readAsString();

      final connection = content.indexOf('===== Android connection diagnostics =====');
      final quickSettings = content.indexOf('===== Quick Settings diagnostics =====');
      final captcha = content.indexOf('===== CAPTCHA diagnostics =====');
      expect(connection, greaterThan(0));
      expect(quickSettings, greaterThan(connection));
      expect(captcha, greaterThan(quickSettings));
      for (final pair in [
        ('connection old', 'connection current'),
        ('quick settings old', 'quick settings current'),
        ('captcha old', 'captcha current'),
      ]) {
        expect(content.indexOf(pair.$1), lessThan(content.indexOf(pair.$2)));
      }
      for (final secret in ['secret.example.test', 'old-secret', 'current-secret', '127.0.0.1:8765']) {
        expect(content, isNot(contains(secret)), reason: secret);
      }
    });

    test('exports current and rotated energy logs through final shared redaction', () async {
      final energyFiles = resolver.energyDiagnosticFiles();
      expect(energyFiles, hasLength(8));
      await energyFiles[0].writeAsString('energy app old access_token=old-secret\n');
      await energyFiles[1].writeAsString('energy app current https://private.example.test/path\n');
      await energyFiles[2].writeAsString('energy core old client_secret=core-old-secret\n');
      await energyFiles[3].writeAsString('energy core current session_token=core-current-secret\n');
      await energyFiles[4].writeAsString('energy diagnostics old https://private.example.test/old\n');
      await energyFiles[5].writeAsString('energy diagnostics current access_token=diagnostics-secret\n');
      await energyFiles[6].writeAsString(
        'MARTEN_PROFILER_WORK schema=3 outcome=failed client_secret=work-old-secret\n',
      );
      await energyFiles[7].writeAsString(
        'MARTEN_PROFILER_WORK schema=3 outcome=complete client_secret=work-current-secret\n',
      );

      final file = await resolver.prepareShareFile(metadata: metadata(DateTime.utc(2026, 8, 10, 20, 5)));
      final content = await file.readAsString();

      expect(content, contains('===== Android energy diagnostics ====='));
      for (final marker in [
        'energy app old',
        'energy app current',
        'energy core old',
        'energy core current',
        'energy diagnostics old',
        'energy diagnostics current',
        'MARTEN_PROFILER_WORK schema=3 outcome=failed',
        'MARTEN_PROFILER_WORK schema=3 outcome=complete',
      ]) {
        expect(content, contains(marker));
      }
      expect(content.indexOf('energy app old'), lessThan(content.indexOf('energy app current')));
      expect(content.indexOf('energy core old'), lessThan(content.indexOf('energy core current')));
      expect(content.indexOf('energy diagnostics old'), lessThan(content.indexOf('energy diagnostics current')));
      expect(content.indexOf('outcome=failed'), lessThan(content.indexOf('outcome=complete')));
      for (final secret in [
        'old-secret',
        'private.example.test',
        'core-old-secret',
        'core-current-secret',
        'diagnostics-secret',
        'work-old-secret',
        'work-current-secret',
      ]) {
        expect(content, isNot(contains(secret)), reason: secret);
      }
    });

    test('diagnostic ZIP contains only allowlisted sanitized profiles and redacted reports', () async {
      final snapshot = File('${tempDir.path}/snapshot.txt')
        ..writeAsStringSync('''
safe redacted log snapshot
MARTEN_ENERGY schema=3 process=app sample=interval cpu_delta_ms=100 window_ms=1000 awake_ms=900 ordinary_window=true interactive=true
MARTEN_PROFILER_WORK schema=3 outcome=complete cpu_ms=5 loopback_rx_bytes=2048 loopback_tx_bytes=128
''');
      final profiles = Directory('${tempDir.path}/energy-profiles-v3')..createSync();
      await File('${profiles.path}/core-cpu-0.pprof').writeAsBytes([0x1f, 0x8b, 0x08, 0x00]);
      await File(
        '${profiles.path}/core-status.txt',
      ).writeAsString('MARTEN_PROFILE schema=3 process=core outcome=ready access_token=status-secret\n');
      await File(
        '${profiles.path}/core-self-check.txt',
      ).writeAsString('MARTEN_PROFILE_SELF_CHECK outcome=passed samples=3 calibration_cpu_ms=200\n');
      await File(
        '${profiles.path}/core-report-0.txt',
      ).writeAsString('$profilingIdentityReport client_secret=report-secret\n');
      await File(
        '${profiles.path}/core-report-peak.txt',
      ).writeAsString('CORE_CPU peak_window=true access_token=peak-secret\n');
      final historyPart1 = GZipEncoder().encode(
        'MARTEN_PROFILE schema=3 process=core segment=1 continuous=true\n'.codeUnits,
      )!;
      final historyPart2 = GZipEncoder().encode(
        'MARTEN_PROFILE schema=3 process=core segment=2 continuous=true\n'.codeUnits,
      )!;
      await File('${profiles.path}/core-history.txt.gz').writeAsBytes([...historyPart1, ...historyPart2]);
      await File(
        '${profiles.path}/core-history-status.txt',
      ).writeAsString('MARTEN_PROFILE schema=3 outcome=complete\n');
      await File(
        '${profiles.path}/art-report-0.txt',
      ).writeAsString('ART_PROFILE outcome=ready symbol=com:example:Worker::run\n');
      await File('${profiles.path}/art-report-peak.txt').writeAsString('ART_PROFILE peak_window=true\n');
      await File(
        '${profiles.path}/dart-status.txt',
      ).writeAsString('MARTEN_PROFILE source=dart outcome=ready samples=4\n');
      await File('${profiles.path}/dart-report-peak.txt').writeAsString('DART_CPU peak_window=true\n');
      await File('${profiles.path}/raw-art.trace').writeAsString('private raw trace data\n');
      await File('${profiles.path}/core-0-cpu.raw').writeAsString('private raw Go profile\n');
      await File('${profiles.path}/core-0.job').writeAsString('{"private":"capture metadata"}\n');
      await File('${profiles.path}/core-cpu-6.pprof').writeAsString('outside cpu rotation\n');
      await File('${profiles.path}/config.json').writeAsString('{"server":"private.example.test"}\n');
      await File('${profiles.path}/core-report-0.txt.pending').writeAsString('pending secret\n');
      await File('${profiles.path}/unrelated.pprof').writeAsString('unrecognized profile\n');
      await File('${tempDir.path}/outside-secret.txt').writeAsString('outside symlink secret\n');
      await Link('${profiles.path}/core-report-1.txt').create('${tempDir.path}/outside-secret.txt');
      final legacy = Directory('${tempDir.path}/energy-profiles')..createSync();
      await File('${legacy.path}/core-report-2.txt').writeAsString('legacy report must not export\n');

      final bundle = await resolver.prepareDiagnosticBundle(snapshot);
      final archive = ZipDecoder().decodeBytes(await bundle.readAsBytes());
      final entries = {for (final entry in archive.files) entry.name: entry};

      expect(bundle.path, endsWith('marten-diagnostics.zip'));
      expect(
        entries.keys,
        containsAll([
          'marten-logs.txt',
          'profiling-report.txt',
          'profiles/core-cpu-0.pprof',
          'profiles/core-status.txt',
          'profiles/core-self-check.txt',
          'profiles/core-report-0.txt',
          'profiles/core-report-peak.txt',
          'profiles/core-history.txt.gz',
          'profiles/core-history-status.txt',
          'profiles/art-report-0.txt',
          'profiles/art-report-peak.txt',
          'profiles/dart-status.txt',
          'profiles/dart-report-peak.txt',
        ]),
      );
      expect(entries.keys, hasLength(13));
      expect(
        entries.keys.any(
          (name) =>
              name.contains('raw-art') ||
              name.endsWith('.raw') ||
              name.endsWith('.job') ||
              name.contains('config') ||
              name.endsWith('.pending') ||
              name.contains('outside-secret') ||
              name.contains('cpu-6') ||
              name.contains('unrelated'),
        ),
        isFalse,
      );
      expect(entries['profiles/core-cpu-0.pprof']!.content, [0x1f, 0x8b, 0x08, 0x00]);
      final historyBytes = entries['profiles/core-history.txt.gz']!.content as List<int>;
      final history = String.fromCharCodes(GZipDecoder().decodeBytes(historyBytes));
      expect(history, contains('segment=1'));
      expect(history, contains('segment=2'));
      expect(
        String.fromCharCodes(entries['marten-logs.txt']!.content as List<int>),
        contains('safe redacted log snapshot'),
      );

      final report = String.fromCharCodes(entries['profiling-report.txt']!.content as List<int>);
      final nativeReport = String.fromCharCodes(entries['profiles/core-report-0.txt']!.content as List<int>);
      expect(report, contains('MARTEN_PROFILE_SELF_CHECK outcome=passed'));
      expect(report, contains('CORE_CPU peak_window=true'));
      expect(
        report.contains('Largest observed process CPU load (including in-process recording): Interface.') ||
            report.contains('Основная наблюдаемая CPU-нагрузка процесса (включая встроенную запись): Интерфейс.'),
        isTrue,
      );
      expect(
        report.contains('Operations: 1, unavailable: 0.') || report.contains('Выполнено операций: 1, недоступных: 0.'),
        isTrue,
      );
      expectSanitizedProfilingIdentities(report);
      expectSanitizedProfilingIdentities(nativeReport);
      for (final secret in [
        'status-secret',
        'report-secret',
        'peak-secret',
        'private raw trace data',
        'private raw Go profile',
        'capture metadata',
        'legacy report must not export',
        'private.example.test',
        'outside symlink secret',
      ]) {
        expect(report, isNot(contains(secret)), reason: secret);
        expect(nativeReport, isNot(contains(secret)), reason: secret);
      }
    });

    test(
      'streams large concatenated history members through redaction into the diagnostic ZIP',
      () async {
        final snapshot = File('${tempDir.path}/snapshot.txt')..writeAsStringSync('safe log snapshot\n');
        final profiles = Directory('${tempDir.path}/energy-profiles-v3')..createSync();
        final history = BytesBuilder(copy: false);
        const startLine = 'CORE_RECORDING schema=3 marker=history-start';
        const secretLine = 'CORE_RECORDING schema=3 access_token=private-history-token';
        const endLine = 'CORE_RECORDING schema=3 marker=history-end';
        const fillerRowsPerMember = 18;
        const fillerMembers = 65;
        final fillerLine = 'CORE_RECORDING schema=3 metric=${'value=1 ' * 7500}';
        expect(fillerLine.length, lessThan(64 * 1024));
        final fillerText = '${List<String>.filled(fillerRowsPerMember, fillerLine).join('\n')}\n';
        final fillerMember = GZipEncoder().encode(fillerText.codeUnits)!;
        final startMember = GZipEncoder().encode('$startLine\n$secretLine\n'.codeUnits)!;
        final endMember = GZipEncoder().encode('$endLine\n'.codeUnits)!;
        var inputDecodedBytes = startLine.length + secretLine.length + endLine.length + 3;
        inputDecodedBytes += fillerText.length * fillerMembers;
        history.add(startMember);
        for (var member = 0; member < fillerMembers; member++) {
          // Reuse the same compressed member while exercising concatenated-member decoding.
          history.add(fillerMember);
        }
        history.add(endMember);
        expect(inputDecodedBytes, greaterThan(64 * 1024 * 1024));
        await File('${profiles.path}/core-history.txt.gz').writeAsBytes(history.takeBytes());

        final bundle = await resolver.prepareDiagnosticBundle(snapshot);
        final archive = ZipDecoder().decodeBytes(await bundle.readAsBytes());
        final historyBytes =
            archive.files.singleWhere((entry) => entry.name == 'profiles/core-history.txt.gz').content as List<int>;
        final inspection = _HistoryInspectionSink();
        final decoder = gzip.decoder.startChunkedConversion(inspection);
        for (var offset = 0; offset < historyBytes.length; offset += 8192) {
          decoder.add(historyBytes.sublist(offset, (offset + 8192).clamp(0, historyBytes.length)));
        }
        decoder.close();

        expect(inspection.decodedBytes, greaterThan(64 * 1024 * 1024));
        expect(inspection.sawStart, isTrue);
        expect(inspection.sawEnd, isTrue);
        expect(inspection.sawPrivateToken, isFalse);
        final report = String.fromCharCodes(
          archive.files.singleWhere((entry) => entry.name == 'profiling-report.txt').content as List<int>,
        );
        expect(report, isNot(contains('HISTORY outcome=unavailable source=core')));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('omits malformed and oversized history with explicit failure categories', () async {
      final snapshot = File('${tempDir.path}/snapshot.txt')..writeAsStringSync('safe log snapshot\n');
      final profiles = Directory('${tempDir.path}/energy-profiles-v3')..createSync();
      const privateToken = 'private-overlong-history-token';
      final cases = <(String, List<int>)>[
        ('invalid_history', [0x1f, 0x8b, 0x08, 0x00, 0xff]),
        ('line_size_limit', GZipEncoder().encode(('x' * (64 * 1024 + 1) + ' access_token=$privateToken').codeUnits)!),
      ];

      for (final (category, compressed) in cases) {
        await File('${profiles.path}/core-history.txt.gz').writeAsBytes(compressed);
        final bundle = await resolver.prepareDiagnosticBundle(snapshot);
        final archive = ZipDecoder().decodeBytes(await bundle.readAsBytes());
        final entries = {for (final entry in archive.files) entry.name: entry};
        final report = String.fromCharCodes(entries['profiling-report.txt']!.content as List<int>);

        expect(entries.containsKey('profiles/core-history.txt.gz'), isFalse, reason: category);
        expect(report, contains('HISTORY outcome=unavailable source=core category=$category'));
        expect(report, isNot(contains(privateToken)));
      }
    });

    test('reports a changed history snapshot boundary and still exports the diagnostic ZIP', () async {
      final snapshot = File('${tempDir.path}/snapshot.txt')..writeAsStringSync('safe log snapshot\n');
      final profiles = Directory('${tempDir.path}/energy-profiles-v3')..createSync();
      final historyFile = File('${profiles.path}/core-history.txt.gz');
      final compressed = GZipEncoder().encode('CORE_RECORDING schema=3 segment=1\n'.codeUnits)!;
      await historyFile.writeAsBytes(compressed);
      await File('${profiles.path}/core-history-length.txt').writeAsString('${compressed.length + 1}');

      final bundle = await resolver.prepareDiagnosticBundle(snapshot);
      final archive = ZipDecoder().decodeBytes(await bundle.readAsBytes());
      final entries = {for (final entry in archive.files) entry.name: entry};
      final report = String.fromCharCodes(entries['profiling-report.txt']!.content as List<int>);

      expect(bundle.existsSync(), isTrue);
      expect(entries.containsKey('profiles/core-history.txt.gz'), isFalse);
      expect(report, contains('HISTORY outcome=unavailable source=core category=snapshot_changed'));
    });

    test('profiling report view reads statuses and only the newest bounded report per source', () async {
      final profiles = Directory('${tempDir.path}/energy-profiles-v3')..createSync();
      await File(
        '${profiles.path}/core-status.txt',
      ).writeAsString('MARTEN_PROFILE schema=3 process=core outcome=ready access_token=status-secret\n');
      await File(
        '${profiles.path}/core-self-check.txt',
      ).writeAsString('MARTEN_PROFILE_SELF_CHECK outcome=passed samples=9\n');
      await File('${profiles.path}/art-status.txt').writeAsString('MARTEN_PROFILE source=art outcome=ready\n');
      await File('${profiles.path}/dart-status.txt').writeAsString('MARTEN_PROFILE source=dart outcome=ready\n');
      final olderCore = File('${profiles.path}/core-report-0.txt');
      final newestCore = File('${profiles.path}/core-report-1.txt');
      final oldArt = File('${profiles.path}/art-report-0.txt');
      final currentDart = File('${profiles.path}/dart-report-5.txt');
      await olderCore.writeAsString('old core function\n');
      await newestCore.writeAsString('$profilingIdentityReport client_secret=report-secret\n');
      await File('${profiles.path}/core-report-peak.txt').writeAsString('core peak profile\n');
      await oldArt.writeAsString('ART profile function\n');
      await File('${profiles.path}/art-report-peak.txt').writeAsString('ART peak profile\n');
      await currentDart.writeAsString('Dart profile function\n');
      await File('${profiles.path}/dart-report-peak.txt').writeAsString('Dart peak profile\n');
      await File('${profiles.path}/core-report-6.txt').writeAsString('out of range report\n');
      await File('${profiles.path}/private-art.trace').writeAsString('raw private trace\n');
      await File('${profiles.path}/core-0-cpu.raw').writeAsString('private raw Go profile\n');
      await File('${profiles.path}/core-0.job').writeAsString('{"private":"capture metadata"}\n');
      final energyFiles = resolver.energyDiagnosticFiles();
      await energyFiles[6].writeAsString('MARTEN_PROFILER_WORK schema=3 outcome=complete cpu_ms=5\n');
      await energyFiles[7].writeAsString('MARTEN_PROFILER_WORK schema=3 outcome=complete cpu_ms=7\n');
      await olderCore.setLastModified(DateTime.utc(2026, 1, 1));
      await newestCore.setLastModified(DateTime.utc(2026, 1, 2));

      final report = await resolver.readProfilingReport();

      expect(report, contains('outcome=ready'));
      expect(
        report.contains('Operations: 2, unavailable: 0.') || report.contains('Выполнено операций: 2, недоступных: 0.'),
        isTrue,
      );
      expect(
        report.contains('Summary pending: no complete measured interval yet') ||
            report.contains('Итог пока не готов: ещё нет полного измеренного интервала'),
        isTrue,
      );
      expect(report, contains('MARTEN_PROFILE_SELF_CHECK outcome=passed samples=9'));
      expectSanitizedProfilingIdentities(report);
      expect(report, contains('core peak profile'));
      expect(report, isNot(contains('old core function')));
      expect(report, contains('ART profile function'));
      expect(report, contains('ART peak profile'));
      expect(report, contains('Dart profile function'));
      expect(report, contains('Dart peak profile'));
      for (final privateValue in [
        'status-secret',
        'report-secret',
        'out of range report',
        'raw private trace',
        'private raw Go profile',
        'capture metadata',
      ]) {
        expect(report, isNot(contains(privateValue)), reason: privateValue);
      }
    });

    test('deletes every unsafe legacy raw log while retaining safe destinations', () async {
      const coreContent = 'safe core log\n';
      const appContent = 'safe app log\n';
      await resolver.coreFile().writeAsString(coreContent);
      await resolver.appFile().writeAsString(appContent);
      final unsafeFiles = resolver.unsafeRawFiles();
      for (final file in unsafeFiles) {
        await file.parent.create(recursive: true);
        await file.writeAsString('unsafe ${file.path}\n');
      }

      await resolver.deleteUnsafeRawFiles();

      for (final file in unsafeFiles) {
        expect(await file.exists(), isFalse, reason: file.path);
      }
      expect(await resolver.coreFile().readAsString(), coreContent);
      expect(await resolver.appFile().readAsString(), appContent);
    });
  });
}

class _HistoryInspectionSink implements Sink<List<int>> {
  var decodedBytes = 0;
  var sawStart = false;
  var sawEnd = false;
  var sawPrivateToken = false;
  var _tail = '';

  @override
  void add(List<int> data) {
    decodedBytes += data.length;
    final text = '$_tail${String.fromCharCodes(data)}';
    sawStart |= text.contains('marker=history-start');
    sawEnd |= text.contains('marker=history-end');
    sawPrivateToken |= text.contains('private-history-token');
    _tail = text.substring(text.length > 64 ? text.length - 64 : 0);
  }

  @override
  void close() {}
}
