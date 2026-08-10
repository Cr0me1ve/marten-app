import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/martencore/core_interface/core_interface.dart';
import 'package:marten/martencore/core_interface/core_interface_mobile.dart';
import 'package:marten/singbox/model/core_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(CoreInterfaceMobile.methodChannel, null);
  });

  test('explicit manual start keeps stopped grace at zero', () {
    expect(backgroundAttachStoppedGrace(explicitManualStart: true, platformStartedByUser: false), Duration.zero);
    expect(backgroundAttachStoppedGrace(explicitManualStart: true, platformStartedByUser: true), Duration.zero);
    expect(backgroundAttachStoppedGrace(explicitManualStart: true), Duration.zero);
  });

  test('non-manual attach keeps stopped grace at zero only when platform was not started by user', () {
    expect(backgroundAttachStoppedGrace(explicitManualStart: false, platformStartedByUser: false), Duration.zero);
    expect(
      backgroundAttachStoppedGrace(explicitManualStart: false, platformStartedByUser: true),
      const Duration(seconds: 1),
    );
    expect(backgroundAttachStoppedGrace(explicitManualStart: false), const Duration(seconds: 1));
  });

  group('manual Android background-core probe policy', () {
    test('authoritative stopped status skips exhaustive attach even with a retained known channel', () {
      for (final knownChannel in [false, true]) {
        expect(
          shouldProbeExistingBackgroundCoreForManualStart(
            isAndroid: true,
            platformStatus: const CoreStopped(),
            backgroundChannelKnownAvailable: knownChannel,
          ),
          isFalse,
        );
      }
    });

    test('probes an Android background core while platform startup is live or the channel is known', () {
      for (final platformStatus in const <CoreStatus>[CoreStarting(), CoreStarted()]) {
        expect(
          shouldProbeExistingBackgroundCoreForManualStart(
            isAndroid: true,
            platformStatus: platformStatus,
            backgroundChannelKnownAvailable: false,
          ),
          isTrue,
        );
      }
    });

    test('unknown Android platform status probes only an already-known channel', () {
      expect(
        shouldProbeExistingBackgroundCoreForManualStart(
          isAndroid: true,
          platformStatus: null,
          backgroundChannelKnownAvailable: true,
        ),
        isTrue,
      );
      expect(
        shouldProbeExistingBackgroundCoreForManualStart(
          isAndroid: true,
          platformStatus: null,
          backgroundChannelKnownAvailable: false,
        ),
        isFalse,
      );
    });

    test('non-Android retains the existing background-core probe', () {
      expect(
        shouldProbeExistingBackgroundCoreForManualStart(
          isAndroid: false,
          platformStatus: const CoreStopped(),
          backgroundChannelKnownAvailable: false,
        ),
        isTrue,
      );
    });
  });

  test('manual setup reads authoritative platform status before conditionally attaching background gRPC', () {
    final source = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final start = source.indexOf('Future<BackgroundCoreSetupResult> setupBackground(String path, String name) async {');
    final end = source.indexOf('Future<void> _invokeBackgroundStartAndWait', start);
    final setupBackground = start < 0 || end < 0 ? '' : source.substring(start, end);

    expect(setupBackground, isNotEmpty);
    expect(setupBackground, contains('final platformStatus = await readPlatformServiceStatus();'));
    expect(setupBackground, contains('final shouldProbeExisting = shouldProbeExistingBackgroundCoreForManualStart('));
    expect(setupBackground, contains('backgroundChannelKnownAvailable: _isBgClientAvailable'));
    expect(setupBackground, contains('_BackgroundCoreEndpoint? attachedExisting;'));
    expect(setupBackground, contains('if (shouldProbeExisting) {'));
    expect(
      setupBackground,
      contains('if (attachedExisting?.status case CoreStarting() || CoreStarted()) {'),
      reason: 'background attach should return attached result for starting/started background core',
    );
    expect(setupBackground, contains('return BackgroundCoreSetupResult.attached(attachedExisting.status);'));
    expect(setupBackground, contains('final setupResult = BackgroundCoreSetupResult.fromStatus(startStatus);'));
    expect(setupBackground, contains('if (setupResult is! BackgroundCoreSetupFailed) {'));
    expect(setupBackground, contains('return setupResult;'));
    expect(setupBackground, contains('final lateAttached = await _attachExistingBackgroundCore('));
    expect(setupBackground, contains('if (lateAttached != null) {'));
    expect(setupBackground, contains('return BackgroundCoreSetupResult.attached(lateAttached.status);'));
  });

  group('BackgroundCoreSetupResult.fromStatus', () {
    test('maps stopped (without alert) to ready-to-start', () {
      final result = BackgroundCoreSetupResult.fromStatus(const CoreStatus.stopped());
      expect(result, isA<BackgroundCoreReadyToStart>());
    });

    test('maps starting core status to attached', () {
      final starting = BackgroundCoreSetupResult.fromStatus(const CoreStatus.starting());
      expect(starting, isA<BackgroundCoreAttached>());
      expect((starting as BackgroundCoreAttached).status, const CoreStatus.starting());

      final started = BackgroundCoreSetupResult.fromStatus(const CoreStatus.started());
      expect(started, isA<BackgroundCoreAttached>());
      expect((started as BackgroundCoreAttached).status, const CoreStatus.started());
    });

    test('maps stopping and alert-bearing stopped status to setup failed', () {
      final stopping = BackgroundCoreSetupResult.fromStatus(const CoreStatus.stopping());
      expect(stopping, isA<BackgroundCoreSetupFailed>());
      expect((stopping as BackgroundCoreSetupFailed).status, const CoreStatus.stopping());

      final stoppedWithAlert = BackgroundCoreSetupResult.fromStatus(
        const CoreStatus.stopped(alert: CoreAlert.startService, message: 'already running'),
      );
      expect(stoppedWithAlert, isA<BackgroundCoreSetupFailed>());
      expect(
        (stoppedWithAlert as BackgroundCoreSetupFailed).status,
        const CoreStatus.stopped(alert: CoreAlert.startService, message: 'already running'),
      );
    });
  });

  group('background start cancellation', () {
    test('matching lifecycle generation keeps the background start active', () {
      expect(backgroundStartCancelled(startGeneration: 41, lifecycleGeneration: 41), isFalse);
    });

    test('a stop or replacement lifecycle generation cancels the old background start', () {
      expect(backgroundStartCancelled(startGeneration: 41, lifecycleGeneration: 42), isTrue);
    });

    test('a new background start is active again for its replacement lifecycle generation', () {
      expect(backgroundStartCancelled(startGeneration: 42, lifecycleGeneration: 42), isFalse);
    });
  });

  test('background start acknowledgement has an explicit boolean result', () async {
    final core = CoreInterface();

    final accepted = await core.notifyBackgroundStarted();

    expect(accepted, isA<bool>());
    expect(accepted, isTrue);
  });

  test('a true authoritative platform stop succeeds when the background port is stopped', () async {
    var stopCalls = 0;
    messenger.setMockMethodCallHandler(CoreInterfaceMobile.methodChannel, (call) async {
      expect(call.method, 'stop');
      stopCalls++;
      return true;
    });

    expect(await CoreInterfaceMobile().stop(), isTrue);
    expect(stopCalls, 1);
  });

  test('a normal false platform stop is reconciled once after the background core is independently absent', () async {
    var stopCalls = 0;
    messenger.setMockMethodCallHandler(CoreInterfaceMobile.methodChannel, (call) async {
      expect(call.method, 'stop');
      stopCalls++;
      return stopCalls == 1 ? false : true;
    });

    expect(await CoreInterfaceMobile().stop(), isTrue);
    expect(stopCalls, 2);
  });

  test('a normal false reconciliation acknowledgement remains a failed disconnect', () async {
    var stopCalls = 0;
    messenger.setMockMethodCallHandler(CoreInterfaceMobile.methodChannel, (call) async {
      expect(call.method, 'stop');
      stopCalls++;
      return false;
    });

    expect(await CoreInterfaceMobile().stop(), isFalse);
    expect(stopCalls, 2);

    stopCalls = 0;
    messenger.setMockMethodCallHandler(CoreInterfaceMobile.methodChannel, (call) async {
      stopCalls++;
      return null;
    });
    expect(await CoreInterfaceMobile().stop(), isFalse);
    expect(stopCalls, 2);
  });

  test('a platform stop exception never reconciles or reports a successful disconnect', () async {
    var stopCalls = 0;
    messenger.setMockMethodCallHandler(CoreInterfaceMobile.methodChannel, (call) async {
      stopCalls++;
      throw PlatformException(code: 'stop_failed');
    });

    expect(await CoreInterfaceMobile().stop(), isFalse);
    expect(stopCalls, 1);
  });

  test(
    'a platform stop timeout never reconciles or reports a successful disconnect',
    () async {
      var stopCalls = 0;
      final neverCompletes = Completer<bool>();
      messenger.setMockMethodCallHandler(CoreInterfaceMobile.methodChannel, (call) {
        stopCalls++;
        return neverCompletes.future;
      });

      expect(await CoreInterfaceMobile().stop(), isFalse);
      expect(stopCalls, 1);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test('a lingering non-stopped background core fails before platform reconciliation', () {
    final source = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final stopStart = source.indexOf('Future<bool> stop() async {');
    final stopEnd = source.indexOf('Future<bool> stopMethodChannel() async {', stopStart);
    final stop = stopStart < 0 || stopEnd < 0 ? '' : source.substring(stopStart, stopEnd);
    final lingeringCheck = stop.indexOf('final lingeringStatus = await _coreStatusOnPort');
    final stoppedOnly = stop.indexOf('if (lingeringStatus is CoreStopped)', lingeringCheck);
    final lingeringFailure = stop.indexOf('return false;', stoppedOnly);
    final reconcile = stop.indexOf('if (!platformStopSucceeded && platformStopReturned)', lingeringFailure);

    expect(stop, isNotEmpty);
    expect(lingeringCheck, greaterThanOrEqualTo(0));
    expect(stoppedOnly, greaterThan(lingeringCheck));
    expect(lingeringFailure, greaterThan(stoppedOnly));
    expect(reconcile, greaterThan(lingeringFailure));
  });
}
