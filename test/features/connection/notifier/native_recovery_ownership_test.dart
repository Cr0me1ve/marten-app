import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/features/connection/model/connection_failure.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/singbox/model/core_status.dart';

void main() {
  Future<TranslationsEn> loadRuTranslations() => AppLocale.ru.build();

  test('Flutter reconnect defers to Android native recovery transitions', () {
    expect(
      shouldDeferFlutterReconnect(
        isAndroid: true,
        nativeRecoveryInProgress: true,
        platformStatus: const CoreStatus.started(),
      ),
      isTrue,
    );
    expect(
      shouldDeferFlutterReconnect(
        isAndroid: true,
        nativeRecoveryInProgress: false,
        platformStatus: const CoreStatus.starting(),
      ),
      isTrue,
    );
    expect(
      shouldDeferFlutterReconnect(
        isAndroid: true,
        nativeRecoveryInProgress: false,
        platformStatus: const CoreStatus.stopping(),
      ),
      isTrue,
    );
  });

  test('Flutter reconnect remains available outside Android native recovery', () {
    expect(
      shouldDeferFlutterReconnect(
        isAndroid: true,
        nativeRecoveryInProgress: false,
        platformStatus: const CoreStatus.started(),
      ),
      isFalse,
    );
    expect(
      shouldDeferFlutterReconnect(
        isAndroid: false,
        nativeRecoveryInProgress: true,
        platformStatus: const CoreStatus.starting(),
      ),
      isFalse,
    );
  });

  test('persistent connection status stream does not self-invalidate lifecycle work', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();

    expect(source, isNot(contains('ref.watch(coreRestartSignalProvider)')));
  });

  test('reports bootstrap setup failures only while the same request remains active', () {
    final cases = [
      (requestAbortToken: 4, currentAbortToken: 4, manualDisconnectRequested: false, expected: true),
      (requestAbortToken: 4, currentAbortToken: 5, manualDisconnectRequested: false, expected: false),
      (requestAbortToken: 4, currentAbortToken: 4, manualDisconnectRequested: true, expected: false),
      (requestAbortToken: 4, currentAbortToken: 5, manualDisconnectRequested: true, expected: false),
    ];

    for (final testCase in cases) {
      expect(
        shouldReportBootstrapSetupFailure(
          requestAbortToken: testCase.requestAbortToken,
          currentAbortToken: testCase.currentAbortToken,
          manualDisconnectRequested: testCase.manualDisconnectRequested,
        ),
        testCase.expected,
      );
    }
  });

  test('bootstrap setup logs stale failures as context rather than Crashlytics errors', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final buildStart = source.indexOf('Stream<ConnectionStatus> build() async*');
    final buildEnd = source.indexOf('\n  ConnectionRepository get _connectionRepo', buildStart);
    expect(buildStart, isNonNegative);
    expect(buildEnd, greaterThan(buildStart));
    final build = source.substring(buildStart, buildEnd);
    final setupStart = build.indexOf('await _connectionRepo.setup()');
    final setupEnd = build.indexOf('\n    listenSelf(', setupStart);
    expect(setupStart, isNonNegative);
    expect(setupEnd, greaterThan(setupStart));
    final setup = build.substring(setupStart, setupEnd);
    final reportGuard = setup.indexOf('shouldReportBootstrapSetupFailure(');
    final reportError = setup.indexOf('loggy.error("error setting up connection repository", l, stackTrace)');

    expect(reportGuard, isNonNegative);
    expect(reportError, greaterThan(reportGuard));
    expect(setup, contains('loggy.info('));
  });

  test('Android-selected-route startup failures are terminal and never delegated to recovery', () async {
    final t = await loadRuTranslations();
    const routeFailure = ConnectionFailure.unexpected('selected route failed startup connectivity check');

    expect(
      File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync(),
      isNot(contains('shouldDelegateFailedConnectionToAndroidRecovery')),
      reason: 'a failed startup already awaited native Stop/Close and must publish its terminal result',
    );
    expect(routeFailure.present(t).type, 'сервер недоступен');
  });

  test('owned Android cold attach arms CAPTCHA before existing-session route verification', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final verificationStart = source.indexOf('Future<void> _verifyExistingStartedRoute() async {');
    final verificationEnd = source.indexOf(
      '\n  void _scheduleExistingStartedRouteVerificationRetry',
      verificationStart,
    );
    expect(verificationStart, isNonNegative);
    expect(verificationEnd, greaterThan(verificationStart));
    final verification = source.substring(verificationStart, verificationEnd);

    final unownedStart = verification.indexOf('if (!ownsSession) {');
    final routeProof = verification.indexOf('verifyConnectedRoute(holdStartupRouteReady: true)');
    final captchaArm = verification.indexOf('captchaNotifierProvider.notifier).arm(enabled: true)');
    final androidGate = verification.lastIndexOf('if (Platform.isAndroid)', captchaArm);
    expect(unownedStart, isNonNegative);
    expect(routeProof, isNonNegative);
    expect(androidGate, greaterThan(unownedStart));
    expect(androidGate, lessThan(captchaArm));
    expect(captchaArm, greaterThan(unownedStart));
    expect(captchaArm, lessThan(routeProof));

    final unownedBranch = verification.substring(unownedStart, captchaArm);
    expect(unownedBranch, contains('await _disconnect(showError: false)'));
    expect(unownedBranch, contains('state = const AsyncData(Disconnected())'));
    expect(unownedBranch, isNot(contains('captchaNotifierProvider.notifier).arm(')));

    final ownedSetup = verification.substring(androidGate, routeProof);
    expect(ownedSetup, contains('if (Platform.isAndroid)'));
    expect(ownedSetup, contains('captchaNotifierProvider.notifier).arm(enabled: true)'));
  });

  test('owned iOS cold attach restores exact runtime features before route proof', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final verificationStart = source.indexOf('Future<void> _verifyExistingStartedRoute() async {');
    final verificationEnd = source.indexOf(
      '\n  void _scheduleExistingStartedRouteVerificationRetry',
      verificationStart,
    );
    expect(verificationStart, isNonNegative);
    expect(verificationEnd, greaterThan(verificationStart));
    final verification = source.substring(verificationStart, verificationEnd);

    final unownedCheck = verification.indexOf('if (!ownsSession) {');
    final restoreGate = verification.indexOf('if (Platform.isIOS) {');
    final iosBranchEnd = verification.indexOf(
      'loggy.info("verifying existing started route before showing connected")',
      restoreGate,
    );
    final restore = verification.indexOf('restoreActiveRuntimeFeatures(profile, isCurrent: retainedSessionIsCurrent)');
    final currentCheck = verification.indexOf('if (!retainedSessionIsCurrent()) return;', restore);
    final failedRestore = verification.indexOf('if (!restored) {', currentCheck);
    final abortToken = verification.indexOf('final abortToken = _abortToken;', restoreGate);
    final intentGeneration = verification.indexOf('final intentGeneration = _connectIntentGeneration;', abortToken);
    final profileWait = verification.indexOf(
      'await ref.read(activeProfileProvider.future).timeout(const Duration(seconds: 8))',
      intentGeneration,
    );
    final profileRevision = verification.indexOf('final profileRevision = _activeProfileChangeRevision;', profileWait);
    final currentCallback = verification.indexOf('bool retainedSessionIsCurrent() =>', profileRevision);
    final preRestoreCheck = verification.indexOf('if (!retainedSessionIsCurrent()) return;', currentCallback);
    final livenessCapture = verification.indexOf(
      'final retainedLiveness = Platform.isIOS ? ref.read(turncoatLivenessNotifierProvider.notifier) : null;',
    );
    final livenessGeneration = verification.indexOf(
      'final retainedLivenessGeneration = retainedLiveness?.generation;',
      livenessCapture,
    );
    final routeProof = verification.indexOf('verifyConnectedRoute(holdStartupRouteReady: true)');
    final resultMatch = verification.indexOf('await result.match(', routeProof);
    final proofSuccess = verification.indexOf('\n        (_) {', resultMatch);
    final proofSuccessEnd = verification.indexOf('\n        },', proofSuccess);

    expect(unownedCheck, isNonNegative);
    expect(restoreGate, greaterThan(unownedCheck));
    expect(abortToken, greaterThan(restoreGate));
    expect(intentGeneration, greaterThan(abortToken));
    expect(profileWait, greaterThan(intentGeneration));
    expect(profileRevision, greaterThan(profileWait));
    expect(currentCallback, greaterThan(profileRevision));
    expect(preRestoreCheck, greaterThan(currentCallback));
    expect(restore, greaterThan(preRestoreCheck));
    expect(restore, greaterThan(restoreGate));
    expect(currentCheck, greaterThan(restore));
    expect(failedRestore, greaterThan(currentCheck));
    expect(livenessCapture, greaterThan(failedRestore));
    expect(livenessGeneration, greaterThan(livenessCapture));
    expect(routeProof, greaterThan(livenessGeneration));
    expect(resultMatch, greaterThan(routeProof));
    expect(proofSuccess, greaterThan(resultMatch));
    expect(proofSuccessEnd, greaterThan(proofSuccess));

    final iosBranch = verification.substring(restoreGate, iosBranchEnd);
    expect(iosBranch, contains('.timeout(const Duration(seconds: 8))'));
    expect(iosBranch, isNot(contains('activeProfileProvider).valueOrNull')));
    expect(iosBranch, isNot(contains('activeProfileProvider.valueOrNull')));

    final unownedBranch = verification.substring(unownedCheck, restoreGate);
    expect(unownedBranch, contains('await _disconnect(showError: false)'));
    expect(unownedBranch, isNot(contains('restoreActiveRuntimeFeatures')));

    final restoreFailureBranch = verification.substring(failedRestore, routeProof);
    expect(restoreFailureBranch, contains('await _disconnect(showError: false)'));
    expect(restoreFailureBranch, contains('state = const AsyncData(Disconnected())'));
    expect(restoreFailureBranch, contains('return;'));

    final routeFailureBranch = verification.substring(resultMatch, proofSuccess);
    final routeSuccessBranch = verification.substring(proofSuccess, proofSuccessEnd);
    expect(routeFailureBranch, isNot(contains('acceptVerifiedRouteProof')));
    expect(routeSuccessBranch, contains('retainedLiveness.acceptVerifiedRouteProof('));
    expect(routeSuccessBranch, contains('expectedGeneration: retainedLivenessGeneration'));
    expect(routeSuccessBranch, contains('retainedLivenessGeneration != null'));
    expect(routeSuccessBranch, contains('!_manualDisconnectRequested'));
    expect(routeSuccessBranch, contains('ref.read(Preferences.startedByUser)'));

    final currentCallbackEnd = verification.indexOf(';', currentCallback);
    final currentCallbackBody = verification.substring(currentCallback, currentCallbackEnd);
    expect(currentCallbackBody, contains('abortToken == _abortToken'));
    expect(currentCallbackBody, contains('intentGeneration == _connectIntentGeneration'));
    expect(currentCallbackBody, contains('profileRevision == _activeProfileChangeRevision'));
    expect(currentCallbackBody, contains('ref.read(Preferences.startedByUser)'));

    final androidArm = verification.indexOf('captchaNotifierProvider.notifier).arm(enabled: true)');
    expect(androidArm, isNonNegative);
    expect(verification.lastIndexOf('if (Platform.isAndroid)', androidArm), greaterThan(unownedCheck));
    expect(androidArm, lessThan(restoreGate));
  });

  test('delegated Android route verification awaits authority without a retry timer', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final handlerStart = source.indexOf('void _handleStartupRouteVerification(ConnectionStatus? nextStatus) {');
    final handlerEnd = source.indexOf('\n  Future<void> _verifyExistingStartedRoute() async {', handlerStart);
    final verificationStart = handlerEnd + 1;
    final verificationEnd = source.indexOf(
      '\n  void _scheduleExistingStartedRouteVerificationRetry',
      verificationStart,
    );
    expect(handlerStart, isNonNegative);
    expect(handlerEnd, greaterThan(handlerStart));
    expect(verificationEnd, greaterThan(verificationStart));

    final handler = source.substring(handlerStart, handlerEnd);
    final verification = source.substring(verificationStart, verificationEnd);
    final delegatedStart = verification.indexOf('if (!_flutterOwnsAutomaticRecovery) {');
    final flutterOwnedRecovery = verification.indexOf('\n            final liveness', delegatedStart);
    final delegated = verification.substring(delegatedStart, flutterOwnedRecovery);
    final successStart = verification.indexOf('\n        (_) {');
    final successEnd = verification.indexOf('\n        },\n      );', successStart);

    expect(delegatedStart, isNonNegative);
    expect(flutterOwnedRecovery, greaterThan(delegatedStart));
    expect(delegated, contains('_awaitingAndroidAuthoritativeRecoveryStatus = true'));
    expect(delegated, contains('_existingStartedRouteVerificationRetryTimer?.cancel()'));
    expect(delegated, contains('_existingStartedRouteVerificationRetryTimer = null'));
    expect(delegated, contains('return;'));
    expect(delegated, isNot(contains('_scheduleExistingStartedRouteVerificationRetry')));
    expect(delegated, isNot(contains('Timer(')));

    final reset = handler.indexOf('if (nextStatus is! Connecting) {');
    final duplicateGuard = handler.indexOf('if (_awaitingAndroidAuthoritativeRecoveryStatus) return;');
    final probe = handler.indexOf('unawaited(_verifyExistingStartedRoute())');
    expect(reset, isNonNegative);
    expect(handler.substring(reset, duplicateGuard), contains('_awaitingAndroidAuthoritativeRecoveryStatus = false'));
    expect(handler.substring(reset, duplicateGuard), contains('_cancelExistingStartedRouteVerificationRetry()'));
    expect(duplicateGuard, greaterThan(reset));
    expect(probe, greaterThan(duplicateGuard));

    expect(successStart, isNonNegative);
    expect(successEnd, greaterThan(successStart));
    final success = verification.substring(successStart, successEnd);
    expect(success, contains('_awaitingAndroidAuthoritativeRecoveryStatus = false'));
    expect(success, contains('_cancelExistingStartedRouteVerificationRetry()'));
  });
}
