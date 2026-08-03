import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/logger/log_file_retention.dart';
import 'package:marten/features/log/data/log_parser.dart';
import 'package:marten/features/log/model/log_entity.dart';
import 'package:marten/features/log/model/log_level.dart';

void main() {
  group('LogFileRetention', () {
    test('ensureExists creates parent/file without pruning existing stale content, while prepare prunes it', () async {
      final dir = await Directory.systemTemp.createTemp('marten-log-retention-ensure-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/nested/logs/app.log');

      await LogFileRetention.ensureExists(file);
      expect(await file.parent.exists(), isTrue);
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), isEmpty);

      const staleContent = '2000-01-01T00:00:00.000 - [INFO] preserved-until-pruned\n';
      await file.writeAsString(staleContent);
      await LogFileRetention.ensureExists(file);
      expect(await file.readAsString(), staleContent);

      await LogFileRetention.prepare(file);
      expect(await file.readAsString(), isEmpty);
    });

    test('keeps ordinary entries for an hour and error-related entries for a day', () {
      final now = DateTime(2026, 6, 3, 15);
      final content = [
        '2026-06-02T14:59:59.000 - [ERROR] expired error',
        '2026-06-02T15:00:00.000 - [WARN] warning boundary',
        '2026-06-03T13:59:59.000 - [INFO] expired info',
        '2026-06-03T14:00:00.000 - [DEBUG] debug boundary',
        '2026-06-03T14:30:00.000 - [INFO] recent info',
        '',
      ].join('\n');

      final trimmed = LogFileRetention.trimToRetention(content, now: now);

      expect(trimmed, isNot(contains('expired error')));
      expect(trimmed, contains('warning boundary'));
      expect(trimmed, isNot(contains('expired info')));
      expect(trimmed, contains('debug boundary'));
      expect(trimmed, contains('recent info'));
      expect(trimmed, endsWith('\n'));
    });

    test('keeps the 20 entries immediately before an error for a day', () {
      final now = DateTime(2026, 6, 3, 15);
      final content = [
        for (var index = 0; index < 25; index++)
          '2026-06-03T12:00:${index.toString().padLeft(2, '0')}.000 - [INFO] context-$index',
        '2026-06-03T14:30:00.000 - [ERROR] failure',
        '',
      ].join('\n');

      final trimmed = LogFileRetention.trimToRetention(content, now: now);
      final retained = LogFileRetention.entries(trimmed);

      expect(retained, hasLength(21));
      expect(trimmed, isNot(contains('context-4')));
      expect(trimmed, contains('context-5'));
      expect(trimmed, contains('context-24'));
      expect(trimmed, contains('failure'));
    });

    test('warning is retained for a day without promoting preceding context', () {
      final now = DateTime(2026, 6, 3, 15);
      final content = [
        '2026-06-03T12:00:00.000 - [INFO] old context',
        '2026-06-03T14:30:00.000 - [WARNING] warning',
        '',
      ].join('\n');

      final trimmed = LogFileRetention.trimToRetention(content, now: now);

      expect(trimmed, isNot(contains('old context')));
      expect(trimmed, contains('warning'));
    });

    test('recognizes short app log levels when retaining error context', () {
      final now = DateTime(2026, 6, 3, 15);
      final content = [
        '2026-06-03T12:00:00.000 - [I] app context',
        '2026-06-03T14:30:00.000 - [E] app failure',
        '',
      ].join('\n');

      final trimmed = LogFileRetention.trimToRetention(content, now: now);

      expect(trimmed, contains('app context'));
      expect(trimmed, contains('app failure'));
    });

    test('retains lowercase model levels used by the logs UI', () {
      final now = DateTime(2026, 6, 3, 15);
      final logs = [
        LogEntity(level: LogLevel.info, time: DateTime(2026, 6, 3, 12), message: 'ui context'),
        LogEntity(level: LogLevel.error, time: DateTime(2026, 6, 3, 14, 30), message: 'ui failure'),
      ];

      final retained = LogFileRetention.retainItems<LogEntity>(
        logs,
        timestampOf: (log) => log.time,
        levelOf: (log) => log.level?.name,
        now: now,
      );

      expect(retained, logs);
    });

    test('expired error no longer protects its preceding context', () {
      final now = DateTime(2026, 6, 3, 15);
      final content = [
        '2026-06-02T13:59:58.000 - [INFO] old context',
        '2026-06-02T13:59:59.000 - [FATAL] expired failure',
        '',
      ].join('\n');

      expect(LogFileRetention.trimToRetention(content, now: now), isEmpty);
    });

    test('parses legacy time-only prefixes against the current day', () {
      final now = DateTime(2026, 6, 3, 0, 0, 30);

      expect(
        LogFileRetention.timestampFromLine('23:59:59.123456 - previous day', now: now),
        DateTime(2026, 6, 2, 23, 59, 59, 123, 456),
      );
    });

    test('groups multiline entries and parses persisted levels', () {
      final logs = LogParser.parsePersistedContent(
        ['2026-06-03T14:30:00.000 - [ERROR] first line', 'second line\u0000', ''].join('\n'),
      );

      expect(logs, hasLength(1));
      expect(logs.single.level, LogLevel.error);
      expect(logs.single.time, DateTime(2026, 6, 3, 14, 30));
      expect(logs.single.message, 'first line\nsecond line');
    });

    test('parses raw core log lines', () {
      final log = LogParser.parseRawCoreLine(
        'INFO [170 1ms] outbound/direct[direct]: outbound connection to example.com:443',
      );

      expect(log.level, LogLevel.info);
      expect(log.time, isNull);
      expect(log.message, '[170 1ms] outbound/direct[direct]: outbound connection to example.com:443');
    });

    test('keeps entries without timestamps', () {
      final trimmed = LogFileRetention.trimToRetention('raw legacy line\n', now: DateTime(2026, 6, 3, 15));

      expect(trimmed, 'raw legacy line\n');
    });

    test('prunes malformed utf8 log files without throwing', () async {
      final dir = await Directory.systemTemp.createTemp('marten-malformed-log-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/box.log');
      await file.writeAsBytes([...'2026-06-03T14:30:00.000 - [INFO] kept '.codeUnits, 0xff, 0xfe, 0x0a]);

      await LogFileRetention.prune(file, now: DateTime(2026, 6, 3, 15));

      expect(await file.readAsString(), contains('kept'));
    });
  });
}
