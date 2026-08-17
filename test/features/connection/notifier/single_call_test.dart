import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/connection/model/connection_failure.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';

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
    final commandBlock = _extractFunctionBlock(
      source,
      'Future<void> executeManualCommand(ManualConnectionCommand command) async {',
    );
    final hapticBlock = _extractFunctionBlock(source, 'void _sendManualHaptic(Future<void> feedback) {');

    expect(commandBlock, isNotEmpty);
    expect(hapticBlock, isNotEmpty);
    expect(commandBlock, isNot(contains('await haptic.')));
    expect(
      commandBlock.indexOf('_sendManualHaptic(haptic.lightImpact())'),
      lessThan(commandBlock.indexOf('await _connect()')),
    );
    expect(
      commandBlock.indexOf('_sendManualHaptic(haptic.mediumImpact())'),
      lessThan(commandBlock.indexOf('await _stopFromManualCommand(currentStatus);')),
    );
    expect(
      commandBlock.lastIndexOf('_sendManualHaptic(haptic.mediumImpact())'),
      lessThan(commandBlock.lastIndexOf('await _stopFromManualCommand(currentStatus);')),
    );
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
    final connectStart = source.indexOf('Future<bool> _connect({bool silent = false}) {');
    final connectEnd = source.indexOf('Future<bool> _connectThrottled', connectStart);
    final connectBlock = connectStart < 0 || connectEnd < 0 ? '' : source.substring(connectStart, connectEnd);
    final commandBlock = _extractFunctionBlock(
      source,
      'Future<void> executeManualCommand(ManualConnectionCommand command) async {',
    );

    expect(connectBlock, isNotEmpty);
    expect(commandBlock, isNotEmpty);
    expect(connectBlock, contains('return _singleStart.run('));
    expect(connectBlock, isNot(contains('waitForCurrent:')));
    expect(connectBlock, isNot(contains('supersedeQueued:')));
    expect(
      connectBlock.indexOf('() async {'),
      lessThan(connectBlock.indexOf('state = const AsyncData(Connecting());')),
    );
    expect(commandBlock, contains('canExecuteManualConnectionCommand(command, currentStatus)'));
    expect(commandBlock, contains(r'stale manual $command ignored'));
  });

  test('a completed startup failure becomes disconnected before its dialog and never leaves an async error', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final connectStart = source.indexOf('Future<bool> _connect({bool silent = false}) {');
    final throttledStart = source.indexOf('Future<bool> _connectThrottled({');
    final throttledEnd = source.indexOf('\n  Future<bool> _disconnect', throttledStart);
    final connect = connectStart < 0 || throttledStart < 0 ? '' : source.substring(connectStart, throttledStart);
    final throttled = throttledStart < 0 || throttledEnd < 0 ? '' : source.substring(throttledStart, throttledEnd);

    expect(connectStart, isNonNegative);
    expect(throttledStart, isNonNegative);
    expect(throttledEnd, greaterThan(throttledStart));
    expect(
      throttled,
      isNot(contains('.mapLeft((\n      ConnectionFailure err,\n    ) async')),
      reason: 'TaskEither.mapLeft cannot await an async failure handler',
    );
    expect(throttled, contains('required ConnectionRepository connectionRepo'));
    expect(throttled, contains('required PreferencesNotifier<bool, bool> startedByUserNotifier'));
    expect(throttled, contains('required DialogNotifier dialogNotifier'));
    expect(throttled, contains('required Future<Translations> translationsFuture'));
    expect(throttled, contains('await connectionRepo.connect('));
    expect(throttled, contains('.run();'));
    expect(
      throttled,
      isNot(contains('ref.read(')),
      reason: 'all lifecycle dependencies must be captured before the connection await',
    );

    final clearIntent = throttled.indexOf('await startedByUserNotifier.update(false);');
    final terminalState = throttled.indexOf('state = AsyncData(Disconnected(err));');
    final showDialog = throttled.indexOf('await dialogNotifier.showCustomAlertFromErr(');
    expect(clearIntent, isNonNegative);
    expect(terminalState, greaterThan(clearIntent), reason: 'cleanup completion clears user intent first');
    expect(
      showDialog,
      greaterThan(terminalState),
      reason: 'the retryable terminal state must publish before the dialog',
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
    expect(failureBlock, contains('return;'));
    expect(failureBlock, isNot(contains('_manualButtonDisconnectInProgress = false;')));
    expect(failureBlock, isNot(contains('_settleManualDisconnectInput')));
    expect(failureBlock, isNot(contains('_connect(')));
    expect(cleanupBlock, isNot(contains('_connect(')));
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
    expect(shouldReconnectAfterRouteWatchdogFailures(1), isFalse);
    expect(shouldReconnectAfterRouteWatchdogFailures(2), isFalse);
    expect(shouldReconnectAfterRouteWatchdogFailures(3), isTrue);
    expect(shouldReconnectAfterRouteWatchdogFailures(99, preserveLongLivedRoute: true), isFalse);
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
    final reconnectEnd = source.indexOf('\n  void _scheduleReconnectAfterNativeRecovery', reconnectStart);
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

    final connectionRun = connectThrottled.indexOf(
      'final result = await connectionRepo.connect(activeProfile, disableMemoryLimit).run();',
    );
    final clearUserIntent = connectThrottled.indexOf('await startedByUserNotifier.update(false)', connectionRun);
    final dialog = connectThrottled.indexOf('showCustomAlertFromErr', clearUserIntent);
    final terminalState = connectThrottled.indexOf('state = AsyncData(Disconnected(err));', clearUserIntent);
    expect(connectionRun, isNonNegative);
    expect(clearUserIntent, isNonNegative);
    expect(clearUserIntent, greaterThan(connectionRun));
    expect(terminalState, greaterThan(clearUserIntent));
    expect(dialog, greaterThan(terminalState));
    expect(connectThrottled, isNot(contains('state = AsyncError(err, StackTrace.current);')));
    expect(connectThrottled, isNot(contains('ref.read(')));
  });
}
