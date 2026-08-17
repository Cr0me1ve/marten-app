import 'dart:async';
import 'dart:io';

import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/crypto/profile_crypto.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/core/model/directories.dart';
import 'package:marten/core/utils/exception_handler.dart';
import 'package:marten/features/captcha/data/captcha_notifier.dart';
import 'package:marten/features/connection/data/turncoat_liveness_notifier.dart';
import 'package:marten/features/connection/model/connection_failure.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:marten/features/profile/data/profile_parser.dart';
import 'package:marten/features/profile/data/profile_path_resolver.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/settings/data/config_option_repository.dart';
import 'package:marten/martencore/marten_core_service.dart';
import 'package:marten/singbox/model/core_status.dart';
import 'package:marten/singbox/model/singbox_config_option.dart';
import 'package:marten/utils/utils.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';
import 'package:uuid/uuid.dart';

abstract interface class ConnectionRepository {
  SingboxConfigOption? get configOptionsSnapshot;
  bool get isCoreStartedSnapshot;
  bool get nativePlatformRecoveryInProgress;
  Future<bool?> readPlatformStartedByUser();
  Future<CoreStatus?> readPlatformServiceStatus();
  Future<int?> tryBeginFlutterRestart();
  Future<void> endFlutterRestart(int token);
  Future<bool> initializeStoppedPlatformStatus();

  TaskEither<ConnectionFailure, Unit> setup();
  Stream<ConnectionStatus> watchConnectionStatus();
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit);
  TaskEither<ConnectionFailure, Unit> disconnect();
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit);
  TaskEither<ConnectionFailure, Unit> syncNativeResumeConfig(ProfileEntity? activeProfile);
  TaskEither<ConnectionFailure, Unit> verifyConnectedRoute({bool holdStartupRouteReady = false});
  TaskEither<ConnectionFailure, int> measureConnectedRouteDelay();
}

class ConnectionRepositoryImpl with ExceptionHandler, InfraLogger implements ConnectionRepository {
  ConnectionRepositoryImpl({
    required this.ref,
    required this.directories,
    required this.singbox,
    required this.configOptionRepository,
    required this.profilePathResolver,
    required this.readDeviceIdentity,
  }) {
    ref.onDispose(_startupRouteReadyController.close);
  }

  final Ref ref;

  final Directories directories;
  final MartenCoreService singbox;

  final ConfigOptionRepository configOptionRepository;
  final ProfilePathResolver profilePathResolver;
  final Future<DeviceIdentity> Function() readDeviceIdentity;

  SingboxConfigOption? _configOptionsSnapshot;
  @override
  SingboxConfigOption? get configOptionsSnapshot => _configOptionsSnapshot;

  @override
  bool get isCoreStartedSnapshot => singbox.currentState == const CoreStatus.started();

  @override
  bool get nativePlatformRecoveryInProgress => singbox.nativePlatformRecoveryInProgress;

  @override
  Future<bool?> readPlatformStartedByUser() => singbox.readPlatformStartedByUser();

  @override
  Future<CoreStatus?> readPlatformServiceStatus() => singbox.readPlatformServiceStatus();

  @override
  Future<int?> tryBeginFlutterRestart() => singbox.tryBeginFlutterRestart();

  @override
  Future<void> endFlutterRestart(int token) => singbox.endFlutterRestart(token);

  @override
  Future<bool> initializeStoppedPlatformStatus() => singbox.initializeStoppedPlatformStatus();

  bool _initialized = false;
  Future<void> _connectionOperation = Future.value();
  final _disconnectOperations = CoalescedFuture<Either<ConnectionFailure, Unit>>();
  bool _connectionOperationInProgress = false;
  int _connectionGeneration = 0;
  _ConnectionIntent _connectionIntent = _ConnectionIntent.stop;
  StartupEndpointProbe? _activeStartupEndpoint;
  CoreStatus? _lastObservedCoreStatus;
  CoreStatus? _lastObservedPlatformStatus;
  bool _nativeRecoveryRouteGatePending = false;
  bool _nativePlatformRecoveryRouteGatePending = false;
  final _startupRouteReadyController = BehaviorSubject<bool>.seeded(
    initialStartupRouteReadyForPlatform(isAndroid: Platform.isAndroid),
  );

  @override
  TaskEither<ConnectionFailure, Unit> setup() {
    if (_initialized || singbox.core.isInitialized()) {
      _initialized = true;
      return TaskEither.of(unit);
    }
    return exceptionHandler(() {
      loggy.debug("setting up singbox");

      return singbox
          .setup()
          .map((r) {
            _initialized = true;
            return r;
          })
          .mapLeft(UnexpectedConnectionFailure.new)
          .run();
    }, UnexpectedConnectionFailure.new);
  }

  @override
  Stream<ConnectionStatus> watchConnectionStatus() {
    final coreStatus = singbox.watchStatus().doOnData((event) {
      if (Platform.isAndroid) {
        if (androidRouteGateReset(event) case final ready?) _setStartupRouteReady(ready);
      } else {
        final transition = nativeRecoveryRouteGateTransition(
          previous: _lastObservedCoreStatus,
          current: event,
          pending: _nativeRecoveryRouteGatePending,
        );
        _nativeRecoveryRouteGatePending = transition.pending;
        if (transition.routeReady case final ready?) _setStartupRouteReady(ready);
      }
      _lastObservedCoreStatus = event;
    });

    if (!Platform.isAndroid) {
      return Rx.combineLatest2<CoreStatus, bool, ConnectionStatus>(
        coreStatus,
        _startupRouteReadyController.stream,
        connectionStatusFromCore,
      ).distinct();
    }

    final platformStatus = singbox
        .watchPlatformServiceStatus()
        .doOnData((event) {
          final transition = nativeRecoveryRouteGateTransition(
            previous: _lastObservedPlatformStatus,
            current: event,
            pending: _nativePlatformRecoveryRouteGatePending,
          );
          _lastObservedPlatformStatus = event;
          _nativePlatformRecoveryRouteGatePending = transition.pending;
          if (transition.routeReady case final ready?) _setStartupRouteReady(ready);
          if (androidRouteGateReset(event) case final ready?) _setStartupRouteReady(ready);
        })
        .startWith(const CoreStatus.stopped());

    return Rx.combineLatest3<CoreStatus, bool, CoreStatus, ConnectionStatus>(
      coreStatus,
      _startupRouteReadyController.stream,
      platformStatus,
      (core, routeReady, _) => connectionStatusFromCore(core, routeReady),
    ).distinct();
  }

  @override
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit) {
    final generation = _markConnectionIntent(_ConnectionIntent.start);
    return _serializedConnectionTask(
      () => _unlessConnectionStale(generation, setup)
          .flatMap((_) => _unlessConnectionStale(generation, () => applyConfigOption(activeProfile)))
          .flatMap(
            (_) => _unlessConnectionStale(
              generation,
              () => _withPreparedConfig(
                activeProfile,
                (path, displayName) => singbox.start(path, displayName, disableMemoryLimit),
                generation: generation,
              ),
            ),
          ),
    );
  }

  TaskEither<ConnectionFailure, Unit> _serializedConnectionTask(TaskEither<ConnectionFailure, Unit> Function() task) {
    return TaskEither.tryCatch(
      () => _runSerializedConnectionOperation(() async {
        final result = await task().run();
        return result.match((failure) => throw failure, (value) => value);
      }),
      (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st),
    );
  }

  Future<T> _runSerializedConnectionOperation<T>(Future<T> Function() action) {
    final run = _connectionOperation.then((_) async {
      _connectionOperationInProgress = true;
      try {
        return await action();
      } finally {
        _connectionOperationInProgress = false;
      }
    });
    _connectionOperation = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  @override
  TaskEither<ConnectionFailure, Unit> disconnect() {
    return TaskEither.tryCatch(() async {
      final result = await _interruptConnectionOperation();
      return result.match((failure) => throw failure, (value) => value);
    }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st));
  }

  @override
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit) {
    final generation = _markConnectionIntent(_ConnectionIntent.start);
    return _serializedConnectionTask(
      () => _unlessConnectionStale(generation, () => applyConfigOption(activeProfile)).flatMap(
        (_) => _unlessConnectionStale(
          generation,
          () => _withPreparedConfig(
            activeProfile,
            (path, displayName) => reconnectCoreForPlatform(
              isAndroid: Platform.isAndroid,
              stop: singbox.stop().mapLeft(UnexpectedConnectionFailure.new),
              start: singbox.start(path, displayName, disableMemoryLimit),
              restart: singbox.restart(path, displayName, disableMemoryLimit).mapLeft(UnexpectedConnectionFailure.new),
            ),
            generation: generation,
          ),
        ),
      ),
    );
  }

  @override
  TaskEither<ConnectionFailure, Unit> syncNativeResumeConfig(ProfileEntity? activeProfile) {
    if (!Platform.isAndroid) return TaskEither.of(unit);
    return TaskEither.tryCatch(() async {
      final generation = _connectionGeneration;

      if (activeProfile == null) {
        if (_isConnectionStale(generation)) return unit;
        final cleared = await singbox.clearNativeResumeConfig();
        if (!cleared) throw const ConnectionFailure.unexpected('failed to clear native resume config');
        loggy.info('cleared native resume config because there is no active profile');
        return unit;
      }

      final encFile = profilePathResolver.file(activeProfile.id);
      final decFile = profilePathResolver.tempFile('${activeProfile.id}_native_resume_${const Uuid().v4()}');
      try {
        if (!await encFile.exists()) {
          throw const ConnectionFailure.invalidConfig(missingProfileConfigFailureMessage);
        }
        final deviceIdentity = await readDeviceIdentity();
        if (_isConnectionStale(generation)) return unit;
        try {
          await ProfileCrypto.decryptToTemp(encFile, decFile, deviceIdentity.clientSecret);
        } catch (error) {
          if (!ProfileCrypto.isMissingFileError(error)) rethrow;
          throw const ConnectionFailure.invalidConfig(missingProfileConfigFailureMessage);
        }
        if (_isConnectionStale(generation)) return unit;

        final rawConfig = await decFile.readAsString();
        final coreConfig = ProfileParser.stripMartenSubscriptionMetadata(rawConfig);
        final tags = selectableOutboundTagsFromConfig(coreConfig);
        final selectedTag = _selectedOutboundTag(activeProfile, tags);
        final preparedConfig = selectedTag == null
            ? coreConfig
            : prepareConfigForSelectedOutbound(coreConfig, selectedTag);
        await decFile.writeAsString(preparedConfig, flush: true);
        await _stripNativeStartMetadata(decFile);
        if (_isConnectionStale(generation)) return unit;

        final stored = await singbox.storeNativeResumeConfig(
          decFile.path,
          _notificationDisplayName(activeProfile, selectedTag),
        );
        if (!stored) throw const ConnectionFailure.unexpected('failed to store native resume config');
        loggy.info('synchronized native resume config for the active profile');
        return unit;
      } catch (error, stackTrace) {
        if (!_isConnectionStale(generation)) {
          final cleared = await singbox.clearNativeResumeConfig();
          if (!cleared) loggy.warning('failed to clear stale native resume config after sync failure');
        }
        Error.throwWithStackTrace(error, stackTrace);
      } finally {
        if (await decFile.exists()) await decFile.delete();
      }
    }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st));
  }

  @override
  TaskEither<ConnectionFailure, Unit> verifyConnectedRoute({bool holdStartupRouteReady = false}) {
    return TaskEither.tryCatch(() async {
      if (holdStartupRouteReady) _setStartupRouteReady(false);
      var verified = false;
      try {
        if (Platform.isAndroid) {
          // The Android service performs the authoritative request through
          // the current VPN Network/TUN. Running the direct core urltest first
          // would both add latency and reproduce the old false-positive gate.
          final platformAccepted = await singbox.notifyBackgroundStarted();
          if (!platformAccepted) {
            throw const ConnectionFailure.unexpected("Android VPN data plane did not become ready");
          }
          loggy.info('Android VPN data plane verified');
        } else {
          final health = await _probeSelectedRouteHealth();
          final delay = health.delay;
          if (delay == null) {
            loggy.info('route watchdog verified [${health.tag}] by ${health.source}');
          } else {
            loggy.info('route watchdog verified [${health.tag}]: ${delay}ms');
          }
        }
        verified = true;
        return unit;
      } finally {
        // Cold-attach verification must not briefly expose CONNECTED after a
        // failed probe; the caller will reconnect or stop the broken native core.
        if (holdStartupRouteReady && verified) _setStartupRouteReady(true);
      }
    }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st));
  }

  @override
  TaskEither<ConnectionFailure, int> measureConnectedRouteDelay() {
    return TaskEither.tryCatch(() async {
      final stopwatch = Stopwatch()..start();
      final health = await _probeSelectedRouteHealth();
      stopwatch.stop();
      final delay = connectedRoutePingDelay(reportedDelay: health.delay, elapsed: stopwatch.elapsedMilliseconds);
      loggy.info('manual connected-route ping verified [${health.tag}] by ${health.source}: ${delay}ms');
      return delay;
    }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st));
  }

  Future<({String tag, int? delay, String source})> _probeSelectedRouteHealth() async {
    final endpoint = _activeStartupEndpoint;
    final probe = await _runFreshUrlTestProbe(
      readSnapshot: () => singbox.selectedUrlTestDelaySnapshot(_startupRouteTestGroup),
      timeout: _routeWatchdogUrlTestTimeout,
      timeoutMessage: 'route watchdog timed out waiting for fresh url test result',
    );
    final error = probe.error;
    final selectedSnapshot = probe.snapshot;
    final ({String tag, int delay})? selectedDelay;
    if (selectedSnapshot != null && selectedSnapshot.delay != null) {
      selectedDelay = (tag: selectedSnapshot.tag, delay: selectedSnapshot.delay!);
    } else {
      selectedDelay = null;
    }
    final failure = selectedRouteHealthFailure(error, selectedDelay);
    if (failure != null) {
      if (endpoint != null &&
          error == null &&
          selectedDelay != null &&
          !isStartupUrlTestTimeoutDelay(selectedDelay.delay)) {
        final delay = await _measureStartupEndpoint(endpoint, _connectionGeneration);
        if (delay != null) {
          loggy.info('route watchdog verified by endpoint fallback [${endpoint.tag}]: ${delay}ms');
          return (tag: endpoint.tag, delay: delay, source: 'endpoint fallback');
        }
      }
      throw failure;
    }
    return (tag: selectedDelay!.tag, delay: selectedDelay.delay, source: 'url test');
  }

  Future<({bool cancelled, String? error, UrlTestDelaySnapshot? snapshot})> _runFreshUrlTestProbe({
    required Future<UrlTestDelaySnapshot?> Function() readSnapshot,
    required Duration timeout,
    required String timeoutMessage,
    bool Function()? isCancelled,
  }) async {
    final deadline = DateTime.now().add(timeout);

    Future<UrlTestDelaySnapshot?> readWithin(Duration remaining) {
      if (remaining <= Duration.zero) return Future.value();
      final readTimeout = remaining < _routeWatchdogDelaySnapshotTimeout
          ? remaining
          : _routeWatchdogDelaySnapshotTimeout;
      return readSnapshot().timeout(readTimeout, onTimeout: () => null);
    }

    // UrlTest only schedules the group check; its RPC can return before the
    // selected outbound publishes a new delay. Capture the previous timestamp
    // and poll that single probe until MainOutboundsInfo advances past it.
    // Re-triggering UrlTest on every read would keep moving the target and can
    // misclassify the previous 65535 sentinel as the current probe result.
    final baseline = await readWithin(deadline.difference(DateTime.now()));
    if (isCancelled?.call() == true) return (cancelled: true, error: null, snapshot: null);

    final probeStartedAt = DateTime.now();
    final commandBudget = deadline.difference(DateTime.now());
    if (commandBudget <= Duration.zero) {
      return (cancelled: false, error: timeoutMessage, snapshot: null);
    }
    final result = await singbox
        .urlTest(_startupRouteTestGroup)
        .run()
        .timeout(commandBudget, onTimeout: () => left(timeoutMessage));
    if (isCancelled?.call() == true) return (cancelled: true, error: null, snapshot: null);

    final error = result.match<String?>((err) => err, (_) => null);
    if (error != null) return (cancelled: false, error: error, snapshot: null);

    final waitBudget = deadline.difference(DateTime.now());
    if (waitBudget <= Duration.zero) {
      return (cancelled: false, error: timeoutMessage, snapshot: null);
    }
    final snapshot = await waitForFreshUrlTestDelaySnapshot(
      baselineTestedAt: baseline?.testedAt,
      probeStartedAt: probeStartedAt,
      timeout: waitBudget,
      isCancelled: isCancelled,
      readSnapshot: readWithin,
    );
    if (isCancelled?.call() == true) return (cancelled: true, error: null, snapshot: null);
    if (snapshot == null) return (cancelled: false, error: timeoutMessage, snapshot: null);
    return (cancelled: false, error: null, snapshot: snapshot);
  }

  TaskEither<ConnectionFailure, Unit> _withPreparedConfig(
    ProfileEntity profile,
    TaskEither<ConnectionFailure, Unit> Function(String path, String displayName) action, {
    required int generation,
  }) {
    return TaskEither.tryCatch(() async {
      if (_isConnectionStale(generation)) return unit;
      final encFile = profilePathResolver.file(profile.id);
      final decFile = profilePathResolver.tempFile('${profile.id}_dec');
      try {
        if (!await encFile.exists()) {
          loggy.warning('active profile config file is missing [${profile.id}]');
          throw const ConnectionFailure.invalidConfig(missingProfileConfigFailureMessage);
        }
        final deviceIdentity = await readDeviceIdentity();
        if (_isConnectionStale(generation)) return unit;
        try {
          await ProfileCrypto.decryptToTemp(encFile, decFile, deviceIdentity.clientSecret);
        } catch (error) {
          if (!ProfileCrypto.isMissingFileError(error)) rethrow;
          loggy.warning('active profile config file disappeared during encrypted read [${profile.id}]');
          throw const ConnectionFailure.invalidConfig(missingProfileConfigFailureMessage);
        }
        if (_isConnectionStale(generation)) return unit;
        final rawConfig = await decFile.readAsString();
        final coreConfig = ProfileParser.stripMartenSubscriptionMetadata(rawConfig);
        final tags = selectableOutboundTagsFromConfig(coreConfig);
        final selectedTag = _selectedOutboundTag(profile, tags);
        final selected = await _prepareSelectedOutboundAttempt(
          profile,
          decFile,
          rawConfig,
          coreConfig,
          tags,
          selectedTag,
        );
        if (_isConnectionStale(generation)) {
          _resetStaleConnectionFeatures();
          return unit;
        }
        final actionConfigFile = await _prepareNativeStartConfig(decFile);
        if (_isConnectionStale(generation)) {
          _resetStaleConnectionFeatures();
          return unit;
        }
        _activeStartupEndpoint = selected.startupEndpoint;
        _setStartupRouteReady(false);
        final startupRoute = selected.tag ?? 'prepared route';
        try {
          final result = await action(actionConfigFile.path, _notificationDisplayName(profile, selected.tag)).run();
          if (_isConnectionStale(generation)) {
            await _stopStaleConnectionOperation(generation);
            return unit;
          }
          final value = result.match((failure) => throw failure, (success) => success);
          if (_isConnectionStale(generation)) {
            await _stopStaleConnectionOperation(generation);
            return unit;
          }
          if (selected.tag != null) {
            if (!await _waitForCoreStarted()) {
              loggy.warning(
                'core did not report started before route selection '
                '[${selected.tag}], core state is ${singbox.currentState}',
              );
              throw const ConnectionFailure.unexpected("core did not report started after launch");
            }
            if (_isConnectionStale(generation)) {
              await _stopStaleConnectionOperation(generation);
              return unit;
            }
            await _selectPreparedOutbound(selected.tag!);

            // Android owns the authoritative startup request. Its probe is
            // bound to the active VPN Network/TUN, so a direct core urltest or
            // TURNcoat carrier signal cannot admit the route first.
            if (!Platform.isAndroid) {
              final verification = startupRouteVerificationFor(startupEndpoint: selected.startupEndpoint);
              final routeVerified = switch (verification) {
                StartupRouteVerification.endpointFallback => await _verifyStartupRouteWithEndpointFallback(
                  selected.tag!,
                  selected.startupEndpoint!,
                  generation,
                ),
                StartupRouteVerification.urlTest => await _verifyStartupRoute(selected.tag!, generation),
              };
              if (!routeVerified) {
                throw const ConnectionFailure.unexpected("selected route failed startup connectivity check");
              }
            }
          }
          if (_isConnectionStale(generation)) {
            await _stopStaleConnectionOperation(generation);
            return unit;
          }

          // On Android this call performs the authoritative HTTP request over
          // the current VPN Network/TUN and returns only after native startup
          // cleanup if the proof fails. Connected is published afterward.
          final platformAccepted = await singbox.notifyBackgroundStarted();
          if (!platformAccepted) {
            throw const ConnectionFailure.unexpected("Android VPN data plane did not become ready");
          }
          _setStartupRouteReady(true);
          return value;
        } catch (error, stackTrace) {
          if (_isConnectionStale(generation)) {
            await _stopStaleConnectionOperation(generation);
            return unit;
          }
          await _stopFailedStartupRoute(startupRoute);
          Error.throwWithStackTrace(error, stackTrace);
        }
      } finally {
        if (await decFile.exists()) await decFile.delete();
      }
    }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st));
  }

  TaskEither<ConnectionFailure, Unit> _unlessConnectionStale(
    int generation,
    TaskEither<ConnectionFailure, Unit> Function() task,
  ) {
    return TaskEither(() async {
      if (_isConnectionStale(generation)) return right(unit);
      final result = await task().run();
      if (_isConnectionStale(generation)) return right(unit);
      return result;
    });
  }

  bool _isConnectionStale(int generation) => generation != _connectionGeneration;

  int _markConnectionIntent(_ConnectionIntent intent) {
    _connectionIntent = intent;
    return ++_connectionGeneration;
  }

  Future<Either<ConnectionFailure, Unit>> _interruptConnectionOperation() {
    _markConnectionIntent(_ConnectionIntent.stop);
    return _disconnectOperations.run(
      () {
        final previousOperation = _connectionOperation;
        final previousOperationInProgress = _connectionOperationInProgress;
        final cleanup = _stopAroundPreviousConnectionOperation(
          previousOperation,
          previousOperationInProgress: previousOperationInProgress,
        );
        _connectionOperation = cleanup.then<void>((_) {}, onError: (_) {});
        return cleanup;
      },
      onCoalesced: () {
        loggy.info('coalescing repeated disconnect with active cleanup');
      },
    );
  }

  Future<Either<ConnectionFailure, Unit>> _stopAroundPreviousConnectionOperation(
    Future<void> previousOperation, {
    required bool previousOperationInProgress,
  }) async {
    final firstStop = await _stopConnectionNow();
    try {
      await previousOperation;
    } catch (err) {
      loggy.debug('previous connection operation finished after stop with error', err);
    }
    // A second stop is only needed when the interrupted operation was already
    // inside setup/start and could have opened the native core after the first
    // stop. For an ordinary connected -> disconnected transition it is both
    // redundant and harmful: Android has already torn down mode 4, so another
    // close can stall the next connect while the foreground app is reopening.
    if (!shouldRunFinalStopAfterInterrupt(previousOperationInProgress: previousOperationInProgress)) return firstStop;
    final finalStop = await _stopConnectionNow();
    return firstStop.match(
      (firstFailure) => finalStop.match((_) => left(firstFailure), (_) => right(unit)),
      (_) => finalStop,
    );
  }

  Future<Either<ConnectionFailure, Unit>> _stopConnectionNow() {
    _resetTurncoatFeatures();
    _activeStartupEndpoint = null;
    return singbox.stop().mapLeft(UnexpectedConnectionFailure.new).run();
  }

  void _resetStaleConnectionFeatures() {
    if (_connectionIntent == _ConnectionIntent.stop) {
      _resetTurncoatFeatures();
      _activeStartupEndpoint = null;
    }
  }

  Future<void> _stopStaleConnectionOperation(int generation) async {
    if (!_isConnectionStale(generation) || _connectionIntent != _ConnectionIntent.stop) return;
    loggy.info('stopping stale connection operation after user abort');
    _resetTurncoatFeatures();
    _activeStartupEndpoint = null;
    final result = await singbox.stop().run();
    result.match((err) => loggy.warning('error stopping stale connection operation', err), (_) {});
  }

  Future<File> _prepareNativeStartConfig(File preparedConfig) async {
    await _stripNativeStartMetadata(preparedConfig);
    // Android copies this short-lived file into a Keystore-encrypted native
    // recovery store inside the synchronous start method-channel call. Flutter
    // retains no persistent plaintext notification/tile/boot config.
    return preparedConfig;
  }

  Future<void> _stripNativeStartMetadata(File preparedConfig) async {
    final raw = await preparedConfig.readAsString();
    final stripped = ProfileParser.stripMartenSubscriptionMetadata(raw);
    if (stripped == raw) return;
    loggy.info('prepared native start config by stripping Marten-only metadata');
    await preparedConfig.writeAsString(stripped, flush: true);
  }

  String _notificationDisplayName(ProfileEntity profile, String? selectedTag) {
    final selectedName = selectedTag == null ? '' : stripTagMetadata(selectedTag).trim();
    return selectedName.isEmpty ? profile.name : selectedName;
  }

  String? _selectedOutboundTag(ProfileEntity profile, List<String> tags) {
    if (tags.isEmpty) return null;
    return resolveSelectedOutboundTag(
      tags,
      pending: ref.read(pendingProxySelectionProvider),
      remembered: ref.read(selectedProxyByProfileProvider.notifier).rememberedTagFor(profile.id, tags),
    );
  }

  Future<({String? tag, bool usesTurncoat, StartupEndpointProbe? startupEndpoint})> _prepareSelectedOutboundAttempt(
    ProfileEntity profile,
    File decFile,
    String rawWithMetadata,
    String coreRaw,
    List<String> tags,
    String? selectedTag,
  ) async {
    if (selectedTag == null) {
      await decFile.writeAsString(coreRaw);
      _armTurncoatFeatures(false, selectedTag: null);
      return (tag: null, usesTurncoat: false, startupEndpoint: null);
    }

    final prepared = prepareConfigForSelectedOutbound(coreRaw, selectedTag);
    await decFile.writeAsString(prepared);
    final usesTurncoat = selectedOutboundUsesTurncoat(prepared, selectedTag);
    final startupEndpoint = selectedStartupEndpointProbe(rawWithMetadata, selectedTag);
    _armTurncoatFeatures(usesTurncoat, selectedTag: selectedTag);
    await ref.read(selectedProxyByProfileProvider.notifier).select(profile.id, selectedTag, availableTags: tags);
    ref.read(pendingProxySelectionProvider.notifier).selected = selectedTag;
    return (tag: selectedTag, usesTurncoat: usesTurncoat, startupEndpoint: startupEndpoint);
  }

  void _armTurncoatFeatures(bool enabled, {required String? selectedTag}) {
    ref.read(turncoatLivenessNotifierProvider.notifier).arm(inUse: enabled, selectedTag: selectedTag);
    ref.read(captchaNotifierProvider.notifier).arm(enabled: enabled);
  }

  void _resetTurncoatFeatures() {
    ref.read(turncoatLivenessNotifierProvider.notifier).reset();
    ref.read(captchaNotifierProvider.notifier).reset();
  }

  Future<void> _selectPreparedOutbound(String selectedTag) async {
    final result = await singbox.selectOutbound('select', selectedTag, skipProbe: true).run();
    requireCoreOperationSuccess(result, operation: 'select prepared outbound [$selectedTag]');
  }

  Future<bool> _waitForCoreStarted() async {
    const attempts = 20;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (singbox.currentState == const CoreStatus.started()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return singbox.currentState == const CoreStatus.started();
  }

  Future<bool> _verifyStartupRoute(
    String selectedTag,
    int generation, {
    Duration timeout = _startupRouteTestTimeout,
  }) async {
    final result = await _verifyStartupRouteByUrlTest(selectedTag, generation, timeout: timeout);
    return result.connectionStale || result.routeVerified;
  }

  Future<bool> _verifyStartupRouteWithEndpointFallback(
    String selectedTag,
    StartupEndpointProbe endpoint,
    int generation, {
    Duration timeout = _startupRouteTestTimeout,
  }) async {
    final result = await _verifyStartupRouteByUrlTest(selectedTag, generation, timeout: timeout);
    if (result.connectionStale || result.routeVerified) return true;
    if (!result.endpointFallbackAllowed) return false;

    loggy.info('falling back to startup endpoint probe [$selectedTag]');
    return _verifyStartupEndpoint(endpoint, generation);
  }

  Future<({bool connectionStale, bool routeVerified, bool endpointFallbackAllowed})> _verifyStartupRouteByUrlTest(
    String selectedTag,
    int generation, {
    required Duration timeout,
    bool Function()? isCancelled,
  }) async {
    loggy.info('verifying startup route [$selectedTag]');
    final deadline = DateTime.now().add(timeout);
    var endpointFallbackAllowed = false;

    for (var attempt = 1; attempt <= _startupRouteTestAttempts; attempt++) {
      if (isCancelled?.call() == true) {
        return (connectionStale: true, routeVerified: false, endpointFallbackAllowed: endpointFallbackAllowed);
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        loggy.warning('startup route timed out [$selectedTag]');
        break;
      }

      final probe = await _probeStartupRouteDelay(selectedTag, generation, timeout: remaining);
      if (probe.connectionStale || isCancelled?.call() == true) {
        return (connectionStale: true, routeVerified: false, endpointFallbackAllowed: endpointFallbackAllowed);
      }

      final error = probe.error;
      final delay = probe.delay;
      if (error != null) {
        loggy.warning(
          'startup route url test command failed [$selectedTag] '
          '(attempt $attempt/$_startupRouteTestAttempts): $error',
        );
      } else if (isUsableStartupUrlTestDelay(delay)) {
        loggy.info('startup route verified [$selectedTag]: ${delay}ms');
        return (connectionStale: false, routeVerified: true, endpointFallbackAllowed: endpointFallbackAllowed);
      } else {
        loggy.warning(
          'startup route failed [$selectedTag]: delay=$delay '
          '(attempt $attempt/$_startupRouteTestAttempts)',
        );
        endpointFallbackAllowed |= delay != null && !isStartupUrlTestTimeoutDelay(delay);
      }

      if (attempt < _startupRouteTestAttempts) {
        final retryWindow = deadline.difference(DateTime.now());
        if (retryWindow <= _startupRouteTestRetryDelay) break;
        await Future<void>.delayed(_startupRouteTestRetryDelay);
        if (_isConnectionStale(generation) || isCancelled?.call() == true) {
          return (connectionStale: true, routeVerified: false, endpointFallbackAllowed: endpointFallbackAllowed);
        }
      }
    }

    return (connectionStale: false, routeVerified: false, endpointFallbackAllowed: endpointFallbackAllowed);
  }

  Future<({bool connectionStale, String? error, int? delay})> _probeStartupRouteDelay(
    String selectedTag,
    int generation, {
    required Duration timeout,
  }) async {
    final result = await singbox.probeSelectedRoute(_startupRouteTestGroup, timeout: timeout).run();
    if (_isConnectionStale(generation)) {
      return (connectionStale: true, error: null, delay: null);
    }
    return result.match((error) => (connectionStale: false, error: error, delay: null), (snapshot) {
      if (snapshot.tag != selectedTag) {
        return (
          connectionStale: false,
          error: 'selected route probe returned [${snapshot.tag}], expected [$selectedTag]',
          delay: null,
        );
      }
      return (connectionStale: false, error: null, delay: snapshot.delay);
    });
  }

  Future<bool> _verifyStartupEndpoint(
    StartupEndpointProbe endpoint,
    int generation, {
    Duration timeout = _startupEndpointProbeTimeout,
  }) async {
    loggy.info('verifying startup endpoint [${endpoint.tag}]: ${endpoint.server}:${endpoint.serverPort}');
    final delay = await _measureStartupEndpoint(endpoint, generation, timeout: timeout);
    if (delay != null) {
      loggy.info('startup endpoint verified [${endpoint.tag}]: ${delay}ms');
      return true;
    }
    if (_isConnectionStale(generation)) return true;
    return false;
  }

  Future<int?> _measureStartupEndpoint(
    StartupEndpointProbe endpoint,
    int generation, {
    Duration timeout = _startupEndpointProbeTimeout,
  }) async {
    Socket? socket;
    final stopwatch = Stopwatch()..start();
    try {
      socket = await Socket.connect(endpoint.server, endpoint.serverPort, timeout: timeout);
      if (_isConnectionStale(generation)) return 1;
      final elapsed = stopwatch.elapsedMilliseconds;
      return elapsed <= 0 ? 1 : elapsed;
    } catch (err) {
      if (!_isConnectionStale(generation)) {
        loggy.warning(
          'startup endpoint probe failed [${endpoint.tag}]: ${endpoint.server}:${endpoint.serverPort}',
          err,
        );
      }
      return null;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _stopFailedStartupRoute(String selectedTag) async {
    _resetTurncoatFeatures();
    _activeStartupEndpoint = null;
    _setStartupRouteReady(false);
    loggy.warning('stopping failed startup route [$selectedTag]');
    final result = await singbox.stop().run();
    result.match(
      (err) => throw ConnectionFailure.unexpected('failed to stop/close startup route [$selectedTag]: $err'),
      (_) => unit,
    );
  }

  void _setStartupRouteReady(bool ready) {
    if (_startupRouteReadyController.valueOrNull == ready) return;
    _startupRouteReadyController.add(ready);
  }

  @visibleForTesting
  TaskEither<ConnectionFailure, Unit> applyConfigOption(ProfileEntity prof) =>
      TaskEither.fromEither(configOptionRepository.fullOptionsOverrided(prof.profileOverride))
          .mapLeft((l) => ConnectionFailure.invalidConfigOption(null, l))
          .flatMap(
            (overridedOptions) => TaskEither.tryCatch(() async {
              final result = await singbox.changeOptions(overridedOptions).run();
              requireCoreOperationSuccess(result, operation: 'apply core config options');
              _configOptionsSnapshot = overridedOptions;
              return unit;
            }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st)),
          );
}

@visibleForTesting
TaskEither<L, Unit> reconnectCoreForPlatform<L>({
  required bool isAndroid,
  required TaskEither<L, Unit> stop,
  required TaskEither<L, Unit> start,
  required TaskEither<L, Unit> restart,
}) => isAndroid ? stop.flatMap((_) => start) : restart;

@visibleForTesting
class CoalescedFuture<T> {
  Future<T>? _active;

  bool get isRunning => _active != null;

  Future<T> run(Future<T> Function() operation, {void Function()? onCoalesced}) {
    final active = _active;
    if (active != null) {
      onCoalesced?.call();
      return active;
    }

    final future = operation();
    _active = future;
    unawaited(future.then<void>((_) => _clear(future), onError: (Object _, StackTrace _) => _clear(future)));
    return future;
  }

  void _clear(Future<T> future) {
    if (identical(_active, future)) _active = null;
  }
}

@visibleForTesting
T requireCoreOperationSuccess<T>(Either<String, T> result, {required String operation}) {
  return result.match((error) => throw ConnectionFailure.unexpected('$operation failed: $error'), (value) => value);
}

enum _ConnectionIntent { start, stop }

@visibleForTesting
const initialStartupRouteReady = true;

@visibleForTesting
bool initialStartupRouteReadyForPlatform({required bool isAndroid}) => !isAndroid && initialStartupRouteReady;

const _startupRouteTestGroup = 'select';
const _startupRouteTestTimeout = Duration(seconds: 12);
const _startupRouteTestAttempts = 3;
const _startupRouteTestRetryDelay = Duration(milliseconds: 700);
const _urlTestResultPollInterval = Duration(milliseconds: 200);
const _urlTestFreshnessGrace = Duration(seconds: 2);
const _startupEndpointProbeTimeout = Duration(seconds: 6);
const _routeWatchdogUrlTestTimeout = Duration(seconds: 8);
const _routeWatchdogDelaySnapshotTimeout = Duration(seconds: 2);
const _startupRouteTimeoutDelay = 65535;

@visibleForTesting
bool isFreshUrlTestDelaySnapshot(
  UrlTestDelaySnapshot snapshot, {
  required DateTime? baselineTestedAt,
  required DateTime probeStartedAt,
  Duration freshnessGrace = _urlTestFreshnessGrace,
}) {
  final testedAt = snapshot.testedAt;
  if (testedAt == null) return false;
  if (baselineTestedAt != null) return testedAt.isAfter(baselineTestedAt);
  return !testedAt.isBefore(probeStartedAt.subtract(freshnessGrace));
}

@visibleForTesting
Future<UrlTestDelaySnapshot?> waitForFreshUrlTestDelaySnapshot({
  required Future<UrlTestDelaySnapshot?> Function(Duration remaining) readSnapshot,
  required DateTime? baselineTestedAt,
  required DateTime probeStartedAt,
  required Duration timeout,
  bool Function()? isCancelled,
  Duration pollInterval = _urlTestResultPollInterval,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (isCancelled?.call() != true) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return null;

    final snapshot = await readSnapshot(remaining);
    if (isCancelled?.call() == true) return null;
    if (snapshot != null &&
        isFreshUrlTestDelaySnapshot(snapshot, baselineTestedAt: baselineTestedAt, probeStartedAt: probeStartedAt)) {
      return snapshot;
    }

    final retryWindow = deadline.difference(DateTime.now());
    if (retryWindow <= Duration.zero) return null;
    final delay = retryWindow < pollInterval ? retryWindow : pollInterval;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
  }
  return null;
}

@visibleForTesting
class StartupEndpointProbe {
  const StartupEndpointProbe({required this.tag, required this.type, required this.server, required this.serverPort});

  final String tag;
  final String type;
  final String server;
  final int serverPort;
}

@visibleForTesting
enum StartupRouteVerification { endpointFallback, urlTest }

@visibleForTesting
StartupRouteVerification startupRouteVerificationFor({required StartupEndpointProbe? startupEndpoint}) {
  if (startupEndpoint != null) return StartupRouteVerification.endpointFallback;
  return StartupRouteVerification.urlTest;
}

@visibleForTesting
StartupEndpointProbe? selectedStartupEndpointProbe(String raw, String selectedTag) {
  if (raw.isEmpty || selectedTag.isEmpty) return null;
  final outbound = parseLocalOutbounds(raw).where((outbound) => outbound.tag == selectedTag).firstOrNull;
  if (outbound == null || !localOutboundUsesServerPortPing(outbound)) return null;
  return StartupEndpointProbe(
    tag: outbound.tag,
    type: outbound.type,
    server: outbound.server,
    serverPort: outbound.serverPort,
  );
}

@visibleForTesting
bool isUsableStartupUrlTestDelay(int? delay) => delay != null && delay > 0 && delay < _startupRouteTimeoutDelay;

@visibleForTesting
bool isStartupUrlTestTimeoutDelay(int delay) => delay >= _startupRouteTimeoutDelay;

int connectedRoutePingDelay({required int? reportedDelay, required int elapsed}) {
  if (reportedDelay != null && isUsableStartupUrlTestDelay(reportedDelay)) return reportedDelay;
  return elapsed < 1 ? 1 : elapsed;
}

@visibleForTesting
bool shouldRunFinalStopAfterInterrupt({required bool previousOperationInProgress}) => previousOperationInProgress;

@visibleForTesting
ConnectionFailure? selectedRouteHealthFailure(String? urlTestError, ({String tag, int delay})? selectedDelay) {
  if (urlTestError != null) {
    return ConnectionFailure.unexpected('selected route watchdog url test failed: $urlTestError');
  }
  if (selectedDelay == null) {
    return const ConnectionFailure.unexpected('selected route watchdog delay is unavailable');
  }
  if (!isUsableStartupUrlTestDelay(selectedDelay.delay)) {
    return ConnectionFailure.unexpected(
      'selected route watchdog failed [${selectedDelay.tag}]: delay=${selectedDelay.delay}',
    );
  }
  return null;
}

@visibleForTesting
ConnectionStatus connectionStatusFromCore(CoreStatus event, bool startupRouteReady) {
  return switch (event) {
    CoreStopped() => Disconnected(event.getCoreAlert()),
    CoreStarting() => const Connecting(),
    CoreStarted() => startupRouteReady ? const Connected() : const Connecting(),
    CoreStopping() => const Disconnecting(),
  };
}

/// Android's runtime core stream describes lifecycle, not route admission, so
/// it may only close this gate. Native recovery reopens it separately when the
/// platform service publishes Started after its explicit VPN Network proof.
@visibleForTesting
bool? androidRouteGateReset(CoreStatus current) {
  return switch (current) {
    CoreStarting() || CoreStopping() || CoreStopped() => false,
    CoreStarted() => null,
  };
}

@visibleForTesting
({bool pending, bool? routeReady}) nativeRecoveryRouteGateTransition({
  required CoreStatus? previous,
  required CoreStatus current,
  required bool pending,
}) {
  if (current is CoreStarting) {
    return (pending: pending || previous is CoreStarted, routeReady: false);
  }
  if (current is CoreStarted && pending) {
    return (pending: false, routeReady: true);
  }
  if (current is CoreStopped || current is CoreStopping) {
    return (pending: false, routeReady: false);
  }
  return (pending: pending, routeReady: null);
}
