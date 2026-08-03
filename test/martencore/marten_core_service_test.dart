import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/martencore/marten_core_service.dart';
import 'package:marten/singbox/model/core_status.dart';

String _extractFunctionBlock(String source, String signature) {
  final marker = source.indexOf(signature);
  if (marker < 0) return '';

  final open = source.indexOf('{', marker);
  if (open < 0) return '';

  var depth = 0;
  for (var index = open; index < source.length; index++) {
    final char = source[index];
    if (char == '{') depth++;
    if (char == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(open + 1, index);
      }
    }
  }

  return '';
}

void main() {
  group('platform bootstrap helpers', () {
    test('startup markers and deferred work keep the first interaction path lean', () {
      final bootstrap = File('lib/bootstrap.dart').readAsStringSync();
      final bootstrapStart = bootstrap.indexOf('Future<void> lazyBootstrap');
      final warmUpStart = bootstrap.indexOf('Future<void> _warmUpAfterFirstFrame', bootstrapStart);
      final profileDeferredStart = bootstrap.indexOf('Future<void> _warmUpDeferredProfileServices', warmUpStart);
      final platformDeferredStart = bootstrap.indexOf(
        'Future<void> _warmUpDeferredPlatformServices',
        profileDeferredStart,
      );
      expect(bootstrapStart, isNonNegative);
      expect(warmUpStart, isNonNegative);
      expect(profileDeferredStart, isNonNegative);
      expect(platformDeferredStart, isNonNegative);

      final launch = bootstrap.substring(bootstrapStart, warmUpStart);
      final deferredProfile = bootstrap.substring(profileDeferredStart, platformDeferredStart);
      expect(launch, contains('startup phase=bootstrap_prerequisites_ready'));
      expect(launch, contains('startup phase=first_post_frame'));
      expect(launch, contains('startup phase=first_frame_timing'));
      expect(launch.indexOf('bootstrap_prerequisites_ready'), lessThan(launch.indexOf('runApp(')));
      expect(launch.indexOf('first_post_frame'), greaterThan(launch.indexOf('runApp(')));

      expect(deferredProfile, contains('Duration(seconds: 30)'));
      expect(deferredProfile, contains('subscriptionPushRefreshServiceProvider'));
      expect(deferredProfile, isNot(contains('profileRepositoryProvider')));
    });

    test('foreground profile scheduler waits for startup delay while manual triggers stay available', () {
      final source = File('lib/features/profile/notifier/profiles_update_notifier.dart').readAsStringSync();
      final buildStart = source.indexOf('Stream<ProfileUpdateStatus?> build()');
      final fieldsStart = source.indexOf('\n  NeatPeriodicTaskScheduler?', buildStart);
      expect(buildStart, isNonNegative);
      expect(fieldsStart, isNonNegative);
      final build = source.substring(buildStart, fieldsStart);

      expect(source, contains('initialStartupDelay = Duration(seconds: 45)'));
      expect(build, contains('Timer(initialStartupDelay'));
      expect(build, contains('_initialStartTimer?.cancel()'));
      expect(build, isNot(contains('checkDueNow(')));
      expect(build.indexOf('Timer(initialStartupDelay'), lessThan(build.indexOf('scheduler.start()')));

      final triggerStart = source.indexOf('Future<void> trigger()');
      final dueStart = source.indexOf('Future<void> checkDueNow()');
      expect(triggerStart, isNonNegative);
      expect(dueStart, isNonNegative);
      expect(source.substring(triggerStart, dueStart), contains('_scheduler!.trigger()'));
      expect(source.substring(dueStart), contains('_scheduler!.trigger()'));
    });

    test('per-app package enumeration is delayed and fails closed after dispose', () {
      final source = File('lib/features/per_app_proxy/overview/per_app_proxy_service_notifier.dart').readAsStringSync();
      final buildStart = source.indexOf('Future<void> build() async');
      final updateStart = source.indexOf('\n  Future<void> _autoSelectionUpdate()', buildStart);
      expect(buildStart, isNonNegative);
      expect(updateStart, isNonNegative);
      final build = source.substring(buildStart, updateStart);
      final delay = build.indexOf('delayed(initialStartupDelay)');
      final platformCall = build.indexOf('InstalledApps.getInstalledApps');
      final disposedAfterDelay = build.indexOf('if (disposed) return;', delay);

      expect(source, contains('initialStartupDelay = Duration(seconds: 60)'));
      expect(delay, isNonNegative);
      expect(platformCall, greaterThan(delay));
      expect(disposedAfterDelay, greaterThan(delay));
      expect(disposedAfterDelay, lessThan(platformCall));
      expect(build, contains('_timer?.cancel()'));
    });

    test('post-frame startup defers profile, refresh, and Android display work', () {
      final source = File('lib/bootstrap.dart').readAsStringSync();
      final warmUpStart = source.indexOf('Future<void> _warmUpAfterFirstFrame');
      final profileDeferredStart = source.indexOf('Future<void> _warmUpDeferredProfileServices', warmUpStart);
      final platformDeferredStart = source.indexOf(
        'Future<void> _warmUpDeferredPlatformServices',
        profileDeferredStart,
      );
      final initStart = source.indexOf('Future<T> _init', platformDeferredStart);
      expect(warmUpStart, isNonNegative);
      expect(profileDeferredStart, isNonNegative);
      expect(platformDeferredStart, isNonNegative);
      expect(initStart, isNonNegative);

      final warmUp = source.substring(warmUpStart, profileDeferredStart);
      final deferredProfile = source.substring(profileDeferredStart, platformDeferredStart);
      final deferredPlatform = source.substring(platformDeferredStart, initStart);

      expect(warmUp, isNot(contains('activeProfileProvider')));
      expect(warmUp, isNot(contains('initializeProfilesBackgroundRefresh')));
      expect(warmUp, isNot(contains('FlutterDisplayMode.setHighRefreshRate')));
      expect(warmUp, contains('unawaited(_warmUpDeferredProfileServices'));
      expect(warmUp, contains('unawaited(_warmUpDeferredPlatformServices'));

      expect(deferredProfile, isNot(contains('profileRepositoryProvider')));
      expect(deferredProfile, contains('subscriptionPushRefreshServiceProvider'));
      expect(deferredPlatform, contains('initializeProfilesBackgroundRefresh'));
      expect(deferredPlatform, contains('FlutterDisplayMode.setHighRefreshRate'));
      expect(deferredPlatform, contains('PlatformUtils.isAndroid'));
    });

    test('Android warm-up defers full core setup to the authoritative platform-status path', () {
      final bootstrap = File('lib/bootstrap.dart').readAsStringSync();
      final warmUpStart = bootstrap.indexOf('Future<void> _warmUpAfterFirstFrame');
      final warmUpEnd = bootstrap.indexOf('Future<void> _warmUpDeferredProfileServices', warmUpStart);
      expect(warmUpStart, isNonNegative);
      expect(warmUpEnd, isNonNegative);
      final warmUp = bootstrap.substring(warmUpStart, warmUpEnd);

      expect(
        warmUp,
        contains(
          'final martenCoreWarmUp = PlatformUtils.isAndroid\n'
          '      ? Future<void>.value()\n'
          '      : _safeInit("marten-core", () => container.read(martenCoreServiceProvider).init());',
        ),
      );

      final notifier = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
      final buildStart = notifier.indexOf('Stream<ConnectionStatus> build() async*');
      final buildEnd = notifier.indexOf('\n  ConnectionRepository get _connectionRepo', buildStart);
      expect(buildStart, isNonNegative);
      expect(buildEnd, isNonNegative);
      final build = notifier.substring(buildStart, buildEnd);
      expect(build, contains('Platform.isAndroid && await _connectionRepo.initializeStoppedPlatformStatus()'));
      expect(build, contains('if (!platformStopped)'));
    });

    test('uses lightweight bootstrap only for an Android stopped platform service', () {
      final cases = [
        (isAndroid: true, platformStatus: const CoreStatus.stopped(), expected: true),
        (isAndroid: false, platformStatus: const CoreStatus.stopped(), expected: false),
        (isAndroid: true, platformStatus: null, expected: false),
        (isAndroid: true, platformStatus: const CoreStatus.starting(), expected: false),
        (isAndroid: true, platformStatus: const CoreStatus.started(), expected: false),
      ];

      for (final testCase in cases) {
        expect(
          shouldUseLightweightPlatformBootstrap(isAndroid: testCase.isAndroid, platformStatus: testCase.platformStatus),
          testCase.expected,
        );
      }
    });

    test('initializes an uninitialized core only when the platform starts', () {
      final cases = [
        (platformStatus: const CoreStatus.starting(), coreInitialized: false, expected: true),
        (platformStatus: const CoreStatus.starting(), coreInitialized: true, expected: false),
        (platformStatus: const CoreStatus.stopped(), coreInitialized: false, expected: false),
        (platformStatus: const CoreStatus.started(), coreInitialized: false, expected: false),
      ];

      for (final testCase in cases) {
        expect(
          shouldInitializeCoreForPlatformEvent(testCase.platformStatus, coreInitialized: testCase.coreInitialized),
          testCase.expected,
        );
      }
    });
  });

  group('platform service status merge', () {
    test('tracks a native recovery only when a running core enters platform starting', () {
      expect(startsNativePlatformRecovery(const CoreStatus.started(), const CoreStatus.starting()), isTrue);
      expect(startsNativePlatformRecovery(const CoreStatus.stopped(), const CoreStatus.starting()), isFalse);
      expect(startsNativePlatformRecovery(const CoreStatus.starting(), const CoreStatus.starting()), isFalse);
    });

    test('keeps native recovery runtime stop events visible as connecting', () {
      expect(
        coreStatusAfterRuntimeEvent(const CoreStatus.started(), nativeRecoveryInProgress: true),
        const CoreStatus.starting(),
        reason: 'a runtime Started event is not Android route verification',
      );
      expect(
        coreStatusAfterRuntimeEvent(const CoreStatus.stopping(), nativeRecoveryInProgress: true),
        const CoreStatus.starting(),
      );
      expect(
        coreStatusAfterRuntimeEvent(const CoreStatus.stopped(), nativeRecoveryInProgress: true),
        const CoreStatus.starting(),
      );
      expect(
        coreStatusAfterRuntimeEvent(
          const CoreStatus.stopped(alert: CoreAlert.startService),
          nativeRecoveryInProgress: true,
        ),
        const CoreStatus.stopped(alert: CoreAlert.startService),
      );
    });

    test('promotes native recovery only after Android route-verified started', () {
      expect(
        coreStatusAfterPlatformEvent(
          const CoreStatus.starting(),
          const CoreStatus.started(),
          nativeRecoveryInProgress: true,
        ),
        const CoreStatus.started(),
      );
      expect(
        coreStatusAfterPlatformEvent(
          const CoreStatus.starting(),
          const CoreStatus.stopped(),
          nativeRecoveryInProgress: true,
        ),
        const CoreStatus.starting(),
      );
    });

    test('promotes retained Android route-verified started over stale local startup snapshots', () {
      expect(
        coreStatusAfterPlatformEvent(const CoreStatus.starting(), const CoreStatus.started()),
        const CoreStatus.started(),
      );
      expect(
        coreStatusAfterPlatformEvent(const CoreStatus.stopped(), const CoreStatus.started()),
        const CoreStatus.started(),
      );
      expect(
        coreStatusAfterPlatformEvent(const CoreStatus.stopping(), const CoreStatus.started()),
        const CoreStatus.stopping(),
        reason: 'a delayed retained callback must not cancel a manual stop',
      );
    });

    test('allows platform stop statuses to clear stale core state', () {
      expect(
        coreStatusAfterPlatformEvent(const CoreStatus.started(), const CoreStatus.stopping()),
        const CoreStatus.stopping(),
      );
      expect(
        coreStatusAfterPlatformEvent(const CoreStatus.stopping(), const CoreStatus.stopped()),
        const CoreStatus.stopped(),
      );
    });

    test('does not let a stale shell stopped status cancel an in-flight start', () {
      expect(
        coreStatusAfterPlatformEvent(const CoreStatus.starting(), const CoreStatus.stopped()),
        const CoreStatus.starting(),
      );
    });

    test('does not let a stale shell stopped status hide a running core', () {
      expect(
        coreStatusAfterPlatformEvent(const CoreStatus.started(), const CoreStatus.stopped()),
        const CoreStatus.started(),
      );
    });

    test('keeps alert-bearing stopped status during an in-flight start', () {
      expect(
        coreStatusAfterPlatformEvent(
          const CoreStatus.starting(),
          const CoreStatus.stopped(alert: CoreAlert.startService, message: 'failed'),
        ),
        const CoreStatus.stopped(alert: CoreAlert.startService, message: 'failed'),
      );
    });

    test('vpn revoke stop overrides a stale started core state', () {
      expect(
        coreStatusAfterPlatformEvent(const CoreStatus.started(), const CoreStatus.stopped(alert: CoreAlert.vpnRevoked)),
        const CoreStatus.stopped(alert: CoreAlert.vpnRevoked),
      );
    });

    test('skips duplicate stop only after both runtime and Android service stopped', () {
      expect(isRedundantCoreStop(const CoreStatus.stopped(), const CoreStatus.stopped()), isTrue);
      expect(isRedundantCoreStop(const CoreStatus.stopped(), const CoreStatus.stopping()), isFalse);
      expect(isRedundantCoreStop(const CoreStatus.stopping(), const CoreStatus.stopped()), isFalse);
      expect(isRedundantCoreStop(const CoreStatus.stopped(), null), isFalse);
    });

    test('Android leaves shutdown to the authoritative platform stop while other platforms pre-stop over gRPC', () {
      expect(shouldAttemptGracefulGrpcStop(isAndroid: true), isFalse);
      expect(shouldAttemptGracefulGrpcStop(isAndroid: false), isTrue);
    });
  });

  group('restart settlement', () {
    test('restart settles restart transport shutdown by waiting for runtime start before success', () {
      final source = File('lib/martencore/marten_core_service.dart').readAsStringSync();
      final restartBlock = _extractFunctionBlock(source, 'TaskEither<String, Unit> restart(');
      expect(restartBlock, isNotEmpty);

      final shutdownPath = restartBlock.indexOf('_isExpectedRestartTransportShutdown(e)');
      final waitForRestarted = restartBlock.indexOf('await _waitForRestartedBackgroundCore()');
      final successRestartSignal = restartBlock.indexOf('coreRestartSignalProvider.notifier).restart();');
      final transportFailureState = restartBlock.indexOf('background core did not settle after restart');
      final startFailureState = restartBlock.indexOf('background core did not start after restart');
      final timeoutWait = restartBlock.indexOf('connection timed out while restarting core');

      expect(shutdownPath, isNonNegative);
      expect(waitForRestarted, isNonNegative);
      expect(shutdownPath, lessThan(waitForRestarted));
      expect(successRestartSignal, isNonNegative);
      expect(transportFailureState, isNonNegative);
      expect(startFailureState, isNonNegative);
      expect(timeoutWait, isNonNegative);
      expect(successRestartSignal, greaterThan(waitForRestarted));
    });

    test('restart settles by waiting for runtime-started background state', () {
      final source = File('lib/martencore/marten_core_service.dart').readAsStringSync();
      final settleBlock = _extractFunctionBlock(source, 'Future<bool> _waitForRestartedBackgroundCore()');
      expect(settleBlock, isNotEmpty);

      expect(settleBlock, contains('waitForRestartedCoreRuntime('));
      expect(
        settleBlock,
        contains('readStatus: () => _refreshBackgroundCoreStatusSnapshot(reason: "restart settle", emit: true)'),
      );
      expect(settleBlock, contains('_restartSettleTimeout'));
      expect(settleBlock, contains('_restartSettlePollInterval'));
    });

    test('failed restart settlement is done only via _settleFailedRestart', () {
      final source = File('lib/martencore/marten_core_service.dart').readAsStringSync();
      final settleBlock = _extractFunctionBlock(source, 'Future<Either<String, Unit>> _settleFailedRestart(');
      expect(settleBlock, isNotEmpty);

      final stop = settleBlock.indexOf('await stop().run()');
      final stopped = settleBlock.indexOf('currentState = CoreStatus.stopped');
      final published = settleBlock.indexOf('statusController.add(currentState);');
      final failureReturn = settleBlock.indexOf('return left(message);');

      expect(stop, isNonNegative);
      expect(stopped, isNonNegative);
      expect(published, isNonNegative);
      expect(failureReturn, isNonNegative);
      expect(stop, lessThan(stopped));
      expect(stopped, lessThan(published));
      expect(published, lessThan(failureReturn));
    });

    test('restart terminal failures all delegate to _settleFailedRestart', () {
      final source = File('lib/martencore/marten_core_service.dart').readAsStringSync();
      final restartBlock = _extractFunctionBlock(source, 'TaskEither<String, Unit> restart(');
      expect(restartBlock, isNotEmpty);

      expect(restartBlock, contains(r'return _settleFailedRestart("${res.messageType} ${res.message}");'));
      expect(restartBlock, contains('_isExpectedRestartTransportShutdown(e)'));
      expect(restartBlock, contains('return _settleFailedRestart("background core did not settle after restart");'));
      expect(restartBlock, contains('return _settleFailedRestart("connection timed out while restarting core");'));
      expect(restartBlock, contains('return _settleFailedRestart(message);'));
      expect(restartBlock, contains('return _settleFailedRestart("failed to restart background core");'));
      expect(restartBlock, contains('return _settleFailedRestart("background core did not start after restart");'));
      expect(restartBlock, isNot(contains('return left("background core did not settle after restart");')));
      expect(restartBlock, isNot(contains('return left("connection timed out while restarting core");')));
      expect(restartBlock, isNot(contains('return left("failed to restart background core");')));
      expect(restartBlock, isNot(contains('return left("background core did not start after restart");')));
    });

    test('restart can still recover from non-terminal restart transport error when runtime becomes started', () {
      final source = File('lib/martencore/marten_core_service.dart').readAsStringSync();
      final restartBlock = _extractFunctionBlock(source, 'TaskEither<String, Unit> restart(');
      expect(restartBlock, isNotEmpty);
      expect(restartBlock, contains('ref.read(coreRestartSignalProvider.notifier).restart();'));

      final branchStart = restartBlock.indexOf('if (_isExpectedRestartTransportShutdown(e))');
      final branchSuccess = restartBlock.indexOf('return right(unit);', branchStart);
      final branchFailure = restartBlock.indexOf(
        'return _settleFailedRestart("background core did not settle after restart");',
        branchStart,
      );

      expect(branchStart, isNonNegative);
      expect(branchSuccess, isNonNegative);
      expect(branchFailure, isNonNegative);
      expect(branchSuccess, lessThan(branchFailure));
    });

    test('waits for the runtime instead of accepting an available gRPC shell', () async {
      final statuses = <CoreStatus?>[
        const CoreStatus.starting(),
        const CoreStatus.stopped(),
        const CoreStatus.starting(),
        const CoreStatus.started(),
      ];
      var reads = 0;

      final ready = await waitForRestartedCoreRuntime(
        readStatus: () async => statuses[reads++],
        timeout: const Duration(seconds: 1),
        pollInterval: Duration.zero,
      );

      expect(ready, isTrue);
      expect(reads, statuses.length);
    });

    test('stops waiting after an authoritative runtime failure', () async {
      var reads = 0;

      final ready = await waitForRestartedCoreRuntime(
        readStatus: () async {
          reads++;
          return const CoreStatus.stopped(alert: CoreAlert.startFailed, message: 'tun failed');
        },
        timeout: const Duration(seconds: 1),
        pollInterval: Duration.zero,
      );

      expect(ready, isFalse);
      expect(reads, 1);
    });
  });

  group('stale background status work', () {
    test('background inactivity result cannot overwrite a newer started status', () {
      expect(
        shouldApplyBackgroundInactiveResult(
          requestRevision: 4,
          currentRevision: 5,
          nativeRecoveryInProgress: false,
          backgroundActive: false,
        ),
        isFalse,
      );
      expect(
        shouldApplyBackgroundInactiveResult(
          requestRevision: 5,
          currentRevision: 5,
          nativeRecoveryInProgress: true,
          backgroundActive: false,
        ),
        isFalse,
      );
      expect(
        shouldApplyBackgroundInactiveResult(
          requestRevision: 5,
          currentRevision: 5,
          nativeRecoveryInProgress: false,
          backgroundActive: true,
        ),
        isFalse,
      );
    });

    test('native recovery reattach snapshot applies only to its live started session', () {
      expect(
        shouldApplyNativeRecoverySnapshot(
          requestRevision: 4,
          currentRevision: 5,
          currentStatus: const CoreStatus.started(),
        ),
        isFalse,
      );
      expect(
        shouldApplyNativeRecoverySnapshot(
          requestRevision: 5,
          currentRevision: 5,
          currentStatus: const CoreStatus.stopping(),
        ),
        isFalse,
      );
      expect(
        shouldApplyNativeRecoverySnapshot(
          requestRevision: 5,
          currentRevision: 5,
          currentStatus: const CoreStatus.started(),
        ),
        isTrue,
      );
    });
  });
}
