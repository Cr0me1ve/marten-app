import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:marten/core/analytics/analytics_controller.dart';
import 'package:marten/core/analytics/analytics_logger.dart';
import 'package:marten/core/haptic/haptic_service.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/preferences/general_preferences.dart';
import 'package:marten/core/router/dialog/dialog_notifier.dart';
import 'package:marten/features/captcha/data/captcha_notifier.dart';
import 'package:marten/features/connection/data/connection_data_providers.dart';
import 'package:marten/features/connection/data/connection_repository.dart';
import 'package:marten/features/connection/data/turncoat_liveness_notifier.dart';
import 'package:marten/features/connection/model/connection_failure.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/notifier/active_profile_notifier.dart';
import 'package:marten/martencore/init_signal.dart';
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
  ManualConnectionCommand.disconnect => status is Connected,
  ManualConnectionCommand.abort => status is Connecting,
};

@Riverpod(keepAlive: true)
class ConnectionNotifier extends _$ConnectionNotifier with AppLogger {
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
  static const _routeWatchdogRetryDelay = Duration(seconds: 10);
  static const _turncoatRouteWatchdogRetryDelay = Duration(seconds: 30);
  static const _routeWatchdogResumeDelay = Duration(seconds: 3);
  static const _turncoatRouteWatchdogResumeDelay = Duration(seconds: 15);
  static const _routeWatchdogMaxFailures = 3;
  static const _turncoatRouteWatchdogMaxFailures = 3;
  static const _androidNativeRecoveryRouteVerificationRetryDelay = Duration(seconds: 2);
  static const _existingTurncoatRouteVerificationRetryDelay = Duration(seconds: 30);
  static const _existingTurncoatRouteVerificationMaxFailures = 6;

  Timer? _autoReconnectTimer;
  Timer? _routeWatchdogTimer;
  Timer? _existingStartedRouteVerificationRetryTimer;
  Timer? _nativeRecoveryReconnectTimer;
  int _autoReconnectAttempt = 0;
  int _routeWatchdogFailures = 0;
  int _existingStartedRouteVerificationFailures = 0;
  bool _nextRouteWatchdogCheckRequiresFreshRoute = false;
  bool _manualDisconnectRequested = false;
  bool _autoReconnectPending = false;
  bool _autoReconnectRunning = false;
  bool _routeWatchdogRunning = false;
  bool _startupRouteVerificationRunning = false;
  bool _manualConnectPending = false;
  bool _manualButtonDisconnectInProgress = false;
  bool _manualDisconnectInputSettling = false;
  bool _showIdleDuringAbort = false;
  ConnectionFailure? _lastSilentAutoReconnectFailure;
  int _abortToken = 0;

  @override
  Stream<ConnectionStatus> build() async* {
    if (PlatformUtils.isMobile) {
      final platformStopped = Platform.isAndroid && await _connectionRepo.initializeStoppedPlatformStatus();
      if (!platformStopped) {
        await _connectionRepo.setup().mapLeft((l) {
          loggy.error("error setting up connection repository", l);
        }).run();
      }
    }

    ref.onDispose(() {
      _cancelAutoReconnect();
      _stopRouteWatchdog();
      _cancelExistingStartedRouteVerificationRetry();
      _nativeRecoveryReconnectTimer?.cancel();
    });

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

    ref.listen(activeProfileProvider.select((value) => value.asData?.value), (previous, next) async {
      if (previous == null) return;
      final shouldReconnect = next == null || previous.id != next.id;
      if (shouldReconnect) {
        await reconnect(next);
      }
    });
    ref.listen(turncoatLivenessNotifierProvider.select((value) => value.timedOut), (previous, next) {
      if (previous == true || next != true) return;
      unawaited(_handleTurncoatConnectTimeout());
    });
    ref.watch(coreRestartSignalProvider);

    yield* _connectionRepo.watchConnectionStatus().map(_visibleConnectionStatus).doOnData((event) {
      if (event case Disconnected(connectionFailure: final _?) when PlatformUtils.isDesktop) {
        ref.read(Preferences.startedByUser.notifier).update(false);
      }
      loggy.info("connection status: ${event.format()}");
    });
  }

  ConnectionRepository get _connectionRepo => ref.read(connectionRepositoryProvider);

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

  Future<void> executeManualCommand(ManualConnectionCommand command) async {
    final currentStatus = state.valueOrNull;
    final commandIsValid = currentStatus != null && canExecuteManualConnectionCommand(command, currentStatus);
    final canRecoverFromError = command == ManualConnectionCommand.connect && state is AsyncError<ConnectionStatus>;
    if (!commandIsValid && !canRecoverFromError) {
      loggy.debug("stale manual $command ignored for current status $currentStatus");
      return;
    }

    crashReporter.setContext('last_action', 'manual_${command.name}');

    final haptic = ref.read(hapticServiceProvider.notifier);
    switch (command) {
      case ManualConnectionCommand.connect:
        _sendManualHaptic(haptic.lightImpact());
        await _connect();
      case ManualConnectionCommand.disconnect:
        _sendManualHaptic(haptic.mediumImpact());
        await _disconnectFromManualCommand();
      case ManualConnectionCommand.abort:
        _sendManualHaptic(haptic.mediumImpact());
        await abortConnection();
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
      final visibleStatus = state.valueOrNull;
      if (shouldPublishManualDisconnectReleased(
        operationCompleted: completed,
        disconnectSucceeded: disconnectSucceeded,
        visibleStatus: visibleStatus,
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

  Future<void> reconnect(ProfileEntity? profile) async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (profile == null) {
        loggy.info("no active profile, disconnecting");
        await _singleStart.run(
          () async {
            _markManualDisconnect();
            await ref.read(Preferences.startedByUser.notifier).update(false);
            await _disconnect();
          },
          onIgnored: () {
            loggy.debug("profile disconnect called while another connect/disconnect is still running, ignoring");
          },
        );
        return;
      }
      loggy.info("active profile changed, reconnecting");
      await _singleStart.run(
        () async {
          final platformStatus = await _connectionRepo.readPlatformServiceStatus();
          if (shouldDeferFlutterReconnect(
            isAndroid: Platform.isAndroid,
            nativeRecoveryInProgress: _connectionRepo.nativePlatformRecoveryInProgress,
            platformStatus: platformStatus,
          )) {
            loggy.info("deferring Flutter reconnect until Android native recovery completes");
            _scheduleReconnectAfterNativeRecovery();
            return;
          }
          final restartLease = await _connectionRepo.tryBeginFlutterRestart();
          if (restartLease == null) {
            loggy.info("Android native lifecycle is busy; deferring Flutter reconnect");
            _scheduleReconnectAfterNativeRecovery();
            return;
          }
          _manualDisconnectRequested = false;
          _showIdleDuringAbort = false;
          _cancelAutoReconnect();
          _nativeRecoveryReconnectTimer?.cancel();
          _nativeRecoveryReconnectTimer = null;
          try {
            await ref.read(Preferences.startedByUser.notifier).update(true);
            final result = await _connectionRepo.reconnect(profile, ref.read(Preferences.disableMemoryLimit)).run();
            await result.match((err) async {
              loggy.warning("error reconnecting", err);
              await ref.read(Preferences.startedByUser.notifier).update(false);
              final cleanup = await _connectionRepo.disconnect().run();
              cleanup.match(
                (cleanupError) => loggy.warning("error cleaning up failed reconnect", cleanupError),
                (_) {},
              );
              state = AsyncError(err, StackTrace.current);
              await ref
                  .read(dialogNotifierProvider.notifier)
                  .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
            }, (_) => Future<void>.value());
          } finally {
            await _connectionRepo.endFlutterRestart(restartLease);
          }
        },
        onIgnored: () {
          loggy.debug("reconnect called while another connect/disconnect is still running, ignoring");
        },
      );
    }
  }

  void _scheduleReconnectAfterNativeRecovery() {
    if (!Platform.isAndroid || _nativeRecoveryReconnectTimer?.isActive == true) return;
    _nativeRecoveryReconnectTimer = Timer(const Duration(seconds: 1), () async {
      _nativeRecoveryReconnectTimer = null;
      if (_manualDisconnectRequested || !ref.read(Preferences.startedByUser)) return;

      final platformStatus = await _connectionRepo.readPlatformServiceStatus();
      final visibleStatus = state.valueOrNull;
      if (shouldDeferFlutterReconnect(
            isAndroid: true,
            nativeRecoveryInProgress: _connectionRepo.nativePlatformRecoveryInProgress,
            platformStatus: platformStatus,
          ) ||
          visibleStatus is Connecting ||
          visibleStatus is Disconnecting ||
          visibleStatus is Disconnected) {
        _scheduleReconnectAfterNativeRecovery();
        return;
      }

      final activeProfile = await ref.read(activeProfileProvider.future);
      await reconnect(activeProfile);
    });
  }

  Future<void> abortConnection() async {
    if (state case AsyncData(:final value)) {
      switch (value) {
        case Connected() || Connecting():
          loggy.debug("aborting connection");
          _abortConnectionImmediately();
        default:
      }
    }
  }

  final _singleStart = SingleCall();

  Future<bool> _connect({bool silent = false}) {
    int? requestToken;
    return _singleStart.run(
      () async {
        if (!silent) {
          requestToken = ++_abortToken;
          _showIdleDuringAbort = false;
          _manualDisconnectRequested = false;
          _cancelAutoReconnect();
          _manualConnectPending = true;
          state = const AsyncData(Connecting());
        }

        try {
          await ref.read(Preferences.startedByUser.notifier).update(true);
          final attempted = await _connectThrottled(silent: silent, requestToken: requestToken);
          if (!attempted && requestToken == _abortToken) {
            state = const AsyncData(Disconnected());
          }
        } finally {
          if (requestToken == _abortToken) _manualConnectPending = false;
        }
      },
      onIgnored: () {
        loggy.debug("connect called while another connect/disconnect is still running, ignoring");
      },
    );
  }

  Future<bool> _connectThrottled({bool silent = false, int? requestToken}) async {
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) {
      loggy.info("no active profile, not connecting");
      await ref.read(Preferences.startedByUser.notifier).update(false);
      return false;
    }
    await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).mapLeft((
      ConnectionFailure err,
    ) async {
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
      loggy.warning("error connecting", err);
      if (err.toString().contains("panic")) {
        await ref
            .read(analyticsControllerProvider.notifier)
            .recordNonFatal(
              StateError('native core panic reported during connect'),
              StackTrace.current,
              reason: 'native_core_panic_connect',
            );
      }
      final platformStatus = await _connectionRepo.readPlatformServiceStatus();
      final platformStartedByUser = await _connectionRepo.readPlatformStartedByUser();
      if (shouldDelegateFailedConnectionToAndroidRecovery(
        isAndroid: Platform.isAndroid,
        failure: err,
        platformStatus: platformStatus,
        platformStartedByUser: platformStartedByUser,
        nativeRecoveryInProgress: _connectionRepo.nativePlatformRecoveryInProgress,
      )) {
        loggy.warning("selected server is unavailable; Android native recovery will keep retrying", err);
        state = const AsyncData(Connecting());
        return;
      }
      if (silent) {
        loggy.warning("auto reconnect attempt failed", err);
        _lastSilentAutoReconnectFailure = err;
        state = AsyncData(_visibleStatusDuringAutoReconnect(Disconnected(err)));
        return;
      }
      await ref.read(Preferences.startedByUser.notifier).update(false);
      //Go err is not normal object to see the go errors are string and need to be dumped
      await ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      loggy.warning(err);
      state = AsyncError(err, StackTrace.current);
    }).run();
    return true;
  }

  Future<bool> _disconnect({bool showError = true}) async {
    final result = await _connectionRepo.disconnect().mapLeft((err) {
      loggy.warning("error disconnecting", err);
      if (showError) {
        ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
        state = AsyncError(err, StackTrace.current);
      }
    }).run();
    return result.isRight();
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
    final disconnectSucceeded = await _disconnect(showError: false).onError((error, stackTrace) {
      loggy.error("aborted connection cleanup threw; keeping reconnect unavailable", error, stackTrace);
      return false;
    });
    if (_abortToken != token) return;
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
      _cancelExistingStartedRouteVerificationRetry();
      return;
    }
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
      loggy.info("verifying existing started route before showing connected");
      final result = await _connectionRepo.verifyConnectedRoute(holdStartupRouteReady: true).run();
      await result.match(
        (err) async {
          loggy.warning("existing started route verification failed", err);
          if (!_manualDisconnectRequested && ref.read(Preferences.startedByUser)) {
            if (!_flutterOwnsAutomaticRecovery) {
              _existingStartedRouteVerificationFailures = 0;
              loggy.info("delegating automatic route recovery to the Android service");
              _scheduleExistingStartedRouteVerificationRetry(delay: _androidNativeRecoveryRouteVerificationRetryDelay);
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
  }

  void _startRouteWatchdog() {
    if (!_flutterOwnsAutomaticRecovery) return;
    if (_routeWatchdogTimer?.isActive == true || _routeWatchdogRunning) return;
    _routeWatchdogFailures = 0;
    _scheduleRouteWatchdogCheck(_routeWatchdogInitialDelayForCurrentRoute());
  }

  Duration _routeWatchdogInitialDelayForCurrentRoute() {
    return _isTurncoatRouteInUse ? _turncoatRouteWatchdogInitialDelay : _routeWatchdogInitialDelay;
  }

  Duration _routeWatchdogIntervalForCurrentRoute({bool? turncoatInUse}) {
    return (turncoatInUse ?? _isTurncoatRouteInUse) ? _turncoatRouteWatchdogInterval : _routeWatchdogInterval;
  }

  Duration _routeWatchdogRetryDelayForCurrentRoute({bool? turncoatInUse}) {
    return (turncoatInUse ?? _isTurncoatRouteInUse) ? _turncoatRouteWatchdogRetryDelay : _routeWatchdogRetryDelay;
  }

  Duration _routeWatchdogResumeDelayForCurrentRoute() {
    return _isTurncoatRouteInUse ? _turncoatRouteWatchdogResumeDelay : _routeWatchdogResumeDelay;
  }

  int _routeWatchdogMaxFailuresForCurrentRoute({bool? turncoatInUse}) {
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
            turncoatInUse
                ? "route watchdog failed ($_routeWatchdogFailures/$maxFailures, preserving TURNcoat route)"
                : "route watchdog failed ($_routeWatchdogFailures/$maxFailures)",
            err,
          );
          if (shouldReconnectAfterRouteWatchdogFailures(
            _routeWatchdogFailures,
            maxFailures: maxFailures,
            preserveLongLivedRoute: turncoatInUse,
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

bool shouldDelegateFailedConnectionToAndroidRecovery({
  required bool isAndroid,
  required ConnectionFailure failure,
  required CoreStatus? platformStatus,
  required bool? platformStartedByUser,
  required bool nativeRecoveryInProgress,
}) {
  final recoverableFailure = switch (failure) {
    UnexpectedConnectionFailure(:final error) => looksLikeSelectedRouteConnectivityError(error),
    _ => false,
  };
  if (!isAndroid || !recoverableFailure || platformStartedByUser != true) return false;
  if (platformStatus is CoreStarting || platformStatus is CoreStarted) return true;
  return nativeRecoveryInProgress && platformStatus == null;
}

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
}) => !preserveLongLivedRoute && failures >= maxFailures;

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

bool shouldPublishManualDisconnectReleased({
  required bool operationCompleted,
  required bool disconnectSucceeded,
  required ConnectionStatus? visibleStatus,
}) => operationCompleted && disconnectSucceeded && (visibleStatus is Disconnecting || visibleStatus is Disconnected);

@Riverpod(keepAlive: true)
Future<bool> serviceRunning(Ref ref) async {
  // ref.watch(coreRestartSignalProvider);
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
