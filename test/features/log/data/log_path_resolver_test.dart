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

    test('prepares a combined text file for sharing', () async {
      await resolver.coreFile().writeAsString('core line dns.private.example\n');
      await resolver.rawCoreFile().parent.create(recursive: true);
      await resolver.rawCoreFile().writeAsString('raw core line\n');
      await resolver.appFile().writeAsString('app line');

      final file = await resolver.prepareShareFile();
      final content = await file.readAsString();

      expect(file.path, endsWith('marten-logs.txt'));
      expect(content, contains('Marten logs'));
      expect(content, contains('===== Core logs ====='));
      expect(content, contains('Source: [redacted-host]'));
      expect(content, contains('core line'));
      expect(content, isNot(contains('dns.private.example')));
      expect(content, isNot(contains('Source: data/box.log')));
      expect(content, isNot(contains('raw core line')));
      expect(content, contains('===== App logs ====='));
      expect(content, contains('Source: [redacted-host]'));
      expect(content, contains('app line'));
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
