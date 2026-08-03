import 'package:flutter_test/flutter_test.dart';
import 'package:marten/martencore/core_log_deduplicator.dart';
import 'package:marten/martencore/generated/google/protobuf/timestamp.pb.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart';

void main() {
  LogMessage event({
    required DateTime time,
    String message = 'same observer event',
    LogLevel level = LogLevel.INFO,
    LogType type = LogType.SERVICE,
  }) => LogMessage(level: level, type: type, message: message, time: Timestamp.fromDateTime(time));

  test('drops an exact event cloned by a second core log listener', () {
    final deduplicator = CoreLogDeduplicator();
    final time = DateTime.utc(2026, 7, 19, 14, 17, 12, 503);

    expect(deduplicator.shouldAccept(event(time: time)), isTrue);
    expect(deduplicator.shouldAccept(event(time: time)), isFalse);
  });

  test('keeps legitimate repeated messages with different timestamps', () {
    final deduplicator = CoreLogDeduplicator();
    final first = DateTime.utc(2026, 7, 19, 14, 17, 12);

    expect(deduplicator.shouldAccept(event(time: first)), isTrue);
    expect(deduplicator.shouldAccept(event(time: first.add(const Duration(microseconds: 1)))), isTrue);
  });

  test('uses level, type, and message as part of the identity', () {
    final deduplicator = CoreLogDeduplicator();
    final time = DateTime.utc(2026, 7, 19, 14, 17, 12);

    expect(deduplicator.shouldAccept(event(time: time)), isTrue);
    expect(deduplicator.shouldAccept(event(time: time, message: 'different')), isTrue);
    expect(deduplicator.shouldAccept(event(time: time, level: LogLevel.WARNING)), isTrue);
    expect(deduplicator.shouldAccept(event(time: time, type: LogType.CORE)), isTrue);
  });

  test('bounds remembered identities and can be reset with the log buffers', () {
    final deduplicator = CoreLogDeduplicator(capacity: 2);
    final first = DateTime.utc(2026, 7, 19, 14, 17, 12);
    final second = first.add(const Duration(seconds: 1));
    final third = first.add(const Duration(seconds: 2));

    expect(deduplicator.shouldAccept(event(time: first)), isTrue);
    expect(deduplicator.shouldAccept(event(time: second)), isTrue);
    expect(deduplicator.shouldAccept(event(time: third)), isTrue);
    expect(deduplicator.shouldAccept(event(time: first)), isTrue);

    expect(deduplicator.shouldAccept(event(time: first)), isFalse);
    deduplicator.clear();
    expect(deduplicator.shouldAccept(event(time: first)), isTrue);
  });

  test('does not collapse timestamp-less diagnostics', () {
    final deduplicator = CoreLogDeduplicator();
    final first = LogMessage(level: LogLevel.INFO, type: LogType.SERVICE, message: 'no timestamp');
    final second = LogMessage(level: LogLevel.INFO, type: LogType.SERVICE, message: 'no timestamp');

    expect(deduplicator.shouldAccept(first), isTrue);
    expect(deduplicator.shouldAccept(second), isTrue);
  });
}
