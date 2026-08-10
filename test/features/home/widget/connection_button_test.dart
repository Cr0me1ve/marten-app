import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/home/widget/connection_button.dart';

void main() {
  test('null status remains neutral while connection state is loading', () {
    expect(connectionButtonStatus(null), const Disconnected());
  });

  test('authoritative non-null connection states are preserved', () {
    for (final status in const <ConnectionStatus>[Connecting(), Connected(), Disconnecting(), Disconnected()]) {
      expect(connectionButtonStatus(status), status);
    }
  });

  test('connecting state remains actionable and uses abort/disconnect intent', () {
    const status = Connecting();

    final mapped = connectionButtonStatus(status);
    expect(mapped, const Connecting());
    expect(mapped.isSwitching, isTrue);
    expect(manualConnectionCommandForStatus(mapped), ManualConnectionCommand.abort);
    expect(canExecuteManualConnectionCommand(ManualConnectionCommand.abort, mapped), isTrue);
  });

  test('normal connecting remains switching while cold-attach verification is absent', () {
    expect(const Connecting().isSwitching, isTrue);
  });

  test('connection_button.dart does not expose visible checking state for cold attach', () {
    final source = File('lib/features/home/widget/connection_button.dart').readAsStringSync();
    expect(source, isNot(contains('Connecting(existingSessionVerification: true) => t.connection.checking')));
    expect(source, isNot(contains('Connecting(existingSessionVerification: true) => null')));
    expect(source, contains('Connecting() => t.connection.connecting'));
    expect(source, contains('Connecting() => () async'));
    expect(source, contains('manualCommand = manualConnectionCommandForStatus(status)'));
  });

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
