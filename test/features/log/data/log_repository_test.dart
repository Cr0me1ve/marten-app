import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart';
import 'package:marten/core/logger/logger_controller.dart';
import 'package:marten/features/log/data/log_path_resolver.dart';
import 'package:marten/features/log/data/log_repository.dart';
import 'package:marten/martencore/marten_core_service_provider.dart';

void main() {
  group('LogRepositoryImpl log-file coordination', () {
    late Directory tempDir;
    late ProviderContainer container;
    late LogPathResolver resolver;
    late LogRepositoryImpl repository;

    final metadata = LogExportMetadata(
      generatedAt: DateTime.utc(2026, 8, 10, 20, 5),
      appName: 'Marten',
      appVersion: '0.6.8',
      appBuildNumber: '608',
      platform: 'android',
      timeZoneOffset: const Duration(hours: 3),
      timeZoneName: 'MSK',
    );

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('marten-log-repository-test-');
      resolver = LogPathResolver(tempDir);
      container = ProviderContainer();
      final coreService = container.read(martenCoreServiceProvider);
      await coreService.setCoreLogFilePath(resolver.coreFile().path);
      LoggerController.init(resolver.appFile().path, debugConsole: false);
      repository = LogRepositoryImpl(singbox: coreService, logPathResolver: resolver);
    });

    tearDown(() async {
      await LoggerController.instance.removePrinter('app');
      container.dispose();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('exports data buffered in app.log through the synchronized writers', () async {
      await resolver.coreFile().writeAsString('core line\n', flush: true);
      LoggerController.instance.onLog(LogRecord(LogLevel.info, 'queued app line', 'test'));

      final file = await repository.prepareShareFile(metadata);
      final content = await file.readAsString();

      expect(content, contains('core line'));
      expect(content, contains('queued app line'));
    });

    test('does not let a queued app write reappear after clearLogs', () async {
      LoggerController.instance.onLog(LogRecord(LogLevel.info, 'must be cleared', 'test'));

      final result = await repository.clearLogs().run();
      await LoggerController.instance.runAppLogSynchronized(() async {});

      expect(result.isRight(), isTrue);
      expect(await resolver.appFile().readAsString(), isEmpty);
      expect(await resolver.coreFile().readAsString(), isEmpty);
    });
  });
}
