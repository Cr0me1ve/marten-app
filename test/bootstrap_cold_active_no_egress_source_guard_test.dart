import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android bootstrap keeps Firebase, FCM, and headless WorkManager Dart work behind a verified VPN route', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    for (final entry in const [
      'android:name="firebase_crashlytics_collection_enabled"\n            android:value="false"',
      'android:name="firebase_messaging_auto_init_enabled"\n            android:value="false"',
      'android:name="firebase_analytics_collection_enabled"\n            android:value="false"',
      'android:name="com.google.firebase.provider.FirebaseInitProvider"\n            tools:node="remove"',
      'android:name="io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingInitProvider"\n            tools:node="remove"',
      'android:name="androidx.work.WorkManagerInitializer"\n                tools:node="remove"',
    ]) {
      expect(manifest, contains(entry), reason: 'Android cold start must opt out of network SDK auto-init $entry');
    }

    final bootstrap = File('lib/bootstrap.dart').readAsStringSync();
    final strictColdStart = bootstrap.indexOf(
      'final strictAndroidSessionPending = PlatformUtils.isAndroid && container.read(Preferences.startedByUser);',
    );
    final androidNetworkCold = bootstrap.indexOf(
      'final networkServicesAdmitted = !PlatformUtils.isAndroid;',
      strictColdStart,
    );
    final retainedJoin = bootstrap.indexOf('tryJoinVerifiedVpnAdmission()', strictColdStart);
    final retainedAdmission = bootstrap.indexOf('if (retainedAdmission != null)', retainedJoin);
    final egressSeal = bootstrap.indexOf('await strictVpnEgressGate.sealForVpnTransition();', retainedAdmission);
    final resumeAdmission = bootstrap.indexOf('beginVpnStartAdmission(resumeSession: true)', egressSeal);
    expect(
      strictColdStart,
      greaterThanOrEqualTo(0),
      reason: 'bootstrap must derive Android cold-active state from started_by_user',
    );
    expect(
      androidNetworkCold,
      greaterThan(strictColdStart),
      reason: 'Android optional networking must start disabled even before an admission attempt',
    );
    expect(
      retainedJoin,
      greaterThan(androidNetworkCold),
      reason: 'cold-active bootstrap must first inspect whether it can join the retained route-verified VPN generation',
    );
    expect(
      retainedAdmission,
      greaterThan(retainedJoin),
      reason: 'the retained join result must decide whether a new transition is needed',
    );
    expect(
      egressSeal,
      greaterThan(retainedAdmission),
      reason: 'only a failed retained join may seal ordinary egress for a replacement transition',
    );
    expect(
      resumeAdmission,
      greaterThan(egressSeal),
      reason: 'the retained-join fallback must request native resume admission after sealing egress',
    );

    for (final call in const [
      'registerSubscriptionPushBackgroundHandler()',
      'unawaited(_warmUpDeferredProfileServices(container, debug));',
    ]) {
      final callIndex = bootstrap.indexOf(call);
      expect(callIndex, greaterThanOrEqualTo(0), reason: 'guarded startup call $call is missing');
      expect(
        _isInsideAdmittedBranch(bootstrap, callIndex, 'networkServicesAdmitted'),
        isTrue,
        reason: '$call must be skipped while Android starts into an already user-active VPN session',
      );
    }

    final deferredPlatformServices = _sourceSection(
      bootstrap,
      'Future<void> _warmUpDeferredPlatformServices(bool debug) async {',
      '\nFuture<void> _waitForUiIdle',
    );
    final periodicRefreshRegistration = bootstrap.indexOf('initializeProfilesBackgroundRefresh(debug: debug)');
    expect(
      deferredPlatformServices,
      contains('initializeProfilesBackgroundRefresh(debug: debug)'),
      reason: 'Android registers periodic subscription refresh regardless of current VPN connection state',
    );
    expect(
      periodicRefreshRegistration,
      greaterThanOrEqualTo(0),
      reason: 'the periodic worker must be registered during deferred platform warm-up',
    );
    expect(
      _isInsideAdmittedBranch(bootstrap, periodicRefreshRegistration, 'networkServicesAdmitted'),
      isFalse,
      reason:
          'local WorkManager registration does not open network work and must not be withheld until route admission',
    );
    final deferredPlatformWarmup = bootstrap.indexOf('unawaited(_warmUpDeferredPlatformServices(debug));');
    expect(deferredPlatformWarmup, greaterThanOrEqualTo(0));
    expect(
      _isInsideAdmittedBranch(bootstrap, deferredPlatformWarmup, 'networkServicesAdmitted'),
      isFalse,
      reason: 'deferred platform warm-up must reach local worker registration regardless of VPN state',
    );

    expect(
      bootstrap,
      isNot(contains('Firebase.initializeApp(')),
      reason: 'bootstrap must never initialize Firebase before Android verifies a VPN route',
    );

    final coreInterface = File('lib/martencore/core_interface/core_interface.dart').readAsStringSync();
    final mobileCoreInterface = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final coreService = File('lib/martencore/marten_core_service.dart').readAsStringSync();
    expect(coreInterface, contains('Future<int?> tryJoinVerifiedVpnAdmission()'));
    expect(
      mobileCoreInterface,
      contains('methodChannel.invokeMethod<int>("try_join_verified_vpn_admission")'),
      reason: 'the retained join must remain a native authoritative query, not cached Dart state',
    );
    expect(
      coreService,
      contains('Future<int?> tryJoinVerifiedVpnAdmission() => core.tryJoinVerifiedVpnAdmission();'),
      reason: 'bootstrap must invoke the CoreInterface counterpart through MartenCoreService',
    );

    final workerFactory = File(
      'android/app/src/main/kotlin/app/marten/client/bg/StrictVpnWorkerFactory.kt',
    ).readAsStringSync();
    final routeAdmission = workerFactory.indexOf('NativeCrashDiagnostics.isNetworkAdmissionAllowed()');
    final verifiedRoute = workerFactory.indexOf(
      'BoxService.hasVerifiedRouteForOptionalBackgroundWork()',
      routeAdmission,
    );
    final terminalAdmission = workerFactory.indexOf(
      'BoxService.hasTerminalOrdinaryNetworkAdmissionForOptionalBackgroundWork()',
      verifiedRoute,
    );
    final admissionDecision = workerFactory.indexOf(
      'if (isStopped || (!verifiedVpnRoute && !terminalOrdinaryNetwork))',
      terminalAdmission,
    );
    final retry = workerFactory.indexOf('Futures.immediateFuture(Result.retry())', admissionDecision);
    final flutterDelegate = workerFactory.indexOf('BackgroundWorker(applicationContext, workerParameters)');
    expect(routeAdmission, greaterThanOrEqualTo(0));
    expect(
      verifiedRoute,
      greaterThan(routeAdmission),
      reason: 'network admission must combine native permission with an exact route-ready process state',
    );
    expect(
      terminalAdmission,
      greaterThan(verifiedRoute),
      reason: 'headless work may also run after exact terminal ordinary-network release',
    );
    expect(
      admissionDecision,
      greaterThan(terminalAdmission),
      reason: 'headless work retries unless the exact route or terminal admission is true',
    );
    expect(retry, greaterThan(admissionDecision));
    expect(
      flutterDelegate,
      greaterThan(retry),
      reason:
          'WorkManager local initialization is allowed, but it must retry before creating headless Dart work without route proof',
    );

    final profileRefreshService = File('lib/features/profile/data/profile_auto_update_service.dart').readAsStringSync();
    final refreshBody = _sourceSection(
      profileRefreshService,
      'Future<ProfileAutoUpdateResult?> _performProfileUpdate(',
      '\n  void _logRefreshFailure',
    ).replaceAll(RegExp(r'\s+'), '');
    expect(
      refreshBody,
      contains(
        "_egressAdmission.runWhenAdmitted('subscriptionrefresh',()=>profilesRepo.refreshRemote(profile,validate:request.validate,cancelToken:cancelToken).run(),)",
      ),
      reason: 'a registered worker may perform subscription networking only through strict VPN admission',
    );
    final connectionNotifier = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final routeAdmittedStartup = _sourceSection(
      connectionNotifier,
      'Future<void> _startAndroidNetworkServicesAfterVerifiedRoute() async {',
      '\n  void _abortConnectionImmediately()',
    );
    expect(
      routeAdmittedStartup,
      contains('await initializeProfilesBackgroundRefresh(debug: ref.read(debugModeNotifierProvider));'),
      reason: 'the live Android route-admission path also registers periodic refresh after route verification',
    );
  });

  test('local crash report capture has no idle retry timer or polling loop', () {
    final reporter = File('lib/core/analytics/analytics_logger.dart').readAsStringSync();
    final store = File('lib/core/analytics/pending_crash_report.dart').readAsStringSync();
    expect(reporter, isNot(matches(RegExp(r'\bTimer(?:\.periodic)?\s*\('))));
    expect(reporter, isNot(contains('Future.delayed(')));
    expect(reporter, isNot(matches(RegExp(r'\b(?:while|for)\s*\(\s*true\s*\)'))));
    expect(store, isNot(matches(RegExp(r'\bTimer(?:\.periodic)?\s*\('))));
    expect(store, isNot(contains('Future.delayed(')));
    expect(store, isNot(matches(RegExp(r'\b(?:while|for)\s*\(\s*true\s*\)'))));
  });

  test('manual Flutter connection admits the VPN before publishing intent or opening the repository', () {
    final notifier = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final connect = _sourceSection(notifier, 'Future<bool> _connectThrottled(', '\n  Future<bool> _disconnect(');
    final egressGate = connect.indexOf(
      "final egressSeal = _sealAndroidOrdinaryNetworking('manual or automatic Connect');",
    );
    final handoffAcceptance = connect.indexOf('final handoffAcceptance = onConnectTransitionSealed?.call();');
    final egressAwait = connect.indexOf('egressEpoch = await egressSeal;');
    final leaseFuture = connect.indexOf('final startLeaseFuture = Platform.isAndroid');
    final leaseClaim = connect.indexOf('handoffAcceptance ?? connectionRepo.claimVpnStartLease()', leaseFuture);
    final leaseAwait = connect.indexOf('explicitStartLease = await startLeaseFuture;', egressAwait);
    final rejectedHandoff = connect.indexOf('if (Platform.isAndroid && explicitStartLease == null)');
    final rejectedReturn = connect.indexOf('return false;', rejectedHandoff);
    final activeProfile = connect.indexOf('final activeProfile = await activeProfileFuture;');
    final admission = connect.indexOf('.beginVpnStartAdmission(');
    final admissionLease = connect.indexOf('explicitStartLease: explicitStartLease', admission);
    final nativeHandoffClaim = connect.indexOf('nativeHandoffClaim: handoffAcceptance != null', admissionLease);
    final intent = connect.indexOf('await startedByUserNotifier.update(true);');
    final repositoryConnect = connect.indexOf('connectionRepo.connect(', intent);
    expect(
      egressGate,
      greaterThanOrEqualTo(0),
      reason: 'manual Connect must synchronously request Dart egress quiescence before Android VPN admission',
    );
    expect(
      handoffAcceptance,
      greaterThan(egressGate),
      reason: 'the post-seal handoff acknowledgement must be captured only after synchronous egress sealing',
    );
    expect(
      egressAwait,
      greaterThan(egressGate),
      reason: 'native admission must wait for the egress quiesce barrier to drain',
    );
    expect(
      leaseAwait,
      greaterThan(egressAwait),
      reason: 'native admission must await its exact explicit-start lease after the egress barrier drains',
    );
    expect(
      leaseFuture,
      greaterThan(egressGate),
      reason: 'every Android manual connect must claim an exact native start lease before profile work',
    );
    expect(
      leaseClaim,
      greaterThan(leaseFuture),
      reason: 'a non-handoff Flutter start must synchronously claim its own native lease',
    );
    expect(
      rejectedHandoff,
      greaterThan(leaseAwait),
      reason: 'native admission requires an awaited positive exact handoff lease',
    );
    expect(
      rejectedReturn,
      greaterThan(rejectedHandoff),
      reason: 'a missing/stale lease must reject the attempt before any native VPN start',
    );
    expect(activeProfile, greaterThan(rejectedReturn));
    expect(
      admission,
      greaterThan(activeProfile),
      reason: 'native admission must follow the egress quiesce barrier and accepted handoff',
    );
    expect(admissionLease, greaterThan(admission));
    expect(
      nativeHandoffClaim,
      greaterThan(admissionLease),
      reason: 'only a live native handoff may consume bridge ownership; ordinary UI leases remain exact but unclaimed',
    );
    final cancellationFinally = connect.indexOf(
      'if (nativeClaimNeedsCancellation && explicitStartLease != null)',
      admission,
    );
    final cancelExactLease = connect.indexOf('await cancelStartLease(explicitStartLease);', cancellationFinally);
    expect(
      cancellationFinally,
      greaterThan(admission),
      reason: 'an activeProfileFuture exception must reach the exact-lease cleanup finally block',
    );
    expect(
      cancelExactLease,
      greaterThan(cancellationFinally),
      reason:
          'every pre-admission exception, including activeProfileFuture failure, must cancel its exact claimed native lease',
    );
    expect(
      intent,
      greaterThan(admission),
      reason: 'Flutter may persist started_by_user only after VPN admission succeeds',
    );
    expect(
      repositoryConnect,
      greaterThan(intent),
      reason: 'repository setup/connect must remain behind the admitted intent transition',
    );
    final admissionEpoch = connect.indexOf('(admissionEpoch) => TaskEither.tryCatch', admission);
    final forwardedEpoch = connect.indexOf('androidVpnStartEpoch: admissionEpoch', repositoryConnect);
    expect(
      admissionEpoch,
      greaterThan(admission),
      reason: 'the exact Android admission epoch must be retained through the async handoff',
    );
    expect(
      forwardedEpoch,
      greaterThan(repositoryConnect),
      reason: 'repository connect must receive the exact admitted epoch, not infer user intent again',
    );

    final mobile = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final nativeAdmission = _sourceSection(
      mobile,
      'Future<int?> beginVpnStartAdmission(',
      '\n  Future<HelloResponse> _connectOrStartForegroundCore',
    );
    final invoke = nativeAdmission.indexOf('methodChannel.invokeMethod<int>("begin_vpn_start_admission"');
    final leaseArgument = nativeAdmission.indexOf(
      'if (explicitStartLease != null) "explicitStartLease": explicitStartLease',
      invoke,
    );
    expect(
      leaseArgument,
      greaterThan(invoke),
      reason: 'the mobile interface must forward the exact native-start lease, not a cached Flutter boolean',
    );
    expect(
      nativeAdmission,
      contains('bool nativeHandoffClaim = false'),
      reason: 'ordinary Flutter UI admission and bridged native handoff must remain distinguishable',
    );
    expect(
      nativeAdmission,
      contains('if (nativeHandoffClaim) "nativeHandoffClaim": true'),
      reason: 'only an actual bridge handoff may ask Android to consume the bridge claim',
    );
    expect(
      nativeAdmission,
      isNot(contains('stop()')),
      reason: 'a prepared manual admission must not tear down its full-route blocker',
    );

    final cancellation = connect.indexOf("VPN start was superseded while publishing admitted intent");
    final clearIntent = connect.lastIndexOf('await startedByUserNotifier.update(false);', cancellation);
    final cancelDisconnect = connect.lastIndexOf('await connectionRepo.disconnect().run();', cancellation);
    expect(
      cancellation,
      greaterThan(intent),
      reason: 'manual cancellation must be checked while publishing admitted Flutter intent',
    );
    expect(clearIntent, greaterThan(intent), reason: 'cancelled admission must clear started_by_user');
    expect(
      cancelDisconnect,
      greaterThan(clearIntent),
      reason: 'cancelled admission must authoritatively disconnect the prepared VPN service',
    );

    final ordinaryFailure = connect.indexOf("final cleanup = await connectionRepo.disconnect().run();", cancellation);
    final terminalIntent = connect.indexOf('await startedByUserNotifier.update(false);', ordinaryFailure);
    final terminalUi = connect.indexOf('state = AsyncData(Disconnected(err));', terminalIntent);
    final terminalDialog = connect.indexOf('dialogNotifier.showCustomAlertFromErr', terminalUi);
    expect(
      ordinaryFailure,
      greaterThan(cancellation),
      reason: 'ordinary Connect failure must release the admitted service',
    );
    expect(terminalIntent, greaterThan(ordinaryFailure), reason: 'terminal UI intent follows authoritative disconnect');
    expect(terminalUi, greaterThan(terminalIntent));
    expect(terminalDialog, greaterThan(terminalUi));
  });

  test('Android carries the exact admitted user-session epoch through core setup and MethodChannel start', () {
    final repository = File('lib/features/connection/data/connection_repository.dart').readAsStringSync();
    final coreService = File('lib/martencore/marten_core_service.dart').readAsStringSync();
    final mobile = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();

    final repositoryConnect = _sourceSection(
      repository,
      '@override\n  TaskEither<ConnectionFailure, Unit> connect(',
      '\n  TaskEither<ConnectionFailure, Unit> disconnect',
    );
    expect(repositoryConnect, contains('int? androidVpnStartEpoch'));
    expect(repositoryConnect, contains('androidVpnStartEpoch: androidVpnStartEpoch'));

    final coreStart = _sourceSection(
      coreService,
      'TaskEither<ConnectionFailure, Unit> start(',
      '\n  TaskEither<String, Unit> stop',
    );
    expect(coreStart, contains('int? androidVpnStartEpoch'));
    expect(coreStart, contains('androidVpnStartEpoch: androidVpnStartEpoch'));

    final setup = _sourceSection(
      mobile,
      'Future<BackgroundCoreSetupResult> setupBackground(',
      '\n  Future<void> _invokeBackgroundStartAndWait',
    );
    final setupEpoch = setup.indexOf('int? androidVpnStartEpoch');
    final setupForward = setup.indexOf('androidVpnStartEpoch: androidVpnStartEpoch');
    expect(setupEpoch, greaterThanOrEqualTo(0));
    expect(setupForward, greaterThan(setupEpoch));

    final invoke = _sourceSection(
      mobile,
      'Future<void> _invokeBackgroundStart(',
      '\n  Future<bool> _matchesActiveConfigGeneration',
    );
    final invokeEpoch = invoke.indexOf('int? androidVpnStartEpoch');
    final channelEpoch = invoke.indexOf('"userSessionEpoch": androidVpnStartEpoch');
    expect(invokeEpoch, greaterThanOrEqualTo(0));
    expect(
      channelEpoch,
      greaterThan(invokeEpoch),
      reason: 'the MethodChannel start request must carry the exact epoch returned by admission',
    );
  });

  test('manual Android admission claims and cancels one exact native start lease', () {
    final notifier = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final mobile = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final connect = _sourceSection(notifier, 'Future<bool> _connectThrottled(', '\n  Future<bool> _disconnect(');

    final leaseFuture = connect.indexOf('final startLeaseFuture = Platform.isAndroid');
    final ownClaim = connect.indexOf('handoffAcceptance ?? connectionRepo.claimVpnStartLease()', leaseFuture);
    final awaitLease = connect.indexOf('explicitStartLease = await startLeaseFuture;', ownClaim);
    final rejectMissing = connect.indexOf('if (Platform.isAndroid && explicitStartLease == null)', awaitLease);
    final profile = connect.indexOf('final activeProfile = await activeProfileFuture;');
    final admission = connect.indexOf('.beginVpnStartAdmission(');
    final finallyCancel = connect.indexOf('if (nativeClaimNeedsCancellation && explicitStartLease != null)', admission);
    final exactCancel = connect.indexOf('await cancelStartLease(explicitStartLease);', finallyCancel);
    expect(leaseFuture, greaterThanOrEqualTo(0));
    expect(ownClaim, greaterThan(leaseFuture));
    expect(awaitLease, greaterThan(ownClaim));
    expect(
      rejectMissing,
      greaterThan(awaitLease),
      reason: 'a cancelled or terminally stale lease must reject before profile/config work',
    );
    expect(profile, greaterThan(rejectMissing));
    expect(admission, greaterThan(profile));
    expect(finallyCancel, greaterThan(admission));
    expect(exactCancel, greaterThan(finallyCancel));

    final claim = _sourceSection(
      mobile,
      'Future<int?> claimVpnStartLease() async',
      '\n  @override\n  Future<void> cancelVpnStartLease',
    );
    final cancel = _sourceSection(
      mobile,
      'Future<void> cancelVpnStartLease(int token) async',
      '\n  @override\n  Future<int?> beginVpnStartAdmission',
    );
    expect(claim, contains('methodChannel.invokeMethod<int>("claim_vpn_start_lease")'));
    expect(cancel, contains('methodChannel.invokeMethod<bool>("cancel_vpn_start_lease", token)'));
  });

  test('a Connect superseded while waiting for its profile never reaches native admission or terminal cleanup', () {
    final notifier = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final connect = _sourceSection(notifier, 'Future<bool> _connectThrottled(', '\n  Future<bool> _disconnect(');

    final activeProfile = connect.indexOf('final activeProfile = await activeProfileFuture;');
    final superseded = connect.indexOf('if (_manualDisconnectRequested || _showIdleDuringAbort ||', activeProfile);
    final supersededReturn = connect.indexOf('return false;', superseded);
    final nullProfile = connect.indexOf('if (activeProfile == null)', supersededReturn);
    final admission = connect.indexOf('.beginVpnStartAdmission(', nullProfile);
    final supersededBranch = connect.substring(superseded, nullProfile);
    final leaseConsumed = connect.indexOf('nativeClaimNeedsCancellation = false;', admission);
    final finallyCancellation = connect.indexOf(
      'if (nativeClaimNeedsCancellation && explicitStartLease != null)',
      admission,
    );
    final exactCancel = connect.indexOf('await cancelStartLease(explicitStartLease);', finallyCancellation);

    expect(activeProfile, greaterThanOrEqualTo(0));
    expect(
      superseded,
      greaterThan(activeProfile),
      reason: 'a manual Stop/idle/token supersession must be rechecked immediately after profile await',
    );
    expect(
      supersededReturn,
      greaterThan(superseded),
      reason: 'the stale pre-admission attempt must return false rather than publish intent or start VPN',
    );
    expect(nullProfile, greaterThan(supersededReturn));
    expect(
      admission,
      greaterThan(nullProfile),
      reason: 'the supersede check must precede both null-profile cleanup and native VPN admission',
    );
    expect(supersededBranch, contains('_showIdleDuringAbort'));
    expect(supersededBranch, contains('requestToken != null && requestToken != _abortToken'));
    expect(
      supersededBranch,
      isNot(contains('startedByUserNotifier.update(false)')),
      reason: 'the pre-admission stale path must not mutate terminal intent owned by the Stop path',
    );
    expect(supersededBranch, isNot(contains('connectionRepo.disconnect().run()')));
    expect(supersededBranch, isNot(contains('_releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect')));
    expect(supersededBranch, isNot(contains('.beginVpnStartAdmission(')));
    expect(
      leaseConsumed,
      greaterThan(admission),
      reason: 'only a successful native admission may consume the exact lease',
    );
    expect(
      finallyCancellation,
      greaterThan(admission),
      reason: 'a pre-admission return must leave the exact lease under finally cancellation ownership',
    );
    expect(exactCancel, greaterThan(finallyCancellation));
  });

  test('strict egress seal always drains process-wide native probes before isolate-local retirees', () {
    final gate = File('lib/core/network/strict_vpn_egress_gate.dart').readAsStringSync();
    final retireAndDrain = _sourceSection(
      gate,
      'Future<void> _retireAndDrain() async',
      '\n  Future<bool> _openForCurrentTransition',
    );
    final firstNativeCancel = retireAndDrain.indexOf("'cancel_local_probes'");
    final keepBlocked = retireAndDrain.indexOf("'keepBlocked': true", firstNativeCancel);
    final localRetirees = retireAndDrain.indexOf(
      'for (final retire in List<StrictVpnEgressRetirer>.of(_retirers.values))',
    );
    final activeRetirees = retireAndDrain.indexOf(
      'for (final operation in List<_ActiveEgressOperation>.of(_activeOperations))',
      localRetirees,
    );
    final waitForActive = retireAndDrain.indexOf('while (_activeOperations.isNotEmpty)', activeRetirees);
    final finalEpochCapture = retireAndDrain.indexOf('final nativeBlockEpoch = await', waitForActive);
    final finalNativeCancel = retireAndDrain.indexOf("'cancel_local_probes'", finalEpochCapture);
    final persistNewestEpoch = retireAndDrain.indexOf('_nativeBlockEpoch = nativeBlockEpoch;', finalNativeCancel);
    expect(firstNativeCancel, greaterThanOrEqualTo(0));
    expect(keepBlocked, greaterThan(firstNativeCancel));
    expect(
      localRetirees,
      greaterThan(keepBlocked),
      reason: 'the process-wide Android drain must run even when this Flutter isolate has no locally registered probe',
    );
    expect(activeRetirees, greaterThan(localRetirees));
    expect(waitForActive, greaterThan(activeRetirees));
    expect(
      finalNativeCancel,
      greaterThan(finalEpochCapture),
      reason: 'the final native drain must obtain the newest block epoch after every local retire/join',
    );
    expect(
      persistNewestEpoch,
      greaterThan(finalNativeCancel),
      reason: 'the final native block epoch, not an early drain result, owns a later allow request',
    );
    expect(retireAndDrain, contains('await _strictVpnNativeMethodChannel'));

    final handler = File('android/app/src/main/kotlin/app/marten/client/MethodHandler.kt').readAsStringSync();
    final nativeDrain = _sourceSection(
      handler,
      'private suspend fun cancelLocalProbes(keepBlocked: Boolean)',
      '\n\n    private suspend fun allowLocalProbes',
    );
    final blockDrain = nativeDrain.indexOf('LocalProbeAdmission.beginBlockTransitionAndDrain()');
    final conditionalAllow = nativeDrain.indexOf('if (!keepBlocked)', blockDrain);
    final allowWithEpoch = nativeDrain.indexOf('allowLocalProbes(blockEpoch)', conditionalAllow);
    final returnEpoch = nativeDrain.indexOf('return blockEpoch', allowWithEpoch);
    expect(blockDrain, greaterThanOrEqualTo(0));
    expect(
      conditionalAllow,
      greaterThan(blockDrain),
      reason: 'keepBlocked=true must leave physical TLS/ICMP admission closed after the exact drain',
    );
    expect(
      allowWithEpoch,
      greaterThan(conditionalAllow),
      reason: 'a non-strict profile clear may reopen only with the exact epoch it just blocked',
    );
    expect(returnEpoch, greaterThan(allowWithEpoch));
    expect(nativeDrain, contains('private suspend fun cancelLocalProbes(keepBlocked: Boolean): Long'));
  });

  test('Android strict egress sealing and admission are epoch-owned across persistence', () {
    final notifier = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final build = _sourceSection(
      notifier,
      'Stream<ConnectionStatus> build() async* {',
      '\n  ConnectionRepository get _connectionRepo',
    );
    final platformTransition = _sourceSection(
      build,
      'if (Platform.isAndroid) {\n        if (nextStatus is Connected)',
      '\n      if (nextStatus is Disconnected',
    );
    final terminalPlatformDisconnect = _sourceSection(
      build,
      'if (nextStatus is Disconnected && previousStatus is! Disconnected) {',
      '\n      if (shouldResetTransientConnectionFeatures(',
    );
    final synchronizeTerminalIntent = _sourceSection(
      notifier,
      'Future<void> _synchronizeAndroidTerminalUserIntent({ConnectionRepository? repository}) async',
      '\n  Future<void> abortConnection',
    );
    final connect = _sourceSection(notifier, 'Future<bool> _connectThrottled(', '\n  Future<bool> _disconnect(');
    final seal = _sourceSection(
      notifier,
      'Future<int?> _sealAndroidOrdinaryNetworking(',
      '\n  Future<void> _releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect',
    );
    final ensure = _sourceSection(
      notifier,
      'Future<void> _ensureAndroidOrdinaryNetworkingSealed(',
      '\n  Future<void> _releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect',
    );
    final adoptBootstrapSeal = _sourceSection(
      notifier,
      'void _adoptBootstrapAndroidEgressSeal()',
      '\n  Future<void> _releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect',
    );
    final release = _sourceSection(
      notifier,
      'Future<void> _releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect({int? expectedEpoch}) async',
      '\n  bool _ownsCurrentAndroidEgressEpoch',
    );
    final ownership = _sourceSection(
      notifier,
      'bool _ownsCurrentAndroidEgressEpoch(int? epoch)',
      '\n  Future<void> _admitAndroidOrdinaryNetworking',
    );
    final admit = _sourceSection(
      notifier,
      'Future<void> _admitAndroidOrdinaryNetworking(int? epoch)',
      '\n  void _abortConnectionImmediately',
    );
    final sdkServices = _sourceSection(
      notifier,
      'Future<void> _startAndroidNetworkServicesAfterVerifiedRoute()',
      '\n  void _abortConnectionImmediately',
    );
    final disconnect = _sourceSection(
      notifier,
      'Future<bool> _disconnect(',
      '\n  Future<int?> _sealAndroidOrdinaryNetworking',
    );

    final gateSeal = seal.indexOf('strictVpnEgressGate.sealForVpnTransition()');
    final epoch = seal.indexOf('final epoch = ++_androidEgressEpoch;', gateSeal);
    final firstAwait = seal.indexOf('await ', gateSeal);
    final clearVerified = seal.indexOf('Preferences.strictVpnRouteVerified.notifier).update(false)', firstAwait);
    expect(gateSeal, greaterThanOrEqualTo(0));
    expect(epoch, greaterThan(gateSeal), reason: 'sealing must capture a new epoch synchronously with the transition');
    expect(
      firstAwait,
      greaterThan(epoch),
      reason: 'the gate must seal before any await or preference write can permit ordinary networking',
    );
    expect(clearVerified, greaterThanOrEqualTo(firstAwait));
    expect(
      connect,
      contains("final egressSeal = _sealAndroidOrdinaryNetworking('manual or automatic Connect');"),
      reason: 'each manual or automatic Connect remains an independent transition with its own epoch',
    );

    final bootstrapAdopt = build.indexOf('_adoptBootstrapAndroidEgressSeal();');
    final bootstrapFirstAwait = build.indexOf('await ');
    expect(
      bootstrapAdopt,
      greaterThanOrEqualTo(0),
      reason: 'the notifier must adopt a cold-bootstrap egress seal before awaiting platform bootstrap work',
    );
    expect(bootstrapFirstAwait, greaterThan(bootstrapAdopt));
    expect(
      adoptBootstrapSeal,
      contains(
        'if (!Platform.isAndroid || !strictVpnEgressGate.isSealed || _androidPlatformTransitionEgressEpoch != null)',
      ),
      reason: 'only an unowned, already sealed Android bootstrap transition may be adopted',
    );
    final bootstrapOwner = adoptBootstrapSeal.indexOf('_androidPlatformTransitionEgressEpoch = _androidEgressEpoch;');
    expect(
      bootstrapOwner,
      greaterThanOrEqualTo(0),
      reason: 'bootstrap adoption must retain the current exact epoch for authoritative terminal release',
    );
    expect(
      adoptBootstrapSeal,
      isNot(contains('++_androidEgressEpoch')),
      reason: 'adopting a preexisting bootstrap seal must not manufacture a competing Connect epoch',
    );
    expect(
      adoptBootstrapSeal,
      isNot(contains('sealForVpnTransition')),
      reason: 'bootstrap adoption owns an already-drained gate rather than resealing it',
    );

    final platformEnsure = platformTransition.indexOf(
      "unawaited(_ensureAndroidOrdinaryNetworkingSealed('platform status \${nextStatus.runtimeType}'));",
    );
    expect(platformEnsure, greaterThanOrEqualTo(0));
    expect(
      platformTransition,
      contains('nextStatus is Connecting || (nextStatus is Disconnecting && previousStatus is! Disconnected)'),
      reason: 'Connecting and only a pre-terminal Disconnecting frame may reinforce the existing egress seal',
    );
    expect(
      platformTransition,
      isNot(contains('_sealAndroidOrdinaryNetworking(')),
      reason: 'a Connecting/Disconnecting status must not advance the explicit transition epoch again',
    );
    final staleDisconnecting = platformTransition.indexOf('else if (nextStatus is Disconnecting) {');
    final staleDisconnectingLog = platformTransition.indexOf(
      "loggy.info('ignoring stale platform Disconnecting after authoritative Disconnected');",
      staleDisconnecting,
    );
    expect(staleDisconnecting, greaterThan(platformEnsure));
    expect(
      staleDisconnectingLog,
      greaterThan(staleDisconnecting),
      reason:
          'a Disconnecting frame immediately after authoritative Disconnected is stale rather than a new transition',
    );
    expect(
      platformTransition.substring(staleDisconnecting),
      isNot(contains('_ensureAndroidOrdinaryNetworkingSealed(')),
      reason: 'stale Disconnecting must not reseal or mint a newer epoch after terminal release',
    );
    expect(
      ensure,
      contains('if (!Platform.isAndroid || strictVpnEgressGate.isSealed) return;'),
      reason: 'status reinforcement must short-circuit off Android and for an already sealed transition',
    );
    expect(
      ensure,
      contains('final sealOperation = _sealAndroidOrdinaryNetworking(reason);'),
      reason: 'an unsealed Android status transition must still establish its initial seal',
    );
    final ensureSeal = ensure.indexOf('final sealOperation = _sealAndroidOrdinaryNetworking(reason);');
    final ensurePlatformEpoch = ensure.indexOf(
      '_androidPlatformTransitionEgressEpoch = _androidEgressEpoch;',
      ensureSeal,
    );
    final ensureAwait = ensure.indexOf('await sealOperation;', ensurePlatformEpoch);
    expect(ensureSeal, greaterThanOrEqualTo(0));
    expect(
      ensurePlatformEpoch,
      greaterThan(ensureSeal),
      reason: 'the platform-owned epoch must be captured after synchronous seal minting',
    );
    expect(
      ensureAwait,
      greaterThan(ensurePlatformEpoch),
      reason: 'the exact platform epoch must be retained before the asynchronous seal completes',
    );
    expect(
      ensure,
      isNot(contains('++_androidEgressEpoch')),
      reason: 'ensure is a join operation and cannot mint a competing egress epoch itself',
    );

    final terminalPlatformEpoch = terminalPlatformDisconnect.indexOf(
      'final platformEgressEpoch = _androidPlatformTransitionEgressEpoch;',
    );
    final clearTerminalPlatformEpoch = terminalPlatformDisconnect.indexOf(
      '_androidPlatformTransitionEgressEpoch = null;',
      terminalPlatformEpoch,
    );
    final terminalPlatformRelease = terminalPlatformDisconnect.indexOf(
      '_releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: platformEgressEpoch)',
      clearTerminalPlatformEpoch,
    );
    expect(terminalPlatformEpoch, greaterThanOrEqualTo(0));
    expect(
      clearTerminalPlatformEpoch,
      greaterThan(terminalPlatformEpoch),
      reason: 'authoritative Disconnected must take and clear the one platform-owned epoch exactly once',
    );
    expect(
      terminalPlatformRelease,
      greaterThan(clearTerminalPlatformEpoch),
      reason: 'authoritative platform Stop must release the exact retained epoch after clearing its ownership slot',
    );

    final terminalEpochCapture = synchronizeTerminalIntent.indexOf('final terminalEgressEpoch = _androidEgressEpoch;');
    final nativeIntentRead = synchronizeTerminalIntent.indexOf(
      'await (repository ?? _connectionRepo).readPlatformStartedByUser();',
      terminalEpochCapture,
    );
    final postReadEpochGuard = synchronizeTerminalIntent.indexOf(
      'if (terminalEgressEpoch != _androidEgressEpoch ||',
      nativeIntentRead,
    );
    final disconnectedGuard = synchronizeTerminalIntent.indexOf(
      'state.valueOrNull is! Disconnected',
      postReadEpochGuard,
    );
    final manualConnectGuard = synchronizeTerminalIntent.indexOf('_manualConnectPending', disconnectedGuard);
    final nativeConnectGuard = synchronizeTerminalIntent.indexOf('_nativeConnectRequestPending', manualConnectGuard);
    final postReadReturn = synchronizeTerminalIntent.indexOf('return;', nativeConnectGuard);
    final terminalIntentUpdate = synchronizeTerminalIntent.indexOf(
      'Preferences.startedByUser.notifier).update(false)',
      postReadReturn,
    );
    expect(terminalEpochCapture, greaterThanOrEqualTo(0));
    expect(
      nativeIntentRead,
      greaterThan(terminalEpochCapture),
      reason: 'terminal synchronization must capture its egress epoch before its asynchronous native-intent read',
    );
    expect(
      postReadEpochGuard,
      greaterThan(nativeIntentRead),
      reason: 'terminal synchronization must reject a newer lifecycle epoch after the native read returns',
    );
    expect(
      disconnectedGuard,
      greaterThan(postReadEpochGuard),
      reason: 'terminal intent may change only while the visible state is still authoritative Disconnected',
    );
    expect(manualConnectGuard, greaterThan(disconnectedGuard));
    expect(
      nativeConnectGuard,
      greaterThan(manualConnectGuard),
      reason: 'neither a manual nor native Connect pending state may be overwritten by stale terminal synchronization',
    );
    expect(postReadReturn, greaterThan(nativeConnectGuard));
    expect(
      terminalIntentUpdate,
      greaterThan(postReadReturn),
      reason:
          'the started-by-user preference must remain unchanged until every post-await terminal ownership guard succeeds',
    );

    final disconnectSeal = disconnect.indexOf(
      "final egressEpoch = await _sealAndroidOrdinaryNetworking('Disconnect');",
    );
    final disconnectRepository = disconnect.indexOf(
      'final result = await connectionRepo.disconnect().run();',
      disconnectSeal,
    );
    final disconnectMatch = disconnect.indexOf('await result.match(', disconnectRepository);
    final disconnectEgressReleased = disconnect.indexOf('var egressReleased = !Platform.isAndroid;', disconnectSeal);
    final disconnectTryRelease = disconnect.indexOf(
      'egressReleased = await _tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: egressEpoch);',
      disconnectRepository,
    );
    final disconnectReturn = disconnect.indexOf('return result.isRight() && egressReleased;', disconnectRepository);
    final disconnectVoidRelease = disconnect.indexOf(
      '_releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: egressEpoch)',
      disconnectRepository,
    );
    expect(
      disconnectSeal,
      greaterThanOrEqualTo(0),
      reason: 'an explicit Disconnect must capture the epoch of its own direct seal',
    );
    expect(disconnectRepository, greaterThan(disconnectSeal));
    expect(
      disconnectMatch,
      greaterThan(disconnectRepository),
      reason: 'terminal disconnect ownership checks must await the repository run result before release bookkeeping',
    );
    expect(
      disconnectEgressReleased,
      greaterThan(disconnectSeal),
      reason: 'a Disconnect should track release success explicitly on all platforms',
    );
    expect(
      disconnectTryRelease,
      greaterThan(disconnectEgressReleased),
      reason:
          'the terminal Disconnect success branch must capture its own sealed epoch in the bool-returning release attempt',
    );
    expect(
      disconnectReturn,
      greaterThan(disconnectTryRelease),
      reason: 'Disconnect result should require both repository completion and epoch-gated ordinary egress release',
    );
    expect(
      disconnectMatch,
      lessThan(disconnectReturn),
      reason: 'the final Disconnect result must be returned after matching repository and egress-release outcomes',
    );
    expect(
      disconnectVoidRelease,
      lessThan(0),
      reason: '_disconnect must not discard egress-release failure through the void helper',
    );

    expect(
      notifier,
      contains(
        'final egressEpoch = _androidEgressEpoch;\n          unawaited(_admitAndroidOrdinaryNetworking(egressEpoch));',
      ),
      reason: 'a Connected platform status must capture its exact current epoch before scheduling admission',
    );
    expect(
      notifier,
      contains('_admitAndroidOrdinaryNetworking(egressEpoch)'),
      reason: 'successful Connect/reconnect paths must forward their captured seal epoch',
    );
    expect(
      notifier,
      isNot(contains('_admitAndroidOrdinaryNetworking()')),
      reason: 'no admit may use an unowned implicit epoch',
    );

    final clearAdmittedPlatformEpoch = admit.indexOf('if (_androidPlatformTransitionEgressEpoch == epoch) {');
    final admittedPlatformEpochCleared = admit.indexOf(
      '_androidPlatformTransitionEgressEpoch = null;',
      clearAdmittedPlatformEpoch,
    );
    expect(
      clearAdmittedPlatformEpoch,
      greaterThanOrEqualTo(0),
      reason: 'a successful Connected admission may retire only its matching platform transition epoch',
    );
    expect(admittedPlatformEpochCleared, greaterThan(clearAdmittedPlatformEpoch));
    expect(
      _sourceSection(
        admit,
        'if (_androidPlatformTransitionEgressEpoch == epoch) {',
        "\n    loggy.info('ordinary Marten networking admitted through verified Android VPN route epoch=\$epoch');",
      ),
      contains('_androidPlatformTransitionEgressEpoch = null;'),
      reason: 'a newer platform epoch must survive an older Connected admission',
    );

    expect(ownership, contains('epoch == _androidEgressEpoch'));
    expect(ownership, contains('state.valueOrNull is Connected'));
    expect(
      ownership,
      isNot(contains('isCoreStartedSnapshot')),
      reason:
          'Connected platform state owns Android ordinary-egress admission; a lagging runtime-core snapshot must not strand a recovered VPN generation behind its sealed gate',
    );
    expect(ownership, contains('!_manualDisconnectRequested'));
    expect(ownership, contains('!_showIdleDuringAbort'));

    final ownershipBeforeOpen = admit.indexOf('if (!_ownsCurrentAndroidEgressEpoch(epoch))');
    final openGate = admit.indexOf('strictVpnEgressGate.admitVerifiedVpnRoute()');
    final persistVerified = admit.indexOf('Preferences.strictVpnRouteVerified.notifier).update(true)');
    final postPersistRecheck = admit.indexOf(
      'if (!_ownsCurrentAndroidEgressEpoch(epoch) || strictVpnEgressGate.isSealed)',
      persistVerified,
    );
    final clearStaleProof = postPersistRecheck < 0
        ? -1
        : admit.indexOf('Preferences.strictVpnRouteVerified.notifier).update(false)', postPersistRecheck);
    final staleReturn = clearStaleProof < 0 ? -1 : admit.indexOf('return;', clearStaleProof);
    final sdkStart = admit.indexOf('_startAndroidNetworkServicesAfterVerifiedRoute()');
    expect(ownershipBeforeOpen, greaterThanOrEqualTo(0));
    expect(
      openGate,
      greaterThan(ownershipBeforeOpen),
      reason: 'stale epoch, non-Connected status, missing proof, or abort must reject before opening',
    );
    expect(
      persistVerified,
      greaterThan(openGate),
      reason: 'the route proof persists only after a valid in-memory admission',
    );
    expect(
      postPersistRecheck,
      greaterThan(persistVerified),
      reason: 'a seal/Disconnect that races persistence must reject SDK startup after the await',
    );
    expect(
      clearStaleProof,
      greaterThan(postPersistRecheck),
      reason:
          'a Stop that changes the epoch during native allow or preference persistence must not leave strict_vpn_route_verified=true',
    );
    expect(
      staleReturn,
      greaterThan(clearStaleProof),
      reason: 'the stale admission must persist false before it returns and before headless SDK work can start',
    );
    expect(
      sdkStart,
      greaterThan(postPersistRecheck),
      reason: 'Firebase, FCM, and WorkManager startup remains after the post-await epoch/gate recheck',
    );

    final staleTerminalRelease = release.indexOf('if (expectedEpoch != null && expectedEpoch != _androidEgressEpoch)');
    final staleTerminalReturn = release.indexOf('return false;', staleTerminalRelease);
    final invalidateEpoch = release.indexOf('_androidEgressEpoch += 1;');
    final releaseGate = release.indexOf('strictVpnEgressGate.releaseAfterTerminalDisconnect();');
    final nativeGateRejected = release.indexOf('if (!released) {', releaseGate);
    final nativeGateRejectedLog = release.indexOf(
      'terminal ordinary-network release was rejected by native gate',
      nativeGateRejected,
    );
    final nativeGateRejectedReturn = release.indexOf('return false;', nativeGateRejectedLog);
    final dartEpochSuperseded = release.indexOf('if (releaseEpoch != _androidEgressEpoch) {', nativeGateRejectedReturn);
    final dartEpochSupersededLog = release.indexOf(
      'terminal ordinary-network release was superseded',
      dartEpochSuperseded,
    );
    expect(
      staleTerminalRelease,
      greaterThanOrEqualTo(0),
      reason: 'a terminal release for an older explicit or platform transition epoch must be rejected',
    );
    expect(
      staleTerminalReturn,
      greaterThan(staleTerminalRelease),
      reason: 'newer-epoch protection must return before invalidating or reopening ordinary networking',
    );
    expect(
      invalidateEpoch,
      greaterThan(staleTerminalReturn),
      reason: 'terminal release must invalidate every in-flight admission epoch',
    );
    expect(
      releaseGate,
      greaterThan(invalidateEpoch),
      reason: 'epoch invalidation must happen before reopening the gate',
    );
    expect(
      nativeGateRejected,
      greaterThan(releaseGate),
      reason: 'a false native allow must be classified before considering a Dart epoch race',
    );
    expect(nativeGateRejectedLog, greaterThan(nativeGateRejected));
    expect(nativeGateRejectedReturn, greaterThan(nativeGateRejectedLog));
    expect(
      dartEpochSuperseded,
      greaterThan(nativeGateRejectedReturn),
      reason: 'only a successful native release may proceed to the real Dart-epoch supersession check',
    );
    expect(dartEpochSupersededLog, greaterThan(dartEpochSuperseded));

    for (final call in const [
      'ensureInitialized(refreshNativeReports: true)',
      'registerSubscriptionPushBackgroundHandler()',
      'subscriptionPushRefreshServiceProvider)',
      'initializeProfilesBackgroundRefresh(',
    ]) {
      expect(
        sdkServices.indexOf(call),
        greaterThanOrEqualTo(0),
        reason: '$call must be constructed only in the VPN-verified SDK branch',
      );
    }
  });

  test('Android strict egress gate retires local probes and awaits native reopening before unsealing', () {
    final gate = File('lib/core/network/strict_vpn_egress_gate.dart').readAsStringSync();
    final drain = _sourceSection(
      gate,
      'Future<void> _retireAndDrain() async {',
      '\n  /// Opens ordinary Dart networking',
    );
    final admit = _sourceSection(
      gate,
      'Future<bool> admitVerifiedVpnRoute() {',
      '\n  /// A completed terminal Disconnect',
    );
    final release = _sourceSection(
      gate,
      'Future<bool> releaseAfterTerminalDisconnect() => _openForCurrentTransition(refreshNativeBlockEpoch: true);',
      '\n\n  Future<bool> _openForCurrentTransition',
    );
    final open = _sourceSection(
      gate,
      'Future<bool> _openForCurrentTransition({required bool refreshNativeBlockEpoch}) {',
      '\n  Future<T> _serializeTransition',
    );
    final localPings = File('lib/features/home/data/local_outbounds_provider.dart').readAsStringSync();
    final pingAll = _sourceSection(localPings, 'Future<void> pingAll(', '\n  Future<void> _pingAllAdmitted');
    final retire = _sourceSection(localPings, 'Future<void> _retireRun(', '\n  Future<void> _pingOne');

    final retireActiveOperations = drain.indexOf(
      'for (final operation in List<_ActiveEgressOperation>.of(_activeOperations))',
    );
    final retireCallback = drain.indexOf('await Future<void>.sync(retire);', retireActiveOperations);
    final waitActiveOperations = drain.indexOf('while (_activeOperations.isNotEmpty)', retireCallback);
    expect(retireActiveOperations, greaterThanOrEqualTo(0));
    expect(
      retireCallback,
      greaterThan(retireActiveOperations),
      reason: 'the strict egress seal must actively retire each admitted local operation',
    );
    expect(
      waitActiveOperations,
      greaterThan(retireCallback),
      reason: 'native VPN admission must wait until the retired local probe completes',
    );
    expect(
      pingAll,
      matches(RegExp(r"strictVpnEgressGate\s*\.run\(\s*'local outbound probes',")),
      reason: 'local probes must remain admitted through the strict egress gate regardless of cascade formatting',
    );
    expect(pingAll, contains('retire: () => _retireRun(run, keepNativeAdmissionBlocked: true)'));
    expect(retire, matches(RegExp(r"'cancel_local_probes',\s*\{\s*'keepBlocked': keepNativeAdmissionBlocked,\s*\}")));
    expect(
      retire,
      contains('if (!keepNativeAdmissionBlocked || _nativeProbeRetirementKeepsBlocked)'),
      reason:
          'an ordinary profile clear may reuse its existing retirement, but a strict transition may not weaken a blocked native gate',
    );
    expect(
      retire,
      matches(RegExp(r"'cancel_local_probes',\s*\{\s*'keepBlocked': true\s*\}")),
      reason:
          'a strict VPN transition overlapping a profile clear must upgrade native probe retirement to remain blocked',
    );
    expect(
      retire,
      isNot(contains('Future.delayed')),
      reason: 'native probe retirement must be join-driven, not timer-polled',
    );
    expect(retire, isNot(contains('Timer(')), reason: 'native probe retirement must not create a wake timer');

    expect(admit, contains('_openForCurrentTransition(refreshNativeBlockEpoch: false)'));
    expect(
      admit,
      isNot(contains('cancel_local_probes')),
      reason: 'a verified-route admission must use its cached proof-generation block epoch',
    );
    expect(release, contains('refreshNativeBlockEpoch: true'));
    final expectedEpoch = open.indexOf('final expectedEpoch = _transitionEpoch;');
    final nativeBlockEpoch = open.indexOf('var nativeBlockEpoch = _nativeBlockEpoch;', expectedEpoch);
    final refreshEpoch = open.indexOf('if (refreshNativeBlockEpoch) {', nativeBlockEpoch);
    final refreshNativeCancel = open.indexOf("'cancel_local_probes'", refreshEpoch);
    final refreshKeepBlocked = open.indexOf("'keepBlocked': true", refreshNativeCancel);
    final refreshOwnershipGuard = open.indexOf(
      'if (nativeBlockEpoch == null || expectedEpoch != _transitionEpoch) return false;',
      refreshKeepBlocked,
    );
    final persistFreshEpoch = open.indexOf('_nativeBlockEpoch = nativeBlockEpoch;', refreshOwnershipGuard);
    final nativeAllow = open.indexOf("'allow_local_probes'", persistFreshEpoch);
    final allowEpoch = open.indexOf("'blockEpoch': nativeBlockEpoch", nativeAllow);
    final allowed = open.indexOf('final allowed = await', nativeBlockEpoch);
    final rejectFalse = open.indexOf('if (allowed != true) return false;', allowed);
    final staleEpoch = open.indexOf('if (expectedEpoch != _transitionEpoch)', rejectFalse);
    final resealOnStale = open.indexOf("'cancel_local_probes'", staleEpoch);
    final staleReturn = open.indexOf('return false;', resealOnStale);
    final unseal = open.indexOf('_sealed = false;', staleReturn);
    expect(expectedEpoch, greaterThanOrEqualTo(0));
    expect(nativeBlockEpoch, greaterThan(expectedEpoch));
    expect(
      refreshEpoch,
      greaterThan(nativeBlockEpoch),
      reason: 'only terminal release may reacquire the process-wide native block epoch',
    );
    expect(
      refreshNativeCancel,
      greaterThan(refreshEpoch),
      reason: 'terminal release must capture a fresh keepBlocked epoch before allow_local_probes',
    );
    expect(refreshKeepBlocked, greaterThan(refreshNativeCancel));
    expect(
      refreshOwnershipGuard,
      greaterThan(refreshKeepBlocked),
      reason: 'a transition that changes during fresh-epoch capture remains fail-closed',
    );
    expect(
      persistFreshEpoch,
      greaterThan(refreshOwnershipGuard),
      reason: 'the freshly captured process-wide epoch must replace stale isolate-local ownership before allow',
    );
    expect(nativeAllow, greaterThanOrEqualTo(0));
    expect(allowEpoch, greaterThan(nativeAllow));
    expect(
      rejectFalse,
      greaterThan(allowed),
      reason: 'Dart must stay sealed unless native accepts the exact block epoch',
    );
    expect(
      staleEpoch,
      greaterThan(rejectFalse),
      reason: 'a transition that changed while native allow awaited must be rechecked before unseal',
    );
    expect(resealOnStale, greaterThan(staleEpoch));
    expect(staleReturn, greaterThan(resealOnStale));
    expect(
      unseal,
      greaterThan(staleReturn),
      reason: 'Dart may unseal only after a true exact-epoch native allow and a post-await ownership recheck',
    );
  });

  test('Android crash reporting checks exact native admission before constructing Firebase', () {
    final analytics = File('lib/core/analytics/analytics_controller.dart').readAsStringSync();
    final initialize = _sourceSection(
      analytics,
      'Future<void> _initializeReporting() async {',
      '\n  Future<void> disableAnalytics()',
    );
    final nativeGate = initialize.indexOf("invokeMethod<bool>('is_crash_reporting_admitted')");
    final nativeDecision = initialize.indexOf('!= true', nativeGate);
    final deferredReturn = initialize.indexOf('return;', nativeDecision);
    final firebase = initialize.indexOf('Firebase.initializeApp()', deferredReturn);
    expect(nativeGate, greaterThanOrEqualTo(0));
    expect(
      nativeDecision,
      greaterThan(nativeGate),
      reason: 'the native process must approve crash reporting for the current admitted VPN owner',
    );
    expect(
      deferredReturn,
      greaterThan(nativeDecision),
      reason: 'an unadmitted Android process must return before Firebase initialization',
    );
    expect(
      firebase,
      greaterThan(deferredReturn),
      reason: 'Firebase construction remains after the verified-route gate',
    );
    final ensure = _sourceSection(analytics, 'Future<void> ensureInitialized({', '\n  bool get _canInitialize');
    expect(ensure, contains('if (active != null) return active;'));
    expect(ensure, contains('if (identical(_initialization, start)) _initialization = null;'));
    expect(analytics, contains('crashReporter.onResume = ensureInitialized;'));
    expect(analytics, contains('crashReporter.enable(discardExistingReports: _discardExistingReports)'));
  });

  test('a live Android native entry request is queued through Flutter before it can connect', () {
    final notifier = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final build = _sourceSection(
      notifier,
      'Stream<ConnectionStatus> build() async* {',
      '\n  ConnectionRepository get _connectionRepo',
    );
    final listener = _sourceSection(
      notifier,
      'void _installNativeConnectRequestListener()',
      '\n  void _handleNativeConnectRequest',
    );
    final request = _sourceSection(
      notifier,
      'void _handleNativeConnectRequest(dynamic event)',
      '\n  void _tryExecutePendingNativeConnectRequest',
    );
    final execution = _sourceSection(
      notifier,
      'void _tryExecutePendingNativeConnectRequest(ConnectionStatus? status)',
      '\n  bool get _flutterOwnsAutomaticRecovery',
    );
    final claim = _sourceSection(
      notifier,
      'Future<int?> _claimNativeConnectRequest(int handoffId) async',
      '\n  Future<NativeSatisfiedConnectResolution> _resolvePossiblySatisfiedNativeConnectRequest',
    );
    final satisfiedAcknowledgement = _sourceSection(
      notifier,
      'Future<NativeSatisfiedConnectResolution> _resolvePossiblySatisfiedNativeConnectRequest(',
      '\n  void _cancelPendingNativeConnectRequestForTerminalStop',
    );
    final cancelClaim = _sourceSection(
      notifier,
      'Future<void> _cancelNativeConnectClaim(int startLease) async',
      '\n  void _cancelPendingNativeConnectRequestForTerminalStop',
    );
    final terminalStop = _sourceSection(
      notifier,
      'Future<void> _stopFromManualCommand(ConnectionStatus? currentStatus) async',
      '\n  void _sendManualHaptic',
    );
    final localTerminalCancellation = _sourceSection(
      notifier,
      'void _cancelPendingNativeConnectRequestForTerminalStop()',
      '\n  bool get _flutterOwnsAutomaticRecovery',
    );
    final connectOperation = _sourceSection(notifier, 'Future<bool> _connect({', '\n  Future<bool> _connectThrottled');
    final connect = _sourceSection(notifier, 'Future<bool> _connectThrottled(', '\n  Future<bool> _disconnect(');
    final mobile = File('lib/martencore/core_interface/core_interface_mobile.dart').readAsStringSync();
    final readiness = _sourceSection(
      mobile,
      'Future<CoreStatus> _waitForBackgroundServiceReady({',
      '\n  Future<bool> _isVpnUserSessionCurrent',
    );

    final install = build.indexOf('_installNativeConnectRequestListener();');
    final firstAwait = build.indexOf('await ');
    expect(
      install,
      greaterThanOrEqualTo(0),
      reason: 'ConnectionNotifier must subscribe before bootstrap can await platform work',
    );
    expect(
      firstAwait,
      greaterThan(install),
      reason: 'a native user gesture must not be lost during Flutter bootstrap awaits',
    );
    expect(
      notifier,
      contains("EventChannel('app.marten.client/connect.requests', JSONMethodCodec())"),
      reason: 'Dart must consume the dedicated native connect-request EventChannel',
    );
    expect(listener, contains('_nativeConnectRequestsChannel.receiveBroadcastStream().listen('));
    expect(listener, contains('if (!Platform.isAndroid || _nativeConnectRequestsSubscription != null) return;'));

    final handoffValidation = request.indexOf('if (handoffId == null)');
    final duplicateDelivery = request.indexOf('_nativeConnectRequestHandoffId == handoffId');
    final pending = request.indexOf('_nativeConnectRequestPending = true;');
    final dispatch = request.indexOf('_tryExecutePendingNativeConnectRequest(state.valueOrNull);', pending);
    expect(
      handoffValidation,
      greaterThanOrEqualTo(0),
      reason: 'only uniquely identified native handoffs are actionable',
    );
    expect(
      duplicateDelivery,
      greaterThan(handoffValidation),
      reason: 'the same listener must not replay an already pending/owned handoff',
    );
    expect(pending, greaterThanOrEqualTo(0), reason: 'native channel delivery must become a pending manual command');
    expect(dispatch, greaterThan(pending), reason: 'the notifier may assess the command only after retaining it');

    final executableTerminal = execution.indexOf(
      'if (status is Disconnected || state is AsyncError<ConnectionStatus>) {',
    );
    final retainWhileTransitioning = execution.indexOf(
      'AsyncLoading and Disconnecting retain the one-shot request until the',
    );
    final attemptOwner = execution.indexOf('_nativeConnectRequestAttemptHandoffId = handoffId;');
    final manualExecution = execution.indexOf('final execution = executeManualCommand(', attemptOwner);
    final manualCommand = execution.indexOf('ManualConnectionCommand.connect,', manualExecution);
    final sealedCallback = execution.indexOf('onConnectTransitionSealed: () async {', manualExecution);
    final exactAttemptCheck = execution.indexOf(
      'if (_nativeConnectRequestHandoffId != handoffId) return null;',
      sealedCallback,
    );
    final claimAfterSeal = execution.indexOf('return _claimNativeConnectRequest(handoffId);', exactAttemptCheck);
    final completionRetry = execution.lastIndexOf('_tryExecutePendingNativeConnectRequest(state.valueOrNull);');
    expect(
      executableTerminal,
      greaterThanOrEqualTo(0),
      reason: 'only a terminal Flutter state may begin the retained native Connect handoff',
    );
    expect(
      retainWhileTransitioning,
      greaterThan(executableTerminal),
      reason:
          'a live native request must remain pending through AsyncLoading or Disconnecting until Flutter reaches an executable state',
    );
    expect(
      manualExecution,
      greaterThan(attemptOwner),
      reason: 'only the normal state-validated manual Connect path may open the repository',
    );
    expect(manualCommand, greaterThan(manualExecution));
    expect(
      sealedCallback,
      greaterThan(manualExecution),
      reason: 'Dart may claim only once the manual attempt seals strict egress',
    );
    expect(
      exactAttemptCheck,
      greaterThan(sealedCallback),
      reason: 'a superseded attempt must not claim a newer handoff',
    );
    expect(
      claimAfterSeal,
      greaterThan(exactAttemptCheck),
      reason: 'only the exact handoff may receive an explicit native-start lease',
    );
    expect(execution, isNot(contains('Future.delayed')), reason: 'a retained handoff must not poll on a timer');
    expect(execution, isNot(contains('Timer(')), reason: 'a retained handoff must not create a wake-lock-like timer');
    expect(
      completionRetry,
      greaterThan(claimAfterSeal),
      reason: 'serialized rejection retries only from completion or authoritative status events',
    );
    expect(execution, contains('Native redelivery or an authoritative status transition'));
    expect(execution, contains('no polling loop is introduced'));
    expect(execution, contains('queueConnectAfterCurrentOperation: true'));
    expect(connectOperation, contains('waitForCurrent: queueAfterCurrentOperation'));
    expect(connectOperation, contains('supersedeQueued: queueAfterCurrentOperation'));

    final rejectedEpoch = readiness.indexOf(
      'if (androidVpnStartEpoch != null && !await _isVpnUserSessionCurrent(androidVpnStartEpoch)) {',
    );
    final exactGeneration = readiness.indexOf(
      'if (startGeneration == _backgroundLifecycleGeneration) {',
      rejectedEpoch,
    );
    final invalidate = readiness.indexOf('_backgroundLifecycleGeneration++;', exactGeneration);
    final staleReturn = readiness.indexOf('return const CoreStatus.stopped();', invalidate);
    final grpcReadiness = readiness.indexOf('_coreStatusOnPort(', rejectedEpoch);
    final readinessDelay = readiness.indexOf('Future.delayed(_backgroundServicePollInterval)', rejectedEpoch);
    expect(
      rejectedEpoch,
      greaterThanOrEqualTo(0),
      reason:
          'the exact Android user-session epoch must be checked while the native request is still waiting for gRPC readiness',
    );
    expect(
      exactGeneration,
      greaterThan(rejectedEpoch),
      reason: "only the stale native request's exact background generation may be invalidated",
    );
    expect(invalidate, greaterThan(exactGeneration));
    expect(
      staleReturn,
      greaterThan(invalidate),
      reason: 'a rejected exact epoch must cancel terminally before it can connect',
    );
    expect(
      grpcReadiness,
      greaterThan(staleReturn),
      reason: 'stale Android admission must return before probing gRPC readiness',
    );
    expect(
      readinessDelay,
      greaterThan(staleReturn),
      reason: 'stale Android admission must not wait for the generic readiness poll or timeout',
    );

    final joiningEnsure = execution.indexOf(
      "_ensureAndroidOrdinaryNetworkingSealed('native Connect joined an existing transition')",
    );
    final joiningAck = execution.indexOf('_resolvePossiblySatisfiedNativeConnectRequest(handoffId, status)');
    expect(
      joiningEnsure,
      greaterThanOrEqualTo(0),
      reason:
          'a native Connecting join must reinforce an existing seal without minting a second epoch before ack_satisfied',
    );
    expect(joiningAck, greaterThan(joiningEnsure));
    expect(
      execution,
      isNot(contains("_sealAndroidOrdinaryNetworking('native Connect joined an existing transition')")),
      reason: 'a native Connecting join must not turn an already sealed manual transition into a newer epoch',
    );
    expect(claim, contains('Future<int?> _claimNativeConnectRequest(int handoffId) async'));
    expect(
      claim,
      contains(
        'if (_nativeConnectRequestHandoffId != handoffId || _nativeConnectRequestAckInFlightHandoffId == handoffId)',
      ),
    );
    final nativeClaim = claim.indexOf("invokeMethod<int>('claim', {'handoffId': handoffId})");
    final leaseAccepted = claim.indexOf('if (startLease != null && startLease > 0)', nativeClaim);
    final clearPendingAfterLease = claim.indexOf('_nativeConnectRequestPending = false;', leaseAccepted);
    final clearIdAfterLease = claim.indexOf('_nativeConnectRequestHandoffId = null;', clearPendingAfterLease);
    final explicitNativeRejection = claim.indexOf('if (nativeAnswered)', clearIdAfterLease);
    final clearPendingAfterRejection = claim.indexOf('_nativeConnectRequestPending = false;', explicitNativeRejection);
    final clearIdAfterRejection = claim.indexOf('_nativeConnectRequestHandoffId = null;', clearPendingAfterRejection);
    final transportRetain = claim.indexOf(
      'A transport exception has no native ownership answer.',
      clearIdAfterRejection,
    );
    expect(nativeClaim, greaterThanOrEqualTo(0));
    expect(
      leaseAccepted,
      greaterThan(nativeClaim),
      reason: 'Dart may proceed only after native grants its exact start lease',
    );
    expect(clearPendingAfterLease, greaterThan(leaseAccepted));
    expect(clearIdAfterLease, greaterThan(clearPendingAfterLease));
    expect(
      explicitNativeRejection,
      greaterThan(clearIdAfterLease),
      reason: 'an explicit null claim answer is a distinct cancellation/replacement result',
    );
    expect(clearPendingAfterRejection, greaterThan(explicitNativeRejection));
    expect(clearIdAfterRejection, greaterThan(clearPendingAfterRejection));
    expect(
      transportRetain,
      greaterThan(clearIdAfterRejection),
      reason: 'only a transport exception retains the exact owner for event-driven redelivery',
    );
    expect(claim, isNot(contains('Future.delayed')));
    expect(claim, isNot(contains('Timer(')));
    expect(claim, contains('timer, wake lock or polling watchdog'));

    expect(satisfiedAcknowledgement, contains('Future<NativeSatisfiedConnectResolution>'));
    final nativeSatisfiedAck = satisfiedAcknowledgement.indexOf("invokeMethod<Object?>('ack_satisfied'");
    final resolved = satisfiedAcknowledgement.indexOf(
      'final resolution = nativeSatisfiedConnectResolutionFromPlatform(nativeResolution);',
      nativeSatisfiedAck,
    );
    final satisfiedCase = satisfiedAcknowledgement.indexOf(
      'case NativeSatisfiedConnectResolution.satisfied:',
      resolved,
    );
    final connectRequiredCase = satisfiedAcknowledgement.indexOf(
      'case NativeSatisfiedConnectResolution.connectRequired:',
      satisfiedCase,
    );
    final executeInactive = satisfiedAcknowledgement.indexOf(
      '_executePendingNativeConnectRequest(handoffId, nativeServiceConfirmedInactive: true);',
      connectRequiredCase,
    );
    final cancelledCase = satisfiedAcknowledgement.indexOf(
      'case NativeSatisfiedConnectResolution.cancelled:',
      executeInactive,
    );
    final transportFailureCase = satisfiedAcknowledgement.indexOf(
      'case NativeSatisfiedConnectResolution.transportFailure:',
      cancelledCase,
    );
    expect(nativeSatisfiedAck, greaterThanOrEqualTo(0));
    expect(
      resolved,
      greaterThan(nativeSatisfiedAck),
      reason: 'ack_satisfied must parse its exact authoritative wire outcome before changing handoff ownership',
    );
    expect(satisfiedCase, greaterThan(resolved));
    expect(
      connectRequiredCase,
      greaterThan(satisfiedCase),
      reason: 'a stale retained Connected/Connecting state must start only after native authoritatively requires it',
    );
    expect(executeInactive, greaterThan(connectRequiredCase));
    expect(cancelledCase, greaterThan(executeInactive));
    expect(
      transportFailureCase,
      greaterThan(cancelledCase),
      reason: 'transport failure must retain the exact handoff rather than guessing it was superseded',
    );
    expect(satisfiedAcknowledgement, isNot(contains('Future.delayed')));
    expect(satisfiedAcknowledgement, isNot(contains('Timer(')));

    expect(cancelClaim, contains("invokeMethod<bool>('cancel_claim', {'startLease': startLease})"));
    expect(cancelClaim, contains('The authoritative terminal Stop path also invalidates this lease.'));
    expect(cancelClaim, isNot(contains('Future.delayed')));
    expect(cancelClaim, isNot(contains('Timer(')));
    final cancelUnusedAfterSealFailure = connect.indexOf(
      'if (unusedLease != null) await cancelStartLease(unusedLease);',
    );
    final activeProfile = connect.indexOf('final activeProfile = await activeProfileFuture;');
    final nullProfile = connect.indexOf('if (activeProfile == null)', activeProfile);
    final leaseToCancel = connect.indexOf('final leaseToCancel = explicitStartLease;', nullProfile);
    final cancelNoProfile = connect.indexOf('await cancelStartLease(leaseToCancel);', leaseToCancel);
    final cancelOwnershipCleared = connect.indexOf('nativeClaimNeedsCancellation = false;', cancelNoProfile);
    final canonicalDisconnect = connect.indexOf(
      'final cleanup = await connectionRepo.disconnect().run();',
      cancelOwnershipCleared,
    );
    final cleanupSuccess = connect.indexOf(
      '}, (_) => _releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(',
      canonicalDisconnect,
    );
    final terminalRelease = connect.indexOf('expectedEpoch: egressEpoch', cleanupSuccess);
    expect(
      cancelUnusedAfterSealFailure,
      greaterThanOrEqualTo(0),
      reason:
          'a failed seal/claim transaction must return its exact unused native lease rather than leaving it claimed',
    );
    expect(
      nullProfile,
      greaterThan(activeProfile),
      reason: 'the empty-profile terminal path must be selected only after profile resolution',
    );
    expect(
      leaseToCancel,
      greaterThan(nullProfile),
      reason: 'an empty-profile Connect must retain the exact claimed lease until it is explicitly retired',
    );
    expect(
      cancelNoProfile,
      greaterThan(leaseToCancel),
      reason: 'a claimed native handoff with no profile must cancel its exact lease before cleanup',
    );
    expect(
      cancelOwnershipCleared,
      greaterThan(cancelNoProfile),
      reason: 'the finally block must not replay a lease already retired by the null-profile branch',
    );
    expect(
      canonicalDisconnect,
      greaterThan(cancelOwnershipCleared),
      reason: 'null-profile cleanup must use the canonical repository disconnect to prove platform release',
    );
    expect(
      cleanupSuccess,
      greaterThan(canonicalDisconnect),
      reason: 'terminal ordinary-network release may run only in the successful canonical cleanup branch',
    );
    expect(
      terminalRelease,
      greaterThan(cleanupSuccess),
      reason: 'both lease and null-lease empty-profile exits must use the epoch-gated terminal release helper',
    );

    final cancelBeforeAwait = terminalStop.indexOf('_cancelPendingNativeConnectRequestForTerminalStop();');
    final terminalStopFirstAwait = terminalStop.indexOf('await ');
    expect(
      cancelBeforeAwait,
      greaterThanOrEqualTo(0),
      reason: 'manual terminal Stop must synchronously cancel its local native handoff',
    );
    expect(terminalStopFirstAwait, greaterThan(cancelBeforeAwait));
    expect(localTerminalCancellation, contains('_nativeConnectRequestPending = false;'));
    expect(localTerminalCancellation, contains('_nativeConnectRequestHandoffId = null;'));
    expect(localTerminalCancellation, contains('_nativeConnectRequestAckInFlightHandoffId = null;'));
  });

  test(
    'native Connect retries only after lifecycle completion, never after UI presentation or a stale attempt lease',
    () {
      final notifier = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
      final connect = _sourceSection(notifier, 'Future<bool> _connect({', '\n  Future<bool> _connectThrottled');
      final execution = _sourceSection(
        notifier,
        'void _executePendingNativeConnectRequest(int handoffId, {bool nativeServiceConfirmedInactive = false})',
        '\n  Future<int?> _claimNativeConnectRequest',
      );
      final terminalCancellation = _sourceSection(
        notifier,
        'void _cancelPendingNativeConnectRequestForTerminalStop()',
        '\n  bool get _flutterOwnsAutomaticRecovery',
      );

      final lifecycleCompletion = connect.indexOf('await _singleStart.run(');
      final asynchronousPresentation = connect.indexOf('unawaited(');
      expect(lifecycleCompletion, greaterThanOrEqualTo(0));
      expect(
        asynchronousPresentation,
        greaterThan(lifecycleCompletion),
        reason: 'a native replacement handoff may observe completion without waiting for a user dialog',
      );

      final whenComplete = execution.indexOf('execution.whenComplete(() {');
      final clearAttempt = execution.indexOf('_nativeConnectRequestAttemptHandoffId = null;', whenComplete);
      final newerHandoffGuard = execution.indexOf('if (_nativeConnectRequestHandoffId != handoffId) {', clearAttempt);
      final eventDrivenRetry = execution.indexOf(
        '_tryExecutePendingNativeConnectRequest(state.valueOrNull);',
        newerHandoffGuard,
      );
      expect(whenComplete, greaterThanOrEqualTo(0));
      expect(
        clearAttempt,
        greaterThan(whenComplete),
        reason: 'the active handoff stays owned until its actual lifecycle task completes',
      );
      expect(
        newerHandoffGuard,
        greaterThan(clearAttempt),
        reason: 'only a different exact handoff may be released after the completed attempt clears',
      );
      expect(
        eventDrivenRetry,
        greaterThan(newerHandoffGuard),
        reason: 'the next exact Connect is retried from completion/status events, not a timer',
      );
      expect(execution, isNot(contains('Timer(')));
      expect(execution, isNot(contains('Future.delayed')));

      expect(
        terminalCancellation,
        isNot(contains('_nativeConnectRequestAttemptHandoffId = null;')),
        reason: 'terminal Stop must not free an attempt while its lifecycle cleanup still owns _singleStart',
      );
    },
  );
}

bool _isInsideAdmittedBranch(String source, int offset, String flag) {
  final branches = RegExp(r'if\s*\(([^)]*)\)\s*\{').allMatches(source);
  for (final branch in branches) {
    final condition = branch.group(1)!;
    if (!RegExp('\\b${RegExp.escape(flag)}\\b').hasMatch(condition) || condition.contains('!$flag')) continue;
    final bodyStart = source.indexOf('{', branch.start);
    final bodyEnd = _matchingBrace(source, bodyStart);
    if (bodyStart < offset && offset < bodyEnd) return true;
  }
  return false;
}

String _sourceSection(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing source marker $startMarker');
  final end = source.indexOf(endMarker, start + startMarker.length);
  expect(end, greaterThan(start), reason: 'missing source end marker $endMarker');
  return source.substring(start, end);
}

int _matchingBrace(String source, int openBrace) {
  var depth = 0;
  for (var index = openBrace; index < source.length; index++) {
    if (source[index] == '{') {
      depth++;
    } else if (source[index] == '}') {
      depth--;
      if (depth == 0) return index;
    }
  }
  fail('unclosed source branch beginning at offset $openBrace');
}
