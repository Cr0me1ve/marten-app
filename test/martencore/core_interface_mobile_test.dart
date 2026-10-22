import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/martencore/core_interface/core_interface.dart';
import 'package:marten/martencore/core_interface/core_interface_mobile.dart';
import 'package:marten/singbox/model/core_status.dart';

String _functionBlock(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return '';
  var parenthesisDepth = 0;
  var open = -1;
  for (var index = start; index < source.length; index++) {
    switch (source[index]) {
      case '(':
        parenthesisDepth++;
      case ')':
        parenthesisDepth--;
      case '{' when parenthesisDepth == 0:
        open = index;
    }
    if (open >= 0) break;
  }
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

  group('bounded local gRPC channel termination', () {
    test('returns true after terminating the channel once', () async {
      var terminateCalls = 0;

      final terminated = await terminateLocalGrpcChannelBoundedly(() async {
        terminateCalls++;
      });

      expect(terminated, isTrue);
      expect(terminateCalls, 1);
    });

    test('returns false when termination does not complete before its injected timeout', () async {
      final neverCompletes = Completer<void>();

      final terminated = await terminateLocalGrpcChannelBoundedly(() => neverCompletes.future, timeout: Duration.zero);

      expect(terminated, isFalse);
    });

    test('propagates a non-timeout termination error', () async {
      final error = StateError('terminate failed');

      await expectLater(terminateLocalGrpcChannelBoundedly(() => Future<void>.error(error)), throwsA(same(error)));
    });
  });

  test('temporary probe channels use bounded termination instead of graceful shutdown', () {
    final source = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final backgroundProbe = _functionBlock(source, 'Future<CoreStatus?> _coreStatusOnPort(');
    final foregroundProbe = _functionBlock(source, 'Future<HelloResponse> _sayHelloOnPort(');

    expect(source, isNot(contains('await channel.shutdown()')));
    expect(backgroundProbe, contains('await _terminateChannel(channel, "temporary background status probe")'));
    expect(foregroundProbe, contains('await _terminateChannel(channel, "temporary foreground health probe")'));
    expect(backgroundProbe, isNot(contains('channel.shutdown()')));
    expect(foregroundProbe, isNot(contains('channel.shutdown()')));
  });

  test('uninitialized core reports no shared channel without reading either late client', () {
    final core = CoreInterface();

    expect(core.isInitialized(), isFalse);
    expect(core.isSingleChannel(), isFalse);
  });

  test('Android resume restores foreground control before inspecting the background channel topology', () {
    final source = File('lib/martencore/marten_core_service.dart').readAsStringSync();
    final resume = _functionBlock(source, 'Future<void> resumeFront() async');
    final foregroundControl = resume.indexOf('await _ensureForegroundControlReady()');
    final healthFailure = resume.indexOf('if (foregroundReady.isLeft())', foregroundControl);
    final singleChannel = resume.indexOf('if (core.isSingleChannel())', healthFailure);
    final backgroundLogs = resume.indexOf('await startListeningLogs("bg", core.bgClient);', singleChannel);

    expect(foregroundControl, isNonNegative);
    expect(healthFailure, greaterThan(foregroundControl));
    expect(singleChannel, greaterThan(healthFailure));
    expect(backgroundLogs, greaterThan(singleChannel));
  });

  test('exact Android explicit-stop marker preserves true false and unavailable transport separately', () {
    final source = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final query = _functionBlock(source, 'Future<bool?> wasVpnUserSessionExplicitlyStopped(int epoch) async');

    expect(query, contains('if (!Platform.isAndroid) return false;'));
    expect(query, contains('invokeMethod<bool>("was_vpn_user_session_explicitly_stopped", epoch)'));
    expect(query, contains('.timeout(_platformSessionValidationTimeout)'));
    expect(query, contains('return null;'));
    expect(query, isNot(contains('?? false')));
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

  group('active runtime configuration attachment policy', () {
    test('attaches an iOS Packet Tunnel only when its resume snapshot matches the selected config', () {
      expect(
        mayAttachToActiveConfigGeneration(isAndroid: false, configIdentityMatches: true),
        isTrue,
        reason: 'the existing healthy tunnel owns the freshly prepared selected outbound config',
      );
      expect(
        mayAttachToActiveConfigGeneration(isAndroid: false, configIdentityMatches: false),
        isFalse,
        reason: 'a healthy tunnel with a different encrypted resume snapshot must be replaced',
      );
    });

    test('fails closed when the active iOS configuration identity is unavailable or invalid', () {
      expect(
        mayAttachToActiveConfigGeneration(isAndroid: false, configIdentityMatches: false),
        isFalse,
        reason: 'the identity verifier normalizes missing or failed encrypted resume snapshots to false',
      );
    });

    test('keeps matching Android runtime attachment available', () {
      expect(mayAttachToActiveConfigGeneration(isAndroid: true, configIdentityMatches: true), isTrue);
      expect(mayAttachToActiveConfigGeneration(isAndroid: true, configIdentityMatches: false), isFalse);
    });
  });

  test('manual setup reads authoritative platform status before conditionally attaching background gRPC', () {
    final source = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final setupBackground = _functionBlock(source, 'Future<BackgroundCoreSetupResult> setupBackground(');

    expect(setupBackground, isNotEmpty);
    expect(setupBackground, contains('var platformStatus = await readPlatformServiceStatus();'));
    final mismatchCleanup = setupBackground.indexOf(
      'if (Platform.isAndroid && !configIdentityMatches && !preparedManualAdmission) {',
    );
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
    expect(
      setupBackground,
      contains(
        'final shouldProbeExisting =\n'
        '        !preparedManualAdmission &&\n'
        '        shouldProbeExistingBackgroundCoreForManualStart(',
      ),
      reason:
          'a manually admitted Android start must not attach an older background shell before its prepared pipeline runs',
    );
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

  test('manual Android background setup waits passively for its owner network before returning ready-to-start', () {
    final mobile = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final methodHandler = File('android/app/src/main/kotlin/app/marten/client/MethodHandler.kt').readAsStringSync();
    final boxService = File('android/app/src/main/kotlin/app/marten/client/bg/BoxService.kt').readAsStringSync();
    final setup = _functionBlock(mobile, 'Future<BackgroundCoreSetupResult> setupBackground(');
    final startupReadyWait = _functionBlock(
      mobile,
      'if (Platform.isAndroid && androidVpnStartEpoch != null && startStatus is CoreStopped && startStatus.alert == null) {',
    );
    final readiness = setup.indexOf('final startStatus = await _waitForBackgroundServiceReady(');
    final networkWait = setup.indexOf('await methodChannel.invokeMethod<bool>("await_start_network", androidVpnStartEpoch) ?? false');
    final cancellationCheck = setup.indexOf('if (backgroundStartCancelled(', networkWait);
    final readyResult = setup.indexOf('BackgroundCoreSetupResult.fromStatus(startStatus)', networkWait);

    expect(setup, isNotEmpty);
    expect(readiness, isNonNegative);
    expect(networkWait, greaterThan(readiness), reason: 'the service shell must be gRPC-ready before passive network admission begins');
    expect(cancellationCheck, greaterThan(networkWait), reason: 'Stop is rechecked after the awaited network callback');
    expect(readyResult, greaterThan(networkWait), reason: 'fresh native start can be admitted only after the network wait returns');
    expect(startupReadyWait, isNotEmpty);
    expect(
      setup,
      contains('if (Platform.isAndroid && androidVpnStartEpoch != null && startStatus is CoreStopped && startStatus.alert == null) {'),
      reason: 'only an admitted manual Android start with a stopped, alert-free shell waits for connectivity',
    );
    expect(startupReadyWait, isNot(contains('.timeout(')), reason: 'offline time must not consume an online route/RPC timeout');
    expect(startupReadyWait, isNot(contains('Future.delayed(')), reason: 'network arrival must wake the start through an event, not polling');
    expect(startupReadyWait, contains('if (!networkReady)'));
    expect(startupReadyWait, contains('_isBgClientAvailable = false;'));
    expect(startupReadyWait, contains('return const BackgroundCoreSetupResult.failed(CoreStatus.stopped());'));

    final channelDispatch = methodHandler.indexOf('"await_start_network" -> {');
    final epoch = methodHandler.indexOf('val epoch = (call.arguments as? Number)?.toLong()', channelDispatch);
    final nativeWait = methodHandler.indexOf('success(BoxService.awaitStartupNetwork(epoch))', epoch);
    expect(channelDispatch, isNonNegative);
    expect(epoch, greaterThan(channelDispatch));
    expect(nativeWait, greaterThan(epoch), reason: 'the exact Flutter VPN epoch must reach the service-owned passive wait');
    expect(boxService, contains('DefaultNetworkMonitor.awaitUsableNetwork(owner.serviceOwnerToken)'));
    expect(boxService, contains('return available && current()'));

    final service = File('lib/martencore/marten_core_service.dart').readAsStringSync();
    final coreStart = _functionBlock(service, 'TaskEither<ConnectionFailure, Unit> start(');
    final setupCall = coreStart.indexOf('await core.setupBackground(');
    final freshStart = coreStart.indexOf('await core.bgClient.start(');
    expect(setupCall, isNonNegative);
    expect(freshStart, greaterThan(setupCall), reason: 'bgClient.start must remain after setupBackground confirms owner-network readiness');
  });

  test(
    'manual Android background setup owns one pending lifecycle generation and stale starts cannot enter readiness wait',
    () {
      final source = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
      final beginLifecycle = _functionBlock(source, 'void beginBackgroundLifecycle()');
      final setup = _functionBlock(source, 'Future<BackgroundCoreSetupResult> setupBackground(');
      final stop = _functionBlock(source, 'Future<bool> stop()');
      final readinessWait = _functionBlock(source, 'Future<CoreStatus> _waitForBackgroundServiceReady(');

      const pendingGenerationAssignment = '_pendingManualStartGeneration = ++_backgroundLifecycleGeneration;';
      final pendingManualGeneration = beginLifecycle.indexOf(pendingGenerationAssignment);
      final lifecycleGeneration = beginLifecycle.indexOf('++_backgroundLifecycleGeneration', pendingManualGeneration);
      expect(
        lifecycleGeneration,
        isNonNegative,
        reason: 'beginBackgroundLifecycle must mint the exact manual lifecycle generation',
      );
      expect(
        pendingManualGeneration,
        lessThan(lifecycleGeneration),
        reason: 'the newly minted manual lifecycle generation must be retained as the one pending start token',
      );

      final preparedManual = setup.indexOf(
        'final preparedManualAdmission = Platform.isAndroid && androidVpnStartEpoch != null;',
      );
      final capturePending = setup.indexOf(
        'final admittedManualGeneration = preparedManualAdmission ? _pendingManualStartGeneration : null;',
        preparedManual,
      );
      final supersededBeforeSetup = setup.indexOf(
        'if (preparedManualAdmission && admittedManualGeneration != _backgroundLifecycleGeneration)',
        capturePending,
      );
      final supersededReturn = setup.indexOf(
        'return const BackgroundCoreSetupResult.failed(CoreStatus.stopped());',
        supersededBeforeSetup,
      );
      final firstAwait = setup.indexOf('await readPlatformServiceStatus()', supersededReturn);
      expect(
        preparedManual,
        isNonNegative,
        reason: 'only an Android call carrying an exact VPN epoch is a prepared manual admission',
      );
      expect(
        capturePending,
        greaterThan(preparedManual),
        reason: 'prepared manual setup must capture its exact pending token before any await',
      );
      expect(
        supersededBeforeSetup,
        greaterThan(capturePending),
        reason: 'a prepared start already superseded by Stop must be rejected before setup work',
      );
      expect(supersededReturn, greaterThan(supersededBeforeSetup));
      expect(
        firstAwait,
        greaterThan(supersededReturn),
        reason: 'the stale prepared start must not even enter asynchronous platform setup',
      );

      const startGenerationExpression =
          'final startGeneration = preparedManualAdmission ? admittedManualGeneration! : ++_backgroundLifecycleGeneration;';
      final startGeneration = setup.indexOf(startGenerationExpression);
      final dispatchRecheck = setup.indexOf('if (startGeneration != _backgroundLifecycleGeneration)', startGeneration);
      final clearExactPending = setup.indexOf(
        'if (preparedManualAdmission && _pendingManualStartGeneration == startGeneration)',
        dispatchRecheck,
      );
      final clearPendingToken = setup.indexOf('_pendingManualStartGeneration = null;', clearExactPending);
      final dispatch = setup.indexOf('await _invokeBackgroundStartAndWait(', clearPendingToken);
      final readiness = setup.indexOf('_waitForBackgroundServiceReady(', dispatch);
      final manualDispatchSection = setup.substring(startGeneration + startGenerationExpression.length, dispatch);
      expect(
        startGeneration,
        isNonNegative,
        reason:
            'normal starts retain their independent generation increment while manual starts reuse exactly the captured token',
      );
      expect(
        dispatchRecheck,
        greaterThan(startGeneration),
        reason: 'manual setup must recheck the same generation immediately before platform dispatch',
      );
      expect(
        manualDispatchSection,
        isNot(contains('++_backgroundLifecycleGeneration')),
        reason: 'the manual dispatch path must not manufacture a newer generation after capture',
      );
      expect(clearExactPending, greaterThan(dispatchRecheck));
      expect(
        clearPendingToken,
        greaterThan(clearExactPending),
        reason: 'only the matching pending manual token may be cleared',
      );
      expect(dispatch, greaterThan(clearPendingToken));
      expect(
        readiness,
        greaterThan(dispatch),
        reason: 'a stale manual generation returns before it can enter the 30-second readiness wait',
      );

      final stopClearPending = stop.indexOf('_pendingManualStartGeneration = null;');
      final stopAdvanceGeneration = stop.indexOf('_backgroundLifecycleGeneration++;', stopClearPending);
      final stopFirstAwait = stop.indexOf('await ', stopAdvanceGeneration);
      expect(stopClearPending, isNonNegative, reason: 'Stop must revoke the pending manual token synchronously');
      expect(
        stopAdvanceGeneration,
        greaterThan(stopClearPending),
        reason: 'Stop must invalidate every captured background-start generation',
      );
      expect(stopFirstAwait, greaterThan(stopAdvanceGeneration));
      expect(
        readinessWait,
        contains('backgroundStartCancelled('),
        reason: 'a Stop racing after dispatch must still terminate the bounded readiness loop early',
      );
    },
  );

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

  test('Android epoch rejection invalidates only its exact background lifecycle before readiness timeout', () {
    final source = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final setup = _functionBlock(source, 'Future<BackgroundCoreSetupResult> setupBackground(');
    final readiness = _functionBlock(source, 'Future<CoreStatus> _waitForBackgroundServiceReady(');
    final validation = _functionBlock(source, 'Future<bool> _isVpnUserSessionCurrent(int epoch) async {');

    final backgroundDispatch = setup.indexOf('await _invokeBackgroundStartAndWait(');
    final readinessCall = setup.indexOf('_waitForBackgroundServiceReady(', backgroundDispatch);
    final passedEpoch = setup.indexOf('androidVpnStartEpoch: androidVpnStartEpoch,', readinessCall);
    final rejectedEpoch = readiness.indexOf(
      'if (androidVpnStartEpoch != null && !await _isVpnUserSessionCurrent(androidVpnStartEpoch)) {',
    );
    final exactGeneration = readiness.indexOf(
      'if (startGeneration == _backgroundLifecycleGeneration) {',
      rejectedEpoch,
    );
    final clearPending = readiness.indexOf('_pendingManualStartGeneration = null;', exactGeneration);
    final invalidate = readiness.indexOf('_backgroundLifecycleGeneration++;', clearPending);
    final clearControl = readiness.indexOf('_clearBackgroundControlClient();', invalidate);
    final rejectedReturn = readiness.indexOf('return const CoreStatus.stopped();', clearControl);
    final firstGrpcProbe = readiness.indexOf('_coreStatusOnPort(', rejectedEpoch);
    final readinessDelay = readiness.indexOf('Future.delayed(_backgroundServicePollInterval)', rejectedEpoch);

    expect(backgroundDispatch, isNonNegative);
    expect(readinessCall, greaterThan(backgroundDispatch));
    expect(passedEpoch, greaterThan(readinessCall));
    expect(
      rejectedEpoch,
      isNonNegative,
      reason: 'the exact Android VPN epoch must be validated inside the readiness loop',
    );
    expect(
      exactGeneration,
      greaterThan(rejectedEpoch),
      reason: 'only the lifecycle generation carrying the rejected epoch may be invalidated',
    );
    expect(clearPending, greaterThan(exactGeneration));
    expect(invalidate, greaterThan(clearPending));
    expect(clearControl, greaterThan(invalidate));
    expect(
      rejectedReturn,
      greaterThan(clearControl),
      reason: 'Android rejection must return terminally rather than wait for generic readiness expiry',
    );
    expect(firstGrpcProbe, greaterThan(rejectedReturn));
    expect(readinessDelay, greaterThan(rejectedReturn));

    expect(validation, contains('invokeMethod<bool>("validate_vpn_user_session", epoch)'));
    expect(validation, contains('.timeout(_platformSessionValidationTimeout)'));
    expect(validation, isNot(contains('_backgroundServiceReadyTimeout')));
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
