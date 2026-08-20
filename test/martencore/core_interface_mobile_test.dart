import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/martencore/core_interface/core_interface.dart';
import 'package:marten/martencore/core_interface/core_interface_mobile.dart';
import 'package:marten/singbox/model/core_status.dart';

String _functionBlock(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return '';
  final open = source.indexOf('{', start);
  if (open < 0) return '';

  var depth = 0;
  for (var index = open; index < source.length; index++) {
    final character = source[index];
    if (character == '{') {
      depth++;
    } else if (character == '}') {
      depth--;
      if (depth == 0) return source.substring(open + 1, index);
    }
  }
  return '';
}

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

  group('authoritative Android background-start join policy', () {
    test('joins only an Android platform service that is still starting', () {
      final cases = [
        (isAndroid: true, platformStatus: const CoreStatus.starting(), expected: true),
        (isAndroid: true, platformStatus: const CoreStatus.started(), expected: false),
        (isAndroid: true, platformStatus: const CoreStatus.stopped(), expected: false),
        (isAndroid: true, platformStatus: null, expected: false),
      ];

      for (final testCase in cases) {
        expect(
          shouldJoinAuthoritativeBackgroundStart(
            isAndroid: testCase.isAndroid,
            platformStatus: testCase.platformStatus,
          ),
          testCase.expected,
        );
      }
    });

    test('never joins the Android-specific authoritative start path on another platform', () {
      expect(
        shouldJoinAuthoritativeBackgroundStart(isAndroid: false, platformStatus: const CoreStatus.starting()),
        isFalse,
      );
    });
  });

  test('manual setup reads authoritative platform status before conditionally attaching background gRPC', () {
    final source = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final start = source.indexOf('Future<BackgroundCoreSetupResult> setupBackground(String path, String name) async {');
    final end = source.indexOf('Future<void> _invokeBackgroundStartAndWait', start);
    final setupBackground = start < 0 || end < 0 ? '' : source.substring(start, end);

    expect(setupBackground, isNotEmpty);
    expect(setupBackground, contains('var platformStatus = await readPlatformServiceStatus();'));
    final mismatchCleanup = setupBackground.indexOf('if (Platform.isAndroid && !configIdentityMatches) {');
    final refreshedPlatformStatus = setupBackground.indexOf(
      'platformStatus = await readPlatformServiceStatus();',
      mismatchCleanup,
    );
    expect(mismatchCleanup, isNonNegative);
    expect(
      refreshedPlatformStatus,
      greaterThan(mismatchCleanup),
      reason: 'an authoritative config-mismatch stop must not reuse its pre-stop platform snapshot',
    );
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

  test('manual Android attach proves runtime config identity before it reuses a live core', () {
    final source = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final setup = _functionBlock(source, 'Future<BackgroundCoreSetupResult> setupBackground(');
    final liveAttach = setup.indexOf('if (attachedExisting?.status case CoreStarting() || CoreStarted()) {');
    final attachedReturn = setup.indexOf(
      'return BackgroundCoreSetupResult.attached(attachedExisting.status);',
      liveAttach,
    );
    final identityMatch = RegExp(
      '(?:matches|match)[A-Za-z]*(?:[Cc]onfig|[Rr]untime|[Ff]ingerprint)|'
      '(?:[Cc]onfig|[Rr]untime|[Ff]ingerprint)[A-Za-z]*(?:matches|match)',
    ).firstMatch(setup.substring(liveAttach));

    expect(liveAttach, isNonNegative);
    expect(attachedReturn, greaterThan(liveAttach));
    expect(identityMatch, isNotNull, reason: 'a live core must prove its prepared-route identity before reuse');
    final identityOffset = liveAttach + identityMatch!.start;
    expect(identityOffset, lessThan(attachedReturn));

    // A core that owns a different prepared route is not attachable. The
    // authoritative platform stop owns TURNcoat's terminal close; after that
    // setup may start a fresh generation but must never return Attached first.
    final replacementStop = setup.indexOf('await stop()', identityOffset);
    expect(replacementStop, greaterThan(identityOffset));
    expect(replacementStop, greaterThanOrEqualTo(attachedReturn));
  });

  test('Android control-session refresh uses the exact current background port without lifecycle side effects', () {
    final interface = File('lib/martencore/core_interface/core_interface.dart').readAsStringSync();
    final mobile = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    const signature = 'Future<CoreStatus?> refreshBackgroundControlSession(int expectedGeneration)';
    final refreshStart = mobile.indexOf('$signature async {');
    final refreshEnd = mobile.indexOf('\n  Future<HelloResponse> _waitForMartenCore', refreshStart + signature.length);
    final refresh = refreshStart < 0 || refreshEnd < 0 ? '' : mobile.substring(refreshStart, refreshEnd);
    final platformOwnership = _functionBlock(mobile, 'bool _platformOwnsCurrentBackgroundLifecycle(');
    final statusOnClient = _functionBlock(mobile, 'Future<CoreStatus?> _coreStatusOnClient(');
    final replaceObservation = _functionBlock(mobile, 'void _replaceBackgroundObservationClient(');

    expect(interface, contains('int get backgroundLifecycleGeneration'));
    expect(interface, contains('CoreClient get backgroundControlClient'));
    expect(interface, contains(signature));
    expect(refresh, isNotEmpty);
    expect(platformOwnership, contains('CoreStarting'));
    expect(platformOwnership, contains('CoreStarted'));
    expect(refresh, contains('_backgroundLifecycleGeneration'));
    expect(refresh, contains('_platformOwnsCurrentBackgroundLifecycle'));
    expect(refresh, contains('_portBack'));
    expect(refresh, contains('CoreClient('));
    expect(refresh, contains('_coreStatusOnClient(controlClient)'));
    expect(statusOnClient, contains('client\n          .coreInfoListener'));
    expect(refresh, contains('backgroundControlClient'));
    expect(refresh, contains('_replaceBackgroundObservationClient(observationChannel)'));
    expect(replaceObservation, contains('bgClient = CoreClient(channel)'));
    expect(refresh, isNot(contains('Future.delayed')));
    expect(refresh, isNot(contains('_selectAvailablePort')));
    expect(refresh, isNot(contains('_invokeBackgroundStart')));
    expect(refresh, isNot(contains('setupBackground(')));
    expect(refresh, isNot(contains('await stop(')));
    expect(refresh, isNot(contains('isPortOpen(')));
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

  test('Flutter waits longer than the bounded native TURNcoat VPN-proof retry', () {
    final source = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final timeout = RegExp(r'static const _platformStartedSyncTimeout = Duration\(seconds: (\d+)\)').firstMatch(source);
    final seconds = int.tryParse(timeout?.group(1) ?? '');
    final acknowledgement = source.indexOf('Future<bool> notifyBackgroundStarted() async {');
    final markStarted = source.indexOf(
      'invokeMethod<bool>("markStarted").timeout(_platformStartedSyncTimeout)',
      acknowledgement,
    );

    expect(seconds, isNotNull);
    expect(
      seconds,
      greaterThanOrEqualTo(75),
      reason: 'Dart must stay attached for the complete bounded native TURNcoat retry window',
    );
    expect(markStarted, greaterThan(acknowledgement));
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
      return stopCalls != 1;
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
    messenger.setMockMethodCallHandler(CoreInterfaceMobile.methodChannel, (call) {
      stopCalls++;
      return null;
    });
    expect(await CoreInterfaceMobile().stop(), isFalse);
    expect(stopCalls, 2);
  });

  test('a platform stop exception never reconciles or reports a successful disconnect', () async {
    var stopCalls = 0;
    messenger.setMockMethodCallHandler(CoreInterfaceMobile.methodChannel, (call) {
      stopCalls++;
      throw PlatformException(code: 'stop_failed');
    });

    expect(await CoreInterfaceMobile().stop(), isFalse);
    expect(stopCalls, 1);
  });

  test('platform stop leaves enough outer time for bounded native and VPN cleanup', () {
    final source = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();

    expect(source, contains('static const _platformStopCallTimeout = Duration(seconds: 30);'));
    expect(
      source,
      contains('up to 20 seconds for the\n  // native core plus 5 seconds for service/VPN ownership release'),
    );
    expect(source, contains('await stopMethodChannel().timeout(_platformStopCallTimeout)'));
  });

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
