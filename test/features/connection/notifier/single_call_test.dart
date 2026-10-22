import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/connection/model/connection_failure.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';

String _extractFunctionBlock(String source, String signature) {
  final marker = source.indexOf(signature);
  if (marker < 0) return '';

  int? open;
  final lineEnd = source.indexOf('\n', marker);
  final signatureTail = lineEnd < 0 ? source.substring(marker) : source.substring(marker, lineEnd);
  final asyncSignature = RegExp(r'\)\s*async\*?\s*\{').firstMatch(signatureTail);
  if (asyncSignature != null) {
    open = marker + asyncSignature.start + asyncSignature.group(0)!.lastIndexOf('{');
  }

  var parenDepth = 0;
  if (open == null) {
    for (var index = marker; index < source.length; index++) {
      final char = source[index];
      if (char == '(') parenDepth++;
      if (char == ')') parenDepth--;
      if (char == '{' && parenDepth == 0) {
        open = index;
        break;
      }
      if (parenDepth < 0) parenDepth = 0;
    }
  }

  open ??= source.indexOf('{', marker);
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

int _countOccurrences(String source, String needle) {
  var count = 0;
  var start = 0;
  while (true) {
    final index = source.indexOf(needle, start);
    if (index < 0) return count;
    count++;
    start = index + needle.length;
  }
}

void main() {
  test('native satisfied-connect wire result distinguishes authoritative outcomes and legacy booleans', () {
    expect(nativeSatisfiedConnectResolutionFromPlatform('satisfied'), NativeSatisfiedConnectResolution.satisfied);
    expect(
      nativeSatisfiedConnectResolutionFromPlatform('connect_required'),
      NativeSatisfiedConnectResolution.connectRequired,
    );
    expect(nativeSatisfiedConnectResolutionFromPlatform('cancelled'), NativeSatisfiedConnectResolution.cancelled);
    expect(nativeSatisfiedConnectResolutionFromPlatform(true), NativeSatisfiedConnectResolution.satisfied);
    expect(nativeSatisfiedConnectResolutionFromPlatform(false), NativeSatisfiedConnectResolution.cancelled);
    expect(nativeSatisfiedConnectResolutionFromPlatform(null), NativeSatisfiedConnectResolution.transportFailure);
    expect(
      nativeSatisfiedConnectResolutionFromPlatform('unexpected'),
      NativeSatisfiedConnectResolution.transportFailure,
    );
    expect(nativeSatisfiedConnectResolutionFromPlatform(17), NativeSatisfiedConnectResolution.transportFailure);
  });

  test('post-release input settle keeps Connect semantically unavailable for 750ms', () {
    expect(manualDisconnectInputSettleDelay, const Duration(milliseconds: 750));

    final settlingStatus = visibleStatusDuringManualButtonDisconnect(const Disconnected(), disconnectInProgress: true);
    expect(settlingStatus, const Disconnecting());
    final capturedDuringSettle = manualConnectionCommandForStatus(settlingStatus);
    expect(capturedDuringSettle, ManualConnectionCommand.disconnect);
    expect(canExecuteManualConnectionCommand(capturedDuringSettle, settlingStatus), isFalse);

    final releasedStatus = visibleStatusDuringManualButtonDisconnect(const Disconnected(), disconnectInProgress: false);
    expect(releasedStatus, const Disconnected());
    expect(canExecuteManualConnectionCommand(manualConnectionCommandForStatus(releasedStatus), releasedStatus), isTrue);
  });

  test('stop while connecting is presented as abort and routes through abort cleanup', () {
    expect(manualConnectionCommandForStatus(const Connecting()), ManualConnectionCommand.abort);
    expect(canExecuteManualConnectionCommand(ManualConnectionCommand.disconnect, const Connecting()), isTrue);
    expect(canExecuteManualConnectionCommand(ManualConnectionCommand.abort, const Connecting()), isTrue);

    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final stopFromManual = _extractFunctionBlock(
      source,
      'Future<void> _stopFromManualCommand(ConnectionStatus? currentStatus) async {',
    );
    expect(stopFromManual, isNotEmpty);
    expect(stopFromManual, contains('case Connecting():'));
    expect(stopFromManual, contains('_abortConnectionImmediately();'));
  });

  test('Android cold-attach avoids startup verification from raw build stream', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final build = _extractFunctionBlock(source, 'Stream<ConnectionStatus> build() async* {');
    final listenSelf = _extractFunctionBlock(source, 'listenSelf((previous, next) async {');
    final startupVerification = _extractFunctionBlock(
      source,
      'void _handleStartupRouteVerification(ConnectionStatus? nextStatus) {',
    );

    expect(build, isNotEmpty);
    expect(listenSelf, isNotEmpty);
    expect(startupVerification, isNotEmpty);

    final statusStream = build.indexOf('yield* _connectionRepo');
    final doOnData = build.indexOf('.doOnData((event) {', statusStream);
    final deduplication = build.indexOf('.distinct()', doOnData);

    expect(statusStream, isNonNegative);
    expect(doOnData, greaterThan(statusStream));
    expect(deduplication, greaterThan(doOnData));
    expect(
      build.substring(doOnData, deduplication),
      isNot(contains('_handleStartupRouteVerification')),
      reason: 'startup verification must stay on notifier-state transitions, not raw build events',
    );

    expect(startupVerification, contains('if (nextStatus is! Connecting) {'));
    expect(listenSelf, contains('_handleStartupRouteVerification(nextStatus);'));

    final routeVerificationInListenSelf = listenSelf.indexOf('_handleStartupRouteVerification(nextStatus);');
    expect(routeVerificationInListenSelf, isNonNegative);
    expect(deduplication, greaterThan(doOnData), reason: 'stream remains distinct() after doOnData');
  });

  test(
    'normal disconnect and abort publish terminal Disconnected after authoritative stop despite delayed stream status',
    () {
      final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
      final normalDisconnect = _extractFunctionBlock(source, 'Future<void> _disconnectFromManualCommand() async {');
      final abortCleanup = _extractFunctionBlock(source, 'Future<void> _disconnectAfterAbort(int token) async {');
      final visibleStream = _extractFunctionBlock(
        source,
        'ConnectionStatus _visibleConnectionStatus(ConnectionStatus event) {',
      );

      expect(normalDisconnect, isNotEmpty);
      expect(abortCleanup, isNotEmpty);
      expect(visibleStream, isNotEmpty);

      final settleInput = _extractFunctionBlock(source, 'Future<void> _settleManualDisconnectInput() async {');
      final normalSettle = normalDisconnect.indexOf('await _settleManualDisconnectInput();');
      final normalReleased = normalDisconnect.indexOf('manual disconnect fully released; reconnect is available');
      final terminalDisconnected = settleInput.indexOf('state = const AsyncData(Disconnected());');
      expect(settleInput, isNotEmpty);
      expect(terminalDisconnected, isNonNegative);
      expect(normalSettle, isNonNegative);
      expect(normalReleased, greaterThan(normalSettle));

      final abortLeaseRelease = abortCleanup.indexOf('_manualButtonDisconnectInProgress = false;');
      final abortSettle = abortCleanup.indexOf('await _settleManualDisconnectInput();');
      final abortReleased = abortCleanup.indexOf('aborted connection cleanup fully released; reconnect is available');
      expect(abortLeaseRelease, isNonNegative);
      expect(abortSettle, greaterThan(abortLeaseRelease));
      expect(abortReleased, greaterThan(abortSettle));

      expect(
        visibleStream,
        contains('disconnectInProgress: _manualButtonDisconnectInProgress || _manualDisconnectInputSettling'),
      );
    },
  );

  test('a captured disconnect intent cannot become a connect after terminal stop', () {
    final capturedCommand = manualConnectionCommandForStatus(const Connected());

    expect(capturedCommand, ManualConnectionCommand.disconnect);
    expect(canExecuteManualConnectionCommand(capturedCommand, const Connected()), isTrue);
    expect(
      canExecuteManualConnectionCommand(capturedCommand, const Disconnected()),
      isFalse,
      reason: 'a late disconnect tap must be ignored after STOPPED, never reinterpreted as Connect',
    );
    expect(
      manualConnectionCommandForStatus(const Disconnected()),
      ManualConnectionCommand.connect,
      reason: 'only a fresh tap rendered while idle may request a new connection',
    );
  });

  test(
    'manual connection command mapping preserves the rendered intent and every active-state tap is a stop intent',
    () {
      expect(manualConnectionCommandForStatus(const Disconnected()), ManualConnectionCommand.connect);
      expect(manualConnectionCommandForStatus(const Connected()), ManualConnectionCommand.disconnect);
      expect(manualConnectionCommandForStatus(const Connecting()), ManualConnectionCommand.abort);
      expect(manualConnectionCommandForStatus(const Disconnecting()), ManualConnectionCommand.disconnect);

      expect(canExecuteManualConnectionCommand(ManualConnectionCommand.connect, const Connected()), isFalse);
      expect(canExecuteManualConnectionCommand(ManualConnectionCommand.disconnect, const Disconnecting()), isFalse);
      expect(canExecuteManualConnectionCommand(ManualConnectionCommand.abort, const Disconnected()), isFalse);

      for (final status in const <ConnectionStatus>[Connecting(), Connected()]) {
        expect(
          canExecuteManualConnectionCommand(ManualConnectionCommand.disconnect, status),
          isTrue,
          reason: 'a captured disconnect tap must remain a stop while Connecting and Connected race',
        );
        expect(
          canExecuteManualConnectionCommand(ManualConnectionCommand.abort, status),
          isTrue,
          reason: 'a captured abort tap must remain a stop while Connecting and Connected race',
        );
      }
    },
  );

  test('abort reads the current retained status so a Connecting-to-Connected race still stops', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final abort = _extractFunctionBlock(source, 'Future<void> abortConnection() async {');

    expect(abort, isNotEmpty);
    expect(abort, contains('final currentStatus = state.valueOrNull;'));
    expect(abort, contains('if (currentStatus is! Connected && currentStatus is! Connecting) return;'));
    expect(abort, contains('await _stopFromManualCommand(currentStatus);'));
    expect(abort, isNot(contains('if (state case AsyncData')));
  });

  test('manual haptic feedback is dispatched without delaying lifecycle commands', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final commandStart = source.indexOf('Future<void> executeManualCommand(');
    final commandEnd = source.indexOf('\n  Future<void> _stopFromManualCommand', commandStart);
    final commandBlock = commandStart < 0 || commandEnd < 0 ? '' : source.substring(commandStart, commandEnd);
    final hapticBlock = _extractFunctionBlock(source, 'void _sendManualHaptic(Future<void> feedback) {');

    expect(commandBlock, isNotEmpty);
    expect(hapticBlock, isNotEmpty);
    expect(commandBlock, contains('ManualConnectionCommand command, {'));
    expect(commandBlock, isNot(contains('await haptic.')));
    final connectHaptic = commandBlock.indexOf('_sendManualHaptic(haptic.lightImpact())');
    final connect = commandBlock.indexOf('await _connect(');
    final firstStopHaptic = commandBlock.indexOf('_sendManualHaptic(haptic.mediumImpact())');
    final firstStop = commandBlock.indexOf('await _stopFromManualCommand(currentStatus);');
    final lastStopHaptic = commandBlock.lastIndexOf('_sendManualHaptic(haptic.mediumImpact())');
    final lastStop = commandBlock.lastIndexOf('await _stopFromManualCommand(currentStatus);');
    expect(connectHaptic, isNonNegative);
    expect(connect, isNonNegative);
    expect(firstStopHaptic, isNonNegative);
    expect(firstStop, isNonNegative);
    expect(connectHaptic, lessThan(connect));
    expect(firstStopHaptic, lessThan(firstStop));
    expect(lastStopHaptic, lessThan(lastStop));
    expect(hapticBlock, contains('unawaited('));
    expect(hapticBlock, contains('feedback.catchError'));
  });

  test('manual connect is not queued behind an occupied lifecycle gate', () async {
    final gate = SingleCall();
    final releaseRunningOperation = Completer<void>();
    var admittedOperations = 0;

    final runningOperation = gate.run(() async {
      admittedOperations++;
      await releaseRunningOperation.future;
    }, onIgnored: () {});
    await Future<void>.delayed(Duration.zero);

    final command = manualConnectionCommandForStatus(const Disconnected());
    expect(command, ManualConnectionCommand.connect);
    final lateConnect = await gate.run(() async {
      admittedOperations++;
    }, onIgnored: () {});

    expect(lateConnect, isFalse);
    expect(admittedOperations, 1, reason: 'the intent must not survive as queued work');
    releaseRunningOperation.complete();
    expect(await runningOperation, isTrue);
  });

  test('notifier admits manual connect inside the gate and does not request queued execution', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final connectStart = source.indexOf('Future<bool> _connect({');
    final connectEnd = source.indexOf('Future<bool> _connectThrottled', connectStart);
    final connectBlock = connectStart < 0 || connectEnd < 0 ? '' : source.substring(connectStart, connectEnd);
    final commandStart = source.indexOf('Future<void> executeManualCommand(');
    final commandEnd = source.indexOf('\n  Future<void> _stopFromManualCommand', commandStart);
    final commandBlock = commandStart < 0 || commandEnd < 0 ? '' : source.substring(commandStart, commandEnd);

    expect(connectBlock, isNotEmpty);
    expect(commandBlock, isNotEmpty);
    expect(connectBlock, contains('final lifecycleCompleted = await _singleStart.run('));
    expect(connectBlock, contains('return lifecycleCompleted;'));
    expect(connectBlock, contains('bool queueAfterCurrentOperation = false'));
    expect(connectBlock, contains('waitForCurrent: queueAfterCurrentOperation'));
    expect(connectBlock, contains('supersedeQueued: queueAfterCurrentOperation'));
    expect(
      connectBlock.indexOf('() async {'),
      lessThan(connectBlock.indexOf('state = const AsyncData(Connecting());')),
    );
    expect(commandBlock, contains('bool queueConnectAfterCurrentOperation = false'));
    expect(commandBlock, contains('canExecuteManualConnectionCommand(command, currentStatus)'));
    expect(commandBlock, contains(r'stale manual $command ignored'));
  });

  test('a completed startup failure releases the lifecycle gate before its dialog and never leaves an async error', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final connectStart = source.indexOf('Future<bool> _connect({');
    final throttledStart = source.indexOf('Future<bool> _connectThrottled({');
    final connect = connectStart < 0 || throttledStart < 0 ? '' : source.substring(connectStart, throttledStart);
    final throttled = _extractFunctionBlock(source, 'Future<bool> _connectThrottled({');

    expect(connectStart, isNonNegative);
    expect(throttledStart, isNonNegative);
    expect(throttled, isNotEmpty);
    expect(
      throttled,
      isNot(contains('.mapLeft((\n      ConnectionFailure err,\n    ) async')),
      reason: 'TaskEither.mapLeft cannot await an async failure handler',
    );
    expect(throttled, contains("_sealAndroidOrdinaryNetworking('manual or automatic Connect')"));
    expect(throttled, contains('await startedByUserNotifier.update(true);'));
    expect(
      throttled,
      isNot(contains('DialogNotifier')),
      reason: 'dialog dependencies belong to asynchronous presentation, never to the lifecycle gate',
    );
    expect(
      throttled,
      isNot(contains('translationsFuture')),
      reason: 'waiting for translated UI text must not retain the lifecycle gate',
    );
    final admittedIntent = throttled.indexOf('await startedByUserNotifier.update(true);');
    final epochConnect = throttled.indexOf(
      'connectionRepo.connect(activeProfile, disableMemoryLimit, androidVpnStartEpoch: admissionEpoch)',
      admittedIntent,
    );
    expect(
      epochConnect,
      greaterThan(admittedIntent),
      reason:
          'the repository connect must remain chained after successful VPN admission and intent publication, carrying its exact epoch',
    );
    expect(throttled, contains('.run();'));
    expect(
      throttled,
      isNot(contains('ref.read(')),
      reason: 'all lifecycle dependencies must be captured before the connection await',
    );

    final clearIntent = throttled.indexOf('await startedByUserNotifier.update(false);');
    final terminalState = throttled.indexOf('state = AsyncData(Disconnected(err));');
    expect(clearIntent, isNonNegative);
    expect(terminalState, greaterThan(clearIntent), reason: 'cleanup completion clears user intent first');
    expect(
      throttled,
      isNot(contains('showCustomAlertFromErr')),
      reason: 'an invisible, blocked, or unclosed dialog must not keep _singleStart running',
    );
    expect(
      throttled,
      isNot(contains('state = AsyncError(err, StackTrace.current);')),
      reason: 'AsyncError can preserve the previous Connecting value in Riverpod',
    );

    expect(
      connect,
      contains('_manualConnectPending = false;'),
      reason: 'every awaited connect completion must release the transient Connecting mask',
    );
    final lifecycleCompletion = connect.indexOf('await _singleStart.run(');
    final asynchronousPresentation = connect.indexOf('unawaited(');
    expect(lifecycleCompletion, isNonNegative);
    expect(
      asynchronousPresentation,
      greaterThan(lifecycleCompletion),
      reason: 'failure presentation must begin only after the lifecycle future has completed and released _singleStart',
    );
    expect(
      source,
      contains('showCustomAlertFromErr'),
      reason: 'the failure remains user-visible, but outside the lifecycle critical section',
    );
  });

  test('cancel keeps the gate closed until the running task finishes', () async {
    final singleCall = SingleCall();
    final first = Completer<void>();
    var runs = 0;
    void onIgnored() {}

    final firstRun = singleCall.run(() async {
      runs++;
      await first.future;
    }, onIgnored: onIgnored);
    await Future<void>.delayed(Duration.zero);

    final ignoredRun = await singleCall.run(() async {
      runs++;
    }, onIgnored: onIgnored);
    expect(ignoredRun, isFalse);
    expect(runs, 1);

    singleCall.cancel();
    final cancelledIgnoredRun = await singleCall.run(() async {
      runs++;
    }, onIgnored: onIgnored);
    expect(cancelledIgnoredRun, isFalse);
    expect(runs, 1);

    first.complete();
    expect(await firstRun, isTrue);

    final secondRun = await singleCall.run(() async {
      runs++;
    }, onIgnored: onIgnored);
    expect(secondRun, isTrue);
    expect(runs, 2);
  });

  test('cancelled run releases the gate after it completes', () async {
    final singleCall = SingleCall();
    final first = Completer<void>();
    var runs = 0;

    final firstRun = singleCall.run(() async {
      runs++;
      await first.future;
    }, onIgnored: () {});
    await Future<void>.delayed(Duration.zero);
    expect(runs, 1);

    singleCall.cancel();
    first.complete();
    expect(await firstRun, isTrue);

    final secondRun = await singleCall.run(() async {
      runs++;
    }, onIgnored: () {});
    expect(secondRun, isTrue);
    expect(runs, 2);
  });

  test('cancel does not complete active work and waitForCurrent awaits its finally block', () async {
    final singleCall = SingleCall();
    final running = Completer<void>();
    final order = <String>[];

    final firstRun = singleCall.run(() async {
      order.add('start');
      try {
        await running.future;
      } finally {
        order.add('finally');
      }
    }, onIgnored: () {});
    await Future<void>.delayed(Duration.zero);
    expect(order, ['start']);

    singleCall.cancel();
    final waitForCurrent = singleCall.waitForCurrent();
    var waitCompleted = false;
    unawaited(
      waitForCurrent.then((_) {
        waitCompleted = true;
      }),
    );

    await Future<void>.delayed(Duration.zero);
    expect(waitCompleted, isFalse);
    expect(order, ['start']);

    running.complete();
    expect(await firstRun, isTrue);
    await waitForCurrent;
    expect(waitCompleted, isTrue);
    expect(order, ['start', 'finally']);
  });

  test('rejected concurrent manual disconnect never releases the active disconnect visibility lease', () async {
    final gate = SingleCall();
    final releaseFirst = Completer<void>();
    final visibility = <bool>[];
    var inProgress = false;
    var ignored = 0;

    final first = runExclusiveManualDisconnect(
      gate: gate,
      task: () => releaseFirst.future,
      setInProgress: (value) {
        inProgress = value;
        visibility.add(value);
      },
      onIgnored: () => ignored++,
    );
    await Future<void>.delayed(Duration.zero);
    expect(inProgress, isTrue);
    expect(visibility, [true]);

    final second = await runExclusiveManualDisconnect(
      gate: gate,
      task: () async => fail('rejected manual disconnect must not run'),
      setInProgress: (value) {
        inProgress = value;
        visibility.add(value);
      },
      onIgnored: () => ignored++,
    );
    expect(second, isFalse);
    expect(ignored, 1);
    expect(inProgress, isTrue);
    expect(visibility, [true], reason: 'the rejected caller must not release the active visibility lease');

    releaseFirst.complete();
    expect(await first, isTrue);
    expect(inProgress, isFalse);
    expect(visibility, [true, false]);
  });

  test('manual disconnect releases its visibility lease after task failure', () async {
    final visibility = <bool>[];

    await expectLater(
      runExclusiveManualDisconnect(
        gate: SingleCall(),
        task: () async => throw StateError('stop failed'),
        setInProgress: visibility.add,
        onIgnored: () => fail('the only manual disconnect must not be ignored'),
      ),
      throwsA(isA<StateError>()),
    );

    expect(visibility, [true, false]);
  });

  test('manual replacement waits for the running task instead of being ignored', () async {
    final singleCall = SingleCall();
    final first = Completer<void>();
    final order = <String>[];

    final firstRun = singleCall.run(() async {
      order.add('first-start');
      await first.future;
      order.add('first-end');
    }, onIgnored: () {});
    await Future<void>.delayed(Duration.zero);

    var ignored = false;
    final replacementRun = singleCall.run(
      () async {
        order.add('replacement');
      },
      waitForCurrent: true,
      onIgnored: () => ignored = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(order, ['first-start']);

    first.complete();
    expect(await firstRun, isTrue);
    expect(await replacementRun, isTrue);
    expect(ignored, isFalse);
    expect(order, ['first-start', 'first-end', 'replacement']);
  });

  test('queued callers remain serialized', () async {
    final singleCall = SingleCall();
    final first = Completer<void>();
    final second = Completer<void>();
    final order = <String>[];

    final firstRun = singleCall.run(() async {
      order.add('first-start');
      await first.future;
      order.add('first-end');
    }, onIgnored: () {});
    await Future<void>.delayed(Duration.zero);

    final secondRun = singleCall.run(
      () async {
        order.add('second-start');
        await second.future;
        order.add('second-end');
      },
      waitForCurrent: true,
      onIgnored: () {},
    );
    final thirdRun = singleCall.run(
      () async {
        order.add('third');
      },
      waitForCurrent: true,
      onIgnored: () {},
    );

    first.complete();
    expect(await firstRun, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(order, ['first-start', 'first-end', 'second-start']);

    second.complete();
    expect(await secondRun, isTrue);
    expect(await thirdRun, isTrue);
    expect(order, ['first-start', 'first-end', 'second-start', 'second-end', 'third']);
  });

  test('latest superseding waiter replaces older queued work', () async {
    final singleCall = SingleCall();
    final first = Completer<void>();
    final order = <String>[];

    final firstRun = singleCall.run(() async {
      order.add('first');
      await first.future;
    }, onIgnored: () {});
    await Future<void>.delayed(Duration.zero);

    final replacedRun = singleCall.run(
      () async => order.add('replaced'),
      waitForCurrent: true,
      supersedeQueued: true,
      onIgnored: () {},
    );
    final latestRun = singleCall.run(
      () async => order.add('latest'),
      waitForCurrent: true,
      supersedeQueued: true,
      onIgnored: () {},
    );

    first.complete();
    expect(await firstRun, isTrue);
    expect(await replacedRun, isFalse);
    expect(await latestRun, isTrue);
    expect(order, ['first', 'latest']);
  });

  test('cancel drops superseding work queued behind the running task', () async {
    final singleCall = SingleCall();
    final first = Completer<void>();
    var queuedRan = false;

    final firstRun = singleCall.run(() => first.future, onIgnored: () {});
    await Future<void>.delayed(Duration.zero);
    final queuedRun = singleCall.run(
      () async => queuedRan = true,
      waitForCurrent: true,
      supersedeQueued: true,
      onIgnored: () {},
    );

    singleCall.cancel();
    first.complete();
    expect(await firstRun, isTrue);
    expect(await queuedRun, isFalse);
    expect(queuedRan, isFalse);
  });

  test('auto reconnect is not scheduled after an initial connecting attempt drops', () {
    expect(
      shouldScheduleAutoReconnectForTransition(const Connecting(), const Disconnected(), operationInProgress: false),
      isFalse,
    );
  });

  test('auto reconnect can be scheduled after an established connection fails', () {
    expect(
      shouldScheduleAutoReconnectForTransition(
        const Connected(),
        const Disconnected(ConnectionFailure.unexpected('connection lost')),
        operationInProgress: false,
      ),
      isTrue,
    );
  });

  test('auto reconnect is not scheduled after a passive disconnected status', () {
    expect(
      shouldScheduleAutoReconnectForTransition(const Connected(), const Disconnected(), operationInProgress: false),
      isFalse,
    );
  });

  test('auto reconnect is not scheduled while a connection operation is running', () {
    expect(
      shouldScheduleAutoReconnectForTransition(const Connected(), const Disconnected(), operationInProgress: true),
      isFalse,
    );
  });

  test('auto reconnect delay is capped and gives Android cleanup time', () {
    expect(autoReconnectDelayForAttempt(0, isAndroid: false), Duration.zero);
    expect(autoReconnectDelayForAttempt(0, isAndroid: true), const Duration(seconds: 2));
    expect(autoReconnectDelayForAttempt(1, isAndroid: true), const Duration(seconds: 5));
    expect(autoReconnectDelayForAttempt(99, isAndroid: true), const Duration(minutes: 1));
  });

  test('auto reconnect keeps retrying after failed silent attempts while user intent remains active', () {
    expect(
      shouldContinueAutoReconnectAfterAttempt(
        const Disconnected(ConnectionFailure.unexpected('connection timed out while starting core')),
        startedByUser: true,
        manualDisconnectRequested: false,
      ),
      isTrue,
    );
    expect(
      shouldContinueAutoReconnectAfterAttempt(null, startedByUser: true, manualDisconnectRequested: false),
      isTrue,
    );
    expect(
      shouldContinueAutoReconnectAfterAttempt(const Connected(), startedByUser: true, manualDisconnectRequested: false),
      isFalse,
    );
    expect(
      shouldContinueAutoReconnectAfterAttempt(
        const Connecting(),
        startedByUser: true,
        manualDisconnectRequested: false,
      ),
      isFalse,
    );
    expect(
      shouldContinueAutoReconnectAfterAttempt(
        const Disconnected(ConnectionFailure.unexpected('failed')),
        startedByUser: false,
        manualDisconnectRequested: false,
      ),
      isFalse,
    );
    expect(
      shouldContinueAutoReconnectAfterAttempt(
        const Disconnected(ConnectionFailure.unexpected('failed')),
        startedByUser: true,
        manualDisconnectRequested: true,
      ),
      isFalse,
    );
  });

  test('auto reconnect keeps the visible status connecting between attempts', () {
    const failure = ConnectionFailure.unexpected('connection lost');

    expect(
      visibleStatusDuringAutoReconnect(
        const Disconnected(failure),
        autoReconnectActive: true,
        startedByUser: true,
        manualDisconnectRequested: false,
      ),
      const Connecting(),
    );
    expect(
      visibleStatusDuringAutoReconnect(
        const Disconnected(failure),
        autoReconnectActive: false,
        startedByUser: true,
        manualDisconnectRequested: false,
      ),
      const Disconnected(failure),
    );
    expect(
      visibleStatusDuringAutoReconnect(
        const Disconnected(failure),
        autoReconnectActive: true,
        startedByUser: true,
        manualDisconnectRequested: true,
      ),
      const Disconnected(failure),
    );
  });

  test('Disconnecting maps to Connecting while auto reconnect remains active and user intent is preserved', () {
    expect(
      visibleStatusDuringAutoReconnect(
        const Disconnecting(),
        autoReconnectActive: true,
        startedByUser: true,
        manualDisconnectRequested: false,
      ),
      const Connecting(),
    );
  });

  test('Disconnecting remains Disconnecting when auto-reconnect continuation is disabled', () {
    expect(
      visibleStatusDuringAutoReconnect(
        const Disconnecting(),
        autoReconnectActive: false,
        startedByUser: true,
        manualDisconnectRequested: false,
      ),
      const Disconnecting(),
    );
    expect(
      visibleStatusDuringAutoReconnect(
        const Disconnecting(),
        autoReconnectActive: true,
        startedByUser: false,
        manualDisconnectRequested: false,
      ),
      const Disconnecting(),
    );
    expect(
      visibleStatusDuringAutoReconnect(
        const Disconnecting(),
        autoReconnectActive: true,
        startedByUser: true,
        manualDisconnectRequested: true,
      ),
      const Disconnecting(),
    );
  });

  test('manual connect pending keeps visible status connecting during transient disconnect', () {
    const failure = ConnectionFailure.unexpected('manual connect attempt in progress');

    expect(
      visibleStatusDuringAutoReconnect(
        const Disconnected(failure),
        autoReconnectActive: true,
        startedByUser: true,
        manualDisconnectRequested: false,
      ),
      const Connecting(),
    );
  });

  test('abort cleanup keeps transient core statuses visually disconnected', () {
    expect(visibleStatusAfterAbort(const Connecting(), showIdleDuringAbort: true), const Disconnected());
    expect(visibleStatusAfterAbort(const Disconnecting(), showIdleDuringAbort: true), const Disconnected());
    expect(visibleStatusAfterAbort(const Connected(), showIdleDuringAbort: true), const Disconnected());
    expect(visibleStatusAfterAbort(const Connecting(), showIdleDuringAbort: false), const Connecting());
  });

  test('connecting abort remains fail closed until the platform stop succeeds', () {
    final prematureRepositoryDisconnect = visibleStatusAfterAbort(const Disconnected(), showIdleDuringAbort: true);
    expect(
      visibleStatusDuringManualButtonDisconnect(prematureRepositoryDisconnect, disconnectInProgress: true),
      const Disconnecting(),
      reason: 'a repository Disconnected event must not expose Connect during abort cleanup',
    );

    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final abortBlock = _extractFunctionBlock(source, 'void _abortConnectionImmediately() {');
    final cleanupBlock = _extractFunctionBlock(source, 'Future<void> _disconnectAfterAbort(int token) async {');
    expect(abortBlock, isNotEmpty);
    expect(cleanupBlock, isNotEmpty);

    final manualQueueCancelled = abortBlock.indexOf('_manualConnectPending = false;');
    final disconnectLeaseAcquired = abortBlock.indexOf('_manualButtonDisconnectInProgress = true;');
    final immediateDisconnecting = abortBlock.indexOf('state = const AsyncData(Disconnecting());');
    final cleanupStarted = abortBlock.indexOf('unawaited(_disconnectAfterAbort(token));');
    expect(manualQueueCancelled, isNonNegative);
    expect(disconnectLeaseAcquired, greaterThan(manualQueueCancelled));
    expect(immediateDisconnecting, greaterThan(disconnectLeaseAcquired));
    expect(cleanupStarted, greaterThan(immediateDisconnecting));
    expect(abortBlock, isNot(contains('Connecting')));

    final platformStop = cleanupBlock.indexOf('await _disconnect(showError: false)');
    final platformStopFailure = cleanupBlock.indexOf('return false;', platformStop);
    final failedStopGuard = cleanupBlock.indexOf('if (!disconnectSucceeded) {');
    final releaseLease = cleanupBlock.indexOf('_manualButtonDisconnectInProgress = false;');
    final settleInput = cleanupBlock.indexOf('await _settleManualDisconnectInput();');
    expect(platformStop, isNonNegative);
    expect(platformStopFailure, greaterThan(platformStop));
    expect(failedStopGuard, greaterThan(platformStop));
    expect(failedStopGuard, greaterThan(platformStopFailure));
    expect(releaseLease, greaterThan(failedStopGuard));
    expect(settleInput, greaterThan(releaseLease));
    expect(_countOccurrences(cleanupBlock, '_manualButtonDisconnectInProgress = false;'), 1);

    final failureBlock = _extractFunctionBlock(cleanupBlock, 'if (!disconnectSucceeded) {');
    final secondFailureGuardStart = cleanupBlock.lastIndexOf('if (!disconnectSucceeded) {');
    expect(secondFailureGuardStart, isNonNegative);
    final secondFailureBlock = secondFailureGuardStart < 0
        ? ''
        : _extractFunctionBlock(cleanupBlock.substring(secondFailureGuardStart), 'if (!disconnectSucceeded) {');
    expect(secondFailureBlock, contains('return;'));
    expect(secondFailureBlock, isNot(contains('_manualButtonDisconnectInProgress = false;')));
    expect(
      failureBlock,
      isNot(contains('_settleManualDisconnectInput')),
      reason: 'first failure branch must defer settle/reconnect',
    );
    expect(failureBlock, isNot(contains('_connect(')));
    expect(cleanupBlock, isNot(contains('_connect(')));
  });

  test('_disconnect returns success only after both repository disconnect and egress release', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final disconnectBlock = _extractFunctionBlock(
      source,
      'Future<bool> _disconnect({bool showError = true, ConnectionRepository? repository}) async {',
    );

    expect(disconnectBlock, isNotEmpty);
    expect(disconnectBlock, contains('var egressReleased = !Platform.isAndroid;'));
    expect(
      disconnectBlock,
      contains(
        'egressReleased = await _tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: egressEpoch);',
      ),
    );
    expect(disconnectBlock, contains('return result.isRight() && egressReleased;'));
    expect(disconnectBlock, isNot(contains('return result.isRight();')));
    expect(disconnectBlock, isNot(contains('return egressReleased;')));
  });

  test(
    'terminal native gate rejection stays distinct from a Dart epoch supersession and abort retry reaches the same release',
    () {
      final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
      final releaseBlock = _extractFunctionBlock(
        source,
        'Future<bool> _tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect({int? expectedEpoch}) async {',
      );
      final abortCleanup = _extractFunctionBlock(source, 'Future<void> _disconnectAfterAbort(int token) async {');

      final releaseGate = releaseBlock.indexOf('strictVpnEgressGate.releaseAfterTerminalDisconnect();');
      final nativeRejected = releaseBlock.indexOf('if (!released) {', releaseGate);
      final nativeRejectedLog = releaseBlock.indexOf(
        'terminal ordinary-network release was rejected by native gate',
        nativeRejected,
      );
      final nativeRejectedReturn = releaseBlock.indexOf('return false;', nativeRejectedLog);
      final dartSuperseded = releaseBlock.indexOf('if (releaseEpoch != _androidEgressEpoch) {', nativeRejectedReturn);
      final dartSupersededLog = releaseBlock.indexOf(
        'terminal ordinary-network release was superseded',
        dartSuperseded,
      );
      final retry = abortCleanup.indexOf(
        '_tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: _androidEgressEpoch)',
      );

      expect(releaseBlock, isNotEmpty);
      expect(abortCleanup, isNotEmpty);
      expect(releaseGate, isNonNegative);
      expect(nativeRejected, greaterThan(releaseGate));
      expect(nativeRejectedLog, greaterThan(nativeRejected));
      expect(nativeRejectedReturn, greaterThan(nativeRejectedLog));
      expect(
        dartSuperseded,
        greaterThan(nativeRejectedReturn),
        reason: 'a successful native release is required before Dart may call the transition superseded',
      );
      expect(dartSupersededLog, greaterThan(dartSuperseded));
      expect(
        releaseBlock,
        isNot(contains('if (!released || releaseEpoch != _androidEgressEpoch)')),
        reason: 'a native rejection must never be logged as a Dart-epoch supersession',
      );
      expect(
        retry,
        isNonNegative,
        reason: 'an aborted start retries the exact terminal release path after the active start unwinds',
      );
    },
  );

  test(
    'abort cleanup waits for the active _singleStart gate before retrying release and only then publishes reconnect',
    () {
      final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
      final cleanupBlock = _extractFunctionBlock(source, 'Future<void> _disconnectAfterAbort(int token) async {');
      final firstDisconnect = cleanupBlock.indexOf('await _disconnect(showError: false)');
      final waitForCurrent = cleanupBlock.indexOf('await _singleStart.waitForCurrent();');
      final retryRelease = cleanupBlock.indexOf(
        '_tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: _androidEgressEpoch)',
      );
      final firstFailureGuard = cleanupBlock.indexOf('if (!disconnectSucceeded) {');
      final secondFailureGuard = cleanupBlock.indexOf('if (!disconnectSucceeded) {', firstFailureGuard + 1);
      final finalFailureReturn = cleanupBlock.indexOf('return;', secondFailureGuard);
      final settleInput = cleanupBlock.indexOf('await _settleManualDisconnectInput();');
      final reconnectAvailable = cleanupBlock.indexOf('reconnect is available');

      expect(cleanupBlock, isNotEmpty);
      expect(firstDisconnect, isNonNegative);
      expect(waitForCurrent, isNonNegative);
      expect(retryRelease, isNonNegative);
      expect(firstFailureGuard, isNonNegative);
      expect(secondFailureGuard, isNonNegative);
      expect(finalFailureReturn, isNonNegative);
      expect(settleInput, isNonNegative);
      expect(reconnectAvailable, isNonNegative);
      expect(waitForCurrent, greaterThan(firstDisconnect));
      expect(retryRelease, greaterThan(waitForCurrent));
      expect(secondFailureGuard, greaterThan(retryRelease));
      expect(finalFailureReturn, greaterThan(secondFailureGuard));
      expect(settleInput, greaterThan(finalFailureReturn));
      expect(reconnectAvailable, greaterThan(settleInput));
      expect(_countOccurrences(cleanupBlock, 'if (!disconnectSucceeded) {'), 2);
      expect(_countOccurrences(cleanupBlock, '_showIdleDuringAbort = false;'), 1);
      expect(_countOccurrences(cleanupBlock, '_manualButtonDisconnectInProgress = false;'), 1);
    },
  );

  test('abort egress retry is event-driven and does not use timer/polling retry', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final cleanupBlock = _extractFunctionBlock(source, 'Future<void> _disconnectAfterAbort(int token) async {');

    expect(cleanupBlock, isNotEmpty);
    expect(cleanupBlock, isNot(contains('Timer(')));
    expect(cleanupBlock, isNot(contains('Timer.periodic')));
    expect(cleanupBlock, isNot(contains('Future.delayed(')));
    expect(cleanupBlock, isNot(contains('while (')));
    expect(cleanupBlock, isNot(contains('.retry(')));
  });

  test(
    'manual button disconnect keeps a premature disconnected event visibly disconnecting until cleanup completes',
    () {
      expect(
        visibleStatusDuringManualButtonDisconnect(const Disconnected(), disconnectInProgress: true),
        const Disconnecting(),
      );
      expect(
        visibleStatusDuringManualButtonDisconnect(const Disconnected(), disconnectInProgress: false),
        const Disconnected(),
      );
      expect(
        visibleStatusDuringManualButtonDisconnect(const Connected(), disconnectInProgress: true),
        const Connected(),
      );
    },
  );

  test('successful authoritative manual disconnect releases independently of a delayed stream status', () {
    expect(shouldPublishManualDisconnectReleased(operationCompleted: true, disconnectSucceeded: true), isTrue);
    expect(shouldPublishManualDisconnectReleased(operationCompleted: false, disconnectSucceeded: true), isFalse);
    expect(
      shouldPublishManualDisconnectReleased(operationCompleted: true, disconnectSucceeded: false),
      isFalse,
      reason: 'a false authoritative platform stop must not publish the release',
    );

    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final normalDisconnect = _extractFunctionBlock(source, 'Future<void> _disconnectFromManualCommand() async {');
    final settleInput = _extractFunctionBlock(source, 'Future<void> _settleManualDisconnectInput() async {');
    expect(normalDisconnect, isNot(contains('visibleStatus:')));
    expect(settleInput, contains('state = const AsyncData(Disconnected());'));
  });

  test('route watchdog waits for repeated failed health checks before reconnecting', () {
    final failures = nextRouteWatchdogFailureCount(0, routeHealthy: false);
    expect(failures, 1);
    expect(shouldReconnectAfterRouteWatchdogFailures(failures), isFalse);
    expect(shouldReconnectAfterRouteWatchdogFailures(3), isTrue);
  });

  test('route watchdog can preserve long-lived TURNcoat routes across transient failures', () {
    expect(shouldReconnectAfterRouteWatchdogFailures(1, preserveLongLivedRoute: true, isIOS: true), isFalse);
    expect(shouldReconnectAfterRouteWatchdogFailures(2, preserveLongLivedRoute: true, isIOS: true), isTrue);
    expect(shouldReconnectAfterRouteWatchdogFailures(99, preserveLongLivedRoute: true), isFalse);
    expect(shouldReconnectAfterRouteWatchdogFailures(99, preserveLongLivedRoute: true, isIOS: false), isFalse);
  });

  test('cold attach retries a live TURNcoat route before restarting the carrier', () {
    expect(
      shouldRetryExistingTurncoatRouteWithoutRestart(
        turncoatInUse: true,
        turncoatLive: true,
        turncoatTimedOut: false,
        consecutiveFailures: 1,
        maxFailures: 6,
      ),
      isTrue,
    );
    expect(
      shouldRetryExistingTurncoatRouteWithoutRestart(
        turncoatInUse: true,
        turncoatLive: true,
        turncoatTimedOut: false,
        consecutiveFailures: 6,
        maxFailures: 6,
      ),
      isFalse,
    );
  });

  test('reconnect error path uses explicit async match and awaits cleanup before terminal state', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final reconnectStart = source.indexOf('  Future<void> reconnect(\n');
    final reconnectEnd = source.indexOf('\n  Future<void> _synchronizeAndroidTerminalUserIntent', reconnectStart);
    final reconnectBlock = reconnectStart < 0 || reconnectEnd < 0 ? '' : source.substring(reconnectStart, reconnectEnd);
    expect(reconnectBlock, isNotEmpty);

    expect(reconnectBlock, contains('ConnectionRepository? repository,'));
    expect(reconnectBlock, contains('final connectionRepo = repository ?? _connectionRepo;'));
    expect(reconnectBlock, contains('final result = await connectionRepo.reconnect(profile'));
    expect(reconnectBlock, contains('await result.match((err) async {'));
    expect(reconnectBlock, isNot(contains('result.match((err) =>')));
    expect(reconnectBlock, isNot(contains('result.mapLeft(')));
    expect(reconnectBlock, contains('final cleanup = await connectionRepo.disconnect().run();'));
    expect(reconnectBlock, contains('state = AsyncError(err, StackTrace.current);'));

    final lifecycleAwait = reconnectBlock.indexOf('await _singleStart.run(');
    final cleanup = reconnectBlock.indexOf('final cleanup = await connectionRepo.disconnect().run();');
    final terminalState = reconnectBlock.indexOf('state = AsyncError(err, StackTrace.current);');
    expect(lifecycleAwait, isNonNegative);
    expect(cleanup, isNonNegative);
    expect(terminalState, isNonNegative);
    expect(cleanup, lessThan(terminalState));
    expect(
      reconnectBlock.substring(lifecycleAwait),
      isNot(contains('ref.read(')),
      reason: 'reconnect must use captured dependencies after the lifecycle operation begins',
    );
  });

  test('connection_notifier.dart no longer contains removed cold-attach helpers or verification flag', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    expect(source, isNot(contains('visibleStatusForColdAttach')));
    expect(source, isNot(contains('_coldAttachStatusPending')));
    expect(source, isNot(contains('existingSessionVerification: true')));
  });

  test(
    'visible status reductions keep ordinary Connecting actionable after abort/auto-reconnect/manual-disconnect paths',
    () {
      final afterAbort = visibleStatusAfterAbort(const Connecting(), showIdleDuringAbort: false);
      final duringAutoReconnect = visibleStatusDuringAutoReconnect(
        afterAbort,
        autoReconnectActive: true,
        startedByUser: true,
        manualDisconnectRequested: false,
      );
      final afterManualDisconnect = visibleStatusDuringManualButtonDisconnect(
        duringAutoReconnect,
        disconnectInProgress: false,
      );

      expect(afterAbort, const Connecting());
      expect(duringAutoReconnect, const Connecting());
      expect(afterManualDisconnect, const Connecting());
      expect(manualConnectionCommandForStatus(afterManualDisconnect), ManualConnectionCommand.abort);
      expect(canExecuteManualConnectionCommand(ManualConnectionCommand.abort, afterManualDisconnect), isTrue);
    },
  );

  test('cold attach does not preserve an unverified or timed-out TURNcoat carrier', () {
    expect(
      shouldRetryExistingTurncoatRouteWithoutRestart(
        turncoatInUse: true,
        turncoatLive: false,
        turncoatTimedOut: false,
        consecutiveFailures: 1,
        maxFailures: 6,
      ),
      isFalse,
    );
    expect(
      shouldRetryExistingTurncoatRouteWithoutRestart(
        turncoatInUse: true,
        turncoatLive: true,
        turncoatTimedOut: true,
        consecutiveFailures: 1,
        maxFailures: 6,
      ),
      isFalse,
    );
  });

  test('fresh route failure is strict without reconnecting immediately', () {
    expect(nextRouteWatchdogFailureCount(0, routeHealthy: false, requireFreshRoute: true), 1);
    expect(nextRouteWatchdogFailureCount(1, routeHealthy: false, requireFreshRoute: true), 3);
    expect(
      nextRouteWatchdogFailureCount(0, routeHealthy: false, requireFreshRoute: true, preserveLongLivedRoute: true),
      1,
    );
  });

  test('route watchdog clears failure count after a healthy check', () {
    final failures = nextRouteWatchdogFailureCount(1, routeHealthy: true);
    expect(failures, 0);
  });

  test('transient connection features stay armed during a managed reconnect', () {
    expect(
      shouldResetTransientConnectionFeatures(
        const Connected(),
        const Disconnecting(),
        operationInProgress: true,
        manualDisconnectRequested: false,
        showIdleDuringAbort: false,
      ),
      isFalse,
    );
    expect(
      shouldResetTransientConnectionFeatures(
        const Connected(),
        const Disconnected(ConnectionFailure.unexpected('native restart')),
        operationInProgress: true,
        manualDisconnectRequested: false,
        showIdleDuringAbort: false,
      ),
      isFalse,
    );
  });

  test('transient connection features reset on deliberate disconnects', () {
    expect(
      shouldResetTransientConnectionFeatures(
        const Connected(),
        const Disconnecting(),
        operationInProgress: true,
        manualDisconnectRequested: true,
        showIdleDuringAbort: false,
      ),
      isTrue,
    );
    expect(
      shouldResetTransientConnectionFeatures(
        const Connected(),
        const Disconnected(),
        operationInProgress: true,
        manualDisconnectRequested: false,
        showIdleDuringAbort: true,
      ),
      isTrue,
    );
  });

  test('initial connecting drop does not clear startup watchers before repository handles it', () {
    expect(
      shouldResetTransientConnectionFeatures(
        const Connecting(),
        const Disconnected(ConnectionFailure.unexpected('startup failed')),
        operationInProgress: false,
        manualDisconnectRequested: false,
        showIdleDuringAbort: false,
      ),
      isFalse,
    );
  });

  test('resume verifies a stale connecting status from an already started core', () {
    expect(
      shouldVerifyRouteAfterResume(
        const Connecting(),
        startedByUser: true,
        canAdoptPlatformSession: true,
        operationInProgress: false,
        verificationRunning: false,
        coreStarted: true,
      ),
      isTrue,
    );
    expect(
      shouldVerifyRouteAfterResume(
        const Connected(),
        startedByUser: true,
        canAdoptPlatformSession: true,
        operationInProgress: false,
        verificationRunning: false,
        coreStarted: true,
      ),
      isFalse,
    );
    expect(
      shouldVerifyRouteAfterResume(
        const Connecting(),
        startedByUser: false,
        canAdoptPlatformSession: true,
        operationInProgress: false,
        verificationRunning: false,
        coreStarted: true,
      ),
      isTrue,
    );
    expect(
      shouldVerifyRouteAfterResume(
        const Connecting(),
        startedByUser: true,
        canAdoptPlatformSession: true,
        operationInProgress: true,
        verificationRunning: false,
        coreStarted: true,
      ),
      isFalse,
    );
    expect(
      shouldVerifyRouteAfterResume(
        const Connecting(),
        startedByUser: true,
        canAdoptPlatformSession: true,
        operationInProgress: false,
        verificationRunning: true,
        coreStarted: true,
      ),
      isFalse,
    );
    expect(
      shouldVerifyRouteAfterResume(
        const Connecting(),
        startedByUser: true,
        canAdoptPlatformSession: true,
        operationInProgress: false,
        verificationRunning: false,
        coreStarted: false,
      ),
      isFalse,
    );

    expect(
      shouldVerifyRouteAfterResume(
        const Connecting(),
        startedByUser: false,
        canAdoptPlatformSession: false,
        operationInProgress: false,
        verificationRunning: false,
        coreStarted: true,
      ),
      isFalse,
    );
  });

  test('native user-session intent is authoritative during Android cold attach', () {
    expect(existingStartedSessionIsOwned(flutterStartedByUser: false, platformStartedByUser: true), isTrue);
    expect(existingStartedSessionIsOwned(flutterStartedByUser: true, platformStartedByUser: false), isFalse);
    expect(existingStartedSessionIsOwned(flutterStartedByUser: true, platformStartedByUser: null), isTrue);
  });

  test('automatic connection recovery owner on Android resolves to androidService', () {
    expect(
      automaticConnectionRecoveryOwnerForPlatform(isAndroid: true),
      AutomaticConnectionRecoveryOwner.androidService,
    );
  });

  test('automatic connection recovery owner on non-Android resolves to flutter', () {
    expect(automaticConnectionRecoveryOwnerForPlatform(isAndroid: false), AutomaticConnectionRecoveryOwner.flutter);
  });

  test('newer exact Connect suppresses stale rejected cleanup while its native handoff remains reserved', () {
    expect(isCurrentConnectIntent(attemptGeneration: 71, currentGeneration: 72), isFalse);
    expect(isCurrentConnectIntent(attemptGeneration: 72, currentGeneration: 72), isTrue);

    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final connect = _extractFunctionBlock(source, 'Future<bool> _connectThrottled({');
    final pending = _extractFunctionBlock(
      source,
      'void _tryExecutePendingNativeConnectRequest(ConnectionStatus? status) {',
    );
    final reserve = _extractFunctionBlock(source, 'int _reserveNativeConnectIntent(int handoffId) {');
    final execute = _extractFunctionBlock(source, 'void _executePendingNativeConnectRequest(int handoffId');

    final rejected = connect.indexOf('await result.match(');
    final staleIntent = connect.indexOf('if (!intentIsCurrent()) {', rejected);
    final staleReturn = connect.indexOf('return;', staleIntent);
    final cleanup = connect.indexOf('final cleanup = await connectionRepo.disconnect().run();', staleReturn);
    final terminalState = connect.indexOf('state = AsyncData(Disconnected(err));', cleanup);
    final failurePresentation = connect.indexOf('onUserVisibleFailure(err);', terminalState);
    expect(rejected, isNonNegative);
    expect(staleIntent, greaterThan(rejected));
    expect(staleReturn, greaterThan(staleIntent));
    expect(
      cleanup,
      greaterThan(staleReturn),
      reason: 'an older rejected Connect must return before terminal cleanup can cancel the newer handoff',
    );
    expect(
      terminalState,
      greaterThan(staleReturn),
      reason: 'a stale rejection must not publish Disconnected(error) over the newer Connect',
    );
    expect(
      failurePresentation,
      greaterThan(terminalState),
      reason: 'a stale rejection must not publish an error or schedule its dialog',
    );

    final terminalStatus = pending.indexOf('if (status is Disconnected || state is AsyncError<ConnectionStatus>) {');
    final reserveBeforeAttempt = pending.indexOf('_reserveNativeConnectIntent(handoffId);', terminalStatus);
    final activeAttempt = pending.indexOf(
      'if (_nativeConnectRequestAttemptHandoffId != null) return;',
      reserveBeforeAttempt,
    );
    expect(
      reserveBeforeAttempt,
      greaterThan(terminalStatus),
      reason: 'a retained native handoff must mint its newest intent before the older attempt finishes unwinding',
    );
    expect(activeAttempt, greaterThan(reserveBeforeAttempt));
    expect(reserve, contains('_nativeConnectRequestIntentGeneration ??= ++_connectIntentGeneration'));

    final attemptAssigned = execute.indexOf('_nativeConnectRequestAttemptHandoffId = handoffId;');
    final completion = execute.indexOf('execution.whenComplete(() {', attemptAssigned);
    final clearExactAttempt = execute.indexOf('if (_nativeConnectRequestAttemptHandoffId == handoffId)', completion);
    final completionBlock = completion < 0 ? '' : execute.substring(completion);
    expect(attemptAssigned, isNonNegative);
    expect(completion, greaterThan(attemptAssigned));
    expect(clearExactAttempt, greaterThan(completion));
    expect(
      completionBlock,
      isNot(contains('_nativeConnectRequestIntentGeneration = null')),
      reason: 'old completion may release only its attempt marker, never the reserved newer intent generation',
    );
  });

  test('startup data-plane failure is terminal only after the awaited native cleanup', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final connectStart = source.indexOf('  Future<bool> _connectThrottled({');
    expect(connectStart, isNonNegative);
    final nextConnectFn = source.indexOf('\n  Future<bool> _disconnect', connectStart);
    expect(nextConnectFn, isNonNegative);
    final connectThrottled = source.substring(connectStart, nextConnectFn);

    expect(
      connectThrottled,
      isNot(contains('shouldDelegateFailedConnectionToAndroidRecovery')),
      reason: 'a failed Android startup probe must stop/close instead of remaining indefinitely in Connecting',
    );

    final resultPipeline = connectThrottled.indexOf('final result = await connectionRepo');
    final connectionStep = connectThrottled.indexOf(
      'connectionRepo.connect(activeProfile, disableMemoryLimit, androidVpnStartEpoch: admissionEpoch)',
      resultPipeline,
    );
    final connectionRun = connectThrottled.indexOf('.run();', connectionStep);
    final cleanup = connectThrottled.indexOf('final cleanup = await connectionRepo.disconnect().run();', connectionRun);
    final clearUserIntent = connectThrottled.indexOf('await startedByUserNotifier.update(false)', cleanup);
    final dialog = connectThrottled.indexOf('showCustomAlertFromErr', clearUserIntent);
    final terminalState = connectThrottled.indexOf('state = AsyncData(Disconnected(err));', clearUserIntent);
    expect(resultPipeline, isNonNegative);
    expect(connectionStep, greaterThan(resultPipeline));
    expect(connectionRun, greaterThan(connectionStep));
    expect(cleanup, greaterThan(connectionRun));
    expect(clearUserIntent, isNonNegative);
    expect(clearUserIntent, greaterThan(connectionRun));
    expect(terminalState, greaterThan(clearUserIntent));
    expect(dialog, greaterThan(terminalState));
    expect(connectThrottled, isNot(contains('state = AsyncError(err, StackTrace.current);')));
    expect(connectThrottled, isNot(contains('ref.read(')));
  });
}
