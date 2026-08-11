import 'dart:io';

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
