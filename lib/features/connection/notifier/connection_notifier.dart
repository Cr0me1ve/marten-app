import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:marten/core/analytics/analytics_controller.dart';
import 'package:marten/core/analytics/analytics_logger.dart';
import 'package:marten/core/haptic/haptic_service.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/network/strict_vpn_egress_gate.dart';
import 'package:marten/core/preferences/general_preferences.dart';
import 'package:marten/core/router/dialog/dialog_notifier.dart';
import 'package:marten/core/utils/preferences_utils.dart';
import 'package:marten/features/captcha/data/captcha_notifier.dart';
import 'package:marten/features/connection/data/connection_data_providers.dart';
import 'package:marten/features/connection/data/connection_repository.dart';
import 'package:marten/features/connection/data/turncoat_liveness_notifier.dart';
import 'package:marten/features/connection/model/connection_failure.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/notifier/active_profile_notifier.dart';
import 'package:marten/features/profile/notifier/background_profiles_update.dart';
import 'package:marten/features/profile/notifier/subscription_push_refresh.dart';
import 'package:marten/singbox/model/core_status.dart';
import 'package:marten/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';

part 'connection_notifier.g.dart';

enum ManualConnectionCommand { connect, disconnect, abort }

String _crashConnectionState(ConnectionStatus status) => switch (status) {
  Disconnected() => 'disconnected',
  Connecting() => 'connecting',
  Connected() => 'connected',
  Disconnecting() => 'disconnecting',
};

const manualDisconnectInputSettleDelay = Duration(milliseconds: 750);

ManualConnectionCommand manualConnectionCommandForStatus(ConnectionStatus status) => switch (status) {
  Disconnected() => ManualConnectionCommand.connect,
  Connected() => ManualConnectionCommand.disconnect,
  Connecting() => ManualConnectionCommand.abort,
  Disconnecting() => ManualConnectionCommand.disconnect,
};

bool canExecuteManualConnectionCommand(ManualConnectionCommand command, ConnectionStatus status) => switch (command) {
  ManualConnectionCommand.connect => status is Disconnected,
  ManualConnectionCommand.disconnect || ManualConnectionCommand.abort => status is Connected || status is Connecting,
};

bool shouldReportBootstrapSetupFailure({
  required int requestAbortToken,
  required int currentAbortToken,
  required bool manualDisconnectRequested,
}) => requestAbortToken == currentAbortToken && !manualDisconnectRequested;

bool isCurrentConnectIntent({required int attemptGeneration, required int currentGeneration}) =>
    attemptGeneration == currentGeneration;

@visibleForTesting
bool shouldPreserveConnectedSessionAfterProfileChange({
  required ProfileEntity? previous,
  required ProfileEntity? next,
  required bool activeRuntimeConfigMatches,
}) => _sameRuntimeRelevantProfileFields(previous, next) && activeRuntimeConfigMatches;

bool _sameRuntimeRelevantProfileFields(ProfileEntity? previous, ProfileEntity? next) =>
    previous != null &&
    next != null &&
    previous.runtimeType == next.runtimeType &&
    previous.id == next.id &&
    previous.active == next.active &&
    previous.name == next.name &&
    previous.profileOverride == next.profileOverride;

enum NativeSatisfiedConnectResolution { satisfied, connectRequired, cancelled, transportFailure }

NativeSatisfiedConnectResolution nativeSatisfiedConnectResolutionFromPlatform(Object? value) => switch (value) {
  'satisfied' || true => NativeSatisfiedConnectResolution.satisfied,
  'connect_required' => NativeSatisfiedConnectResolution.connectRequired,
  'cancelled' || false => NativeSatisfiedConnectResolution.cancelled,
  _ => NativeSatisfiedConnectResolution.transportFailure,
};

@Riverpod(keepAlive: true)
class ConnectionNotifier extends _$ConnectionNotifier with AppLogger {
  static const _nativeConnectRequestsChannel = EventChannel('app.marten.client/connect.requests', JSONMethodCodec());
  static const _nativeConnectRequestAcksChannel = MethodChannel('app.marten.client/connect.requests.ack');
  static const List<Duration> _autoReconnectDelays = [
    Duration.zero,
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
    Duration(minutes: 1),
  ];
  static const _androidAutoReconnectMinimumDelay = Duration(seconds: 2);
  static const _routeWatchdogInitialDelay = Duration(seconds: 5);
  static const _turncoatRouteWatchdogInitialDelay = TurncoatLivenessNotifier.connectTimeout;
  static const _routeWatchdogInterval = Duration(seconds: 10);
  static const _turncoatRouteWatchdogInterval = Duration(seconds: 60);
  static const _iosStableRouteWatchdogInterval = Duration(minutes: 5);
  static const _iosStableBackgroundRouteWatchdogInterval = Duration(minutes: 30);
  static const _routeWatchdogRetryDelay = Duration(seconds: 10);
  static const _turncoatRouteWatchdogRetryDelay = Duration(seconds: 30);
  static const _routeWatchdogResumeDelay = Duration(seconds: 3);
  static const _turncoatRouteWatchdogResumeDelay = Duration(seconds: 15);
  static const _routeWatchdogMaxFailures = 3;
  static const _turncoatRouteWatchdogMaxFailures = 3;
  static const _existingTurncoatRouteVerificationRetryDelay = Duration(seconds: 30);
  static const _existingTurncoatRouteVerificationMaxFailures = 6;

  Timer? _autoReconnectTimer;
  Timer? _routeWatchdogTimer;
  Timer? _existingStartedRouteVerificationRetryTimer;
  int _autoReconnectAttempt = 0;
  int _routeWatchdogFailures = 0;
  int _existingStartedRouteVerificationFailures = 0;
  bool _nextRouteWatchdogCheckRequiresFreshRoute = false;
  bool _manualDisconnectRequested = false;
  bool _autoReconnectPending = false;
  bool _autoReconnectRunning = false;
  bool _routeWatchdogRunning = false;
  bool _startupRouteVerificationRunning = false;
  bool _awaitingAndroidAuthoritativeRecoveryStatus = false;
  bool _manualConnectPending = false;
  bool _manualButtonDisconnectInProgress = false;
  bool _manualDisconnectInputSettling = false;
  bool _showIdleDuringAbort = false;
  ConnectionFailure? _lastSilentAutoReconnectFailure;
  int _abortToken = 0;
  int _connectIntentGeneration = 0;
  int _activeProfileChangeRevision = 0;
  int _androidEgressEpoch = 0;
  int? _androidPlatformTransitionEgressEpoch;
  Future<void> _androidEgressPreferenceOperation = Future<void>.value();
  Future<void>? _androidNetworkServicesStart;
  bool _androidBackgroundRefreshRegistered = false;
  StreamSubscription<dynamic>? _nativeConnectRequestsSubscription;
  bool _nativeConnectRequestPending = false;
  int? _nativeConnectRequestAttemptHandoffId;
  int? _nativeConnectRequestHandoffId;
  int? _nativeConnectRequestIntentGeneration;
  int? _nativeConnectRequestAckInFlightHandoffId;

  @override
  Stream<ConnectionStatus> build() async* {
    ref.onDispose(() {
      _cancelAutoReconnect();
      _stopRouteWatchdog();
      _cancelExistingStartedRouteVerificationRetry();
      _nativeConnectRequestPending = false;
      _nativeConnectRequestAttemptHandoffId = null;
      _nativeConnectRequestHandoffId = null;
      _nativeConnectRequestIntentGeneration = null;
      _nativeConnectRequestAckInFlightHandoffId = null;
      _androidPlatformTransitionEgressEpoch = null;
    });
    _installNativeConnectRequestListener();
    _adoptBootstrapAndroidEgressSeal();

    if (PlatformUtils.isMobile) {
      final platformBootstrapHandled = Platform.isAndroid && await _connectionRepo.initializePassivePlatformStatus();
      if (!platformBootstrapHandled) {
        final setupAbortToken = _abortToken;
        await _connectionRepo.setup().mapLeft((l) {
          if (!shouldReportBootstrapSetupFailure(
            requestAbortToken: setupAbortToken,
            currentAbortToken: _abortToken,
            manualDisconnectRequested: _manualDisconnectRequested,
          )) {
            loggy.info("ignoring bootstrap setup failure superseded by a manual stop");
            return;
          }
          final stackTrace = switch (l) {
            UnexpectedConnectionFailure(:final stackTrace?) => stackTrace,
            _ => StackTrace.current,
          };
          loggy.error("error setting up connection repository", l, stackTrace);
        }).run();
      }
    }

    listenSelf((previous, next) async {
      if (previous == next) return;
      final previousStatus = previous?.valueOrNull;
      final nextStatus = next.valueOrNull;
      if (nextStatus != null) {
        crashReporter.setContext('connection_state', _crashConnectionState(nextStatus));
      }
      _handleAutoReconnectTransition(previousStatus, nextStatus);
      _handleRouteWatchdogTransition(nextStatus);
      _handleStartupRouteVerification(nextStatus);
      _tryExecutePendingNativeConnectRequest(nextStatus);
      if (Platform.isAndroid) {
        if (nextStatus is Connected) {
          final egressEpoch = _androidEgressEpoch;
          unawaited(_admitAndroidOrdinaryNetworking(egressEpoch));
        } else if (nextStatus is Connecting || (nextStatus is Disconnecting && previousStatus is! Disconnected)) {
          unawaited(_ensureAndroidOrdinaryNetworkingSealed('platform status ${nextStatus.runtimeType}'));
        } else if (nextStatus is Disconnecting) {
          // A terminal Disconnected frame is authoritative. Do not let an old
          // EventChannel Disconnecting delivery reseal direct networking after
          // that terminal release; a real new start must publish Connecting.
          loggy.info('ignoring stale platform Disconnecting after authoritative Disconnected');
        }
      }
      if (nextStatus is Disconnected && previousStatus is! Disconnected) {
        if (Platform.isAndroid) {
          final platformEgressEpoch = _androidPlatformTransitionEgressEpoch;
          _androidPlatformTransitionEgressEpoch = null;
          if (platformEgressEpoch != null) {
            unawaited(_releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: platformEgressEpoch));
          }
          unawaited(_synchronizeAndroidTerminalUserIntent());
        }
        unawaited(_syncNativeResumeConfigWhenIdle());
      }
      if (shouldResetTransientConnectionFeatures(
        previousStatus,
        nextStatus,
        operationInProgress: _singleStart.isRunning,
        manualDisconnectRequested: _manualDisconnectRequested,
        showIdleDuringAbort: _showIdleDuringAbort,
      )) {
        ref.read(turncoatLivenessNotifierProvider.notifier).reset();
        ref.read(captchaNotifierProvider.notifier).reset();
      }
      if (previous case AsyncData(:final value) when !value.isConnected && !_routeWatchdogRunning) {
        if (next case AsyncData(value: final Connected _)) {
          await ref.read(hapticServiceProvider.notifier).heavyImpact();

          if (Platform.isAndroid && !ref.read(Preferences.storeReviewedByUser)) {
            if (await InAppReview.instance.isAvailable()) {
              InAppReview.instance.requestReview();
              ref.read(Preferences.storeReviewedByUser.notifier).update(true);
            }
          }
        }
      }
    });

    ref.listen(activeProfileProvider.select((value) => value.asData?.value), (previous, next) {
      // Capture provider-backed dependencies before the first async gap. Core
      // replacement used to rebuild this notifier through a restart signal;
      // reading ref from that outdated build triggered the fatal reported by
      // Firebase. The status stream is persistent, so this notifier no longer
      // watches that self-invalidating signal, and in-flight work still keeps
      // an immutable dependency snapshot.
      final connectionRepo = _connectionRepo;
      final revision = ++_activeProfileChangeRevision;
      unawaited(_handleActiveProfileChange(previous, next, connectionRepo, revision));
    });
    ref.listen(selectedProxyByProfileProvider, (previous, next) {
      if (previous == next) return;
      unawaited(_syncNativeResumeConfigWhenIdle());
    });
    ref.listen(turncoatLivenessNotifierProvider.select((value) => value.timedOut), (previous, next) {
      if (previous == true || next != true) return;
      unawaited(_handleTurncoatConnectTimeout());
    });
    yield* _connectionRepo.watchConnectionStatus().map(_visibleConnectionStatus).doOnData((event) {
      if (event case Disconnected(connectionFailure: final _?) when PlatformUtils.isDesktop) {
        ref.read(Preferences.startedByUser.notifier).update(false);
      }
      loggy.info("connection status: ${event.format()}");
    }).distinct();
  }

  ConnectionRepository get _connectionRepo => ref.read(connectionRepositoryProvider);

  void _installNativeConnectRequestListener() {
    if (!Platform.isAndroid || _nativeConnectRequestsSubscription != null) return;
    final subscription = _nativeConnectRequestsChannel.receiveBroadcastStream().listen(
      _handleNativeConnectRequest,
      onError: (Object error, StackTrace stackTrace) {
        loggy.error('native connect request channel failed', error, stackTrace);
      },
    );
    _nativeConnectRequestsSubscription = subscription;
    ref.onDispose(() {
      if (identical(_nativeConnectRequestsSubscription, subscription)) {
        _nativeConnectRequestsSubscription = null;
      }
      unawaited(subscription.cancel());
    });
  }

  void _handleNativeConnectRequest(dynamic event) {
    final request = event is Map ? event : const <Object?, Object?>{};
    final source = request['source']?.toString() ?? 'native';
    final requestId = request['requestId'];
    final handoffId = switch (request['handoffId']) {
      final int value when value > 0 => value,
      final num value when value.toInt() > 0 => value.toInt(),
      _ => null,
    };
    if (handoffId == null) {
      loggy.warning('discarding native connect request without a valid handoff id');
      return;
    }
    if (_nativeConnectRequestHandoffId == handoffId &&
        (_nativeConnectRequestPending ||
            _nativeConnectRequestAttemptHandoffId == handoffId ||
            _nativeConnectRequestAckInFlightHandoffId == handoffId)) {
      if (_nativeConnectRequestAckInFlightHandoffId == null) {
        _tryExecutePendingNativeConnectRequest(state.valueOrNull);
      }
      return;
    }
    _nativeConnectRequestHandoffId = handoffId;
    _nativeConnectRequestIntentGeneration = null;
    _nativeConnectRequestPending = true;
    loggy.info('queued native connect request source=$source requestId=$requestId handoffId=$handoffId');
    _tryExecutePendingNativeConnectRequest(state.valueOrNull);
  }

  void _tryExecutePendingNativeConnectRequest(ConnectionStatus? status) {
    if (!_nativeConnectRequestPending) return;
    final handoffId = _nativeConnectRequestHandoffId;
    if (handoffId == null) return;
    if (_nativeConnectRequestAckInFlightHandoffId == handoffId) return;
    if (status is Disconnected || state is AsyncError<ConnectionStatus>) {
      // Reserve the newest user intent even while an older Connect is still
      // unwinding. Its delayed failure continuation must not issue a terminal
      // platform Stop that clears this exact retained native handoff.
      _reserveNativeConnectIntent(handoffId);
      if (_nativeConnectRequestAttemptHandoffId != null) return;
      _executePendingNativeConnectRequest(handoffId);
      return;
    }
    if (_nativeConnectRequestAttemptHandoffId == handoffId) return;
    if (status is Connected || status is Connecting) {
      if (status is Connecting) {
        // A platform-originated Connecting update can reach this listener before
        // its later transition callback. Seal synchronously before acknowledging
        // that Dart owns the native gesture.
        unawaited(_ensureAndroidOrdinaryNetworkingSealed('native Connect joined an existing transition'));
      }
      unawaited(_resolvePossiblySatisfiedNativeConnectRequest(handoffId, status));
      loggy.info('checking retained ${status.runtimeType} against the service-owned native lifecycle');
      return;
    }
    // AsyncLoading and Disconnecting retain the one-shot request until the
    // authoritative service stream reaches an executable terminal state.
  }

  int _reserveNativeConnectIntent(int handoffId) {
    if (_nativeConnectRequestHandoffId != handoffId) return _connectIntentGeneration;
    return _nativeConnectRequestIntentGeneration ??= ++_connectIntentGeneration;
  }

  void _executePendingNativeConnectRequest(int handoffId, {bool nativeServiceConfirmedInactive = false}) {
    if (!_nativeConnectRequestPending || _nativeConnectRequestHandoffId != handoffId) return;
    if (_nativeConnectRequestAttemptHandoffId != null || _nativeConnectRequestAckInFlightHandoffId != null) return;
    final connectIntentGeneration = _reserveNativeConnectIntent(handoffId);
    _nativeConnectRequestAttemptHandoffId = handoffId;
    final execution = executeManualCommand(
      ManualConnectionCommand.connect,
      queueConnectAfterCurrentOperation: true,
      nativeServiceConfirmedInactive: nativeServiceConfirmedInactive,
      connectIntentGeneration: connectIntentGeneration,
      onConnectTransitionSealed: () async {
        if (_nativeConnectRequestHandoffId != handoffId) return null;
        return _claimNativeConnectRequest(handoffId);
      },
    );
    unawaited(
      execution.whenComplete(() {
        if (_nativeConnectRequestAttemptHandoffId == handoffId) {
          _nativeConnectRequestAttemptHandoffId = null;
        }
        if (_nativeConnectRequestHandoffId != handoffId) {
          if (_nativeConnectRequestPending) {
            _tryExecutePendingNativeConnectRequest(state.valueOrNull);
          }
        }
        // The same id is intentionally not retried here after a transport
        // exception. Native redelivery or an authoritative status transition
        // is the next event-driven trigger; no polling loop is introduced.
      }),
    );
  }

  Future<int?> _claimNativeConnectRequest(int handoffId) async {
    if (_nativeConnectRequestHandoffId != handoffId || _nativeConnectRequestAckInFlightHandoffId == handoffId) {
      return null;
    }
    _nativeConnectRequestAckInFlightHandoffId = handoffId;
    int? startLease;
    var nativeAnswered = false;
    try {
      startLease = await _nativeConnectRequestAcksChannel.invokeMethod<int>('claim', {'handoffId': handoffId});
      nativeAnswered = true;
    } catch (error, stackTrace) {
      loggy.warning('failed to claim native connect handoff', error, stackTrace);
    }
    if (_nativeConnectRequestAckInFlightHandoffId == handoffId) {
      _nativeConnectRequestAckInFlightHandoffId = null;
    }
    if (_nativeConnectRequestHandoffId != handoffId) return null;
    if (startLease != null && startLease > 0) {
      _nativeConnectRequestPending = false;
      _nativeConnectRequestHandoffId = null;
      return startLease;
    }
    if (nativeAnswered) {
      // A concrete null means Android no longer owns this exact id: a
      // terminal Stop cancelled it or a newer gesture replaced it. Discard it
      // locally so a later Stopped -> Disconnected status cannot replay it.
      _nativeConnectRequestPending = false;
      _nativeConnectRequestHandoffId = null;
      loggy.info('native connect handoff was cancelled or replaced before claim');
    }
    // A transport exception has no native ownership answer. Retain the id;
    // redelivery or an authoritative status transition may retry it without a
    // timer, wake lock or polling watchdog.
    return null;
  }

  Future<NativeSatisfiedConnectResolution> _resolvePossiblySatisfiedNativeConnectRequest(
    int handoffId,
    ConnectionStatus? retainedStatus,
  ) async {
    if (_nativeConnectRequestHandoffId != handoffId || _nativeConnectRequestAckInFlightHandoffId == handoffId) {
      return NativeSatisfiedConnectResolution.cancelled;
    }
    _nativeConnectRequestAckInFlightHandoffId = handoffId;
    Object? nativeResolution;
    try {
      nativeResolution = await _nativeConnectRequestAcksChannel.invokeMethod<Object?>('ack_satisfied', {
        'handoffId': handoffId,
      });
    } catch (error, stackTrace) {
      loggy.warning('failed to retire satisfied native connect handoff', error, stackTrace);
    }
    if (_nativeConnectRequestAckInFlightHandoffId == handoffId) {
      _nativeConnectRequestAckInFlightHandoffId = null;
    }
    if (_nativeConnectRequestHandoffId != handoffId) return NativeSatisfiedConnectResolution.cancelled;
    final resolution = nativeSatisfiedConnectResolutionFromPlatform(nativeResolution);
    switch (resolution) {
      case NativeSatisfiedConnectResolution.satisfied:
        _nativeConnectRequestPending = false;
        _nativeConnectRequestHandoffId = null;
        loggy.info('native connect request was already satisfied by ${retainedStatus.runtimeType}');
      case NativeSatisfiedConnectResolution.connectRequired:
        loggy.info('service lifecycle rejected stale ${retainedStatus.runtimeType}; executing native Connect');
        _reserveNativeConnectIntent(handoffId);
        _executePendingNativeConnectRequest(handoffId, nativeServiceConfirmedInactive: true);
      case NativeSatisfiedConnectResolution.cancelled:
        _nativeConnectRequestPending = false;
        _nativeConnectRequestHandoffId = null;
        loggy.info('satisfied native connect handoff was already cancelled or replaced');
      case NativeSatisfiedConnectResolution.transportFailure:
        // Keep the request for exact native redelivery or the next
        // authoritative lifecycle transition. Never guess after IPC failure.
        loggy.warning('native lifecycle did not resolve the satisfied Connect handoff');
    }
    return resolution;
  }

  Future<void> _cancelNativeConnectClaim(int startLease) async {
    try {
      await _nativeConnectRequestAcksChannel.invokeMethod<bool>('cancel_claim', {'startLease': startLease});
    } catch (error, stackTrace) {
      // The authoritative terminal Stop path also invalidates this lease. A
      // transport failure here retains native ownership for safe redelivery;
      // it must not be converted into a speculative local start.
      loggy.warning('failed to cancel unused native connect claim', error, stackTrace);
    }
  }

  void _cancelPendingNativeConnectRequestForTerminalStop() {
    _nativeConnectRequestPending = false;
    _nativeConnectRequestHandoffId = null;
    _nativeConnectRequestAckInFlightHandoffId = null;
  }

  bool get _flutterOwnsAutomaticRecovery =>
      automaticConnectionRecoveryOwnerForPlatform(isAndroid: Platform.isAndroid) ==
      AutomaticConnectionRecoveryOwner.flutter;

  void checkRouteAfterResume() {
    final status = state.valueOrNull;
    if (status is Connected) {
      if (_flutterOwnsAutomaticRecovery) {
        _scheduleRouteWatchdogCheck(_routeWatchdogResumeDelayForCurrentRoute(), requireFreshRoute: true);
      }
      return;
    }
    if (shouldVerifyRouteAfterResume(
      status,
      startedByUser: ref.read(Preferences.startedByUser),
      canAdoptPlatformSession: Platform.isAndroid,
      operationInProgress: _singleStart.isRunning,
      verificationRunning: _startupRouteVerificationRunning,
      coreStarted: _connectionRepo.isCoreStartedSnapshot,
    )) {
      unawaited(_verifyExistingStartedRoute());
    }
  }

  void deferRouteWatchdogForBackground() {
    if (!Platform.isIOS || !_shouldRunRouteWatchdog) return;
    _scheduleRouteWatchdogCheck(_iosStableBackgroundRouteWatchdogInterval);
  }

  Future<void> mayConnect() async {
    if (state case AsyncData(:final value)) {
      if (value case Disconnected()) await _connect();
    }
  }

  Future<void> toggleConnection() async {
    if (state case AsyncError()) {
      await executeManualCommand(ManualConnectionCommand.connect);
    } else if (state case AsyncData(:final value)) {
      await executeManualCommand(manualConnectionCommandForStatus(value));
    }
  }

  Future<void> executeManualCommand(
    ManualConnectionCommand command, {
    bool queueConnectAfterCurrentOperation = false,
    bool nativeServiceConfirmedInactive = false,
    int? connectIntentGeneration,
    Future<int?> Function()? onConnectTransitionSealed,
  }) async {
    final currentStatus = state.valueOrNull;
    final commandIsValid = currentStatus != null && canExecuteManualConnectionCommand(command, currentStatus);
    final canRecoverFromError = command == ManualConnectionCommand.connect && state is AsyncError<ConnectionStatus>;
    final serviceOwnedNativeConnect = command == ManualConnectionCommand.connect && nativeServiceConfirmedInactive;
    if (!commandIsValid && !canRecoverFromError && !serviceOwnedNativeConnect) {
      loggy.debug("stale manual $command ignored for current status $currentStatus");
      return;
    }

    crashReporter.setContext('last_action', 'manual_${command.name}');

    final haptic = ref.read(hapticServiceProvider.notifier);
    switch (command) {
      case ManualConnectionCommand.connect:
        _sendManualHaptic(haptic.lightImpact());
        await _connect(
          queueAfterCurrentOperation: queueConnectAfterCurrentOperation,
          nativeServiceConfirmedInactive: nativeServiceConfirmedInactive,
          connectIntentGeneration: connectIntentGeneration,
          onConnectTransitionSealed: onConnectTransitionSealed,
        );
      case ManualConnectionCommand.disconnect:
        _sendManualHaptic(haptic.mediumImpact());
        await _stopFromManualCommand(currentStatus);
      case ManualConnectionCommand.abort:
        _sendManualHaptic(haptic.mediumImpact());
        await _stopFromManualCommand(currentStatus);
    }
  }

  Future<void> _stopFromManualCommand(ConnectionStatus? currentStatus) async {
    if (currentStatus is Connected || currentStatus is Connecting) {
      // A captured Stop supersedes every older platform-originated Connect
      // before the first await. Android cancels the retained bridge owner when
      // repository cleanup reaches BoxService.stop().
      _cancelPendingNativeConnectRequestForTerminalStop();
    }
    switch (currentStatus) {
      case Connecting():
        _abortConnectionImmediately();
      case Connected() when _singleStart.isRunning:
        // A lifecycle stream must never expose Connected before the startup
        // operation finishes, but a stop gesture still wins if one does.
        _abortConnectionImmediately();
      case Connected():
        await _disconnectFromManualCommand();
      case Disconnecting() || Disconnected() || null:
        // A stop already completed or is already owned by another tap. Never
        // reinterpret this captured stop intent as a new Connect.
        return;
    }
  }

  void _sendManualHaptic(Future<void> feedback) {
    unawaited(
      feedback.catchError((Object error, StackTrace stackTrace) {
        loggy.debug("haptic feedback failed: $error");
      }),
    );
  }

  Future<void> _disconnectFromManualCommand() async {
    var completed = false;
    var disconnectSucceeded = false;
    try {
      completed = await runExclusiveManualDisconnect(
        gate: _singleStart,
        setInProgress: (inProgress) => _manualButtonDisconnectInProgress = inProgress,
        task: () async {
          _markManualDisconnect();
          await ref.read(Preferences.startedByUser.notifier).update(false);
          disconnectSucceeded = await _disconnect();
        },
        onIgnored: () {
          loggy.debug("disconnect called while another connect/disconnect is still running, ignoring");
        },
      );
    } finally {
      if (shouldPublishManualDisconnectReleased(
        operationCompleted: completed,
        disconnectSucceeded: disconnectSucceeded,
      )) {
        await _settleManualDisconnectInput();
        loggy.info("manual disconnect fully released; reconnect is available");
      }
    }
  }

  Future<void> _settleManualDisconnectInput() async {
    // Android can deliver the tail of a rapid multi-tap after the VPN release
    // has already repainted the button as Connect. Keep a short explicit
    // transition lease so one physical gesture burst cannot become a new
    // lifecycle command after crossing the stop boundary.
    _manualDisconnectInputSettling = true;
    state = const AsyncData(Disconnecting());
    try {
      await Future<void>.delayed(manualDisconnectInputSettleDelay);
    } finally {
      _manualDisconnectInputSettling = false;
    }
    state = const AsyncData(Disconnected());
  }

  Future<void> _handleActiveProfileChange(
    ProfileEntity? previous,
    ProfileEntity? next,
    ConnectionRepository connectionRepo,
    int revision,
  ) async {
    if (previous != null && previous != next) {
      final candidateMatches = _sameRuntimeRelevantProfileFields(previous, next);
      final runtimeMatches =
          candidateMatches && state.valueOrNull is Connected && await connectionRepo.matchesActiveRuntimeConfig(next!);
      if (revision != _activeProfileChangeRevision) return;
      if (shouldPreserveConnectedSessionAfterProfileChange(
        previous: previous,
        next: next,
        activeRuntimeConfigMatches: runtimeMatches,
      )) {
        loggy.info('active profile metadata updated; keeping the verified connection');
        return;
      } else {
        await reconnect(next, repository: connectionRepo, waitForCurrent: true, supersedeQueued: true);
      }
    }
    if (revision != _activeProfileChangeRevision) return;
    await _syncNativeResumeConfigWhenIdle(repository: connectionRepo, activeProfileFuture: Future.value(next));
  }

  Future<void> reconnect(
    ProfileEntity? profile, {
    ConnectionRepository? repository,
    bool waitForCurrent = false,
    bool supersedeQueued = false,
  }) async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      final connectionRepo = repository ?? _connectionRepo;
      final startedByUserNotifier = ref.read(Preferences.startedByUser.notifier);
      final disableMemoryLimit = ref.read(Preferences.disableMemoryLimit);
      final dialogNotifier = ref.read(dialogNotifierProvider.notifier);
      final translationsFuture = ref.read(translationsProvider.future);
      if (profile == null) {
        loggy.info("no active profile, disconnecting");
        await _singleStart.run(
          () async {
            _markManualDisconnect();
            await startedByUserNotifier.update(false);
            await _disconnect(repository: connectionRepo);
          },
          onIgnored: () {
            loggy.debug("profile disconnect called while another connect/disconnect is still running, ignoring");
          },
          waitForCurrent: waitForCurrent,
          supersedeQueued: supersedeQueued,
          onSuperseded: () => loggy.debug("superseded queued profile disconnect"),
        );
        return;
      }
      loggy.info("active profile changed, reconnecting");
      await _singleStart.run(
        () async {
          // Unlike a fresh Connect, a profile restart can be rejected before
          // Flutter receives a restart lease. Retain this exact seal for the
          // authoritative platform status before awaiting the drain: a native
          // Stop may publish Disconnected during either await, and that event
          // must release this epoch rather than an older transition's epoch.
          final egressSeal = _sealAndroidOrdinaryNetworking('profile reconnect');
          final egressEpoch = Platform.isAndroid ? _androidEgressEpoch : null;
          if (Platform.isAndroid) {
            _androidPlatformTransitionEgressEpoch = egressEpoch;
          }
          await egressSeal;
          final restartLease = await connectionRepo.tryBeginFlutterRestart();
          if (restartLease == null) {
            loggy.info("Android native lifecycle rejected or terminally cancelled the Flutter restart");
            await _synchronizeAndroidTerminalUserIntent(repository: connectionRepo);
            if (Platform.isAndroid &&
                state.valueOrNull is Disconnected &&
                _androidPlatformTransitionEgressEpoch == egressEpoch) {
              _androidPlatformTransitionEgressEpoch = null;
              await _tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: egressEpoch);
            }
            return;
          }
          _manualDisconnectRequested = false;
          _showIdleDuringAbort = false;
          _cancelAutoReconnect();
          var releaseAfterRestartLease = false;
          try {
            if (!await connectionRepo.validateFlutterRestart(restartLease)) {
              loggy.info("Flutter restart lease was invalidated by terminal native Stop");
              await _synchronizeAndroidTerminalUserIntent(repository: connectionRepo);
              releaseAfterRestartLease = state.valueOrNull is Disconnected;
              return;
            }
            final result = await connectionRepo.reconnect(profile, disableMemoryLimit).run();
            await result.match((err) async {
              loggy.warning("error reconnecting", err);
              await startedByUserNotifier.update(false);
              final cleanup = await connectionRepo.disconnect().run();
              cleanup.match(
                (cleanupError) {
                  loggy.warning("error cleaning up failed reconnect", cleanupError);
                },
                (_) {
                  releaseAfterRestartLease = true;
                },
              );
              state = AsyncError(err, StackTrace.current);
              final translations = await translationsFuture;
              await dialogNotifier.showCustomAlertFromErr(err.present(translations));
            }, (_) => _admitAndroidOrdinaryNetworking(egressEpoch));
          } finally {
            await connectionRepo.endFlutterRestart(restartLease);
            if (releaseAfterRestartLease && Platform.isAndroid) {
              if (_androidPlatformTransitionEgressEpoch == egressEpoch) {
                _androidPlatformTransitionEgressEpoch = null;
              }
              await _tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: egressEpoch);
            }
          }
        },
        onIgnored: () {
          loggy.debug("reconnect called while another connect/disconnect is still running, ignoring");
        },
        waitForCurrent: waitForCurrent,
        supersedeQueued: supersedeQueued,
        onSuperseded: () => loggy.debug("superseded queued profile reconnect"),
      );
    }
  }

  Future<void> _synchronizeAndroidTerminalUserIntent({ConnectionRepository? repository}) async {
    if (!Platform.isAndroid) return;
    final terminalEgressEpoch = _androidEgressEpoch;
    final nativeIntent = await (repository ?? _connectionRepo).readPlatformStartedByUser();
    if (terminalEgressEpoch != _androidEgressEpoch ||
        state.valueOrNull is! Disconnected ||
        _manualConnectPending ||
        _nativeConnectRequestPending) {
      loggy.info('discarding terminal native-intent sync superseded by a newer Android lifecycle epoch');
      return;
    }
    if (nativeIntent == false && ref.read(Preferences.startedByUser)) {
      await ref.read(Preferences.startedByUser.notifier).update(false);
      loggy.info("synchronized terminal native Stop into the Flutter preference cache");
    }
  }

  Future<void> abortConnection() async {
    final currentStatus = state.valueOrNull;
    if (currentStatus is! Connected && currentStatus is! Connecting) return;
    loggy.debug("aborting connection");
    await _stopFromManualCommand(currentStatus);
  }

  final _singleStart = SingleCall();
  final _nativeResumeConfigSync = SingleCall();

  Future<void> _syncNativeResumeConfigWhenIdle({
    ConnectionRepository? repository,
    Future<ProfileEntity?>? activeProfileFuture,
  }) async {
    if (!Platform.isAndroid) return;
    final connectionRepo = repository ?? _connectionRepo;
    final profileFuture = activeProfileFuture ?? ref.read(activeProfileProvider.future);
    await _nativeResumeConfigSync.run(
      () async {
        if (_singleStart.isRunning || state.valueOrNull is! Disconnected) return;
        final activeProfile = await profileFuture;
        if (_singleStart.isRunning || state.valueOrNull is! Disconnected) return;
        final result = await connectionRepo.syncNativeResumeConfig(activeProfile).run();
        result.match((err) => loggy.warning('failed to synchronize native resume config', err), (_) {});
      },
      waitForCurrent: true,
      supersedeQueued: true,
      onIgnored: () {},
      onSuperseded: () {
        loggy.debug('superseded queued native resume config synchronization');
      },
    );
  }

  Future<bool> _connect({
    bool silent = false,
    bool queueAfterCurrentOperation = false,
    bool nativeServiceConfirmedInactive = false,
    int? connectIntentGeneration,
    Future<int?> Function()? onConnectTransitionSealed,
  }) async {
    final attemptIntentGeneration = connectIntentGeneration ?? ++_connectIntentGeneration;
    final connectionRepo = _connectionRepo;
    final activeProfileFuture = ref.read(activeProfileProvider.future);
    final startedByUserNotifier = ref.read(Preferences.startedByUser.notifier);
    final disableMemoryLimit = ref.read(Preferences.disableMemoryLimit);
    final analyticsController = ref.read(analyticsControllerProvider.notifier);
    final dialogNotifier = ref.read(dialogNotifierProvider.notifier);
    final translationsFuture = ref.read(translationsProvider.future);
    int? requestToken;
    ConnectionFailure? failureForPresentation;
    final lifecycleCompleted = await _singleStart.run(
      () async {
        if (queueAfterCurrentOperation &&
            !nativeServiceConfirmedInactive &&
            state.valueOrNull is! Disconnected &&
            state is! AsyncError<ConnectionStatus>) {
          // The operation that was active when the native gesture arrived may
          // already have satisfied it or may still be publishing terminal
          // status. Let the status listener decide without starting in parallel.
          return;
        }
        if (!silent) {
          requestToken = ++_abortToken;
          _showIdleDuringAbort = false;
          _manualDisconnectRequested = false;
          _cancelAutoReconnect();
          _manualConnectPending = true;
          state = const AsyncData(Connecting());
        }

        try {
          final attempted = await _connectThrottled(
            connectionRepo: connectionRepo,
            activeProfileFuture: activeProfileFuture,
            startedByUserNotifier: startedByUserNotifier,
            disableMemoryLimit: disableMemoryLimit,
            analyticsController: analyticsController,
            silent: silent,
            requestToken: requestToken,
            connectIntentGeneration: attemptIntentGeneration,
            onConnectTransitionSealed: onConnectTransitionSealed,
            onUserVisibleFailure: (failure) {
              failureForPresentation = failure;
            },
          );
          if (!attempted &&
              requestToken == _abortToken &&
              isCurrentConnectIntent(
                attemptGeneration: attemptIntentGeneration,
                currentGeneration: _connectIntentGeneration,
              )) {
            state = const AsyncData(Disconnected());
          }
        } finally {
          if (requestToken == _abortToken &&
              isCurrentConnectIntent(
                attemptGeneration: attemptIntentGeneration,
                currentGeneration: _connectIntentGeneration,
              )) {
            _manualConnectPending = false;
            if (state.valueOrNull is Connecting && !connectionRepo.isCoreStartedSnapshot) {
              loggy.warning("connect operation ended without a running core; publishing terminal disconnected state");
              state = const AsyncData(Disconnected());
            }
          }
        }
      },
      onIgnored: () {
        loggy.debug("connect called while another connect/disconnect is still running, ignoring");
      },
      waitForCurrent: queueAfterCurrentOperation,
      supersedeQueued: queueAfterCurrentOperation,
      onSuperseded: () {
        loggy.debug('superseded queued native connect handoff');
      },
    );
    final terminalFailure = failureForPresentation;
    if (terminalFailure != null) {
      // Error presentation belongs to the UI, not to the process-wide VPN
      // lifecycle transaction. In particular, a Quick Settings request can
      // fail while MainActivity is backgrounded: its DialogRoute may remain
      // open until the user returns, but it must never retain _singleStart or
      // the exact native handoff attempt that serializes a newer Connect.
      unawaited(
        _presentConnectionFailure(
          terminalFailure,
          dialogNotifier: dialogNotifier,
          translationsFuture: translationsFuture,
        ),
      );
    }
    return lifecycleCompleted;
  }

  Future<bool> _connectThrottled({
    required ConnectionRepository connectionRepo,
    required Future<ProfileEntity?> activeProfileFuture,
    required PreferencesNotifier<bool, bool> startedByUserNotifier,
    required bool disableMemoryLimit,
    required AnalyticsController analyticsController,
    bool silent = false,
    int? requestToken,
    required int connectIntentGeneration,
    Future<int?> Function()? onConnectTransitionSealed,
    required void Function(ConnectionFailure) onUserVisibleFailure,
  }) async {
    bool intentIsCurrent() =>
        isCurrentConnectIntent(attemptGeneration: connectIntentGeneration, currentGeneration: _connectIntentGeneration);
    final egressSeal = _sealAndroidOrdinaryNetworking('manual or automatic Connect');
    // _sealAndroidOrdinaryNetworking closes the process-local gate before its
    // first await. Only now may native transfer its durable handoff request.
    final handoffAcceptance = onConnectTransitionSealed?.call();
    // Every Android Flutter Connect, including a normal UI gesture, captures
    // native Stop ownership immediately after the synchronous Dart seal. The
    // profile/config awaits below may not manufacture a fresh session after a
    // later terminal Stop.
    final startLeaseFuture = Platform.isAndroid
        ? handoffAcceptance ?? connectionRepo.claimVpnStartLease()
        : Future<int?>.value();
    Future<void> cancelStartLease(int token) =>
        handoffAcceptance != null ? _cancelNativeConnectClaim(token) : connectionRepo.cancelVpnStartLease(token);
    int? egressEpoch;
    int? explicitStartLease;
    try {
      egressEpoch = await egressSeal;
      explicitStartLease = await startLeaseFuture;
    } catch (_) {
      try {
        final unusedLease = await startLeaseFuture;
        if (unusedLease != null) await cancelStartLease(unusedLease);
      } catch (error, stackTrace) {
        loggy.warning('failed to retire unused native Connect lease', error, stackTrace);
      }
      rethrow;
    }
    if (Platform.isAndroid && explicitStartLease == null) {
      loggy.info('native Connect lease was cancelled or could not be acquired; start remains rejected');
      if (state.valueOrNull is Disconnected || state is AsyncError<ConnectionStatus>) {
        // The native gate independently requires completed VPN/TUN cleanup for
        // this exact probe-block epoch. A concurrent Stop therefore leaves the
        // gate sealed until its authoritative release path completes.
        await _releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: egressEpoch);
      }
      return false;
    }
    var nativeClaimNeedsCancellation = explicitStartLease != null;
    try {
      final activeProfile = await activeProfileFuture;
      if (!intentIsCurrent()) {
        loggy.info('retiring a Connect superseded by a newer exact user intent before native VPN admission');
        return false;
      }
      if (_manualDisconnectRequested || _showIdleDuringAbort || (requestToken != null && requestToken != _abortToken)) {
        // A terminal Stop may win while this Connect is waiting for its
        // profile. Do not let the stale request consume its lease, clear the
        // native Stop tombstone, or dispatch VpnService. The finally block
        // retires the exact still-unconsumed lease; the Stop path owns the
        // fail-closed egress seal and its eventual release.
        loggy.info('retiring a superseded Connect before native VPN admission');
        return false;
      }
      if (activeProfile == null) {
        loggy.info("no active profile, not connecting");
        await startedByUserNotifier.update(false);
        // No platform start was admitted. Retire the exact native lease before
        // asking the terminal-release gate to prove that no newer Connect or
        // still-live VPN/TUN owner exists.
        final leaseToCancel = explicitStartLease;
        if (leaseToCancel != null) {
          await cancelStartLease(leaseToCancel);
          nativeClaimNeedsCancellation = false;
        }
        if (Platform.isAndroid) {
          final cleanup = await connectionRepo.disconnect().run();
          await cleanup.match((cleanupError) {
            loggy.warning('failed to prove terminal platform release after empty-profile Connect', cleanupError);
            return Future<void>.value();
          }, (_) => _releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: egressEpoch));
        }
        return false;
      }
      final result = await connectionRepo
          .beginVpnStartAdmission(explicitStartLease: explicitStartLease, nativeHandoffClaim: handoffAcceptance != null)
          .map((value) {
            // A successful native admission consumes the exact lease before
            // replying. Every earlier exceptional/null-profile exit retains
            // cancellation ownership in this method's finally block.
            nativeClaimNeedsCancellation = false;
            return value;
          })
          .flatMap(
            (admissionEpoch) => TaskEither.tryCatch(() async {
              final superseded =
                  _manualDisconnectRequested ||
                  _showIdleDuringAbort ||
                  (requestToken != null && requestToken != _abortToken);
              if (!intentIsCurrent()) {
                throw StateError('VPN start admission was superseded by a newer exact Connect intent');
              }
              if (superseded) {
                await startedByUserNotifier.update(false);
                await connectionRepo.disconnect().run();
                throw StateError('VPN start admission was superseded by disconnect');
              }
              // Native persistence and every ordinary Marten socket are now
              // behind the physical full-route blocker. Only this admitted
              // point may publish the Flutter-side user-session intent.
              await startedByUserNotifier.update(true);
              if (!intentIsCurrent()) {
                throw StateError('VPN start was superseded while publishing a newer exact Connect intent');
              }
              if (_manualDisconnectRequested ||
                  _showIdleDuringAbort ||
                  (requestToken != null && requestToken != _abortToken)) {
                await startedByUserNotifier.update(false);
                await connectionRepo.disconnect().run();
                throw StateError('VPN start was superseded while publishing admitted intent');
              }
              return admissionEpoch;
            }, (err, stackTrace) => ConnectionFailure.unexpected(err, stackTrace)),
          )
          .flatMap(
            (admissionEpoch) =>
                connectionRepo.connect(activeProfile, disableMemoryLimit, androidVpnStartEpoch: admissionEpoch),
          )
          .run();
      await result.match(
        (ConnectionFailure err) async {
          if (!intentIsCurrent()) {
            // The authoritative Stop already owns the previous core/TUN cleanup.
            // Issuing another terminal disconnect here would cancel the retained
            // newer native handoff, which is exactly the rapid QS race.
            loggy.info('discarding rejected Connect cleanup superseded by a newer exact user intent');
            return;
          }
          if (requestToken != null && requestToken != _abortToken) {
            loggy.info("ignoring connection failure from a superseded manual connect", err);
            return;
          }
          if (_manualDisconnectRequested || _showIdleDuringAbort) {
            loggy.info("ignoring connection failure after manual abort", err);
            state = AsyncData(
              visibleStatusDuringManualButtonDisconnect(
                const Disconnected(),
                disconnectInProgress: _manualButtonDisconnectInProgress,
              ),
            );
            return;
          }
          final cleanup = await connectionRepo.disconnect().run();
          await cleanup.match(
            (cleanupError) {
              loggy.warning('failed to complete platform cleanup after rejected Connect', cleanupError);
              return Future<void>.value();
            },
            (_) async {
              loggy.info('platform cleanup completed after rejected Connect');
              await _releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: egressEpoch);
            },
          );
          loggy.warning("error connecting", err);
          if (err.toString().contains("panic")) {
            await analyticsController.recordNonFatal(
              StateError('native core panic reported during connect'),
              StackTrace.current,
              reason: 'native_core_panic_connect',
            );
          }
          // Repository startup failures are reported only after the core and TUN
          // stop/close path completes. Publish a terminal value before opening the
          // dialog so a dismissed or failed dialog can never retain Connecting.
          await startedByUserNotifier.update(false);
          if (silent) {
            loggy.warning("auto reconnect attempt failed", err);
            _lastSilentAutoReconnectFailure = err;
            state = AsyncData(_visibleStatusDuringAutoReconnect(Disconnected(err)));
            return;
          }
          state = AsyncData(Disconnected(err));
          // Presentation is captured only after platform cleanup and terminal
          // state publication. The caller schedules it after _singleStart has
          // released the exact lifecycle owner.
          onUserVisibleFailure(err);
          loggy.warning(err);
        },
        (_) {
          if (!intentIsCurrent()) {
            loggy.info('discarding successful Connect completion superseded by a newer exact user intent');
            return Future<void>.value();
          }
          return _admitAndroidOrdinaryNetworking(egressEpoch);
        },
      );
      return true;
    } finally {
      if (nativeClaimNeedsCancellation && explicitStartLease != null) {
        await cancelStartLease(explicitStartLease);
      }
    }
  }

  Future<void> _presentConnectionFailure(
    ConnectionFailure failure, {
    required DialogNotifier dialogNotifier,
    required Future<Translations> translationsFuture,
  }) async {
    try {
      final translations = await translationsFuture;
      await dialogNotifier.showCustomAlertFromErr(failure.present(translations));
    } catch (error, stackTrace) {
      // A failed or dismissed presentation can lose only the UI message. The
      // terminal VPN/core/TUN state and any newer native handoff are already
      // independent of this future.
      loggy.warning('failed to present terminal connection error', error, stackTrace);
    }
  }

  Future<bool> _disconnect({bool showError = true, ConnectionRepository? repository}) async {
    final egressEpoch = await _sealAndroidOrdinaryNetworking('Disconnect');
    var egressReleased = !Platform.isAndroid;
    final connectionRepo = repository ?? _connectionRepo;
    final dialogNotifier = ref.read(dialogNotifierProvider.notifier);
    final translationsFuture = ref.read(translationsProvider.future);
    final result = await connectionRepo.disconnect().run();
    await result.match(
      (err) {
        loggy.warning("error disconnecting", err);
        if (!showError) return Future<void>.value();
        state = AsyncError(err, StackTrace.current);
        unawaited(
          translationsFuture.then((translations) {
            return dialogNotifier.showCustomAlertFromErr(err.present(translations));
          }),
        );
        return Future<void>.value();
      },
      (_) async {
        egressReleased = await _tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: egressEpoch);
      },
    );
    return result.isRight() && egressReleased;
  }

  Future<int?> _sealAndroidOrdinaryNetworking(String reason) async {
    if (!Platform.isAndroid) return null;
    // Async functions run synchronously until their first await. Seal the
    // process-local gate before even starting the SharedPreferences write so
    // an already-scheduled Dio/Firebase callback cannot open a physical socket
    // during that platform-channel/disk gap.
    final sealOperation = strictVpnEgressGate.sealForVpnTransition();
    final epoch = ++_androidEgressEpoch;
    await _serializeAndroidEgressPreference(() async {
      await ref.read(Preferences.strictVpnRouteVerified.notifier).update(false);
    });
    await sealOperation;
    loggy.info('ordinary Marten networking quiesced for strict VPN transition: $reason epoch=$epoch');
    return epoch;
  }

  Future<void> _ensureAndroidOrdinaryNetworkingSealed(String reason) async {
    if (!Platform.isAndroid || strictVpnEgressGate.isSealed) return;
    final sealOperation = _sealAndroidOrdinaryNetworking(reason);
    // _sealAndroidOrdinaryNetworking advances the epoch synchronously before
    // its first await. Retain that exact platform-owned epoch so a native-only
    // Stop can reopen direct networking after authoritative Disconnected.
    _androidPlatformTransitionEgressEpoch = _androidEgressEpoch;
    await sealOperation;
  }

  void _adoptBootstrapAndroidEgressSeal() {
    if (!Platform.isAndroid || !strictVpnEgressGate.isSealed || _androidPlatformTransitionEgressEpoch != null) {
      return;
    }
    // lazyBootstrap can seal the process before this notifier exists. Adopt
    // that already-drained transition into the notifier's current epoch so an
    // early resume failure can release it on authoritative Disconnected. Any
    // newer Connect advances _androidEgressEpoch and makes that release stale.
    _androidPlatformTransitionEgressEpoch = _androidEgressEpoch;
    loggy.info('adopted bootstrap strict-egress seal epoch=$_androidEgressEpoch');
  }

  Future<void> _releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect({int? expectedEpoch}) async {
    await _tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: expectedEpoch);
  }

  Future<bool> _tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect({int? expectedEpoch}) async {
    if (!Platform.isAndroid) return true;
    if (expectedEpoch != null && expectedEpoch != _androidEgressEpoch) {
      loggy.info(
        'discarding stale terminal ordinary-network release epoch=$expectedEpoch current=$_androidEgressEpoch',
      );
      return false;
    }
    // Invalidate every in-flight admit before reopening direct networking for
    // an authoritative user-visible terminal Disconnect.
    _androidEgressEpoch += 1;
    final releaseEpoch = _androidEgressEpoch;
    final released = await strictVpnEgressGate.releaseAfterTerminalDisconnect();
    if (!released) {
      loggy.info('terminal ordinary-network release was rejected by native gate epoch=$releaseEpoch');
      return false;
    }
    if (releaseEpoch != _androidEgressEpoch) {
      loggy.info('terminal ordinary-network release was superseded epoch=$releaseEpoch current=$_androidEgressEpoch');
      return false;
    }
    loggy.info('ordinary Marten networking released after authoritative terminal Disconnect');
    return true;
  }

  bool _ownsCurrentAndroidEgressEpoch(int? epoch) {
    // On Android, Connected is emitted only from BoxService's Started state.
    // BoxService publishes Started after the current VPN generation has a real
    // TUN and verified default routes, and the native gate below revalidates
    // that proof. The separate runtime-core snapshot can briefly lag behind
    // the authoritative platform state after an underlying-network recovery;
    // requiring it here would leave ordinary networking sealed indefinitely.
    return epoch != null &&
        epoch == _androidEgressEpoch &&
        state.valueOrNull is Connected &&
        !_manualDisconnectRequested &&
        !_showIdleDuringAbort;
  }

  Future<void> _admitAndroidOrdinaryNetworking(int? epoch) async {
    if (!Platform.isAndroid) return;
    if (!_ownsCurrentAndroidEgressEpoch(epoch)) {
      loggy.info('discarding stale ordinary-network admission epoch=$epoch current=$_androidEgressEpoch');
      return;
    }
    final turncoatLiveness = ref.read(turncoatLivenessNotifierProvider.notifier);
    final turncoatLivenessGeneration = turncoatLiveness.generation;
    // On Android this Connected state is published only after the native
    // service proves HTTP and DNS through the current VPN Network/TUN. Settle
    // the exact liveness generation before any async persistence so a warm
    // carrier restart cannot be stopped by its 75-second startup timer.
    turncoatLiveness.acceptVerifiedRouteProof(expectedGeneration: turncoatLivenessGeneration);
    final gateAdmitted = await strictVpnEgressGate.admitVerifiedVpnRoute();
    if (!gateAdmitted) {
      loggy.info('ordinary-network admission superseded at native gate epoch=$epoch');
      return;
    }
    var persistedForCurrentOwner = false;
    await _serializeAndroidEgressPreference(() async {
      if (!_ownsCurrentAndroidEgressEpoch(epoch) || strictVpnEgressGate.isSealed) {
        await ref.read(Preferences.strictVpnRouteVerified.notifier).update(false);
        return;
      }
      await ref.read(Preferences.strictVpnRouteVerified.notifier).update(true);
      if (!_ownsCurrentAndroidEgressEpoch(epoch) || strictVpnEgressGate.isSealed) {
        // Stop may synchronously advance the epoch while the async preference
        // write is in flight. Restore the fail-closed value before releasing
        // this serialized persistence slot to a newer generation.
        await ref.read(Preferences.strictVpnRouteVerified.notifier).update(false);
        return;
      }
      persistedForCurrentOwner = true;
    });
    if (!persistedForCurrentOwner) {
      loggy.info('ordinary-network admission superseded after persistence epoch=$epoch');
      return;
    }
    if (_androidPlatformTransitionEgressEpoch == epoch) {
      _androidPlatformTransitionEgressEpoch = null;
    }
    loggy.info('ordinary Marten networking admitted through verified Android VPN route epoch=$epoch');

    final activeStart = _androidNetworkServicesStart;
    if (activeStart != null) return activeStart;
    final start = _startAndroidNetworkServicesAfterVerifiedRoute();
    _androidNetworkServicesStart = start;
    try {
      await start;
    } finally {
      if (identical(_androidNetworkServicesStart, start)) _androidNetworkServicesStart = null;
    }
  }

  Future<void> _serializeAndroidEgressPreference(Future<void> Function() operation) {
    final run = _androidEgressPreferenceOperation.then((_) => operation());
    _androidEgressPreferenceOperation = run.then<void>((_) {}, onError: (_, _) {});
    return run;
  }

  Future<void> _startAndroidNetworkServicesAfterVerifiedRoute() async {
    // Manifest auto-init is disabled. These SDKs are deliberately constructed
    // only after the process has been bound to a route-verified VPN Network.
    try {
      final crashReportingEnabled = await ref.read(analyticsControllerProvider.future);
      if (crashReportingEnabled) {
        await ref.read(analyticsControllerProvider.notifier).ensureInitialized(refreshNativeReports: true);
      }
    } catch (error, stackTrace) {
      loggy.warning('VPN-admitted crash reporting initialization failed', error, stackTrace);
    }

    try {
      registerSubscriptionPushBackgroundHandler();
      await ref.read(subscriptionPushRefreshServiceProvider).initialize(debug: ref.read(debugModeNotifierProvider));
    } catch (error, stackTrace) {
      loggy.warning('VPN-admitted subscription push initialization failed', error, stackTrace);
    }

    try {
      if (!_androidBackgroundRefreshRegistered) {
        await initializeProfilesBackgroundRefresh(debug: ref.read(debugModeNotifierProvider));
        _androidBackgroundRefreshRegistered = true;
      }
    } catch (error, stackTrace) {
      loggy.warning('VPN-admitted background refresh initialization failed', error, stackTrace);
    }
  }

  void _abortConnectionImmediately() {
    final token = ++_abortToken;
    _manualConnectPending = false;
    _showIdleDuringAbort = true;
    _manualButtonDisconnectInProgress = true;
    _markManualDisconnect();
    _singleStart.cancel();
    _resetTransientConnectionFeatures();
    state = const AsyncData(Disconnecting());
    unawaited(ref.read(Preferences.startedByUser.notifier).update(false));
    unawaited(_disconnectAfterAbort(token));
  }

  Future<void> _disconnectAfterAbort(int token) async {
    var disconnectSucceeded = await _disconnect(showError: false).onError((error, stackTrace) {
      loggy.error("aborted connection cleanup threw; keeping reconnect unavailable", error, stackTrace);
      return false;
    });
    // SingleCall.cancel invalidates queued starts but cannot interrupt a start
    // that is already inside the native call. The platform disconnect above
    // makes that call unwind; wait for its finally block to release the exact
    // explicit-start lease before asking native admission to reopen egress.
    await _singleStart.waitForCurrent();
    if (_abortToken != token) return;
    if (!disconnectSucceeded) {
      disconnectSucceeded =
          await _tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: _androidEgressEpoch).onError(
            (error, stackTrace) {
              loggy.error(
                "aborted connection egress release retry threw; keeping reconnect unavailable",
                error,
                stackTrace,
              );
              return false;
            },
          );
    }
    if (!disconnectSucceeded) {
      loggy.warning("aborted connection cleanup did not complete; keeping reconnect unavailable");
      return;
    }
    _showIdleDuringAbort = false;
    _manualButtonDisconnectInProgress = false;
    await _settleManualDisconnectInput();
    loggy.info("aborted connection cleanup fully released; reconnect is available");
  }

  Future<void> _handleTurncoatConnectTimeout() async {
    if (!ref.read(turncoatLivenessNotifierProvider).timedOut) return;
    if (_manualDisconnectRequested) return;
    if (_singleStart.isRunning) {
      loggy.info("TURNcoat startup timeout observed during active connection operation; repository will handle it");
      return;
    }
    loggy.warning("TURNcoat route did not become live before timeout; stopping connection");
    const err = ConnectionFailure.unexpected("connection timed out while waiting for TURNcoat route");
    _markManualDisconnect();
    _singleStart.cancel();
    await ref.read(Preferences.startedByUser.notifier).update(false);
    await _disconnect();
    await ref
        .read(dialogNotifierProvider.notifier)
        .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
    state = AsyncError(err, StackTrace.current);
  }

  void _handleAutoReconnectTransition(ConnectionStatus? previousStatus, ConnectionStatus? nextStatus) {
    if (nextStatus is Connected) {
      _manualDisconnectRequested = false;
      _resetAutoReconnect();
      return;
    }
    if (!_flutterOwnsAutomaticRecovery) {
      _cancelAutoReconnect();
      return;
    }
    if (nextStatus is! Disconnected) return;
    if (_manualDisconnectRequested || !ref.read(Preferences.startedByUser)) return;
    if (!shouldScheduleAutoReconnectForTransition(
      previousStatus,
      nextStatus,
      operationInProgress: _showIdleDuringAbort || _singleStart.isRunning,
    )) {
      return;
    }

    _scheduleAutoReconnect();
  }

  void _handleRouteWatchdogTransition(ConnectionStatus? nextStatus) {
    if (!_flutterOwnsAutomaticRecovery) {
      _stopRouteWatchdog();
      return;
    }
    if (nextStatus is Connected && ref.read(Preferences.startedByUser)) {
      _startRouteWatchdog();
      return;
    }
    if (nextStatus is! Connected) {
      _stopRouteWatchdog();
    }
  }

  void _handleStartupRouteVerification(ConnectionStatus? nextStatus) {
    if (nextStatus is! Connecting) {
      _awaitingAndroidAuthoritativeRecoveryStatus = false;
      _cancelExistingStartedRouteVerificationRetry();
      return;
    }
    if (_awaitingAndroidAuthoritativeRecoveryStatus) return;
    if (_existingStartedRouteVerificationRetryTimer?.isActive == true) return;
    if (!shouldVerifyRouteAfterResume(
      nextStatus,
      startedByUser: ref.read(Preferences.startedByUser),
      canAdoptPlatformSession: Platform.isAndroid,
      operationInProgress: _singleStart.isRunning,
      verificationRunning: _startupRouteVerificationRunning,
      coreStarted: _connectionRepo.isCoreStartedSnapshot,
    )) {
      return;
    }
    unawaited(_verifyExistingStartedRoute());
  }

  Future<void> _verifyExistingStartedRoute() async {
    _existingStartedRouteVerificationRetryTimer?.cancel();
    _existingStartedRouteVerificationRetryTimer = null;
    _startupRouteVerificationRunning = true;
    try {
      final flutterStartedByUser = ref.read(Preferences.startedByUser);
      final platformStartedByUser = Platform.isAndroid ? await _connectionRepo.readPlatformStartedByUser() : null;
      final ownsSession = existingStartedSessionIsOwned(
        flutterStartedByUser: flutterStartedByUser,
        platformStartedByUser: platformStartedByUser,
      );
      if (Platform.isAndroid && platformStartedByUser != null && platformStartedByUser != flutterStartedByUser) {
        await ref.read(Preferences.startedByUser.notifier).update(platformStartedByUser);
        loggy.info("synchronized Flutter user-started session flag from Android: $platformStartedByUser");
      }
      if (!ownsSession) {
        loggy.warning("started core has no active native user-session intent; stopping stale cold-attach runtime");
        await _disconnect(showError: false);
        state = const AsyncData(Disconnected());
        return;
      }
      if (Platform.isAndroid) {
        // A retained native TURNcoat session can request CAPTCHA before the
        // Flutter status stream has proved and adopted that session. Arm only
        // after native ownership is confirmed so CaptchaNotifier replays that
        // bounded deferred request while route verification is still pending.
        ref.read(captchaNotifierProvider.notifier).arm(enabled: true);
        loggy.info("armed captcha watcher for owned existing Android session");
      }
      if (Platform.isIOS) {
        final abortToken = _abortToken;
        final intentGeneration = _connectIntentGeneration;
        ProfileEntity? profile;
        try {
          profile = await ref.read(activeProfileProvider.future).timeout(const Duration(seconds: 8));
        } catch (_) {
          loggy.warning('retained iOS profile did not become available within its bounded wait');
        }
        final profileRevision = _activeProfileChangeRevision;
        bool retainedSessionIsCurrent() =>
            abortToken == _abortToken &&
            intentGeneration == _connectIntentGeneration &&
            profileRevision == _activeProfileChangeRevision &&
            !_manualDisconnectRequested &&
            ref.read(Preferences.startedByUser);
        if (!retainedSessionIsCurrent()) return;
        final restored =
            profile != null &&
            await _connectionRepo.restoreActiveRuntimeFeatures(profile, isCurrent: retainedSessionIsCurrent);
        if (!retainedSessionIsCurrent()) return;
        if (!restored) {
          loggy.warning('retained iOS runtime no longer matches the selected profile');
          await _disconnect(showError: false);
          state = const AsyncData(Disconnected());
          return;
        }
      }
      loggy.info("verifying existing started route before showing connected");
      final retainedLiveness = Platform.isIOS ? ref.read(turncoatLivenessNotifierProvider.notifier) : null;
      final retainedLivenessGeneration = retainedLiveness?.generation;
      final result = await _connectionRepo.verifyConnectedRoute(holdStartupRouteReady: true).run();
      await result.match(
        (err) async {
          loggy.warning("existing started route verification failed", err);
          if (!_manualDisconnectRequested && ref.read(Preferences.startedByUser)) {
            if (!_flutterOwnsAutomaticRecovery) {
              _existingStartedRouteVerificationFailures = 0;
              _existingStartedRouteVerificationRetryTimer?.cancel();
              _existingStartedRouteVerificationRetryTimer = null;
              _awaitingAndroidAuthoritativeRecoveryStatus = true;
              loggy.info("delegating automatic route recovery to Android and awaiting authoritative status");
              return;
            }
            final liveness = ref.read(turncoatLivenessNotifierProvider);
            _existingStartedRouteVerificationFailures++;
            if (shouldRetryExistingTurncoatRouteWithoutRestart(
              turncoatInUse: liveness.inUse,
              turncoatLive: liveness.live,
              turncoatTimedOut: liveness.timedOut,
              consecutiveFailures: _existingStartedRouteVerificationFailures,
              maxFailures: _existingTurncoatRouteVerificationMaxFailures,
            )) {
              loggy.warning(
                "keeping live TURNcoat carrier while backend route recovers "
                "($_existingStartedRouteVerificationFailures/$_existingTurncoatRouteVerificationMaxFailures)",
              );
              _scheduleExistingStartedRouteVerificationRetry();
              return;
            }
            _existingStartedRouteVerificationFailures = 0;
            await _reconnectAfterRouteWatchdogFailure(err);
          }
        },
        (_) {
          if (retainedLiveness != null &&
              retainedLivenessGeneration != null &&
              !_manualDisconnectRequested &&
              ref.read(Preferences.startedByUser)) {
            retainedLiveness.acceptVerifiedRouteProof(expectedGeneration: retainedLivenessGeneration);
          }
          _awaitingAndroidAuthoritativeRecoveryStatus = false;
          _existingStartedRouteVerificationFailures = 0;
          _cancelExistingStartedRouteVerificationRetry();
          loggy.info("existing started route verified");
        },
      );
    } finally {
      _startupRouteVerificationRunning = false;
    }
  }

  void _scheduleExistingStartedRouteVerificationRetry({Duration delay = _existingTurncoatRouteVerificationRetryDelay}) {
    _existingStartedRouteVerificationRetryTimer?.cancel();
    _existingStartedRouteVerificationRetryTimer = Timer(delay, () {
      _existingStartedRouteVerificationRetryTimer = null;
      if (_startupRouteVerificationRunning ||
          _manualDisconnectRequested ||
          !ref.read(Preferences.startedByUser) ||
          _singleStart.isRunning ||
          !_connectionRepo.isCoreStartedSnapshot ||
          state.valueOrNull is! Connecting) {
        return;
      }
      unawaited(_verifyExistingStartedRoute());
    });
  }

  void _cancelExistingStartedRouteVerificationRetry() {
    _existingStartedRouteVerificationRetryTimer?.cancel();
    _existingStartedRouteVerificationRetryTimer = null;
    _existingStartedRouteVerificationFailures = 0;
    _awaitingAndroidAuthoritativeRecoveryStatus = false;
  }

  void _startRouteWatchdog() {
    if (!_flutterOwnsAutomaticRecovery) return;
    if (_routeWatchdogTimer?.isActive == true || _routeWatchdogRunning) return;
    _routeWatchdogFailures = 0;
    _scheduleRouteWatchdogCheck(_routeWatchdogInitialDelayForCurrentRoute());
  }

  Duration _routeWatchdogInitialDelayForCurrentRoute() {
    if (Platform.isIOS) return _iosStableRouteWatchdogIntervalForCurrentLifecycle();
    return _isTurncoatRouteInUse ? _turncoatRouteWatchdogInitialDelay : _routeWatchdogInitialDelay;
  }

  Duration _routeWatchdogIntervalForCurrentRoute({bool? turncoatInUse}) {
    if (Platform.isIOS) return _iosStableRouteWatchdogIntervalForCurrentLifecycle();
    return (turncoatInUse ?? _isTurncoatRouteInUse) ? _turncoatRouteWatchdogInterval : _routeWatchdogInterval;
  }

  Duration _iosStableRouteWatchdogIntervalForCurrentLifecycle() =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed
      ? _iosStableRouteWatchdogInterval
      : _iosStableBackgroundRouteWatchdogInterval;

  Duration _routeWatchdogRetryDelayForCurrentRoute({bool? turncoatInUse}) {
    return (turncoatInUse ?? _isTurncoatRouteInUse) ? _turncoatRouteWatchdogRetryDelay : _routeWatchdogRetryDelay;
  }

  Duration _routeWatchdogResumeDelayForCurrentRoute() {
    return _isTurncoatRouteInUse ? _turncoatRouteWatchdogResumeDelay : _routeWatchdogResumeDelay;
  }

  int _routeWatchdogMaxFailuresForCurrentRoute({bool? turncoatInUse}) {
    if (Platform.isIOS && (turncoatInUse ?? _isTurncoatRouteInUse)) return 2;
    return (turncoatInUse ?? _isTurncoatRouteInUse) ? _turncoatRouteWatchdogMaxFailures : _routeWatchdogMaxFailures;
  }

  bool get _isTurncoatRouteInUse {
    final turncoat = ref.read(turncoatLivenessNotifierProvider);
    return turncoat.inUse || turncoat.live;
  }

  void _scheduleRouteWatchdogCheck(Duration delay, {bool requireFreshRoute = false}) {
    if (requireFreshRoute) {
      _nextRouteWatchdogCheckRequiresFreshRoute = true;
    }
    _routeWatchdogTimer?.cancel();
    _routeWatchdogTimer = Timer(delay, () {
      _routeWatchdogTimer = null;
      unawaited(_runRouteWatchdogCheck());
    });
  }

  bool get _shouldRunRouteWatchdog =>
      _flutterOwnsAutomaticRecovery &&
      !_manualDisconnectRequested &&
      ref.read(Preferences.startedByUser) &&
      state.valueOrNull is Connected &&
      !_autoReconnectRunning;

  bool get _shouldManageRouteWatchdogFailure =>
      !_manualDisconnectRequested && ref.read(Preferences.startedByUser) && !_autoReconnectRunning;

  Future<void> _runRouteWatchdogCheck() async {
    if (_routeWatchdogRunning) return;
    if (!_shouldRunRouteWatchdog) {
      _stopRouteWatchdog();
      return;
    }
    if (_singleStart.isRunning) {
      _scheduleRouteWatchdogCheck(_routeWatchdogRetryDelayForCurrentRoute());
      return;
    }

    _routeWatchdogRunning = true;
    final requireFreshRoute = _nextRouteWatchdogCheckRequiresFreshRoute;
    _nextRouteWatchdogCheckRequiresFreshRoute = false;
    final turncoatInUse = _isTurncoatRouteInUse;
    final maxFailures = _routeWatchdogMaxFailuresForCurrentRoute(turncoatInUse: turncoatInUse);
    var nextDelay = _routeWatchdogIntervalForCurrentRoute(turncoatInUse: turncoatInUse);
    var keepChecking = true;
    try {
      final result = await _connectionRepo.verifyConnectedRoute().run();
      if (!_shouldManageRouteWatchdogFailure) return;
      await result.match(
        (err) async {
          _routeWatchdogFailures = nextRouteWatchdogFailureCount(
            _routeWatchdogFailures,
            routeHealthy: false,
            requireFreshRoute: requireFreshRoute,
            preserveLongLivedRoute: turncoatInUse,
            maxFailures: maxFailures,
          );
          loggy.warning(
            turncoatInUse && !Platform.isIOS
                ? "route watchdog failed ($_routeWatchdogFailures/$maxFailures, preserving TURNcoat route)"
                : "route watchdog failed ($_routeWatchdogFailures/$maxFailures)",
            err,
          );
          if (shouldReconnectAfterRouteWatchdogFailures(
            _routeWatchdogFailures,
            maxFailures: maxFailures,
            preserveLongLivedRoute: turncoatInUse,
            isIOS: Platform.isIOS,
          )) {
            final reconnectStarted = await _reconnectAfterRouteWatchdogFailure(err);
            keepChecking = !reconnectStarted;
            if (!reconnectStarted) nextDelay = _routeWatchdogRetryDelayForCurrentRoute(turncoatInUse: turncoatInUse);
          } else {
            nextDelay = _routeWatchdogRetryDelayForCurrentRoute(turncoatInUse: turncoatInUse);
          }
        },
        (_) {
          if (_routeWatchdogFailures > 0) {
            loggy.info("route watchdog recovered after $_routeWatchdogFailures failed check(s)");
          }
          _routeWatchdogFailures = nextRouteWatchdogFailureCount(_routeWatchdogFailures, routeHealthy: true);
        },
      );
    } finally {
      _routeWatchdogRunning = false;
    }

    if (keepChecking && _shouldRunRouteWatchdog && _routeWatchdogTimer == null) {
      _scheduleRouteWatchdogCheck(nextDelay);
    }
  }

  Future<bool> _reconnectAfterRouteWatchdogFailure(ConnectionFailure cause) async {
    if (!_flutterOwnsAutomaticRecovery) {
      loggy.info("automatic route recovery is owned by the Android service");
      return false;
    }
    if (!_shouldManageRouteWatchdogFailure) return false;
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) {
      loggy.warning("route watchdog stopped connection: no active profile");
      _markManualDisconnect();
      await ref.read(Preferences.startedByUser.notifier).update(false);
      await _disconnect(showError: false);
      return true;
    }

    loggy.warning("route watchdog reconnecting after failed health checks", cause);
    var reconnectFailed = false;
    final started = await _singleStart.run(
      () async {
        _manualDisconnectRequested = false;
        _showIdleDuringAbort = false;
        _cancelAutoReconnect();
        await ref.read(Preferences.startedByUser.notifier).update(true);
        final result = await _connectionRepo.reconnect(activeProfile, ref.read(Preferences.disableMemoryLimit)).run();
        await result.match(
          (err) async {
            reconnectFailed = true;
            loggy.warning("route watchdog reconnect failed", err);
            await _disconnect(showError: false);
          },
          (_) {
            _routeWatchdogFailures = 0;
            loggy.info("route watchdog reconnect completed");
            _scheduleRouteWatchdogCheck(_routeWatchdogInitialDelayForCurrentRoute());
          },
        );
      },
      onIgnored: () {
        loggy.debug("route watchdog reconnect skipped while another connection operation is running");
      },
    );
    if (reconnectFailed && !_manualDisconnectRequested && ref.read(Preferences.startedByUser)) {
      _scheduleAutoReconnect();
    }
    return started;
  }

  void _stopRouteWatchdog() {
    _routeWatchdogTimer?.cancel();
    _routeWatchdogTimer = null;
    _nextRouteWatchdogCheckRequiresFreshRoute = false;
    _routeWatchdogFailures = 0;
  }

  ConnectionStatus _visibleStatusAfterAbort(ConnectionStatus event) {
    final visible = visibleStatusAfterAbort(event, showIdleDuringAbort: _showIdleDuringAbort);
    if (!identical(visible, event) && visible != event) {
      loggy.debug("hiding ${event.format()} while abort cleanup is running");
    }
    return visible;
  }

  void _markManualDisconnect() {
    _manualDisconnectRequested = true;
    _cancelPendingNativeConnectRequestForTerminalStop();
    _cancelExistingStartedRouteVerificationRetry();
    _cancelAutoReconnect();
  }

  void _resetTransientConnectionFeatures() {
    ref.read(turncoatLivenessNotifierProvider.notifier).reset();
    ref.read(captchaNotifierProvider.notifier).reset();
  }

  void _scheduleAutoReconnect() {
    if (!_flutterOwnsAutomaticRecovery) {
      _cancelAutoReconnect();
      return;
    }
    if (_autoReconnectTimer?.isActive == true || _autoReconnectRunning) return;

    final delay = autoReconnectDelayForAttempt(_autoReconnectAttempt, isAndroid: Platform.isAndroid);
    _autoReconnectAttempt += 1;
    _autoReconnectPending = true;
    final visible = _visibleStatusDuringAutoReconnect(state.valueOrNull ?? const Disconnected());
    if (state.valueOrNull != visible) {
      state = AsyncData(visible);
    }
    loggy.info("auto reconnect scheduled in ${delay.inMilliseconds} ms");
    _autoReconnectTimer = Timer(delay, () {
      _autoReconnectTimer = null;
      unawaited(_runAutoReconnect());
    });
  }

  Future<void> _runAutoReconnect() async {
    if (!_flutterOwnsAutomaticRecovery) {
      _cancelAutoReconnect();
      return;
    }
    if (_autoReconnectRunning) return;
    if (_manualDisconnectRequested || !ref.read(Preferences.startedByUser)) {
      _autoReconnectPending = false;
      return;
    }
    if (state case AsyncData(value: Connected())) {
      _autoReconnectPending = false;
      return;
    }
    if (state case AsyncData(value: Connecting()) when !_autoReconnectPending) return;

    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) {
      loggy.info("auto reconnect stopped: no active profile");
      _markManualDisconnect();
      await ref.read(Preferences.startedByUser.notifier).update(false);
      return;
    }

    _autoReconnectPending = false;
    _autoReconnectRunning = true;
    var connectStarted = false;
    try {
      loggy.info("auto reconnect attempt $_autoReconnectAttempt");
      await ref.read(Preferences.startedByUser.notifier).update(true);
      connectStarted = await _connect(silent: true);
    } finally {
      _autoReconnectRunning = false;
    }

    if (!connectStarted && !_manualDisconnectRequested && ref.read(Preferences.startedByUser)) {
      _scheduleAutoReconnect();
      return;
    }

    if (state case AsyncData(value: Connected())) {
      _resetAutoReconnect();
      return;
    }

    final lastFailure = _lastSilentAutoReconnectFailure;
    _lastSilentAutoReconnectFailure = null;
    final statusAfterAttempt = lastFailure == null ? state.valueOrNull : Disconnected(lastFailure);
    if (shouldContinueAutoReconnectAfterAttempt(
      statusAfterAttempt,
      startedByUser: ref.read(Preferences.startedByUser),
      manualDisconnectRequested: _manualDisconnectRequested,
    )) {
      _scheduleAutoReconnect();
    } else if (statusAfterAttempt is Disconnected && state.valueOrNull is Connecting) {
      state = AsyncData(statusAfterAttempt);
    }
  }

  void _resetAutoReconnect() {
    _manualDisconnectRequested = false;
    _cancelAutoReconnect();
    _autoReconnectRunning = false;
  }

  void _cancelAutoReconnect() {
    _autoReconnectTimer?.cancel();
    _autoReconnectTimer = null;
    _autoReconnectPending = false;
    _lastSilentAutoReconnectFailure = null;
    _autoReconnectAttempt = 0;
  }

  ConnectionStatus _visibleConnectionStatus(ConnectionStatus event) {
    final afterAbort = _visibleStatusAfterAbort(event);
    final afterAutoReconnect = _visibleStatusDuringAutoReconnect(afterAbort);
    final afterManualButtonDisconnect = visibleStatusDuringManualButtonDisconnect(
      afterAutoReconnect,
      disconnectInProgress: _manualButtonDisconnectInProgress || _manualDisconnectInputSettling,
    );
    return afterManualButtonDisconnect;
  }

  ConnectionStatus _visibleStatusDuringAutoReconnect(ConnectionStatus event) {
    return visibleStatusDuringAutoReconnect(
      event,
      autoReconnectActive: _autoReconnectPending || _autoReconnectRunning || _manualConnectPending,
      startedByUser: ref.read(Preferences.startedByUser) || _manualConnectPending,
      manualDisconnectRequested: _manualDisconnectRequested,
    );
  }
}

enum AutomaticConnectionRecoveryOwner { flutter, androidService }

AutomaticConnectionRecoveryOwner automaticConnectionRecoveryOwnerForPlatform({required bool isAndroid}) =>
    isAndroid ? AutomaticConnectionRecoveryOwner.androidService : AutomaticConnectionRecoveryOwner.flutter;

bool shouldDeferFlutterReconnect({
  required bool isAndroid,
  required bool nativeRecoveryInProgress,
  required CoreStatus? platformStatus,
}) => isAndroid && (nativeRecoveryInProgress || platformStatus is CoreStarting || platformStatus is CoreStopping);

int nextRouteWatchdogFailureCount(
  int currentFailures, {
  required bool routeHealthy,
  bool requireFreshRoute = false,
  bool preserveLongLivedRoute = false,
  int maxFailures = ConnectionNotifier._routeWatchdogMaxFailures,
}) {
  if (routeHealthy) return 0;
  final increment = requireFreshRoute && currentFailures > 0 && !preserveLongLivedRoute ? 2 : 1;
  final failures = currentFailures + increment;
  return failures > maxFailures ? maxFailures : failures;
}

bool shouldReconnectAfterRouteWatchdogFailures(
  int failures, {
  int maxFailures = ConnectionNotifier._routeWatchdogMaxFailures,
  bool preserveLongLivedRoute = false,
  bool isIOS = false,
}) => preserveLongLivedRoute ? isIOS && failures >= 2 : failures >= maxFailures;

bool shouldRetryExistingTurncoatRouteWithoutRestart({
  required bool turncoatInUse,
  required bool turncoatLive,
  required bool turncoatTimedOut,
  required int consecutiveFailures,
  required int maxFailures,
}) => turncoatInUse && turncoatLive && !turncoatTimedOut && consecutiveFailures < maxFailures;

bool shouldScheduleAutoReconnectForTransition(
  ConnectionStatus? previousStatus,
  ConnectionStatus nextStatus, {
  required bool operationInProgress,
}) {
  if (nextStatus is! Disconnected) return false;
  if (operationInProgress) return false;
  if (nextStatus.connectionFailure == null) return false;
  return previousStatus is Connected || previousStatus is Disconnecting;
}

bool shouldResetTransientConnectionFeatures(
  ConnectionStatus? previousStatus,
  ConnectionStatus? nextStatus, {
  required bool operationInProgress,
  required bool manualDisconnectRequested,
  required bool showIdleDuringAbort,
}) {
  if (nextStatus is! Disconnected && nextStatus is! Disconnecting) return false;
  if (previousStatus is Connecting) return false;
  // Native restart emits transient DISCONNECTED/DISCONNECTING states while a
  // repository-managed reconnect is still running. Keep TURNcoat liveness and
  // captcha watchers armed so startup verification can wait for the next live
  // session instead of failing immediately on an intermediate stop.
  if (operationInProgress && !manualDisconnectRequested && !showIdleDuringAbort) return false;
  return true;
}

bool shouldVerifyRouteAfterResume(
  ConnectionStatus? status, {
  required bool startedByUser,
  required bool canAdoptPlatformSession,
  required bool operationInProgress,
  required bool verificationRunning,
  required bool coreStarted,
}) {
  return status is Connecting &&
      (startedByUser || canAdoptPlatformSession) &&
      !operationInProgress &&
      !verificationRunning &&
      coreStarted;
}

bool existingStartedSessionIsOwned({required bool flutterStartedByUser, required bool? platformStartedByUser}) =>
    platformStartedByUser ?? flutterStartedByUser;

Duration autoReconnectDelayForAttempt(int attempt, {required bool isAndroid}) {
  final delayIndex = attempt.clamp(0, ConnectionNotifier._autoReconnectDelays.length - 1);
  final delay = ConnectionNotifier._autoReconnectDelays[delayIndex];
  if (isAndroid && delay < ConnectionNotifier._androidAutoReconnectMinimumDelay) {
    return ConnectionNotifier._androidAutoReconnectMinimumDelay;
  }
  return delay;
}

bool shouldContinueAutoReconnectAfterAttempt(
  ConnectionStatus? status, {
  required bool startedByUser,
  required bool manualDisconnectRequested,
}) {
  if (manualDisconnectRequested || !startedByUser) return false;
  return status is! Connected && status is! Connecting;
}

ConnectionStatus visibleStatusDuringAutoReconnect(
  ConnectionStatus event, {
  required bool autoReconnectActive,
  required bool startedByUser,
  required bool manualDisconnectRequested,
}) {
  if ((event is Disconnected || event is Disconnecting) &&
      autoReconnectActive &&
      startedByUser &&
      !manualDisconnectRequested) {
    return const Connecting();
  }
  return event;
}

ConnectionStatus visibleStatusAfterAbort(ConnectionStatus event, {required bool showIdleDuringAbort}) {
  if (!showIdleDuringAbort) return event;
  if (event is Disconnected) return event;
  return const Disconnected();
}

ConnectionStatus visibleStatusDuringManualButtonDisconnect(
  ConnectionStatus event, {
  required bool disconnectInProgress,
}) {
  if (disconnectInProgress && event is Disconnected) return const Disconnecting();
  return event;
}

bool shouldPublishManualDisconnectReleased({required bool operationCompleted, required bool disconnectSucceeded}) =>
    operationCompleted && disconnectSucceeded;

@Riverpod(keepAlive: true)
Future<bool> serviceRunning(Ref ref) async {
  return await ref
      .watch(connectionNotifierProvider.selectAsync((data) => data.isConnected))
      .onError((error, stackTrace) => false);
}

class SingleCall {
  bool _running = false;
  Completer<void>? _runningCompleter;
  int _queuedGeneration = 0;
  bool get isRunning => _running;

  Future<bool> run(
    Future<void> Function() task, {
    required void Function() onIgnored,
    bool waitForCurrent = false,
    bool supersedeQueued = false,
    void Function()? onSuperseded,
  }) async {
    final queuedGeneration = waitForCurrent && supersedeQueued ? ++_queuedGeneration : null;
    while (_running) {
      if (!waitForCurrent) {
        onIgnored();
        return false;
      }
      await _runningCompleter!.future;
    }
    if (queuedGeneration != null && queuedGeneration != _queuedGeneration) {
      onSuperseded?.call();
      return false;
    }

    _running = true;
    final runningCompleter = _runningCompleter = Completer<void>();
    try {
      await task();
      return true;
    } finally {
      _running = false;
      if (!runningCompleter.isCompleted) runningCompleter.complete();
      if (identical(_runningCompleter, runningCompleter)) _runningCompleter = null;
    }
  }

  void cancel() {
    _queuedGeneration++;
  }

  Future<void> waitForCurrent() async {
    final current = _runningCompleter;
    if (current != null) await current.future;
  }
}

Future<bool> runExclusiveManualDisconnect({
  required SingleCall gate,
  required Future<void> Function() task,
  required void Function(bool inProgress) setInProgress,
  required void Function() onIgnored,
}) async {
  var ownsVisibility = false;
  try {
    return await gate.run(() async {
      ownsVisibility = true;
      setInProgress(true);
      await task();
    }, onIgnored: onIgnored);
  } finally {
    // A rejected concurrent tap never acquires this lease and therefore cannot
    // expose Connect while the accepted disconnect is still tearing down.
    if (ownsVisibility) setInProgress(false);
  }
}
