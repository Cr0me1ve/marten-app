import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:marten/features/connection/data/connection_repository.dart';
import 'package:marten/features/connection/model/connection_failure.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/singbox/model/core_status.dart';

void main() {
  group('native recovery route gate', () {
    test('reopens only after a running core completes Android recovery', () {
      final starting = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.started(),
        current: const CoreStatus.starting(),
        pending: false,
      );
      expect(starting, (pending: true, routeReady: false));

      final started = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.starting(),
        current: const CoreStatus.started(),
        pending: starting.pending,
      );
      expect(started, (pending: false, routeReady: true));
    });

    test('does not bypass the route gate on cold start', () {
      final starting = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.stopped(),
        current: const CoreStatus.starting(),
        pending: false,
      );
      expect(starting, (pending: false, routeReady: false));

      final started = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.starting(),
        current: const CoreStatus.started(),
        pending: starting.pending,
      );
      expect(started, (pending: false, routeReady: null));
    });

    test('Android platform recovery opens the route gate only after its final verified Started event', () {
      final coldStarting = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.stopped(),
        current: const CoreStatus.starting(),
        pending: false,
      );
      final coldStarted = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.starting(),
        current: const CoreStatus.started(),
        pending: coldStarting.pending,
      );
      expect(coldStarting, (pending: false, routeReady: false));
      expect(coldStarted, (pending: false, routeReady: null));

      final recoveryStarting = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.started(),
        current: const CoreStatus.starting(),
        pending: false,
      );
      final recoveryStarted = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.starting(),
        current: const CoreStatus.started(),
        pending: recoveryStarting.pending,
      );
      expect(recoveryStarting, (pending: true, routeReady: false));
      expect(recoveryStarted, (pending: false, routeReady: true));

      final stopping = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.started(),
        current: const CoreStatus.stopping(),
        pending: false,
      );
      final stoppedWithAlert = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.started(),
        current: const CoreStatus.stopped(alert: CoreAlert.startFailed, message: 'route failed'),
        pending: false,
      );
      expect(stopping, (pending: false, routeReady: false));
      expect(stoppedWithAlert, (pending: false, routeReady: false));

      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
      final platformStreamStart = source.indexOf('final platformStatus = singbox');
      final combineStart = source.indexOf('return Rx.combineLatest3', platformStreamStart);
      expect(platformStreamStart, isNonNegative);
      expect(combineStart, greaterThan(platformStreamStart));
      final platformStream = source.substring(platformStreamStart, combineStart);
      expect(platformStream, contains('nativeRecoveryRouteGateTransition('));
      expect(platformStream, contains('previous: _lastObservedPlatformStatus'));
      expect(RegExp(r'pending:\s*_nativePlatformRecoveryRouteGatePending').hasMatch(platformStream), isTrue);
    });
  });

  group('android route gate', () {
    test('platform service is authoritative for every Android connection status', () {
      expect(connectionStatusFromAndroidPlatform(const CoreStatus.starting(), false), const Connecting());
      expect(connectionStatusFromAndroidPlatform(const CoreStatus.started(), false), const Connecting());
      expect(connectionStatusFromAndroidPlatform(const CoreStatus.started(), true), const Connected());
      expect(connectionStatusFromAndroidPlatform(const CoreStatus.stopping(), true), const Disconnecting());
      expect(
        connectionStatusFromAndroidPlatform(
          const CoreStatus.stopped(alert: CoreAlert.startFailed, message: 'route failed'),
          true,
        ),
        isA<Disconnected>(),
      );
    });

    test('Starting/Stopping/Stopped close the route gate', () {
      for (final status in [const CoreStatus.starting(), const CoreStatus.stopping(), const CoreStatus.stopped()]) {
        expect(androidRouteGateReset(status), isFalse);
      }
    });

    test('Started never opens the route gate by itself', () {
      expect(androidRouteGateReset(const CoreStatus.started()), isNull);
    });

    test('route-gated Starting and Started remain separate raw lifecycle events despite the same visible status', () {
      final rawLifecycleStatuses = [
        connectionStatusFromAndroidPlatform(const CoreStatus.starting(), false),
        connectionStatusFromAndroidPlatform(const CoreStatus.started(), false),
      ];

      expect(rawLifecycleStatuses, [const Connecting(), const Connecting()]);
      expect(
        rawLifecycleStatuses.first,
        rawLifecycleStatuses.last,
        reason: 'the notifier must see the final Started-derived Connecting to start route verification',
      );

      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
      final androidBranch = source.indexOf('final platformStatus = singbox');
      final methodEnd = source.indexOf('\n  @override\n  TaskEither<ConnectionFailure, Unit> connect', androidBranch);
      expect(androidBranch, isNonNegative);
      expect(methodEnd, greaterThan(androidBranch));
      final androidStream = source.substring(androidBranch, methodEnd);
      expect(androidStream, contains('Rx.combineLatest3<CoreStatus, bool, CoreStatus, ConnectionStatus>('));
      expect(
        androidStream,
        isNot(contains('.distinct()')),
        reason: 'Android lifecycle events must remain raw until the notifier runs its route-verification hook',
      );
    });

    test('wires the platform status stream into the connection status gate', () {
      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
      final watchStart = source.indexOf('Stream<ConnectionStatus> watchConnectionStatus() {');
      final watchEnd = source.indexOf('\n  @override\n  TaskEither<ConnectionFailure, Unit> connect', watchStart);
      expect(watchStart, isNonNegative);
      expect(watchEnd, isNonNegative);

      final watch = source.substring(watchStart, watchEnd);
      expect(watch, contains('singbox.watchStatus()'));
      expect(watch, contains('watchPlatformServiceStatus()'));
      expect(watch, contains('androidRouteGateReset('));
      expect(watch, contains('_startupRouteReadyController.stream'));
      expect(
        RegExp(r'watchStatus\(\)\.handleError|runtimeStatus\.handleError').hasMatch(watch),
        isTrue,
        reason: 'Android runtime stream transport errors must not terminate the UI stream during native recovery',
      );
      expect(watch, contains('watchPlatformServiceStatus()\n        .handleError'));
    });
  });

  group('startup route readiness', () {
    test('manual lifecycle reservation precedes TURNcoat features and core start', () {
      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
      final configuredStart = source.indexOf('TaskEither<ConnectionFailure, Unit> _withPreparedConfig(');
      final configuredEnd = source.indexOf(
        '\n  TaskEither<ConnectionFailure, Unit> _unlessConnectionStale',
        configuredStart,
      );
      final configured = configuredStart < 0 || configuredEnd < 0
          ? ''
          : source.substring(configuredStart, configuredEnd);
      final preparedStart = source.indexOf(
        'Future<({String? tag, bool usesTurncoat, StartupEndpointProbe? startupEndpoint})> _prepareSelectedOutboundAttempt(',
      );
      final preparedEnd = source.indexOf('\n  void _armTurncoatFeatures', preparedStart);
      final prepared = preparedStart < 0 || preparedEnd < 0 ? '' : source.substring(preparedStart, preparedEnd);

      expect(configured, isNotEmpty);
      expect(prepared, isNotEmpty);
      final reserve = configured.indexOf('singbox.beginManualBackgroundLifecycle();');
      final reset = configured.indexOf('_resetTurncoatFeatures();');
      final arm = configured.indexOf('_armTurncoatFeatures(');
      final action = configured.indexOf('final result = await action(');
      expect(reserve, isNonNegative);
      expect(reset, greaterThan(reserve));
      expect(arm, greaterThan(reset));
      expect(action, greaterThan(arm));
      expect(
        prepared,
        isNot(contains('_armTurncoatFeatures(')),
        reason: 'config preparation must not arm a new route while the previous lifecycle can still emit events',
      );
    });

    test('cold attach gates already started Android core until route verification', () {
      expect(initialStartupRouteReady, isTrue);
      expect(initialStartupRouteReadyForPlatform(isAndroid: false), isTrue);
      expect(initialStartupRouteReadyForPlatform(isAndroid: true), isFalse);
    });

    test('Android cold attach keeps retained started core connecting until route is verified', () {
      final startupRouteReady = initialStartupRouteReadyForPlatform(isAndroid: true);

      expect(startupRouteReady, isFalse);
      expect(connectionStatusFromCore(const CoreStatus.started(), startupRouteReady), const Connecting());
      expect(connectionStatusFromCore(const CoreStatus.started(), true), const Connected());
    });

    test('started core status clears a previous disconnecting state', () {
      expect(connectionStatusFromCore(const CoreStatus.stopping(), true), const Disconnecting());
      expect(connectionStatusFromCore(const CoreStatus.started(), true), const Connected());
    });

    test('vpn revoke maps to a passive disconnected state', () {
      expect(
        connectionStatusFromCore(const CoreStatus.stopped(alert: CoreAlert.vpnRevoked), true),
        const Disconnected(),
      );
    });

    test('accepts only measured non-timeout url test delays', () {
      expect(isUsableStartupUrlTestDelay(null), isFalse);
      expect(isUsableStartupUrlTestDelay(0), isFalse);
      expect(isUsableStartupUrlTestDelay(42), isTrue);
      expect(isUsableStartupUrlTestDelay(65535), isFalse);
      expect(isStartupUrlTestTimeoutDelay(0), isFalse);
      expect(isStartupUrlTestTimeoutDelay(65535), isTrue);
    });

    test('waits past stale 65535 until the triggered url test publishes a fresh result', () async {
      final baseline = DateTime.utc(2026, 7, 14, 23, 7, 10);
      final snapshots = [
        (tag: 'ГЕРМАНИЯ 1 | SIMPLE', delay: 65535, testedAt: baseline),
        (tag: 'ГЕРМАНИЯ 1 | SIMPLE', delay: 65535, testedAt: baseline),
        (tag: 'ГЕРМАНИЯ 1 | SIMPLE', delay: 318, testedAt: baseline.add(const Duration(seconds: 3))),
      ];
      var reads = 0;

      final result = await waitForFreshUrlTestDelaySnapshot(
        baselineTestedAt: baseline,
        probeStartedAt: baseline.add(const Duration(seconds: 1)),
        timeout: const Duration(seconds: 1),
        pollInterval: Duration.zero,
        readSnapshot: (_) async => snapshots[reads++],
      );

      expect(reads, 3);
      expect(result?.delay, 318);
      expect(isUsableStartupUrlTestDelay(result?.delay), isTrue);
    });

    test('keeps a fresh 65535 result as a real route failure', () async {
      final baseline = DateTime.utc(2026, 7, 14, 23, 7, 10);
      final result = await waitForFreshUrlTestDelaySnapshot(
        baselineTestedAt: baseline,
        probeStartedAt: baseline.add(const Duration(seconds: 1)),
        timeout: const Duration(seconds: 1),
        pollInterval: Duration.zero,
        readSnapshot: (_) async =>
            (tag: 'ГЕРМАНИЯ 1 | SIMPLE', delay: 65535, testedAt: baseline.add(const Duration(seconds: 2))),
      );

      expect(result?.delay, 65535);
      expect(isUsableStartupUrlTestDelay(result?.delay), isFalse);
    });

    test('TURNcoat probe and RX evidence are carrier-ready only, never startup route verification', () {
      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();

      expect(
        source,
        isNot(contains('StartupRouteVerification.turncoatProbeAndLiveness')),
        reason: 'a transport carrier is not a selected-route proof',
      );
      expect(
        source,
        isNot(contains('_verifyTurncoatStartupRoute')),
        reason: 'TURNcoat RX/probe must not run a separate startup route gate',
      );
      expect(
        source,
        isNot(contains('isUsableTurncoatStartupRoute')),
        reason: 'carrier liveness and backend RX must not promote startup readiness',
      );
      expect(
        source,
        isNot(contains('waitForLiveSelectedRouteOrTerminal')),
        reason: 'selected-route traffic logs are not an Android VPN data-plane proof',
      );
      expect(
        source,
        isNot(contains('turncoatRouteEvidenceGraceAfterFailedProbe')),
        reason: 'carrier/RX grace windows belong only to carrier readiness, never route admission',
      );
      expect(
        source,
        isNot(contains('waitForFreshRouteActivity')),
        reason: 'selected-route log activity cannot turn a failed Android VPN proof into success',
      );
      expect(
        source,
        isNot(contains('isSelectedOutboundActivityLogLine')),
        reason: 'backend log markers are telemetry, not authoritative route-health evidence',
      );
    });

    test('Flutter exposes Connected only after Android accepts the data-plane gate', () {
      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
      final connectStart = source.indexOf('TaskEither<ConnectionFailure, Unit> _withPreparedConfig(');
      final connectEnd = source.indexOf('\n  TaskEither<ConnectionFailure, Unit> _unlessConnectionStale', connectStart);
      final connect = connectStart < 0 || connectEnd < 0 ? '' : source.substring(connectStart, connectEnd);

      expect(connect, isNotEmpty);
      final platformAccepted = connect.indexOf('await singbox.notifyBackgroundStarted()');
      final routeGateOpen = connect.indexOf('_setStartupRouteReady(true)');
      expect(platformAccepted, isNonNegative);
      expect(routeGateOpen, greaterThan(platformAccepted));
      expect(connect, contains('Android VPN data plane did not become ready'));
    });

    test('accepts a healthy selected route watchdog result', () {
      expect(selectedRouteHealthFailure(null, (tag: 'US 1', delay: 42)), isNull);
    });

    test('uses endpoint probe for VLESS startup when endpoint metadata exists', () {
      const raw = '''
{
  "outbounds": [
    {"type": "selector", "tag": "select", "outbounds": ["Germany"]},
    {
      "type": "xray",
      "tag": "Germany",
      "xconfig": {
        "outbounds": [
          {"protocol": "vless"}
        ]
      }
    }
  ],
  "servers": [
    {"tag": "Germany", "server": "de-01.example", "server_port": 443}
  ]
}
''';

      final probe = selectedStartupEndpointProbe(raw, 'Germany');

      expect(probe, isNotNull);
      expect(probe!.tag, 'Germany');
      expect(probe.type, 'vless');
      expect(probe.server, 'de-01.example');
      expect(probe.serverPort, 443);
    });

    test('uses endpoint probe for native VLESS startup', () {
      const raw = '''
{
  "outbounds": [
    {"type": "selector", "tag": "select", "outbounds": ["US"]},
    {"type": "vless", "tag": "US", "server": "203.0.113.10", "server_port": 443}
  ]
}
''';

      final probe = selectedStartupEndpointProbe(raw, 'US');

      expect(probe, isNotNull);
      expect(probe!.tag, 'US');
      expect(probe.type, 'vless');
      expect(probe.server, '203.0.113.10');
      expect(probe.serverPort, 443);
    });

    test('keeps non server-port startup routes on url test gate', () {
      const raw = '''
{
  "outbounds": [
    {"type": "selector", "tag": "select", "outbounds": ["Hysteria"]},
    {"type": "hysteria2", "tag": "Hysteria", "server": "hy.example", "server_port": 443}
  ]
}
''';

      expect(selectedStartupEndpointProbe(raw, 'Hysteria'), isNull);
    });

    test('rejects failed selected route watchdog results', () {
      expect(selectedRouteHealthFailure('timeout', null), isNotNull);
      expect(selectedRouteHealthFailure(null, null), isNotNull);
      expect(selectedRouteHealthFailure(null, (tag: 'US 1', delay: 65535)), isNotNull);
    });
  });

  group('core operation failures', () {
    test('returns successful core results', () {
      expect(requireCoreOperationSuccess<String>(right('ok'), operation: 'test'), 'ok');
    });

    test('turns change/select Left results into terminal connection failures', () {
      expect(
        () => requireCoreOperationSuccess<Unit>(left('core rejected request'), operation: 'select outbound'),
        throwsA(
          isA<UnexpectedConnectionFailure>().having(
            (failure) => failure.error.toString(),
            'message',
            contains('select outbound failed: core rejected request'),
          ),
        ),
      );
    });

    test('classifies an exhausted local control-channel handoff without exposing raw gRPC as server failure', () {
      expect(
        () => requireCoreOperationSuccess<Unit>(
          left(localCoreControlChannelFailureMessage),
          operation: 'select outbound',
        ),
        throwsA(isA<BackgroundCoreNotAvailable>().having((failure) => failure.message, 'message', isNull)),
      );
    });
  });

  group('connection repository setup', () {
    test('Android stopped service forces a fresh control-shell setup despite retained client flags', () {
      expect(
        shouldRunConnectionRepositorySetup(
          isAndroid: true,
          repositoryInitialized: true,
          coreInitialized: true,
          platformStatus: const CoreStatus.stopped(),
        ),
        isTrue,
      );
    });

    test('Android running service retains the initialized fast path', () {
      for (final platformStatus in [const CoreStatus.starting(), const CoreStatus.started()]) {
        expect(
          shouldRunConnectionRepositorySetup(
            isAndroid: true,
            repositoryInitialized: true,
            coreInitialized: true,
            platformStatus: platformStatus,
          ),
          isFalse,
          reason: '$platformStatus still owns the foreground control shell',
        );
      }
    });

    test('non-Android setup keeps the existing both-uninitialized rule', () {
      expect(
        shouldRunConnectionRepositorySetup(
          isAndroid: false,
          repositoryInitialized: false,
          coreInitialized: false,
          platformStatus: const CoreStatus.stopped(),
        ),
        isTrue,
      );
      for (final flags in [
        (repositoryInitialized: true, coreInitialized: false),
        (repositoryInitialized: false, coreInitialized: true),
        (repositoryInitialized: true, coreInitialized: true),
      ]) {
        expect(
          shouldRunConnectionRepositorySetup(
            isAndroid: false,
            repositoryInitialized: flags.repositoryInitialized,
            coreInitialized: flags.coreInitialized,
            platformStatus: const CoreStatus.stopped(),
          ),
          isFalse,
        );
      }
    });

    test('setup reads Android platform ownership before applying its initialized fast path', () {
      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
      final setupStart = source.indexOf('TaskEither<ConnectionFailure, Unit> setup() {');
      final setupEnd = source.indexOf('\n  @override\n  Stream<ConnectionStatus> watchConnectionStatus()', setupStart);
      expect(setupStart, isNonNegative);
      expect(setupEnd, greaterThan(setupStart));
      final setup = source.substring(setupStart, setupEnd);
      final platformStatus = setup.indexOf('readPlatformServiceStatus()');
      final setupDecision = setup.indexOf('shouldRunConnectionRepositorySetup(');
      final earlySkip = setup.indexOf('return right(unit);');

      expect(platformStatus, isNonNegative);
      expect(setupDecision, greaterThan(platformStatus));
      expect(earlySkip, greaterThan(setupDecision));
    });
  });

  test('syncNativeResumeConfig delegates to the native resume synchronizer with its connection generation guard', () {
    final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
    final syncStart = source.indexOf('@override\n  TaskEither<ConnectionFailure, Unit> syncNativeResumeConfig(');
    final syncEnd = source.indexOf(
      '\n  @override\n  TaskEither<ConnectionFailure, Unit> verifyConnectedRoute',
      syncStart,
    );
    final sync = syncStart < 0 || syncEnd < 0 ? '' : source.substring(syncStart, syncEnd);

    expect(sync, isNotEmpty);
    expect(sync, contains('final generation = _connectionGeneration;'));
    expect(sync, contains('nativeResumeConfigSynchronizer.synchronize('));
    expect(sync, contains('isCurrent: () => !_isConnectionStale(generation)'));
  });

  group('disconnect cleanup', () {
    test('ordinary disconnect performs only the initial stop', () {
      expect(shouldRunFinalStopAfterInterrupt(previousOperationInProgress: false), isFalse);
    });

    test('interrupted in-flight start receives a final safety stop', () {
      expect(shouldRunFinalStopAfterInterrupt(previousOperationInProgress: true), isTrue);
    });
  });

  test('_interruptConnectionOperation marks stop intent before queued disconnect coalescing', () {
    final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
    final interrupt = source.indexOf('Future<Either<ConnectionFailure, Unit>> _interruptConnectionOperation() {');
    expect(interrupt, isPositive);
    final markIntent = source.indexOf('_markConnectionIntent(_ConnectionIntent.stop);', interrupt);
    final runDisconnect = source.indexOf('return _disconnectOperations.run(', interrupt);
    expect(markIntent, isPositive);
    expect(runDisconnect, isPositive);
    expect(markIntent, lessThan(runDisconnect));
  });

  group('CoalescedFuture', () {
    test('run executes operation once while active callers share the same future', () async {
      var runs = 0;
      final coalesced = CoalescedFuture<String>();
      final inFlight = Completer<String>();

      final first = coalesced.run(() {
        runs++;
        return inFlight.future;
      });
      final second = coalesced.run(() {
        runs++;
        return Future.value('second');
      });

      expect(identical(first, second), isTrue);
      expect(runs, 1);

      inFlight.complete('ok');
      final values = await Future.wait([first, second]);

      expect(values, ['ok', 'ok']);
    });

    test('onCoalesced callback runs when a second caller joins an active operation', () async {
      var runs = 0;
      var coalescedCallbacks = 0;
      final coalesced = CoalescedFuture<String>();
      final inFlight = Completer<String>();

      final first = coalesced.run(() {
        runs++;
        return inFlight.future;
      });
      final second = coalesced.run(() {
        runs++;
        return Future.value('should not run');
      }, onCoalesced: () => coalescedCallbacks++);

      expect(identical(first, second), isTrue);
      expect(runs, 1);
      expect(coalescedCallbacks, 1);

      inFlight.complete('ok');
      expect(await first, 'ok');
      expect(await second, 'ok');
    });

    test('a new run executes the operation again after previous completion', () async {
      var runs = 0;
      final coalesced = CoalescedFuture<String>();

      final first = coalesced.run(() {
        runs++;
        return Future.value('first');
      });
      expect(await first, 'first');

      final second = coalesced.run(() {
        runs++;
        return Future.value('second');
      });

      expect(await second, 'second');
      expect(runs, 2);
    });

    test('a new run executes again after a previous error', () async {
      var runs = 0;
      final coalesced = CoalescedFuture<String>();

      final first = coalesced.run(() {
        runs++;
        return Future<String>.error(StateError('coalesced failed'));
      });

      await expectLater(first, throwsA(isA<StateError>()));

      final second = coalesced.run(() {
        runs++;
        return Future.value('recovered');
      });

      expect(await second, 'recovered');
      expect(runs, 2);
    });
  });

  test('startup route verification has only endpoint and url-test cases', () {
    const endpoint = StartupEndpointProbe(tag: 'US', type: 'vless', server: 'us.example', serverPort: 443);

    expect(startupRouteVerificationFor(startupEndpoint: endpoint), StartupRouteVerification.endpointFallback);
    expect(startupRouteVerificationFor(startupEndpoint: null), StartupRouteVerification.urlTest);
    expect(StartupRouteVerification.values, [
      StartupRouteVerification.endpointFallback,
      StartupRouteVerification.urlTest,
    ]);
  });

  test('reconnectCoreForPlatform<String> uses Android stop+start ordering', () async {
    final events = <String>[];
    final stop = TaskEither<String, Unit>(() async {
      events.add('stop');
      return right(unit);
    });
    final start = TaskEither<String, Unit>(() async {
      events.add('start');
      return right(unit);
    });
    final restart = TaskEither<String, Unit>(() async {
      events.add('restart');
      return right(unit);
    });

    final result = await reconnectCoreForPlatform<String>(
      isAndroid: true,
      stop: stop,
      start: start,
      restart: restart,
    ).run();

    expect(result.isRight(), isTrue);
    expect(events, ['stop', 'start']);
    expect(events, isNot(contains('restart')));
  });

  test('reconnectCoreForPlatform<String> uses restart only on non-Android', () async {
    final events = <String>[];
    final stop = TaskEither<String, Unit>(() async {
      events.add('stop');
      return right(unit);
    });
    final start = TaskEither<String, Unit>(() async {
      events.add('start');
      return right(unit);
    });
    final restart = TaskEither<String, Unit>(() async {
      events.add('restart');
      return right(unit);
    });

    final result = await reconnectCoreForPlatform<String>(
      isAndroid: false,
      stop: stop,
      start: start,
      restart: restart,
    ).run();

    expect(result.isRight(), isTrue);
    expect(events, ['restart']);
    expect(events, isNot(contains('start')));
    expect(events, isNot(contains('stop')));
  });

  test('reconnectCoreForPlatform<String> keeps a stop Left and skips downstream start', () async {
    final events = <String>[];
    final stop = TaskEither<String, Unit>(() async {
      events.add('stop');
      return left('stop failed');
    });
    final start = TaskEither<String, Unit>(() async {
      events.add('start');
      return right(unit);
    });
    final restart = TaskEither<String, Unit>(() async {
      events.add('restart');
      return right(unit);
    });

    final result = await reconnectCoreForPlatform<String>(
      isAndroid: true,
      stop: stop,
      start: start,
      restart: restart,
    ).run();

    result.match((failure) => expect(failure, 'stop failed'), (_) => fail('expected stop branch left to be preserved'));
    expect(events, ['stop']);
  });
}
