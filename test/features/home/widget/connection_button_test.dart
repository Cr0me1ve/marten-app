import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/home/widget/connection_button.dart';

void main() {
  test('loading connection state remains neutral', () {
    expect(connectionButtonStatus(const AsyncLoading()), const Disconnected());
  });

  test('loading retains a visible stop intent from the previous connection state', () {
    for (final status in const <ConnectionStatus>[Connecting(), Connected()]) {
      final loadingWithPrevious = const AsyncLoading<ConnectionStatus>().copyWithPrevious(AsyncData(status));

      expect(loadingWithPrevious.valueOrNull, status);
      expect(connectionButtonStatus(loadingWithPrevious), status);
      expect(
        manualConnectionCommandForStatus(connectionButtonStatus(loadingWithPrevious)),
        isNot(ManualConnectionCommand.connect),
      );
    }
  });

  test('authoritative non-null connection states are preserved', () {
    for (final status in const <ConnectionStatus>[Connecting(), Connected(), Disconnecting(), Disconnected()]) {
      expect(connectionButtonStatus(AsyncData(status)), status);
    }
  });

  test('an async error with a retained Connecting value is rendered as retryable disconnected', () {
    final failedAfterConnecting = AsyncError<ConnectionStatus>(
      StateError('startup route verification failed'),
      StackTrace.current,
    ).copyWithPrevious(const AsyncData(Connecting()));

    final status = connectionButtonStatus(failedAfterConnecting);

    expect(failedAfterConnecting.valueOrNull, const Connecting(), reason: 'regression fixture retains the stale value');
    expect(status, const Disconnected());
    expect(manualConnectionCommandForStatus(status), ManualConnectionCommand.connect);
    expect(canExecuteManualConnectionCommand(ManualConnectionCommand.connect, status), isTrue);
  });

  test('connecting state remains actionable and uses abort/disconnect intent', () {
    const status = Connecting();

    final mapped = connectionButtonStatus(const AsyncData(status));
    expect(mapped, const Connecting());
    expect(mapped.isSwitching, isTrue);
    expect(manualConnectionCommandForStatus(mapped), ManualConnectionCommand.abort);
    expect(canExecuteManualConnectionCommand(ManualConnectionCommand.abort, mapped), isTrue);
  });

  test('visible Connecting and Connected always map the primary button to a stop intent', () {
    for (final status in const <ConnectionStatus>[Connecting(), Connected()]) {
      final command = manualConnectionCommandForStatus(connectionButtonStatus(AsyncData(status)));
      expect(command, anyOf(ManualConnectionCommand.abort, ManualConnectionCommand.disconnect));
      expect(command, isNot(ManualConnectionCommand.connect));
    }
  });

  test('normal connecting remains switching while cold-attach verification is absent', () {
    expect(const Connecting().isSwitching, isTrue);
  });

  test(
    'connection button never turns an active session into reconnect and leaves retained active loading actionable',
    () {
      final source = File('lib/features/home/widget/connection_button.dart').readAsStringSync();
      expect(source, isNot(contains('Connecting(existingSessionVerification: true) => t.connection.checking')));
      expect(source, isNot(contains('Connecting(existingSessionVerification: true) => null')));
      expect(source, contains('Connecting() => t.connection.connecting'));
      expect(source, contains('Connecting() || Connected() => () async'));
      expect(source, contains('manualCommand = manualConnectionCommandForStatus(status)'));
      expect(source, contains('connectionButtonStatus(connectionStatus)'));
      expect(source, isNot(contains('connectionButtonStatus(connectionStatus.valueOrNull)')));
      expect(source, contains('state.hasError'));
      expect(source, isNot(contains('configOptionNotifierProvider')));
      expect(source, isNot(contains('requiresReconnect')));
      expect(source, isNot(contains('.reconnect(')));
      expect(source, contains('Disconnected() when connectionStatus.isLoading => null'));
    },
  );

  test('only the stroke is animated; static blur and label stay outside the tick builder', () {
    final source = File('lib/features/home/widget/connection_button.dart').readAsStringSync();
    final circleStart = source.indexOf('class _ConnectionCircle');
    final glowStart = source.indexOf('class _CircleGlowPainter', circleStart);
    final strokeStart = source.indexOf('class _CircleStrokePainter', glowStart);
    expect(circleStart, isNonNegative);
    expect(glowStart, isNonNegative);
    expect(strokeStart, isNonNegative);

    final circle = source.substring(circleStart, glowStart);
    final animatedStart = circle.indexOf('child: AnimatedBuilder(');
    final animatedEnd = circle.indexOf('),\n                Center(', animatedStart);
    expect(animatedStart, isNonNegative);
    expect(animatedEnd, greaterThan(animatedStart));
    final animatedStroke = circle.substring(animatedStart, animatedEnd);

    expect(
      circle,
      contains(
        'RepaintBoundary(\n                  child: CustomPaint(\n                    painter: _CircleGlowPainter',
      ),
    );
    expect(circle, contains('RepaintBoundary(\n                  child: AnimatedBuilder('));
    expect(animatedStroke, contains('_CircleStrokePainter('));
    expect(animatedStroke, isNot(contains('_CircleGlowPainter')));
    expect(animatedStroke, isNot(contains('Text(')));
    expect(circle, contains('Semantics(\n      button: true,'), reason: 'button status semantics remain intact');
    expect(circle, contains('label: label,'), reason: 'the status-derived accessible label remains intact');
  });
}
