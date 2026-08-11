import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loggy/loggy.dart';
import 'package:marten/core/logger/buffered_file_writer.dart';
import 'package:marten/core/logger/custom_logger.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('marten-buffered-log-test-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('batches writes and flushes them on close', () async {
    final file = File('${directory.path}/core.log');
    final writer = BufferedFileWriter(file, flushInterval: const Duration(hours: 1));

    writer.add('first\n');
    writer.add('second\n');
    expect(await file.readAsString(), isEmpty);

    await writer.close();

    expect(await file.readAsString(), 'first\nsecond\n');

    writer.add('late\n');
    await writer.flush();
    expect(await file.readAsString(), 'first\nsecond\n');
  });

  test('FileLogPrinter redacts before asynchronous persistence', () async {
    final file = File('${directory.path}/app.log');
    final printer = FileLogPrinter(file.path);

    printer.onLog(LogRecord(LogLevel.info, 'download https://edge.example/sub/private-token?secret=yes', 'test'));
    await printer.dispose();

    final content = await file.readAsString();
    expect(content, contains('https://[redacted-host]/[redacted]'));
    expect(content, isNot(contains('edge.example')));
    expect(content, isNot(contains('private-token')));
  });

  test('redacts a hostname reconstructed across buffered chunks', () async {
    final file = File('${directory.path}/core.log');
    final writer = BufferedFileWriter(file, flushInterval: const Duration(hours: 1));

    writer.add('route=edge');
    writer.add('.example:443\n');
    await writer.close();

    final content = await file.readAsString();
    expect(content, isNot(contains('edge.example')));
    expect(content, contains('[redacted-host]'));
  });

  test('orders asynchronous initial pruning before immediate buffered writes', () async {
    final file = File('${directory.path}/preexisting.log');
    final staleTime = DateTime.now().subtract(const Duration(hours: 2));
    final staleLog = List.generate(
      256,
      (index) => '${staleTime.toIso8601String()} - [INFO] stale-$index ${'x' * 128}',
    ).join('\n');
    await file.writeAsString('$staleLog\n');

    final writer = BufferedFileWriter(file, flushInterval: const Duration(hours: 1));
    expect(file.existsSync(), isTrue, reason: 'construction preserves immediate log-file availability');

    writer.add('fresh-after-initial-prune\n', timestamp: DateTime.now());
    await writer.close();

    final content = await file.readAsString();
    expect(content, isNot(contains('stale-0')));
    expect(content, contains('fresh-after-initial-prune'));
  });

  test('flushes pending data before a synchronized operation and serializes later appends', () async {
    final file = File('${directory.path}/synchronized.log');
    final writer = BufferedFileWriter(file, flushInterval: const Duration(hours: 1));
    final operationStarted = Completer<void>();
    final releaseOperation = Completer<void>();

    writer.add('before\n');
    final operation = writer.runSynchronized(() async {
      expect(await file.readAsString(), 'before\n');
      operationStarted.complete();
      await releaseOperation.future;
      await file.writeAsString('snapshot\n', mode: FileMode.append, flush: true);
    });

    await operationStarted.future;
    writer.add('after\n');
    releaseOperation.complete();
    await operation;
    await writer.flush();

    expect(await file.readAsString(), 'before\nsnapshot\nafter\n');
    await writer.close();
  });

  test('keeps the writer queue usable after a synchronized operation fails', () async {
    final file = File('${directory.path}/synchronized-error.log');
    final writer = BufferedFileWriter(file, flushInterval: const Duration(hours: 1));

    writer.add('before\n');
    await expectLater(
      writer.runSynchronized<void>(() async => throw StateError('simulated snapshot failure')),
      throwsA(isA<StateError>()),
    );

    writer.add('after\n');
    await writer.flush();

    expect(await file.readAsString(), 'before\nafter\n');
    await writer.close();
  });

  test('initial asynchronous prune failures are isolated from the write chain', () {
    final source = File('lib/core/logger/buffered_file_writer.dart').readAsStringSync();

    expect(source, contains('_writeChain = LogFileRetention.prune(file).catchError((_) {});'));
  });
}
