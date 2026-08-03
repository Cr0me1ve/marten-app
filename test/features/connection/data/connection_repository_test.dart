import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:marten/features/connection/data/connection_repository.dart';
import 'package:marten/features/connection/data/turncoat_liveness_notifier.dart';
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
  });

  group('platform route gate', () {
    test('holds the route gate closed while Android starts its route', () {
      expect(platformRouteGateTransition(current: const CoreStatus.starting(), pending: false), (
        pending: true,
        routeReady: false,
      ));
    });

    test('opens the route gate only for a fresh platform started event', () {
      final starting = platformRouteGateTransition(current: const CoreStatus.starting(), pending: false);

      expect(platformRouteGateTransition(current: const CoreStatus.started(), pending: starting.pending), (
        pending: false,
        routeReady: true,
      ));
    });

    test('does not open the gate for an initially retained platform started event', () {
      expect(platformRouteGateTransition(current: const CoreStatus.started(), pending: false), (
        pending: false,
        routeReady: null,
      ));
    });

    test('closes and clears the gate for terminal platform states', () {
      for (final status in [const CoreStatus.stopping(), const CoreStatus.stopped()]) {
        expect(platformRouteGateTransition(current: status, pending: true), (pending: false, routeReady: false));
      }
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
      expect(watch, contains('platformRouteGateTransition('));
      expect(watch, contains('_startupRouteReadyController.stream'));
    });
  });

  group('startup route readiness', () {
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

    test('connected route ping keeps a numeric delay when TURNcoat uses fresh traffic evidence', () {
      expect(connectedRoutePingDelay(reportedDelay: 42, elapsed: 300), 42);
      expect(connectedRoutePingDelay(reportedDelay: 65535, elapsed: 287), 287);
      expect(connectedRoutePingDelay(reportedDelay: null, elapsed: 0), 1);
    });

    test('accepts TURNcoat startup readiness from live transport state', () {
      expect(isUsableTurncoatStartupLiveness(const TurncoatLivenessState(inUse: true, live: true)), isTrue);
      expect(isUsableTurncoatStartupLiveness(const TurncoatLivenessState(inUse: true, timedOut: true)), isFalse);
      expect(isUsableTurncoatStartupLiveness(const TurncoatLivenessState(inUse: true)), isFalse);
    });

    test('requires TURNcoat liveness plus active probe or selected route traffic for startup readiness', () {
      expect(
        isUsableTurncoatStartupRoute(
          routeVerified: true,
          liveness: const TurncoatLivenessState(inUse: true, live: true),
        ),
        isTrue,
      );
      expect(
        isUsableTurncoatStartupRoute(routeVerified: true, liveness: const TurncoatLivenessState(inUse: true)),
        isFalse,
      );
      expect(
        isUsableTurncoatStartupRoute(
          routeVerified: false,
          liveness: const TurncoatLivenessState(inUse: true, live: true),
        ),
        isFalse,
      );
      expect(
        isUsableTurncoatStartupRoute(
          routeVerified: false,
          liveness: const TurncoatLivenessState(inUse: true, live: true, routeActive: true),
        ),
        isTrue,
      );
    });

    test('bounds route evidence only after the TURNcoat carrier is live', () {
      expect(turncoatRouteEvidenceGraceAfterFailedProbe(const TurncoatLivenessState(inUse: true)), isNull);
      expect(
        turncoatRouteEvidenceGraceAfterFailedProbe(const TurncoatLivenessState(inUse: true, live: true)),
        const Duration(seconds: 8),
      );
      expect(
        turncoatRouteEvidenceGraceAfterFailedProbe(
          const TurncoatLivenessState(inUse: true, live: true, routeActive: true),
        ),
        isNull,
      );
    });

    test('accepts TURNcoat connected health only from fresh selected route traffic', () {
      expect(
        isUsableTurncoatConnectedRoute(
          previousRouteActivityCount: 2,
          liveness: const TurncoatLivenessState(inUse: true, live: true, routeActive: true, routeActivityCount: 3),
        ),
        isTrue,
      );
      expect(
        isUsableTurncoatConnectedRoute(
          previousRouteActivityCount: 2,
          liveness: const TurncoatLivenessState(inUse: true, live: true, routeActive: true, routeActivityCount: 2),
        ),
        isFalse,
      );
      expect(
        isUsableTurncoatConnectedRoute(
          previousRouteActivityCount: 2,
          liveness: const TurncoatLivenessState(inUse: true, routeActive: true, routeActivityCount: 3),
        ),
        isFalse,
      );
    });

    test('uses TURNcoat probe and liveness before endpoint fallback when both are available', () {
      const endpoint = StartupEndpointProbe(tag: 'US', type: 'vless', server: 'us.example', serverPort: 443);

      expect(
        startupRouteVerificationFor(usesTurncoat: true, startupEndpoint: endpoint),
        StartupRouteVerification.turncoatProbeAndLiveness,
      );
      expect(
        startupRouteVerificationFor(usesTurncoat: false, startupEndpoint: endpoint),
        StartupRouteVerification.endpointFallback,
      );
      expect(startupRouteVerificationFor(usesTurncoat: false, startupEndpoint: null), StartupRouteVerification.urlTest);
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

  test('failed startup route is preserved only when Android native recovery is allowed', () {
    expect(shouldPreserveFailedStartupRouteForNativeRecovery(isAndroid: true, allowNativeRecovery: true), isTrue);
    expect(shouldPreserveFailedStartupRouteForNativeRecovery(isAndroid: true, allowNativeRecovery: false), isFalse);
    expect(shouldPreserveFailedStartupRouteForNativeRecovery(isAndroid: false, allowNativeRecovery: true), isFalse);
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
