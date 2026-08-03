import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loggy/loggy.dart';
import 'package:marten/core/logger/custom_logger.dart';
import 'package:marten/core/logger/logger_controller.dart';

class _CapturingPrinter extends LoggyPrinter {
  final records = <LogRecord>[];

  @override
  void onLog(LogRecord record) => records.add(record);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory logDirectory;
  late LoggerController controller;
  late _CapturingPrinter capture;

  setUp(() async {
    logDirectory = await Directory.systemTemp.createTemp('marten-logger-controller-test-');
    LoggerController.init('${logDirectory.path}/app.log', debugConsole: false);
    controller = LoggerController.instance;
    capture = _CapturingPrinter();
    controller.addPrinter('capture', capture);
  });

  tearDown(() async {
    await controller.removePrinter('app');
    Loggy.initLoggy(logPrinter: const ConsolePrinter(), logOptions: const LogOptions(LogLevel.info));
    await logDirectory.delete(recursive: true);
  });

  test('applyDebugMode enables debug records only when requested', () {
    LoggerController.applyDebugMode(true);
    controller.loggy.debug('debug-enabled');

    expect(capture.records.map((record) => record.message), contains('debug-enabled'));
    expect(capture.records.single.level, LogLevel.debug);
  });

  test('applyDebugMode filters debug records but preserves info records when disabled', () {
    LoggerController.applyDebugMode(false);
    runZoned(() {
      controller.loggy.debug('debug-disabled');
      controller.loggy.info('info-disabled');
    }, zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}));

    expect(capture.records.map((record) => record.message), isNot(contains('debug-disabled')));
    expect(capture.records.map((record) => record.message), contains('info-disabled'));
    expect(capture.records.single.level, LogLevel.info);
  });

  test('ConsolePrinter at info level drops debug but preserves info without printing to the test output', () {
    final lines = <String>[];
    const printer = ConsolePrinter(minLevel: LogLevel.info);

    runZoned(() {
      printer.onLog(LogRecord(LogLevel.debug, 'console-debug', 'test'));
      printer.onLog(LogRecord(LogLevel.info, 'console-info', 'test'));
    }, zoneSpecification: ZoneSpecification(print: (_, _, _, line) => lines.add(line)));

    expect(lines, hasLength(1));
    expect(lines.single, contains('console-info'));
    expect(lines.single, isNot(contains('console-debug')));
  });

  test('mobile-style quiet console still persists debug records after debug mode is enabled', () async {
    LoggerController.applyDebugMode(true);
    controller.loggy.debug('persisted-debug');

    await controller.removePrinter('app');
    final content = await File('${logDirectory.path}/app.log').readAsString();
    expect(content, contains('persisted-debug'));
  });

  test('postInit applies the bool supplied by the caller', () {
    final source = File('lib/core/logger/logger_controller.dart').readAsStringSync();
    final postInitStart = source.indexOf('static Future<void> postInit(bool debugMode)');
    final applyDebugModeStart = source.indexOf('static void applyDebugMode', postInitStart);
    expect(postInitStart, isNonNegative);
    expect(applyDebugModeStart, isNonNegative);
    final postInit = source.substring(postInitStart, applyDebugModeStart);

    expect(postInit, contains('applyDebugMode(debugMode);'));
  });
}
