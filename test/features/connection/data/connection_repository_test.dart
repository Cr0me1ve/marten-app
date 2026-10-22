import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:marten/features/connection/data/connection_repository.dart';
import 'package:marten/features/connection/model/connection_failure.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:marten/singbox/model/core_status.dart';

void main() {
  group('retained runtime feature restoration', () {
    test('arms TURNcoat only when the selected route depends on it', () {
      const ordinaryRoute = '''
        {"outbounds":[
          {"type":"vless","tag":"selected"},
          {"type":"turncoat","tag":"unused-helper"}
        ]}
      ''';
      const turncoatRoute = '''
        {"outbounds":[
          {"type":"vless","tag":"selected","detour":"captcha-helper"},
          {"type":"turncoat","tag":"captcha-helper"}
        ]}
      ''';

      expect(selectedOutboundUsesTurncoat(ordinaryRoute, 'selected'), isFalse);
      expect(selectedOutboundUsesTurncoat(turncoatRoute, 'selected'), isTrue);
    });

    test('restoration requires the exact active config and current lifecycle before arming once', () {
      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
      final restoreStart = source.indexOf(
        'Future<bool> restoreActiveRuntimeFeatures(ProfileEntity profile, {bool Function()? isCurrent}) async {',
      );
      final restoreEnd = source.indexOf(
        '\n  Future<({String? selectedTag, bool usesTurncoat})?> _matchingActiveRuntimeRoute',
        restoreStart,
      );
      final matcherEnd = source.indexOf('\n  @override\n  Future<int?> tryBeginFlutterRestart', restoreEnd);
      expect(restoreStart, isNonNegative);
      expect(restoreEnd, greaterThan(restoreStart));
      expect(matcherEnd, greaterThan(restoreEnd));

      final restore = source.substring(restoreStart, restoreEnd);
      final matcher = source.substring(restoreEnd, matcherEnd);
      final routeMatch = restore.indexOf('final route = await _matchingActiveRuntimeRoute(profile);');
      final staleCheck = restore.indexOf('route == null || _isConnectionStale(generation)');
      final callbackCheck = restore.indexOf('isCurrent?.call() == false', staleCheck);
      final livenessRead = restore.indexOf('final liveness = ref.read(turncoatLivenessNotifierProvider.notifier);');
      final duplicateArmGuard = restore.indexOf(
        '_restoredRuntimeFeaturesGeneration != generation || _restoredRuntimeLivenessGeneration != liveness.generation',
      );
      final arm = restore.indexOf('_armTurncoatFeatures(route.usesTurncoat, selectedTag: route.selectedTag)');
      final featuresGenerationSaved = restore.indexOf('_restoredRuntimeFeaturesGeneration = generation;', arm);
      final livenessGenerationSaved = restore.indexOf('_restoredRuntimeLivenessGeneration = liveness.generation;', arm);

      expect(restore, contains('if (isCurrent?.call() == false) return false;'));
      expect(routeMatch, isNonNegative);
      expect(staleCheck, greaterThan(routeMatch));
      expect(callbackCheck, greaterThan(staleCheck));
      expect(livenessRead, greaterThan(callbackCheck));
      expect(duplicateArmGuard, greaterThan(livenessRead));
      expect(arm, greaterThan(duplicateArmGuard));
      expect(featuresGenerationSaved, greaterThan(arm));
      expect(livenessGenerationSaved, greaterThan(arm));
      expect(featuresGenerationSaved, lessThan(livenessGenerationSaved));

      expect(matcher, contains('selectedOutboundUsesTurncoat(prepared, selectedTag)'));
      expect(matcher, contains('singbox.matchesActiveConfigGeneration(preparedFile.path)'));
      expect(matcher, contains('await preparedFile.delete()'));
      expect(matcher, contains('return matches && !_isConnectionStale(generation) ? route : null;'));
    });
  });

  group('pending CAPTCHA resolution wait', () {
    test('completes when the pending CAPTCHA resolves before its deadline', () {
      fakeAsync((async) {
        final resolution = Completer<void>();
        final result = waitForPendingCaptchaResolution(
          pendingAt: DateTime.now(),
          resolution: resolution.future,
          maxWait: const Duration(seconds: 30),
        );
        bool? resolved;
        result.then((value) => resolved = value);

        resolution.complete();
        async.flushMicrotasks();

        expect(resolved, isTrue);
      });
    });

    test('rejects an already expired CAPTCHA even when its resolution is complete', () {
      fakeAsync((async) {
        final result = waitForPendingCaptchaResolution(
          pendingAt: DateTime.now().subtract(const Duration(seconds: 30)),
          resolution: Future<void>.value(),
          maxWait: const Duration(seconds: 30),
        );
        bool? resolved;
        result.then((value) => resolved = value);

        async.flushMicrotasks();

        expect(resolved, isFalse);
      });
    });

    test('times out without reporting success when no CAPTCHA resolution arrives', () {
      fakeAsync((async) {
        final resolution = Completer<void>();
        final result = waitForPendingCaptchaResolution(
          pendingAt: DateTime.now(),
          resolution: resolution.future,
          maxWait: const Duration(seconds: 30),
        );
        bool? resolved;
        result.then((value) => resolved = value);

        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        resolution.complete();
        async.flushMicrotasks();

        expect(resolved, isFalse);
      });
    });
  });

  group('startup route CAPTCHA verification', () {
    test('gives each post-CAPTCHA probe a fresh route budget and admits only a probe success', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final firstResolution = Completer<void>();
        final secondResolution = Completer<void>();
        var challenge = (createdAt: clock.now(), resolution: firstResolution.future);
        final budgets = <Duration>[];
        var calls = 0;
        bool? verified;

        verifyStartupRouteWithCaptcha(
          verifyRoute: (timeout) {
            budgets.add(timeout);
            calls += 1;
            return switch (calls) {
              1 => Future<bool>.delayed(const Duration(seconds: 12), () => false),
              2 => Future<bool>.delayed(const Duration(seconds: 5), () {
                challenge = (createdAt: clock.now(), resolution: secondResolution.future);
                return false;
              }),
              3 => Future<bool>.delayed(const Duration(seconds: 5), () => true),
              _ => throw StateError('unexpected route probe'),
            };
          },
          latestChallenge: () => challenge,
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => verified = value);

        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();
        expect(verified, isNull, reason: 'a pending CAPTCHA alone must not admit the route');

        async.elapse(const Duration(seconds: 47));
        firstResolution.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(verified, isNull, reason: 'a replacement CAPTCHA alone must not admit the route');

        async.elapse(const Duration(seconds: 2));
        secondResolution.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(verified, isTrue);
        expect(budgets, const [Duration(seconds: 12), Duration(seconds: 12), Duration(seconds: 12)]);
      });
    });

    test('does not repeat a failed probe for the same challenge or without a challenge', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final resolution = Completer<void>()..complete();
        final challenge = (createdAt: clock.now(), resolution: resolution.future);
        var calls = 0;
        bool? sameChallengeResult;

        verifyStartupRouteWithCaptcha(
          verifyRoute: (_) async {
            calls += 1;
            return false;
          },
          latestChallenge: () => challenge,
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => sameChallengeResult = value);
        async.flushMicrotasks();

        expect(sameChallengeResult, isFalse);
        expect(calls, 2);

        calls = 0;
        bool? noChallengeResult;
        verifyStartupRouteWithCaptcha(
          verifyRoute: (_) async {
            calls += 1;
            return false;
          },
          latestChallenge: () => null,
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => noChallengeResult = value);
        async.flushMicrotasks();

        expect(noChallengeResult, isFalse);
        expect(calls, 1);
      });
    });

    test('bounds endlessly revised CAPTCHA retries by the overall deadline and clips the final probe', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final budgets = <Duration>[];
        var calls = 0;
        ({DateTime createdAt, Future<void> resolution})? challenge;
        bool? verified;

        verifyStartupRouteWithCaptcha(
          verifyRoute: (timeout) {
            budgets.add(timeout);
            calls += 1;
            return Future<bool>.delayed(timeout, () {
              challenge = (createdAt: clock.now(), resolution: Future<void>.delayed(const Duration(seconds: 1)));
              return false;
            });
          },
          latestChallenge: () => challenge,
          isCancelled: () => false,
          overallTimeout: const Duration(seconds: 84),
          now: clock.now,
        ).then((value) => verified = value);

        async.elapse(const Duration(seconds: 84));
        async.flushMicrotasks();

        expect(verified, isFalse);
        expect(calls, 7);
        expect(budgets.sublist(0, 6), List.filled(6, const Duration(seconds: 12)));
        expect(budgets.last, const Duration(seconds: 6));
      });
    });

    test('does not launch another probe when cancellation happens while awaiting a CAPTCHA', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final resolution = Completer<void>();
        final challenge = (createdAt: clock.now(), resolution: resolution.future);
        var cancelled = false;
        var calls = 0;
        bool? verified;

        verifyStartupRouteWithCaptcha(
          verifyRoute: (_) async {
            calls += 1;
            return false;
          },
          latestChallenge: () => challenge,
          isCancelled: () => cancelled,
          now: clock.now,
        ).then((value) => verified = value);
        async.flushMicrotasks();

        cancelled = true;
        resolution.complete();
        async.flushMicrotasks();

        expect(verified, isFalse);
        expect(calls, 1);
      });
    });

    test('does not admit a positive route result after its start generation is superseded in flight', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final inFlightProof = Completer<bool>();
        var generationIsStale = false;
        bool? verified;

        verifyStartupRouteWithCaptcha(
          verifyRoute: (_) => inFlightProof.future,
          latestChallenge: () => null,
          isCancelled: () => generationIsStale,
          now: clock.now,
        ).then((value) => verified = value);
        async.flushMicrotasks();
        expect(verified, isNull, reason: 'route proof is still pending for this generation');

        generationIsStale = true;
        inFlightProof.complete(true);
        async.flushMicrotasks();

        expect(verified, isFalse, reason: 'a stale successful probe must not open the route-ready gate');
      });
    });

    test('fails when the unresolved CAPTCHA expires', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final resolution = Completer<void>();
        final challenge = (createdAt: clock.now(), resolution: resolution.future);
        var calls = 0;
        bool? verified;

        verifyStartupRouteWithCaptcha(
          verifyRoute: (_) async {
            calls += 1;
            return false;
          },
          latestChallenge: () => challenge,
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => verified = value);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(verified, isFalse);
        expect(calls, 1);
      });
    });

    test('uses one fresh-progress probe after a failed 36-second route verification and admits only its success', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final budgets = <Duration>[];
        var freshProgress = false;
        var calls = 0;
        bool? verified;

        verifyStartupRouteWithCaptcha(
          routeTimeout: const Duration(seconds: 36),
          verifyRoute: (timeout) {
            budgets.add(timeout);
            calls += 1;
            return Future<bool>.delayed(
              timeout == const Duration(seconds: 36) ? timeout : const Duration(seconds: 1),
              () {
                if (calls == 1) freshProgress = true;
                return calls == 2;
              },
            );
          },
          latestChallenge: () => null,
          hasFreshRouteProgress: () => freshProgress,
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => verified = value);

        async.elapse(const Duration(seconds: 37));
        async.flushMicrotasks();

        expect(verified, isTrue);
        expect(budgets, const [Duration(seconds: 36), Duration(seconds: 12)]);
      });
    });

    test('allows only one failed fresh-progress probe', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final budgets = <Duration>[];
        bool? verified;

        verifyStartupRouteWithCaptcha(
          routeTimeout: const Duration(seconds: 36),
          verifyRoute: (timeout) {
            budgets.add(timeout);
            return Future<bool>.value(false);
          },
          latestChallenge: () => null,
          hasFreshRouteProgress: () => true,
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => verified = value);
        async.flushMicrotasks();

        expect(verified, isFalse);
        expect(budgets, const [Duration(seconds: 36), Duration(seconds: 12)]);
      });
    });

    test('does not add a progress probe when no fresh progress exists', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final budgets = <Duration>[];
        bool? verified;

        verifyStartupRouteWithCaptcha(
          routeTimeout: const Duration(seconds: 36),
          verifyRoute: (timeout) {
            budgets.add(timeout);
            return Future<bool>.value(false);
          },
          latestChallenge: () => null,
          hasFreshRouteProgress: () => false,
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => verified = value);
        async.flushMicrotasks();

        expect(verified, isFalse);
        expect(budgets, const [Duration(seconds: 36)]);
      });
    });

    test('does not add a progress probe after cancellation', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final budgets = <Duration>[];
        var cancelled = false;
        bool? verified;

        verifyStartupRouteWithCaptcha(
          routeTimeout: const Duration(seconds: 36),
          verifyRoute: (timeout) {
            budgets.add(timeout);
            cancelled = true;
            return Future<bool>.value(false);
          },
          latestChallenge: () => null,
          hasFreshRouteProgress: () => true,
          isCancelled: () => cancelled,
          now: clock.now,
        ).then((value) => verified = value);
        async.flushMicrotasks();

        expect(verified, isFalse);
        expect(budgets, const [Duration(seconds: 36)]);
      });
    });

    test('clips the one progress probe to the remaining overall deadline', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final budgets = <Duration>[];
        bool? verified;

        verifyStartupRouteWithCaptcha(
          routeTimeout: const Duration(seconds: 36),
          overallTimeout: const Duration(seconds: 40),
          verifyRoute: (timeout) {
            budgets.add(timeout);
            return Future<bool>.delayed(timeout, () => false);
          },
          latestChallenge: () => null,
          hasFreshRouteProgress: () => true,
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => verified = value);
        async.elapse(const Duration(seconds: 40));
        async.flushMicrotasks();

        expect(verified, isFalse);
        expect(budgets, const [Duration(seconds: 36), Duration(seconds: 4)]);
      });
    });

    test('honors a new CAPTCHA that arrives after the progress probe while budget remains', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final challengeResolution = Completer<void>()..complete();
        ({DateTime createdAt, Future<void> resolution})? challenge;
        final budgets = <Duration>[];
        var calls = 0;
        bool? verified;

        verifyStartupRouteWithCaptcha(
          routeTimeout: const Duration(seconds: 36),
          verifyRoute: (timeout) {
            budgets.add(timeout);
            calls += 1;
            return Future<bool>.delayed(timeout == const Duration(seconds: 36) ? timeout : Duration.zero, () {
              if (calls == 2) challenge = (createdAt: clock.now(), resolution: challengeResolution.future);
              return calls == 3;
            });
          },
          latestChallenge: () => challenge,
          hasFreshRouteProgress: () => calls >= 1,
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => verified = value);
        async.elapse(const Duration(seconds: 72));
        async.flushMicrotasks();

        expect(verified, isTrue);
        expect(budgets, const [Duration(seconds: 36), Duration(seconds: 12), Duration(seconds: 36)]);
      });
    });
  });

  group('bounded startup route probes', () {
    test('allows one uninterrupted 36-second iOS TURNcoat probe to verify after 25 seconds', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final budgets = <Duration>[];
        ({bool connectionStale, bool routeVerified, bool endpointFallbackAllowed})? result;

        runStartupRouteProbes(
          timeout: const Duration(seconds: 36),
          maxAttemptTimeout: const Duration(seconds: 36),
          probe: (budget) {
            budgets.add(budget);
            return Future<StartupRouteProbeResult>.delayed(
              const Duration(seconds: 25),
              () => (connectionStale: false, error: null, delay: 25),
            );
          },
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => result = value);

        async.elapse(const Duration(seconds: 25));
        async.flushMicrotasks();

        expect(result, (connectionStale: false, routeVerified: true, endpointFallbackAllowed: false));
        expect(budgets, const [Duration(seconds: 36)]);
      });
    });

    test('does not split a full 36-second iOS TURNcoat attempt into retries', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final budgets = <Duration>[];
        ({bool connectionStale, bool routeVerified, bool endpointFallbackAllowed})? result;

        runStartupRouteProbes(
          timeout: const Duration(seconds: 36),
          maxAttemptTimeout: const Duration(seconds: 36),
          probe: (budget) {
            budgets.add(budget);
            return Future<StartupRouteProbeResult>.delayed(
              budget,
              () => (connectionStale: false, error: 'network', delay: null),
            );
          },
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => result = value);

        async.elapse(const Duration(seconds: 36));
        async.flushMicrotasks();

        expect(result, (connectionStale: false, routeVerified: false, endpointFallbackAllowed: false));
        expect(budgets, const [Duration(seconds: 36)]);
      });
    });

    test('keeps cancellation and the default 12-second attempt cap unchanged', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final defaultBudgets = <Duration>[];
        var cancelled = false;
        ({bool connectionStale, bool routeVerified, bool endpointFallbackAllowed})? cancellationResult;

        runStartupRouteProbes(
          timeout: const Duration(seconds: 36),
          probe: (budget) {
            defaultBudgets.add(budget);
            cancelled = true;
            return Future<StartupRouteProbeResult>.value((connectionStale: false, error: 'network', delay: null));
          },
          isCancelled: () => cancelled,
          now: clock.now,
        ).then((value) => cancellationResult = value);
        async.flushMicrotasks();

        expect(cancellationResult, (connectionStale: true, routeVerified: false, endpointFallbackAllowed: false));
        expect(defaultBudgets, const [Duration(seconds: 12)]);
      });
    });

    test('retries after a full failed network attempt and admits only the next measured success', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final budgets = <Duration>[];
        var calls = 0;
        ({bool connectionStale, bool routeVerified, bool endpointFallbackAllowed})? result;

        runStartupRouteProbes(
          timeout: const Duration(seconds: 36),
          probe: (budget) {
            budgets.add(budget);
            calls += 1;
            if (calls == 1) {
              return Future<StartupRouteProbeResult>.delayed(
                budget,
                () => (connectionStale: false, error: 'network', delay: null),
              );
            }
            return Future<StartupRouteProbeResult>.delayed(
              const Duration(seconds: 1),
              () => (connectionStale: false, error: null, delay: 42),
            );
          },
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => result = value);

        async.elapse(const Duration(seconds: 13, milliseconds: 700));
        async.flushMicrotasks();

        expect(result, (connectionStale: false, routeVerified: true, endpointFallbackAllowed: false));
        expect(budgets, const [Duration(seconds: 12), Duration(seconds: 12)]);
      });
    });

    test('caps three failed network attempts at the 36-second overall budget', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final budgets = <Duration>[];
        ({bool connectionStale, bool routeVerified, bool endpointFallbackAllowed})? result;

        runStartupRouteProbes(
          timeout: const Duration(seconds: 36),
          probe: (budget) {
            budgets.add(budget);
            return Future<StartupRouteProbeResult>.delayed(
              budget,
              () => (connectionStale: false, error: 'network', delay: null),
            );
          },
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => result = value);

        async.elapse(const Duration(seconds: 36));
        async.flushMicrotasks();

        expect(result, (connectionStale: false, routeVerified: false, endpointFallbackAllowed: false));
        expect(budgets, const [Duration(seconds: 12), Duration(seconds: 12), Duration(seconds: 10, milliseconds: 600)]);
      });
    });

    test('keeps an ordinary 12-second budget to one stalled network attempt', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        final budgets = <Duration>[];
        ({bool connectionStale, bool routeVerified, bool endpointFallbackAllowed})? result;

        runStartupRouteProbes(
          timeout: const Duration(seconds: 12),
          probe: (budget) {
            budgets.add(budget);
            return Future<StartupRouteProbeResult>.delayed(
              budget,
              () => (connectionStale: false, error: 'network', delay: null),
            );
          },
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => result = value);

        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();

        expect(result, (connectionStale: false, routeVerified: false, endpointFallbackAllowed: false));
        expect(budgets, const [Duration(seconds: 12)]);
      });
    });

    test('does not launch another probe when cancellation arrives during retry backoff', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        var cancelled = false;
        var calls = 0;
        ({bool connectionStale, bool routeVerified, bool endpointFallbackAllowed})? result;

        runStartupRouteProbes(
          timeout: const Duration(seconds: 36),
          probe: (_) async {
            calls += 1;
            return (connectionStale: false, error: 'network', delay: null);
          },
          isCancelled: () => cancelled,
          now: clock.now,
        ).then((value) => result = value);
        async.flushMicrotasks();

        cancelled = true;
        async.elapse(const Duration(milliseconds: 700));
        async.flushMicrotasks();

        expect(result, (connectionStale: true, routeVerified: false, endpointFallbackAllowed: false));
        expect(calls, 1);
      });
    });

    test('never admits a stale success', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        ({bool connectionStale, bool routeVerified, bool endpointFallbackAllowed})? result;

        runStartupRouteProbes(
          timeout: const Duration(seconds: 36),
          probe: (_) async => (connectionStale: true, error: null, delay: 1),
          isCancelled: () => false,
          now: clock.now,
        ).then((value) => result = value);
        async.flushMicrotasks();

        expect(result, (connectionStale: true, routeVerified: false, endpointFallbackAllowed: false));
      });
    });

    test('permits endpoint fallback only for a measured non-timeout zero delay', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime.utc(2026));
        for (final sample in <({String? error, int? delay, bool fallback})>[
          (error: null, delay: null, fallback: false),
          (error: 'network', delay: 0, fallback: false),
          (error: null, delay: 65535, fallback: false),
          (error: null, delay: 0, fallback: true),
        ]) {
          ({bool connectionStale, bool routeVerified, bool endpointFallbackAllowed})? result;
          runStartupRouteProbes(
            timeout: const Duration(seconds: 1),
            probe: (_) async => (connectionStale: false, error: sample.error, delay: sample.delay),
            isCancelled: () => false,
            now: clock.now,
          ).then((value) => result = value);
          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();

          expect(result, (connectionStale: false, routeVerified: false, endpointFallbackAllowed: sample.fallback));
        }
      });
    });
  });

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
      final platformStreamStart = source.indexOf('final platformEvents = singbox');
      final combineStart = source.indexOf('return Rx.combineLatest2', platformStreamStart);
      expect(platformStreamStart, isNonNegative);
      expect(combineStart, greaterThan(platformStreamStart));
      final platformStream = source.substring(platformStreamStart, combineStart);
      expect(platformStream, contains('nativeRecoveryRouteGateTransition('));
      expect(platformStream, contains('previous: _lastObservedPlatformStatus'));
      expect(RegExp(r'pending:\s*_nativePlatformRecoveryRouteGatePending').hasMatch(platformStream), isTrue);
    });

    test('iOS recovery keeps the route gate closed while a fresh startup verification is pending', () {
      final restarting = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.started(),
        current: const CoreStatus.starting(),
        pending: false,
        startupVerificationInProgress: true,
      );
      final started = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.starting(),
        current: const CoreStatus.started(),
        pending: restarting.pending,
        startupVerificationInProgress: true,
      );

      expect(restarting, (pending: true, routeReady: false));
      expect(started, (pending: false, routeReady: false));

      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
      final coreStatusStart = source.indexOf('final coreStatus = resilientRuntimeStatus');
      final platformBranch = source.indexOf('if (!Platform.isAndroid)', coreStatusStart);
      final coreStatus = coreStatusStart < 0 || platformBranch < 0
          ? ''
          : source.substring(coreStatusStart, platformBranch);
      expect(coreStatus, contains('startupVerificationInProgress: Platform.isIOS && _connectionOperationInProgress'));
    });

    test('native recovery preserves the legacy gate reopening when no startup verification is active', () {
      final restarting = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.started(),
        current: const CoreStatus.starting(),
        pending: false,
      );
      final started = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.starting(),
        current: const CoreStatus.started(),
        pending: restarting.pending,
      );

      expect(started, (pending: false, routeReady: true));
    });

    test('a delayed duplicate Started event does not reopen an iOS verification gate', () {
      final duplicate = nativeRecoveryRouteGateTransition(
        previous: const CoreStatus.started(),
        current: const CoreStatus.started(),
        pending: false,
        startupVerificationInProgress: true,
      );

      expect(duplicate, (pending: false, routeReady: null));
    });
  });

  group('android route gate', () {
    test('platform service is authoritative for every Android connection status', () {
      expect(connectionStatusFromAndroidPlatform(const CoreStatus.starting()), const Connecting());
      expect(connectionStatusFromAndroidPlatform(const CoreStatus.started()), const Connected());
      expect(connectionStatusFromAndroidPlatform(const CoreStatus.stopping()), const Disconnecting());
      expect(
        connectionStatusFromAndroidPlatform(
          const CoreStatus.stopped(alert: CoreAlert.startFailed, message: 'route failed'),
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

    test('route-gated Starting and Started remain separate raw lifecycle events', () {
      final rawLifecycleStatuses = [
        connectionStatusFromAndroidPlatform(const CoreStatus.starting()),
        connectionStatusFromAndroidPlatform(const CoreStatus.started()),
      ];

      expect(rawLifecycleStatuses, [const Connecting(), const Connected()]);
      expect(rawLifecycleStatuses.first, isNot(rawLifecycleStatuses.last));
      expect(
        rawLifecycleStatuses.last,
        isA<Connected>(),
        reason: 'platform Started is route-verified and directly visible',
      );

      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
      final androidBranch = source.indexOf('final platformEvents = singbox');
      final methodEnd = source.indexOf('\n  @override\n  TaskEither<ConnectionFailure, Unit> connect', androidBranch);
      expect(androidBranch, isNonNegative);
      expect(methodEnd, greaterThan(androidBranch));
      final androidStream = source.substring(androidBranch, methodEnd);
      expect(androidStream, contains('Rx.combineLatest2<CoreStatus, CoreStatus, ConnectionStatus>('));
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
      expect(watch, contains('return Rx.combineLatest2<CoreStatus, bool, ConnectionStatus>('));
      expect(watch, contains('return Rx.combineLatest2<CoreStatus, CoreStatus, ConnectionStatus>('));
      expect(
        RegExp(r'watchStatus\(\)\.handleError|runtimeStatus\.handleError').hasMatch(watch),
        isTrue,
        reason: 'Android runtime stream transport errors must not terminate the UI stream during native recovery',
      );
      expect(watch, contains('watchPlatformServiceStatus()\n        .handleError'));
      expect(watch, contains('androidPlatformStatusWithSnapshot('));
      expect(watch, contains('singbox.platformServiceStatusSnapshot'));
      final androidBranch = watch.indexOf('final platformEvents = singbox');
      final routeReadyForNonAndroid = watch.indexOf('return Rx.combineLatest2<CoreStatus, bool, ConnectionStatus>(');
      final routeReadyBranch = watch.indexOf('if (!Platform.isAndroid) {');
      expect(androidBranch, isNonNegative);
      expect(routeReadyForNonAndroid, isNonNegative);
      expect(routeReadyBranch, isNonNegative);
      expect(routeReadyBranch, lessThan(routeReadyForNonAndroid));
      expect(routeReadyForNonAndroid, lessThan(androidBranch));
      expect(watch, contains('return Rx.combineLatest2<CoreStatus, CoreStatus, ConnectionStatus>('));
      expect(watch.substring(androidBranch), isNot(contains('_startupRouteReadyController.stream')));
    });

    test('seeded Started is emitted first and visible as Connected', () async {
      final platformEvents = StreamController<CoreStatus>();
      addTearDown(platformEvents.close);

      final mapped = androidPlatformStatusWithSnapshot(
        platformEvents.stream,
        const CoreStatus.started(),
      ).map(connectionStatusFromAndroidPlatform).take(3).toList();

      platformEvents
        ..add(const CoreStatus.starting())
        ..add(const CoreStatus.started());
      await platformEvents.close();

      final states = await mapped;
      expect(states.first, const Connected());
      expect(states, [const Connected(), const Connecting(), const Connected()]);
      expect(states.any((status) => status is Disconnected), isFalse);
    });

    test('null snapshot waits for a real event and does not emit synthetic Stopped', () async {
      final platformEvents = StreamController<CoreStatus>();
      addTearDown(platformEvents.close);

      final mapped = androidPlatformStatusWithSnapshot(
        platformEvents.stream,
        null,
      ).map(connectionStatusFromAndroidPlatform).take(2).toList();

      await Future<void>.delayed(Duration.zero);
      platformEvents.add(const CoreStatus.starting());
      platformEvents.add(const CoreStatus.started());
      await platformEvents.close();

      final states = await mapped;
      expect(states, [const Connecting(), const Connected()]);
      expect(states.any((status) => status is Disconnected), isFalse);
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

    test('legacy startupRouteReady primitive is false on Android while presentation stays platform-authoritative', () {
      expect(initialStartupRouteReady, isTrue);
      expect(initialStartupRouteReadyForPlatform(isAndroid: false), isTrue);
      expect(initialStartupRouteReadyForPlatform(isAndroid: true), isFalse);
      expect(connectionStatusFromAndroidPlatform(const CoreStatus.started()), const Connected());
    });

    test('Android cold attach with retained platform Started renders immediately connected', () async {
      final startupRouteReady = initialStartupRouteReadyForPlatform(isAndroid: true);

      expect(startupRouteReady, isFalse);
      expect(
        await androidPlatformStatusWithSnapshot(
          const Stream<CoreStatus>.empty(),
          const CoreStatus.started(),
        ).map(connectionStatusFromAndroidPlatform).first,
        const Connected(),
      );
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
      expect(
        startupRouteVerificationFor(startupEndpoint: probe),
        StartupRouteVerification.endpointFallback,
        reason: 'non-iOS callers retain the established TCP endpoint fallback',
      );
      expect(
        startupRouteVerificationFor(startupEndpoint: probe, requireHttpsProof: true),
        StartupRouteVerification.urlTest,
        reason: 'an open VLESS server port does not establish iOS HTTPS reachability',
      );
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

    test('TURNcoat Hysteria2 route with endpoint metadata remains on the URL test gate', () {
      const raw = '''
{
  "outbounds": [
    {"type": "selector", "tag": "select", "outbounds": ["Marten route"]},
    {"type": "hysteria2", "tag": "Marten route", "server": "hy.example", "server_port": 443, "detour": "turncoat-helper"},
    {"type": "turncoat", "tag": "turncoat-helper"}
  ]
}
''';

      final parsedRoute = parseLocalOutbounds(raw).singleWhere((outbound) => outbound.tag == 'Marten route');
      expect(parsedRoute.type, 'hysteria2');
      expect(parsedRoute.usesTurncoat, isTrue);
      final endpoint = selectedStartupEndpointProbe(raw, 'Marten route');
      expect(endpoint, isNull);
      expect(startupRouteVerificationFor(startupEndpoint: endpoint), StartupRouteVerification.urlTest);
      expect(
        startupRouteVerificationFor(startupEndpoint: endpoint, requireHttpsProof: true),
        StartupRouteVerification.urlTest,
        reason: 'Hysteria2 has no endpoint fallback, and iOS must retain the URL proof',
      );
    });

    test('VLESS with a TURNcoat dependency can still select endpoint startup verification', () {
      const raw = '''
{
  "outbounds": [
    {"type": "selector", "tag": "select", "outbounds": ["VLESS route"]},
    {"type": "vless", "tag": "VLESS route", "server": "vless.example", "server_port": 443, "detour": "turncoat-helper"},
    {"type": "turncoat", "tag": "turncoat-helper"}
  ]
}
''';

      final parsedRoute = parseLocalOutbounds(raw).singleWhere((outbound) => outbound.tag == 'VLESS route');
      expect(parsedRoute.type, 'vless');
      expect(parsedRoute.usesTurncoat, isTrue);
      final endpoint = selectedStartupEndpointProbe(raw, 'VLESS route');
      expect(endpoint, isNotNull);
      expect(endpoint!.server, 'vless.example');
      expect(endpoint.serverPort, 443);
      expect(
        startupRouteVerificationFor(startupEndpoint: endpoint),
        StartupRouteVerification.endpointFallback,
        reason: 'desktop behavior retains the TURNcoat VLESS TCP endpoint fallback',
      );
      expect(
        startupRouteVerificationFor(startupEndpoint: endpoint, requireHttpsProof: true),
        StartupRouteVerification.urlTest,
        reason: 'TURNcoat presence cannot make an iOS TCP endpoint ping prove HTTPS',
      );
    });

    test('iOS requests HTTPS startup verification at the connection call site', () {
      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
      final verificationCall = source.indexOf('startupRouteVerificationFor(');
      final verificationEnd = source.indexOf('\n              );', verificationCall);
      final call = verificationCall < 0 || verificationEnd < 0
          ? ''
          : source.substring(verificationCall, verificationEnd);

      expect(call, isNotEmpty);
      expect(call, contains('requireHttpsProof: Platform.isIOS'));
    });

    test('rejects failed selected route watchdog results', () {
      expect(selectedRouteHealthFailure('timeout', null), isNotNull);
      expect(selectedRouteHealthFailure(null, null), isNotNull);
      expect(selectedRouteHealthFailure(null, (tag: 'US 1', delay: 65535)), isNotNull);
    });

    test('does not retain selected-route identifiers or raw core errors in watchdog failures', () {
      const privateTag = 'Synthetic [Private] Route';
      const rawCoreError = 'synthetic private grpc diagnostic';
      final urlTestFailure = selectedRouteHealthFailure(rawCoreError, (tag: privateTag, delay: 65535));
      final delayFailure = selectedRouteHealthFailure(null, (tag: privateTag, delay: 65535));

      for (final failure in [urlTestFailure, delayFailure]) {
        final rendered = failure.toString();
        expect(rendered, isNot(contains(privateTag)));
        expect(rendered, isNot(contains(rawCoreError)));
        expect(rendered, contains('selected route watchdog'));
      }
      expect(delayFailure.toString(), contains('delay=65535'));
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

    test('returns the selected outbound value unchanged', () {
      expect(requirePreparedOutboundSelection<String>(right('prepared outbound')), 'prepared outbound');
    });

    test('turns selected outbound failures into a generic user-facing failure without route or core details', () {
      const selectedTag = 'private-selected-route';
      const coreError = 'grpc core rejected $selectedTag';

      expect(
        () => requirePreparedOutboundSelection<Unit>(left(coreError)),
        throwsA(
          isA<UnexpectedConnectionFailure>()
              .having((failure) => failure.error, 'message', 'selected route could not be applied')
              .having(
                (failure) => failure.error.toString(),
                'does not expose selected route',
                isNot(contains(selectedTag)),
              )
              .having(
                (failure) => failure.error.toString(),
                'does not expose raw core error',
                isNot(contains(coreError)),
              ),
        ),
      );
    });

    test('preserves the typed unavailable-background-core failure for selected outbound selection', () {
      expect(
        () => requirePreparedOutboundSelection<Unit>(left(localCoreControlChannelFailureMessage)),
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

    test('Android and iOS disconnect paths force platform cleanup when stopping core service', () {
      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
      final stopCurrentStart = source.indexOf('Future<Either<ConnectionFailure, Unit>> _stopConnectionNow() {');
      final stopCurrentEnd = source.indexOf('\n  void _resetStaleConnectionFeatures() {', stopCurrentStart);
      expect(stopCurrentStart, isNonNegative);
      expect(stopCurrentEnd, greaterThan(stopCurrentStart));
      final stopCurrent = source.substring(stopCurrentStart, stopCurrentEnd);
      final compactStopCurrent = stopCurrent.replaceAll(RegExp(r'\s+'), '');

      expect(
        compactStopCurrent,
        contains('returnsingbox.stop(forcePlatformCleanup:PlatformUtils.isAndroid||PlatformUtils.isIOS)'),
        reason: 'Android rejected starts and iOS pending VPN consent both require authoritative platform cleanup',
      );
      expect(compactStopCurrent, isNot(contains('returnsingbox.stop().')));
    });
  });

  test('failed start cleanup rechecks generation before surfacing either cleanup or startup failure', () {
    final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
    final preparedStart = source.indexOf('TaskEither<ConnectionFailure, Unit> _withPreparedConfig(');
    final preparedEnd = source.indexOf('\n  TaskEither<ConnectionFailure, Unit> _unlessConnectionStale', preparedStart);
    final prepared = source.substring(preparedStart, preparedEnd);
    final cleanup = prepared.indexOf('final cleanupFailure = await _stopFailedStartupRoute(startupRoute);');
    final staleAfterCleanup = prepared.indexOf('if (_isConnectionStale(generation)) {', cleanup);
    final resetStale = prepared.indexOf('_resetStaleConnectionFeatures();', staleAfterCleanup);
    final returnQuietly = prepared.indexOf('return unit;', resetStale);
    final cleanupError = prepared.indexOf('if (cleanupFailure != null) throw cleanupFailure;', returnQuietly);
    final originalError = prepared.indexOf('Error.throwWithStackTrace(error, stackTrace);', cleanupError);

    expect(cleanup, isNonNegative);
    expect(staleAfterCleanup, greaterThan(cleanup));
    expect(resetStale, greaterThan(staleAfterCleanup));
    expect(returnQuietly, greaterThan(resetStale));
    expect(cleanupError, greaterThan(returnQuietly));
    expect(originalError, greaterThan(cleanupError));
  });

  test('failed startup stop returns a typed failure instead of throwing before stale ownership can be checked', () {
    final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
    final start = source.indexOf('Future<ConnectionFailure?> _stopFailedStartupRoute(');
    final end = source.indexOf('\n  void _setStartupRouteReady', start);
    final cleanup = source.substring(start, end);

    expect(cleanup, contains('final result = await singbox.stop().run();'));
    expect(cleanup, contains('return result.match<ConnectionFailure?>('));
    expect(cleanup, contains("ConnectionFailure.unexpected('failed to stop/close startup route"));
    expect(cleanup, isNot(contains('throw ')));
  });

  test(
    'prepared Android start carries its exact epoch and suppresses failure only for affirmative native Stop ownership',
    () {
      final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
      final connectStart = source.indexOf('TaskEither<ConnectionFailure, Unit> connect(');
      final connectEnd = source.indexOf(
        '\n  TaskEither<ConnectionFailure, Unit> _serializedConnectionTask',
        connectStart,
      );
      final connect = source.substring(connectStart, connectEnd);
      final preparedStart = source.indexOf('TaskEither<ConnectionFailure, Unit> _withPreparedConfig(');
      final preparedEnd = source.indexOf(
        '\n  TaskEither<ConnectionFailure, Unit> _unlessConnectionStale',
        preparedStart,
      );
      final prepared = source.substring(preparedStart, preparedEnd);
      final markerHelperStart = source.indexOf('Future<bool> _wasExplicitlyStoppedByAndroid(');
      final markerHelperEnd = source.indexOf('\n  Future<void> _stopStaleConnectionOperation', markerHelperStart);
      final markerHelper = source.substring(markerHelperStart, markerHelperEnd);

      expect(connect, contains('androidVpnStartEpoch: androidVpnStartEpoch'));
      expect(
        connect,
        contains('singbox.start(path, displayName, disableMemoryLimit, androidVpnStartEpoch: androidVpnStartEpoch)'),
      );
      expect(markerHelper, contains('wasVpnUserSessionExplicitlyStopped(androidVpnStartEpoch)'));
      expect(markerHelper, contains('return explicitlyStopped == true;'));
      expect(markerHelper, isNot(contains('?? true')));

      final markerBeforeCleanup = prepared.indexOf('if (await _wasExplicitlyStoppedByAndroid(androidVpnStartEpoch)) {');
      final cleanup = prepared.indexOf(
        'final cleanupFailure = await _stopFailedStartupRoute(startupRoute);',
        markerBeforeCleanup,
      );
      final markerAfterCleanup = prepared.indexOf(
        'if (await _wasExplicitlyStoppedByAndroid(androidVpnStartEpoch)) {',
        cleanup,
      );
      final cleanupFailure = prepared.indexOf('if (cleanupFailure != null) throw cleanupFailure;', markerAfterCleanup);
      final originalFailure = prepared.indexOf('Error.throwWithStackTrace(error, stackTrace);', cleanupFailure);

      expect(markerBeforeCleanup, isNonNegative);
      expect(cleanup, greaterThan(markerBeforeCleanup));
      expect(markerAfterCleanup, greaterThan(cleanup));
      expect(cleanupFailure, greaterThan(markerAfterCleanup));
      expect(originalFailure, greaterThan(cleanupFailure));
      expect(prepared.substring(markerBeforeCleanup, cleanup), contains('_resetSupersededConnectionFeatures();'));
      expect(prepared.substring(markerAfterCleanup, cleanupFailure), contains('_resetSupersededConnectionFeatures();'));
    },
  );

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

  test('profile reconnect uses a single prepared-config restart on every platform', () {
    final source = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
    final reconnectStart = source.indexOf('@override\n  TaskEither<ConnectionFailure, Unit> reconnect(');
    final reconnectEnd = source.indexOf(
      '\n  @override\n  TaskEither<ConnectionFailure, Unit> syncNativeResumeConfig',
      reconnectStart,
    );
    final preparedStart = source.indexOf('TaskEither<ConnectionFailure, Unit> _withPreparedConfig(');
    final preparedEnd = source.indexOf('\n  TaskEither<ConnectionFailure, Unit> _unlessConnectionStale', preparedStart);
    expect(reconnectStart, isNonNegative);
    expect(reconnectEnd, greaterThan(reconnectStart));
    expect(preparedStart, isNonNegative);
    expect(preparedEnd, greaterThan(preparedStart));
    final reconnect = source.substring(reconnectStart, reconnectEnd);
    final prepared = source.substring(preparedStart, preparedEnd);

    final applyOptions = reconnect.indexOf('applyConfigOption(activeProfile)');
    final withPrepared = reconnect.indexOf('_withPreparedConfig(', applyOptions);
    final restart = reconnect.indexOf('singbox.restart(path, displayName, disableMemoryLimit)', withPrepared);
    expect(applyOptions, isNonNegative);
    expect(withPrepared, greaterThan(applyOptions));
    expect(restart, greaterThan(withPrepared));
    expect(
      reconnect,
      isNot(contains('Platform.isAndroid')),
      reason: 'Android and non-Android profile reloads must share the same atomic restart path',
    );
    expect(
      reconnect,
      isNot(contains('singbox.stop(')),
      reason: 'profile reload must not retire the Android service-owned full-route TUN',
    );
    expect(reconnect, isNot(contains('singbox.start(')));
    expect(reconnect, isNot(contains('reconnectCoreForPlatform')));

    final lifecycleMark = prepared.indexOf('singbox.beginManualBackgroundLifecycle();');
    final clearRouteProof = prepared.indexOf('_setStartupRouteReady(false);', lifecycleMark);
    final verifiedStart = prepared.indexOf('await singbox.notifyBackgroundStarted();', clearRouteProof);
    final publishRouteProof = prepared.indexOf('_setStartupRouteReady(true);', verifiedStart);
    expect(
      lifecycleMark,
      isNonNegative,
      reason: 'restart must retain the fresh manual lifecycle admission in _withPreparedConfig',
    );
    expect(clearRouteProof, greaterThan(lifecycleMark));
    expect(verifiedStart, greaterThan(clearRouteProof));
    expect(
      publishRouteProof,
      greaterThan(verifiedStart),
      reason: 'the new route may be published only after native markStarted/route proof succeeds',
    );
  });
}
