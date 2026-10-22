import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/utils/ui_idle_gate.dart';

void main() {
  testWidgets('idle admission completes asynchronously without requesting frames or timers', (tester) async {
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    var timers = 0;
    late UiIdleGate gate;
    runZoned(
      () {
        gate = UiIdleGate(debugLabel: 'test idle');
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          timers++;
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
    var admitted = false;
    gate.ready.then((value) => admitted = value);
    expect(admitted, isFalse);
    await tester.idle();
    expect(admitted, isTrue);
    expect(binding.hasScheduledFrame, isFalse);
    expect(timers, 0);
  });

  testWidgets('paused animation waits passively and resumes only after a real idle frame', (tester) async {
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    final callback = binding.scheduleFrameCallback((_) {});
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    var timers = 0;
    late UiIdleGate gate;
    runZoned(
      () {
        gate = UiIdleGate(debugLabel: 'paused animation');
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          timers++;
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
    bool? admitted;
    gate.ready.then((value) => admitted = value);
    await tester.idle();
    await tester.pump(const Duration(minutes: 10));
    expect(admitted, isNull);
    expect(timers, 0);
    binding.cancelFrameCallbackWithId(callback);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.idle();
    expect(admitted, isTrue);
    expect(timers, 0);
  });

  testWidgets('animation callback defers admission without spinning the event loop', (tester) async {
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    binding.scheduleFrameCallback((_) {});
    final gate = UiIdleGate(debugLabel: 'animated frame');
    bool? admitted;
    gate.ready.then((value) => admitted = value);
    await tester.idle();
    expect(admitted, isNull);
    await tester.pump();
    await tester.idle();
    expect(admitted, isTrue);
  });

  testWidgets('cancelled background owner cannot resume deferred work', (tester) async {
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final gate = UiIdleGate(debugLabel: 'cancelled');
    var completions = 0;
    bool? admitted;
    gate.ready.then((value) {
      completions++;
      admitted = value;
    });
    await tester.idle();
    gate.cancel();
    gate.cancel();
    await tester.idle();
    expect(admitted, isFalse);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(admitted, isFalse);
    expect(completions, 1);
  });
}
