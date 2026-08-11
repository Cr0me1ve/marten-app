import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';
import 'package:grpc/grpc.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart' as loggyl;
import 'package:marten/core/directories/directories_provider.dart';
import 'package:marten/core/logger/buffered_file_writer.dart';
import 'package:marten/core/logger/log_file_retention.dart';
import 'package:marten/core/logger/logger_controller.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';
import 'package:marten/core/notification/in_app_notification_controller.dart';
import 'package:marten/core/preferences/general_preferences.dart';
import 'package:marten/features/connection/model/connection_failure.dart';
import 'package:marten/features/log/model/log_level.dart' as config_log_level;
import 'package:marten/martencore/core_interface/core_interface.dart';
import 'package:marten/martencore/core_interface/core_interface_wrapper_stub.dart'
    if (dart.library.io) 'package:marten/martencore/core_interface/core_interface_wrapper.dart';
import 'package:marten/martencore/core_log_deduplicator.dart';
import 'package:marten/martencore/generated/v2/hcommon/common.pb.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:marten/martencore/init_signal.dart';
import 'package:marten/martencore/single_stream_subscription_registry.dart';
import 'package:marten/singbox/model/core_status.dart';
import 'package:marten/singbox/model/singbox_config_option.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:marten/utils/platform_utils.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';

typedef UrlTestDelaySnapshot = ({String tag, int? delay, DateTime? testedAt});

bool shouldApplyBackgroundInactiveResult({
  required int requestRevision,
  required int currentRevision,
  required bool nativeRecoveryInProgress,
  required bool backgroundActive,
}) => requestRevision == currentRevision && !nativeRecoveryInProgress && !backgroundActive;

bool shouldApplyNativeRecoverySnapshot({
  required int requestRevision,
  required int currentRevision,
  required CoreStatus currentStatus,
}) => requestRevision == currentRevision && currentStatus is CoreStarted;

bool shouldAttachBackgroundCoreDuringSetup({required bool isAndroid, required CoreStatus? platformStatus}) =>
    !isAndroid || platformStatus is! CoreStopped;

class MartenCoreService with InfraLogger {
  MartenCoreService(this.ref);
  final Ref ref;
  static const _foregroundSetupTimeout = Duration(seconds: 14);
  static const _coreStartTimeout = Duration(seconds: 35);
  static const _platformStopTimeout = Duration(seconds: 22);
  static const _outboundInfoSnapshotTimeout = Duration(seconds: 2);
  static const _coreStatusSnapshotTimeout = Duration(milliseconds: 900);
  static const _restartSettleTimeout = Duration(seconds: 8);
  static const _restartSettlePollInterval = Duration(milliseconds: 200);
  static const _startSettleTimeout = Duration(seconds: 10);
  static const _startSettlePollInterval = Duration(milliseconds: 200);

  // CoreMartenCoreService() {}
  final core = getCoreInterface();

  CoreStatus currentState = const CoreStatus.stopped();
  final statusController = BehaviorSubject<CoreStatus>();
  final runtimeLogController = BehaviorSubject<List<LogMessage>>();
  final logController = BehaviorSubject<List<LogMessage>>();
  final CallOptions? grpcOptions = null; //CallOptions(timeout: const Duration(milliseconds: 10000));
  final SingleStreamSubscriptionRegistry _subscriptionRegistry = SingleStreamSubscriptionRegistry();
  Map<String, StreamSubscription<dynamic>?> get subscriptions => _subscriptionRegistry.subscriptions;
  List<OutboundGroup> latest = [];
  SingboxConfigOption? _latestOptions;
  Future<Either<String, Unit>>? _setupFuture;
  File? _coreLogFile;
  BufferedFileWriter? _coreLogWriter;
  final CoreLogDeduplicator _coreLogDeduplicator = CoreLogDeduplicator();
  bool _nativePlatformRecoveryInProgress = false;
  CoreStatus? _latestPlatformServiceStatus;
  Future<Either<String, Unit>>? _stopFuture;
  Future<void>? _platformTriggeredInitFuture;
  int _statusRevision = 0;

  void _setCurrentState(CoreStatus next, {bool emit = true}) {
    _statusRevision++;
    currentState = next;
    if (emit) statusController.add(next);
  }

  Future<void> setCoreLogFilePath(String path) async {
    if (_coreLogFile?.path == path && _coreLogWriter != null) return;
    final previousWriter = _coreLogWriter;
    _coreLogWriter = null;
    if (previousWriter != null) await previousWriter.close();
    _coreLogFile = File(path);
    _coreLogWriter = BufferedFileWriter(_coreLogFile!);
  }

  Future<T> runCoreLogSynchronized<T>(Future<T> Function() operation) {
    final writer = _coreLogWriter;
    if (writer == null) return operation();
    return writer.runSynchronized(operation);
  }

  Future<bool> notifyBackgroundStarted() => core.notifyBackgroundStarted();

  Future<bool?> readPlatformStartedByUser() => core.readPlatformStartedByUser();

  Future<CoreStatus?> readPlatformServiceStatus() => core.readPlatformServiceStatus();

  Stream<CoreStatus> watchPlatformServiceStatus() => core.watchServiceStatus();

  Future<bool> initializeStoppedPlatformStatus() async {
    if (!PlatformUtils.isAndroid) return false;
    final platformStatus = await readPlatformServiceStatus();
    if (!shouldUseLightweightPlatformBootstrap(isAndroid: true, platformStatus: platformStatus)) {
      return false;
    }

    _applyPlatformServiceStatus(platformStatus!);
    await startListeningPlatformStatus();
    if (!statusController.hasValue || statusController.value != currentState) {
      statusController.add(currentState);
    }
    return true;
  }

  bool get nativePlatformRecoveryInProgress => _nativePlatformRecoveryInProgress;

  Future<int?> tryBeginFlutterRestart() => core.tryBeginFlutterRestart();

  Future<void> endFlutterRestart(int token) => core.endFlutterRestart(token);

  Future<void> init() async {
    await setup()
        .mapLeft((e) {
          loggy.error(e);
          if (PlatformUtils.isIOS) return;
          statusController.add(const CoreStatus.stopped());
          ref.read(inAppNotificationControllerProvider).showErrorToast(e);
        })
        .map((_) {
          loggy.info("Marten core setup done");
          ref.read(coreRestartSignalProvider.notifier).restart();
        })
        .run();
  }

  /// validates config by path and save it
  ///
  /// [path] is used to save validated config
  /// [tempPath] includes base config, possibly invalid
  /// [debug] indicates if debug mode (avoid in prod)

  TaskEither<String, Unit> validateConfigByPath(String path, String tempPath, bool debug) {
    return TaskEither(() async {
      try {
        final response = await core.fgClient.parse(ParseRequest(tempPath: tempPath, configPath: path, debug: false));
        if (response.responseCode != ResponseCode.OK) return left("${response.responseCode} ${response.message}");
      } catch (e) {
        await setup().run();
        final response = await core.fgClient.parse(ParseRequest(tempPath: tempPath, configPath: path, debug: false));
        if (response.responseCode != ResponseCode.OK) return left("${response.responseCode} ${response.message}");
      }
      return right(unit);
    });
  }

  TaskEither<String, String> generateFullConfigByPath(String path) {
    return TaskEither(() async {
      if (!core.isInitialized()) {
        final setupResult = await setup().run();
        final setupError = setupResult.match<String?>((err) => err, (_) => null);
        if (setupError != null) return left(setupError);
      }

      final response = await core.fgClient.parse(ParseRequest(configPath: path, debug: false));
      if (response.responseCode != ResponseCode.OK) return left("${response.responseCode} ${response.message}");
      return right(response.content);
    });
  }

  TaskEither<String, Unit> setup() {
    return TaskEither(() async {
      final runningSetup = _setupFuture;
      if (runningSetup != null) {
        return runningSetup;
      }

      final setupFuture = _setup();
      _setupFuture = setupFuture;
      try {
        return await setupFuture;
      } finally {
        if (identical(_setupFuture, setupFuture)) {
          _setupFuture = null;
        }
      }
    });
  }

  Future<Either<String, Unit>> _setup() async {
    try {
      final directories = ref.read(appDirectoriesProvider).requireValue;
      final debug = ref.read(debugModeNotifierProvider);
      final setupResponse = await core
          .setup(directories, debug, 3)
          .timeout(_foregroundSetupTimeout, onTimeout: () => "foreground core setup timed out");

      if (setupResponse.isNotEmpty) {
        return left(setupResponse);
      }

      await startListeningLogs("fg", core.fgClient);
      // await startListeningStatus("fg", core.fgClient);
      await startListeningPlatformStatus();
      var platformStatus = _latestPlatformServiceStatus;
      if (PlatformUtils.isAndroid && platformStatus == null) {
        try {
          platformStatus = await readPlatformServiceStatus();
          if (platformStatus != null) _applyPlatformServiceStatus(platformStatus);
        } catch (error) {
          loggy.debug("platform status unavailable during setup: $error");
        }
      }
      if (shouldAttachBackgroundCoreDuringSetup(isAndroid: PlatformUtils.isAndroid, platformStatus: platformStatus)) {
        if (!core.isSingleChannel()) {
          await startListeningLogs("bg", core.bgClient);
        }
        await _refreshBackgroundCoreStatusSnapshot(reason: "setup");
        await startListeningStatus("bg", core.bgClient);
      } else {
        loggy.debug("skipping stopped Android background core listeners during setup");
      }
      statusController.add(currentState);
      // ref.read(coreRestartSignalProvider.notifier).restart();
      return right(unit);
    } catch (e) {
      return left(e.toString());
    }
  }

  TaskEither<String, Unit> changeOptions(SingboxConfigOption options) {
    return TaskEither(() async {
      final wasInitialized = core.isInitialized();
      if (!wasInitialized) {
        final setupResult = await setup().run();
        final setupError = setupResult.match<String?>((err) => err, (_) => null);
        if (setupError != null) return left(setupError);
      }

      loggy.debug("changing options");
      if (wasInitialized && _latestOptions == options) {
        loggy.debug("settings unchanged; skipping core settings update");
        return right(unit);
      }
      try {
        final res = await core.fgClient.changeMartenSettings(
          ChangeMartenSettingsRequest(martenSettingsJson: jsonEncode(options.toJson())),
        );
        if (res.messageType != MessageType.EMPTY) return left("${res.messageType} ${res.message}");
        if (await _shouldUpdateBackgroundSettings()) {
          final backgroundResponse = await core.bgClient.changeMartenSettings(
            ChangeMartenSettingsRequest(martenSettingsJson: jsonEncode(options.toJson())),
          );
          if (backgroundResponse.messageType != MessageType.EMPTY) {
            return left("${backgroundResponse.messageType} ${backgroundResponse.message}");
          }
        }
      } catch (error) {
        return left(error.toString());
      }

      _latestOptions = options;
      return right(unit);
    });
  }

  Future<bool> _shouldUpdateBackgroundSettings() async {
    if (currentState == const CoreStatus.stopped()) {
      loggy.debug("skipping background settings update while core is stopped");
      return false;
    }
    try {
      return await core.isActiveBg();
    } catch (e) {
      loggy.debug("background core settings healthcheck failed: $e");
      return false;
    }
  }

  TaskEither<ConnectionFailure, Unit> start(String path, String name, bool disableMemoryLimit) {
    return TaskEither(() async {
      _setCurrentState(const CoreStatus.starting());
      loggy.debug("starting");
      final background = await core.setupBackground(path, name);
      if (background case BackgroundCoreSetupFailed(:final status)) {
        _setCurrentState(const CoreStatus.stopped());
        return _settleFailedStart(status.getCoreAlert() ?? const ConnectionFailure.unexpected("failed to start core"));
      }
      if (!core.isSingleChannel()) {
        await startListeningLogs("bg", core.bgClient);
        await startListeningStatus("bg", core.bgClient);
      }
      if (background case BackgroundCoreAttached(:final status)) {
        _setCurrentState(
          coreStatusAfterRuntimeEvent(status, nativeRecoveryInProgress: _nativePlatformRecoveryInProgress),
        );
        loggy.info("adopted existing background core; skipping fresh-start cleanup and duplicate start RPC");
        return right(unit);
      }
      if (!await _waitForCoreLocalPortsRelease()) {
        loggy.warning("force-stopping previous core before retrying local port release");
        await stop(forcePlatformCleanup: PlatformUtils.isAndroid).run();
        if (!await _waitForCoreLocalPortsRelease()) {
          currentState = const CoreStatus.stopped(
            alert: CoreAlert.startFailed,
            message: "previous core is still releasing local ports",
          );
          _statusRevision++;
          statusController.add(currentState);
          return left(
            currentState.getCoreAlert() ??
                const ConnectionFailure.unexpected("previous core is still releasing local ports"),
          );
        }
      }
      await _deleteClashApiCacheFile();
      // final content = await File(path).readAsString();
      // loggy.debug("starting with content: $content");
      try {
        final res = await core.bgClient.start(
          StartRequest(
            configPath: path,
            configName: name,
            // configContent: content,
            disableMemoryLimit: disableMemoryLimit,
          ),
          options: CallOptions(timeout: _coreStartTimeout),
        );
        ref.read(coreRestartSignalProvider.notifier).restart();
        final responseStatus = CoreStatus.fromCoreInfo(res);
        if (res.messageType != MessageType.ALREADY_STARTED && res.messageType != MessageType.EMPTY) {
          final alert = res.message.contains("denied") ? CoreAlert.requestVPNPermission : CoreAlert.startFailed;
          currentState = CoreStatus.stopped(
            alert: alert,
            message: "failed to start core ${res.messageType} ${res.message}",
          );

          _statusRevision++;
          statusController.add(currentState);

          return _settleFailedStart(
            currentState.getCoreAlert() ??
                ConnectionFailure.unexpected("failed to start core ${res.messageType} ${res.message}"),
          );
        }
        if (responseStatus is CoreStopped) {
          currentState = responseStatus;
          _statusRevision++;
          statusController.add(currentState);
          return _settleFailedStart(
            responseStatus.getCoreAlert() ??
                ConnectionFailure.unexpected("failed to start core ${res.messageType} ${res.message}".trim()),
          );
        }
        if (responseStatus is CoreStarting) {
          _setCurrentState(responseStatus);
        }
      } on GrpcError catch (e) {
        loggy.error("failed to start bg core: $e");
        ref.read(coreRestartSignalProvider.notifier).restart();
        if (e.code == StatusCode.deadlineExceeded) {
          currentState = const CoreStatus.stopped(
            alert: CoreAlert.startFailed,
            message: "connection timed out while starting core",
          );
          _statusRevision++;
          statusController.add(currentState);
          return _settleFailedStart(const ConnectionFailure.unexpected("connection timed out while starting core"));
        }
        if (e.code == StatusCode.unavailable) {
          return _settleFailedStart(const ConnectionFailure.unexpected("background core is not started yet!"));
        }
        final message = e.message?.trim();
        if (message != null && message.isNotEmpty) {
          return _settleFailedStart(
            _looksLikeInvalidConfigStartError(message)
                ? ConnectionFailure.invalidConfig(message)
                : ConnectionFailure.unexpected(message),
          );
        }
        // throw InvalidConfig(e.message);
        // throw DioException.connectionError(requestOptions: RequestOptions(), reason: e.codeName, error: e);

        // throw DioException(requestOptions: RequestOptions(), error: e);
        return _settleFailedStart(const ConnectionFailure.unexpected("failed to start background core"));
      }

      if (!await _waitForBackgroundCoreStarted()) {
        currentState = const CoreStatus.stopped(
          alert: CoreAlert.startFailed,
          message: "background core did not reach started state",
        );
        _statusRevision++;
        statusController.add(currentState);
        return _settleFailedStart(const ConnectionFailure.unexpected("background core did not reach started state"));
      }
      _setCurrentState(const CoreStatus.started());
      // if (res.messageType != MessageType.EMPTY) return left(res);

      return right(unit);
    });
  }

  Future<Either<ConnectionFailure, Unit>> _settleFailedStart(ConnectionFailure failure) async {
    // Android's VpnService retains the framework ParcelFileDescriptor even
    // after a partially-started native Box has closed its duplicate. Do not
    // expose a retry until the authoritative platform stop has released both
    // sides of that TUN generation and the background core setup.
    final cleanup = await stop(forcePlatformCleanup: PlatformUtils.isAndroid).run();
    cleanup.match((error) => loggy.warning("start failure cleanup also reported an error: $error"), (_) {});
    return left(failure);
  }

  bool _looksLikeInvalidConfigStartError(String message) {
    final lower = message.toLowerCase();
    return lower.contains("decode config") ||
        lower.contains("invalid sing-box config") ||
        lower.contains("unknown field") ||
        lower.contains("unmarshal error");
  }

  Future<void> _deleteClashApiCacheFile() async {
    final options = _latestOptions;
    if (options == null || !options.enableClashApi) return;
    try {
      final directories = ref.read(appDirectoriesProvider).requireValue;
      final cacheFile = File('${directories.workingDir.path}/data/clash.db');
      if (!await cacheFile.exists()) return;
      await cacheFile.delete();
      loggy.debug("deleted stale clash api cache before core start");
    } catch (e) {
      loggy.warning("failed to delete clash api cache before core start: $e");
    }
  }

  Future<bool> _waitForCoreLocalPortsRelease() async {
    final options = _latestOptions;
    if (options == null) return true;
    final ports = <int>{
      options.mixedPort,
      options.tproxyPort,
      options.directPort,
      options.redirectPort,
      if (options.enableClashApi) options.clashApiPort,
    }.where((port) => port > 0).toList(growable: false);
    if (ports.isEmpty) return true;

    const maxAttempts = 40;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final open = await Future.wait(ports.map(_isLocalPortOpen));
      final busyPorts = [
        for (var index = 0; index < ports.length; index++)
          if (open[index]) ports[index],
      ];
      if (busyPorts.isEmpty) return true;
      if (attempt == 0) {
        loggy.warning("waiting for previous local ports to be released: $busyPorts");
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    final open = await Future.wait(ports.map(_isLocalPortOpen));
    final busyPorts = [
      for (var index = 0; index < ports.length; index++)
        if (open[index]) ports[index],
    ];
    loggy.warning("local ports are still busy before start: $busyPorts");
    return false;
  }

  Future<bool> _isLocalPortOpen(int port) async {
    try {
      final socket = await Socket.connect("127.0.0.1", port, timeout: const Duration(milliseconds: 120));
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    } catch (_) {
      return false;
    }
  }

  TaskEither<String, Unit> stop({bool forcePlatformCleanup = false}) {
    return TaskEither(() async {
      // An explicit Flutter stop supersedes Android's automatic recovery. If
      // the recovery flag survives the authoritative platform stop, later
      // stopped-status replays are translated back to Starting and the idle
      // UI spins forever even though the core and VPN are already gone.
      if (_nativePlatformRecoveryInProgress) {
        _nativePlatformRecoveryInProgress = false;
        loggy.info("explicit core stop canceled Android native recovery");
      }
      final runningStop = _stopFuture;
      if (runningStop != null) {
        loggy.debug("joining in-flight core stop");
        return runningStop;
      }
      if (!forcePlatformCleanup && isRedundantCoreStop(currentState, _latestPlatformServiceStatus)) {
        loggy.debug("core and Android service are already stopped");
        return right(unit);
      }

      final stopFuture = _stopOnce();
      _stopFuture = stopFuture;
      try {
        return await stopFuture;
      } finally {
        if (identical(_stopFuture, stopFuture)) _stopFuture = null;
      }
    });
  }

  Future<Either<String, Unit>> _stopOnce() async {
    loggy.debug("stopping");
    _setCurrentState(const CoreStatus.stopping());
    var errMsg = "";
    // Android's VPN service owns core shutdown and TUN teardown as one
    // transaction. A separate gRPC Stop here can overlap Mobile.stop/close
    // in that service and race while both callers close the same Box.
    // Other platforms retain the capped graceful gRPC pre-stop.
    if (shouldAttemptGracefulGrpcStop(isAndroid: PlatformUtils.isAndroid)) {
      try {
        await core.bgClient.stop(Empty(), options: CallOptions(timeout: const Duration(seconds: 4)));
      } on GrpcError catch (e) {
        if (e.code == StatusCode.deadlineExceeded) {
          loggy.warning("graceful bg core stop timed out, force-killing");
        } else if (e.code == StatusCode.unknown && !(e.message?.contains("HTTP/2") ?? false)) {
          errMsg = e.message ?? "failed to stop core: $e";
          loggy.error("failed to stop bg core: $e");
        } else {
          loggy.warning("bg core stop returned grpc error code=${e.code} msg=${e.message}");
        }
      } catch (e) {
        loggy.error("failed to stop bg core: $e");
      }
    } else {
      loggy.debug("Android VPN service owns authoritative core stop");
    }
    final platformStopped = await core.stop().timeout(
      _platformStopTimeout,
      onTimeout: () {
        loggy.warning("platform stop did not return within ${_platformStopTimeout.inSeconds} s");
        return false;
      },
    );
    if (!platformStopped) {
      errMsg = "platform stop did not fully close the background core";
      loggy.warning(errMsg);
      _setCurrentState(
        const CoreStatus.stopped(alert: CoreAlert.startService, message: "background core did not stop cleanly"),
      );
      return left(errMsg);
    }
    _setCurrentState(const CoreStatus.stopped());
    if (errMsg.isNotEmpty) return left(errMsg);
    return right(unit);
  }

  Future<Either<String, Unit>> _settleFailedRestart(String message) async {
    final cleanup = await stop().run();
    cleanup.match((error) => loggy.warning("restart failure cleanup also reported an error: $error"), (_) {});
    currentState = CoreStatus.stopped(alert: CoreAlert.startFailed, message: message);
    _statusRevision++;
    statusController.add(currentState);
    return left(message);
  }

  TaskEither<String, Unit> restart(String path, String name, bool disableMemoryLimit) {
    return TaskEither(() async {
      loggy.debug("restarting");
      _setCurrentState(const CoreStatus.starting());
      // if (!await core.restart(path, name)) {
      try {
        final res = await core.bgClient.restart(
          StartRequest(configPath: path, configName: name, disableMemoryLimit: disableMemoryLimit),
          options: CallOptions(timeout: _coreStartTimeout),
        );
        if (res.messageType != MessageType.EMPTY) {
          return _settleFailedRestart("${res.messageType} ${res.message}");
        }
      } on GrpcError catch (e) {
        loggy.error("failed to restart bg core: $e");
        if (_isExpectedRestartTransportShutdown(e)) {
          if (await _waitForRestartedBackgroundCore()) {
            loggy.warning("restart call was interrupted, but background core is healthy");
            ref.read(coreRestartSignalProvider.notifier).restart();
            return right(unit);
          }
          return _settleFailedRestart("background core did not settle after restart");
        }
        if (e.code == StatusCode.deadlineExceeded) {
          return _settleFailedRestart("connection timed out while restarting core");
        }
        final message = e.message?.trim();
        if (message != null && message.isNotEmpty) {
          return _settleFailedRestart(message);
        }
        return _settleFailedRestart("failed to restart background core");
      }

      if (!await _waitForRestartedBackgroundCore()) {
        return _settleFailedRestart("background core did not start after restart");
      }
      ref.read(coreRestartSignalProvider.notifier).restart();
      return right(unit);
      // await stop().run();
      // return await start(path, name, disableMemoryLimit).run();
      // }
      // if (!core.isSingleChannel()) {
      //   await startListeningStatus("bg", core.bgClient);
      //   await startListeningLogs("bg", core.bgClient);
      // }
      // return right(unit);
    });
  }

  bool _isExpectedRestartTransportShutdown(GrpcError error) {
    final message = error.message ?? "";
    return error.code == StatusCode.unavailable ||
        (error.code == StatusCode.unknown &&
            (message.contains("HTTP/2 error") || message.contains("forcefully terminated")));
  }

  Future<bool> _waitForRestartedBackgroundCore() {
    // The mode-4 gRPC shell stays reachable while Restart is still moving the
    // VPN runtime through Stopped/Starting. A Hello healthcheck therefore says
    // nothing about whether SelectOutbound can run yet; only coreInfo=Started
    // is authoritative here.
    return waitForRestartedCoreRuntime(
      readStatus: () => _refreshBackgroundCoreStatusSnapshot(reason: "restart settle", emit: true),
      timeout: _restartSettleTimeout,
      pollInterval: _restartSettlePollInterval,
    );
  }

  Future<bool> _waitForBackgroundCoreStarted() async {
    final deadline = DateTime.now().add(_startSettleTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (currentState == const CoreStatus.started()) return true;
      final snapshot = await _refreshBackgroundCoreStatusSnapshot(reason: "start settle", emit: true);
      if (snapshot == const CoreStatus.started()) return true;
      if (snapshot is CoreStopped && snapshot.alert != null) return false;
      await Future<void>.delayed(_startSettlePollInterval);
    }
    if (currentState == const CoreStatus.started()) return true;
    final snapshot = await _refreshBackgroundCoreStatusSnapshot(reason: "start settle final", emit: true);
    return snapshot == const CoreStatus.started();
  }

  TaskEither<String, Unit> resetTunnel() {
    return TaskEither(() async {
      // only available on iOS (and macOS later)
      if (!PlatformUtils.isIOS) {
        throw UnimplementedError("reset tunnel function unavailable on platform");
      }

      // loggy.debug("resetting tunnel");
      final res = await core.resetTunnel();
      if (res) {
        return right(unit);
      }
      return left("failed to reset tunnel");
    });
  }

  // Stream<List<OutboundGroup>> watchGroups() async* {
  //   loggy.debug("watching groups");
  //   yield* core.bgClient.outboundsInfo(Empty()).map((event) => event.items);
  //   // res?.cancel();
  // }

  Stream<OutboundGroup?> watchGroup() async* {
    loggy.debug("watching group");
    // interrupt managed by core

    if (!core.isInitialized()) {
      loggy.debug("core is not initialized, returning empty group stream");
      return;
    }
    try {
      yield* core.bgClient.outboundsInfo(Empty()).map((event) => event.items.isEmpty ? null : event.items.first);
    } catch (e) {
      loggy.error("error watching group: $e");
      rethrow;
    }
    // //emitting first event immediately
    // yield* core.bgClient.outboundsInfo(Empty()).take(1).map((event) => event.items.isEmpty ? null : event.items.first);
    // //emitting other event after every 4 seconds(latest event)
    // yield* core.bgClient.outboundsInfo(Empty()).throttleTime(const Duration(seconds: 4), leading: false, trailing: true).map((event) => event.items.isEmpty ? null : event.items.first);
  }

  Stream<List<OutboundGroup>> watchActiveGroups() async* {
    loggy.info("watching active groups");

    if (!core.isInitialized()) {
      loggy.debug("core is not initialized, returning empty group stream");
      return;
    }

    try {
      yield* core.bgClient
          .mainOutboundsInfo(Empty())
          .map((event) {
            return latest = event.items;
          })
          .startWith(latest);
    } catch (e) {
      loggy.error("error watching active groups: $e");
      rethrow;
    }
  }

  //
  // Stream<SingboxStatus> watchStatus() => _status;

  ResponseStream<SystemInfo> watchStats() {
    loggy.debug("watching stats");
    try {
      return core.bgClient.getSystemInfo(Empty());
    } catch (e) {
      loggy.error("error watching stats: $e");
      rethrow;
    }
  }

  TaskEither<String, Unit> selectOutbound(String groupTag, String outboundTag, {bool skipProbe = false}) {
    return TaskEither(() async {
      loggy.debug("selecting outbound");
      try {
        final res = await core.bgClient.selectOutbound(
          SelectOutboundRequest(groupTag: groupTag, outboundTag: outboundTag, skipProbe: skipProbe),
          options: CallOptions(timeout: const Duration(seconds: 1)),
        );
        if (res.code != ResponseCode.OK) return left("${res.code} ${res.message}");

        return right(unit);
      } catch (e) {
        loggy.error("error selecting outbound: $e");
        return left(e.toString());
      }
    });
  }

  TaskEither<String, UrlTestDelaySnapshot> probeSelectedRoute(String groupTag, {required Duration timeout}) {
    return TaskEither(() async {
      loggy.debug("probing selected route");
      if (currentState != const CoreStatus.started()) {
        await _refreshBackgroundCoreStatusSnapshot(reason: "selected route probe");
      }
      if (currentState != const CoreStatus.started()) {
        return left("core service is not running");
      }
      try {
        final result = await core.bgClient.probeSelectedRoute(
          UrlTestRequest(groupTag: groupTag),
          options: CallOptions(timeout: timeout),
        );
        if (result.tag.isEmpty || !result.hasUrlTestDelay() || !result.hasUrlTestTime()) {
          return left("selected route probe returned an incomplete result");
        }
        return right((tag: result.tag, delay: result.urlTestDelay, testedAt: result.urlTestTime.toDateTime()));
      } catch (e) {
        loggy.warning("selected route probe failed: $e");
        return left(e.toString());
      }
    });
  }

  TaskEither<String, Unit> urlTest(String tag) {
    return TaskEither(() async {
      loggy.debug("url test");
      if (currentState != const CoreStatus.started()) {
        await _refreshBackgroundCoreStatusSnapshot(reason: "url test");
      }
      if (currentState != const CoreStatus.started()) {
        loggy.debug("skipping url test while core state is $currentState");
        return left("core service is not running");
      }
      try {
        final res = await core.bgClient.urlTest(UrlTestRequest(groupTag: tag));
        if (res.code != ResponseCode.OK) return left("${res.code} ${res.message}");

        return right(unit);
      } catch (e) {
        loggy.error("error in url test: $e");
        rethrow;
      }
    });
  }

  Future<int?> urlTestDelay(String groupTag, String outboundTag) async {
    return (await urlTestDelaySnapshot(groupTag, outboundTag))?.delay;
  }

  Future<UrlTestDelaySnapshot?> urlTestDelaySnapshot(String groupTag, String outboundTag) async {
    if (!core.isInitialized()) return null;
    try {
      final groups = await core.bgClient
          .mainOutboundsInfo(Empty())
          .first
          .timeout(_outboundInfoSnapshotTimeout, onTimeout: () => OutboundGroupList());
      for (final group in groups.items) {
        if (group.tag != groupTag) continue;
        OutboundInfo? item;
        for (final candidate in group.items) {
          if (candidate.tag == outboundTag) {
            item = candidate;
            break;
          }
        }
        final selected = group.hasSelected() && group.selected.tag == outboundTag ? group.selected : null;
        return _urlTestDelaySnapshot(outboundTag, selected, item);
      }
    } catch (e) {
      loggy.warning("failed to read url test snapshot for [$groupTag/$outboundTag]: $e");
    }
    return null;
  }

  Future<({String tag, int delay})?> selectedUrlTestDelay(String groupTag) async {
    final snapshot = await selectedUrlTestDelaySnapshot(groupTag);
    final delay = snapshot?.delay;
    if (snapshot == null || delay == null) return null;
    return (tag: snapshot.tag, delay: delay);
  }

  Future<UrlTestDelaySnapshot?> selectedUrlTestDelaySnapshot(String groupTag) async {
    if (!core.isInitialized()) return null;
    try {
      final groups = await core.bgClient
          .mainOutboundsInfo(Empty())
          .first
          .timeout(_outboundInfoSnapshotTimeout, onTimeout: () => OutboundGroupList());
      for (final group in groups.items) {
        if (group.tag != groupTag || !group.hasSelected()) continue;
        final selectedTag = group.selected.tag;
        if (selectedTag.isEmpty) return null;
        OutboundInfo? item;
        for (final candidate in group.items) {
          if (candidate.tag == selectedTag) {
            item = candidate;
            break;
          }
        }
        return _urlTestDelaySnapshot(selectedTag, group.selected, item);
      }
    } catch (e) {
      loggy.warning("failed to read selected url test snapshot for [$groupTag]: $e");
    }
    return null;
  }

  List<LogMessage> logBuffer = [];
  List<LogMessage> runtimeLogBuffer = [];

  // SingboxConfigOption? latestOptions;

  Stream<List<LogMessage>> watchLogs(String path) async* {
    if (!core.isInitialized()) {
      loggy.debug("core is not initialized, returning empty log stream");
      return;
    }
    await startListeningLogs("bg", core.bgClient);
    await startListeningLogs("fg", core.fgClient);
    try {
      yield* logController.stream;
    } catch (e) {
      loggy.error("error watching logs: $e");
      rethrow;
    }
    // Stream<List<String>> logStream(CoreClient coreClient) {
    //   return coreClient.logListener(Empty()).asBroadcastStream().map((event) => [event.message]).onErrorResume((error, stackTrace) {
    //     loggy.debug('Error in $coreClient: $error, retrying...');
    //     final delay = (currentState == const SingboxStatus.stopped()) ? 5 : 1;
    //     return const Stream<List<String>>.empty().delay(Duration(seconds: delay)).concatWith([logStream(coreClient)]);
    //   });
    // }

    // // Create streams for both fg and bg clients with retry logic
    // final fgLogStream = logStream(core.fgClient);

    // if (core.bgClient == core.fgClient) {
    //   yield* fgLogStream;
    //   return;
    // }
    // final bgLogStream = logStream(core.bgClient);
    // yield* MergeStream([bgLogStream, fgLogStream]);
  }

  TaskEither<String, Unit> clearLogs() {
    return TaskEither(() async {
      loggy.debug("clearing logs");
      logBuffer.clear();
      runtimeLogBuffer.clear();
      _coreLogDeduplicator.clear();
      final file = _coreLogFile;
      if (file != null) {
        final writer = _coreLogWriter;
        if (writer != null) {
          await writer.clear();
        } else {
          await file.writeAsString('', flush: true);
        }
      }
      runtimeLogController.add(const []);
      logController.add(const []);
      // final res = await core.bgClient(Empty());
      // if (res.code != ResponseCode.OK) return left("${res.code} ${res.message}");
      return right(unit);
    });
  }

  Stream<CoreStatus> watchStatus() async* {
    statusController.add(currentState);
    if (!core.isInitialized()) {
      loggy.debug("core is not initialized, returning current status stream");
      yield* statusController.stream;
      return;
    }
    await startListeningStatus("bg", core.bgClient);
    yield* statusController.stream;
    // .endWith(const CoreStatus.stopped());
  }

  Future<CoreStatus?> _refreshBackgroundCoreStatusSnapshot({
    required String reason,
    bool emit = false,
    bool Function()? shouldApply,
  }) async {
    if (!core.isInitialized()) return null;
    try {
      final event = await core.bgClient
          .coreInfoListener(Empty(), options: CallOptions(timeout: _coreStatusSnapshotTimeout))
          .first
          .timeout(_coreStatusSnapshotTimeout);
      final status = CoreStatus.fromCoreInfo(event);
      if (shouldApply != null && !shouldApply()) {
        loggy.debug("discarding stale background core status snapshot during $reason");
        return status;
      }
      _setCurrentState(status, emit: emit);
      return status;
    } catch (e) {
      loggy.debug("background core status snapshot unavailable during $reason: $e");
      return null;
    }
  }

  Future<void> startListeningStatus(String key, CoreClient cc) async {
    await listenSingle<CoreStatus>(
      "${key}StatusListener",
      () => cc
          .coreInfoListener(Empty(), options: grpcOptions)
          .doOnCancel(() {
            loggy.debug("status listener canceled");
            _markStoppedIfBackgroundInactive("status listener canceled");
          })
          .doOnData((event) {
            loggy.debug("status", event);
          })
          .doOnDone(() {
            loggy.debug("status listener done");
            _markStoppedIfBackgroundInactive("status listener done");
          })
          .map((event) {
            _setCurrentState(
              coreStatusAfterRuntimeEvent(
                CoreStatus.fromCoreInfo(event),
                nativeRecoveryInProgress: _nativePlatformRecoveryInProgress,
              ),
            );
            return currentState;
          }),
      // .endWith(const CoreStatus.stopped())
      logErrors: false,
      onError: (error) {
        if (_isExpectedStreamShutdown(error)) {
          loggy.debug("status listener closed: $error");
          _markStoppedIfBackgroundInactive("status listener closed");
          return;
        }
        loggy.error("Stream error in ${key}StatusListener: $error");

        // currentState = const CoreStatus.stopped();
        // statusController.add(currentState);

        // startListeningStatus(key, cc);
      },
    );
  }

  Future<void> startListeningPlatformStatus() async {
    await listenSingle<CoreStatus>(
      "platformServiceStatusListener",
      () => core.watchServiceStatus().map((event) {
        _applyPlatformServiceStatus(event);
        return event;
      }),
      logErrors: false,
    );
  }

  void _applyPlatformServiceStatus(CoreStatus event) {
    final eventRevision = ++_statusRevision;
    _latestPlatformServiceStatus = event;
    if (event case CoreStopped(alert: CoreAlert.vpnRevoked)) {
      loggy.info("Android revoked Marten VPN; clearing user-started session intent");
      unawaited(ref.read(Preferences.startedByUser.notifier).update(false));
    }
    if (startsNativePlatformRecovery(currentState, event)) {
      _nativePlatformRecoveryInProgress = true;
      loggy.info("Android native core recovery started; keeping Flutter status in connecting");
    }

    final recoveryInProgress = _nativePlatformRecoveryInProgress;
    if (event is CoreStopped && event.alert != null) {
      _nativePlatformRecoveryInProgress = false;
    }
    final next = coreStatusAfterPlatformEvent(currentState, event, nativeRecoveryInProgress: recoveryInProgress);
    if (!recoveryInProgress && next is CoreStarted && currentState is! CoreStarted) {
      loggy.info("Android route-verified Started replayed to late Flutter engine");
    }
    if (shouldInitializeCoreForPlatformEvent(event, coreInitialized: core.isInitialized())) {
      _initializeCoreForPlatformStart();
    }
    final recoveryCompleted = recoveryInProgress && event is CoreStarted;
    if (recoveryCompleted) {
      _nativePlatformRecoveryInProgress = false;
      unawaited(_reattachAfterNativePlatformRecovery(eventRevision));
    }
    if (currentState == next) return;
    currentState = next;
    statusController.add(currentState);
  }

  void _initializeCoreForPlatformStart() {
    if (_platformTriggeredInitFuture != null || core.isInitialized()) return;
    final future = init();
    _platformTriggeredInitFuture = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_platformTriggeredInitFuture, future)) {
          _platformTriggeredInitFuture = null;
        }
      }),
    );
  }

  Future<void> _reattachAfterNativePlatformRecovery(int recoveryRevision) async {
    try {
      await startListeningLogs("bg", core.bgClient);
      await startListeningStatus("bg", core.bgClient);
      await _refreshBackgroundCoreStatusSnapshot(
        reason: "native platform recovery",
        emit: true,
        shouldApply: () => shouldApplyNativeRecoverySnapshot(
          requestRevision: recoveryRevision,
          currentRevision: _statusRevision,
          currentStatus: currentState,
        ),
      );
      loggy.info("Android native core recovery reattached to gRPC streams");
    } catch (error) {
      loggy.warning("failed to reattach after Android native core recovery: $error");
    }
  }

  void _markStoppedIfBackgroundInactive(String reason) {
    final requestRevision = _statusRevision;
    unawaited(
      Future(() async {
        if (_nativePlatformRecoveryInProgress) return;
        if (!core.isInitialized()) return;
        final backgroundActive = await core.isActiveBg();
        if (!shouldApplyBackgroundInactiveResult(
          requestRevision: requestRevision,
          currentRevision: _statusRevision,
          nativeRecoveryInProgress: _nativePlatformRecoveryInProgress,
          backgroundActive: backgroundActive,
        )) {
          return;
        }
        if (currentState == const CoreStatus.stopped()) return;
        loggy.debug("$reason and background core is inactive; marking stopped");
        _setCurrentState(const CoreStatus.stopped());
      }),
    );
  }

  Future<void> startListeningLogs(String key, CoreClient cc) async {
    final listenKey = "${key}LogListener";
    // await stopListenSingle(listenKey);
    await listenSingle<LogMessage>(listenKey, () {
      return cc.logListener(Empty(), options: grpcOptions).map((event) {
        if (!_coreLogDeduplicator.shouldAccept(event)) return event;
        // Handle incoming event
        runtimeLogBuffer.add(event);
        final safeEvent = LogMessage(
          level: event.level,
          type: event.type,
          message: SensitiveDataRedactor.redact(event.message),
          time: event.hasTime() ? event.time : null,
        );
        logBuffer.add(safeEvent);
        _trimLogBuffer();
        _persistCoreLog(safeEvent);
        runtimeLogController.add(List.unmodifiable(runtimeLogBuffer));
        logController.add(List.unmodifiable(logBuffer));
        for (final line in safeEvent.message.split('\n')) {
          LoggerController.instance.onCoreLog(loggyl.LogRecord(getLogLevel(event.level), line, 'MartenCoreService'));
        }
        return event;
      });
    });
  }

  Future<void> stopListenSingle(String key) async {
    await _subscriptionRegistry.stop(key);
  }

  void _trimLogBuffer() {
    final now = DateTime.now();
    runtimeLogBuffer = LogFileRetention.retainItems<LogMessage>(
      runtimeLogBuffer,
      timestampOf: (message) => message.hasTime() ? message.time.toDateTime().toLocal() : null,
      levelOf: (message) => message.level.name,
      now: now,
    );
    logBuffer = LogFileRetention.retainItems<LogMessage>(
      logBuffer,
      timestampOf: (message) => message.hasTime() ? message.time.toDateTime().toLocal() : null,
      levelOf: (message) => message.level.name,
      now: now,
    );
    if (runtimeLogBuffer.length > 1000) {
      runtimeLogBuffer = runtimeLogBuffer.sublist(runtimeLogBuffer.length - 1000);
    }
    if (logBuffer.length > 1000) {
      logBuffer = logBuffer.sublist(logBuffer.length - 1000);
    }
  }

  void _persistCoreLog(LogMessage event) {
    final writer = _coreLogWriter;
    if (writer == null) return;
    final time = event.hasTime() ? event.time.toDateTime().toLocal() : DateTime.now();
    final entry =
        '${LogFileRetention.formatTimestamp(time)} - [${event.level.name}] ${event.type.name}: ${event.message}\n';
    writer.add(entry, timestamp: time);
  }

  Future<StreamSubscription<T>?> listenSingle<T>(
    String key,
    Stream<T> Function() stream, {
    Function(dynamic error)? onError,
    bool logErrors = true,
  }) {
    return _subscriptionRegistry.listen<T>(
      key,
      stream,
      onData: (event) {
        // loggy.debug(event);
      },
      onError: (dynamic error) {
        if (_isExpectedStreamShutdown(error)) {
          loggy.debug("Stream $key closed: $error");
        } else if (logErrors) {
          loggy.log(loggyl.LogLevel.error, 'Stream error: $error');
        }
        onError?.call(error);
      },
    );
  }

  bool _isExpectedStreamShutdown(Object? error) {
    if (error is! GrpcError) return false;
    if (error.code == StatusCode.unavailable) return true;
    return error.code == StatusCode.unknown && (error.message?.contains("HTTP/2 error") ?? false);
  }

  loggyl.LogLevel getLogLevel(LogLevel level) {
    return switch (level) {
      LogLevel.DEBUG => loggyl.LogLevel.debug,
      LogLevel.INFO => loggyl.LogLevel.info,
      LogLevel.WARNING => loggyl.LogLevel.warning,
      LogLevel.ERROR => loggyl.LogLevel.error,
      LogLevel.FATAL => loggyl.LogLevel.error,
      _ => loggyl.LogLevel.info, // Default case
    };
  }

  LogLevel getCoreLogLevel(config_log_level.LogLevel level) {
    return switch (level) {
      config_log_level.LogLevel.trace => LogLevel.DEBUG,
      config_log_level.LogLevel.debug => LogLevel.DEBUG,
      config_log_level.LogLevel.info => LogLevel.INFO,
      config_log_level.LogLevel.warn => LogLevel.WARNING,
      config_log_level.LogLevel.error => LogLevel.ERROR,
      config_log_level.LogLevel.fatal => LogLevel.FATAL,
      config_log_level.LogLevel.panic => LogLevel.FATAL,
    };
  }

  Future<void> closeFront() async {
    if (!core.isInitialized()) {
      return;
    }
    if (!core.isSingleChannel()) {
      await stopListenSingle("fg");
      await stopListenSingle("bg");
      try {
        await core.fgClient.pause(PauseRequest(mode: SetupMode.GRPC_NORMAL_INSECURE));
      } catch (_) {
        // The foreground channel may already be gone during shutdown.
      }
      try {
        await core.fgClient.pause(PauseRequest(mode: SetupMode.GRPC_NORMAL));
      } catch (_) {
        // The alternate foreground channel may already be gone too.
      }
    }
  }
}

UrlTestDelaySnapshot? _urlTestDelaySnapshot(String tag, OutboundInfo? selected, OutboundInfo? item) {
  final candidates = [selected, item].whereType<OutboundInfo>().toList(growable: false);
  if (candidates.isEmpty) return null;

  final measured = candidates.where((candidate) => candidate.hasUrlTestDelay() && candidate.urlTestDelay > 0);
  final latest = measured.isEmpty
      ? item ?? selected
      : measured.reduce((current, candidate) {
          final currentTime = current.hasUrlTestTime() ? current.urlTestTime.toDateTime().microsecondsSinceEpoch : -1;
          final candidateTime = candidate.hasUrlTestTime()
              ? candidate.urlTestTime.toDateTime().microsecondsSinceEpoch
              : -1;
          return candidateTime > currentTime ? candidate : current;
        });
  if (latest == null) return null;
  return (
    tag: tag,
    delay: latest.hasUrlTestDelay() ? latest.urlTestDelay : null,
    testedAt: latest.hasUrlTestTime() ? latest.urlTestTime.toDateTime() : null,
  );
}

bool isRedundantCoreStop(CoreStatus current, CoreStatus? platform) => current is CoreStopped && platform is CoreStopped;

@visibleForTesting
bool shouldAttemptGracefulGrpcStop({required bool isAndroid}) => !isAndroid;

Future<bool> waitForRestartedCoreRuntime({
  required Future<CoreStatus?> Function() readStatus,
  required Duration timeout,
  required Duration pollInterval,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final status = await readStatus();
    if (status is CoreStarted) return true;
    if (status is CoreStopped && status.alert != null) return false;

    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return false;
    await Future<void>.delayed(remaining < pollInterval ? remaining : pollInterval);
  }
}

bool startsNativePlatformRecovery(CoreStatus current, CoreStatus platform) {
  return current is CoreStarted && platform is CoreStarting;
}

@visibleForTesting
bool shouldUseLightweightPlatformBootstrap({required bool isAndroid, required CoreStatus? platformStatus}) =>
    isAndroid && platformStatus is CoreStopped;

@visibleForTesting
bool shouldInitializeCoreForPlatformEvent(CoreStatus platformStatus, {required bool coreInitialized}) =>
    !coreInitialized && platformStatus is CoreStarting;

CoreStatus coreStatusAfterRuntimeEvent(CoreStatus runtime, {required bool nativeRecoveryInProgress}) {
  if (nativeRecoveryInProgress &&
      (runtime is CoreStarted || runtime is CoreStopping || (runtime is CoreStopped && runtime.alert == null))) {
    return const CoreStatus.starting();
  }
  return runtime;
}

CoreStatus coreStatusAfterPlatformEvent(
  CoreStatus current,
  CoreStatus platform, {
  bool nativeRecoveryInProgress = false,
}) {
  // A native network recovery owns the whole stop/setup/start sequence. Its
  // intermediate core STOPPING/STOPPED states are not a user-visible stop,
  // and its final Started is emitted only after Android's selected-route gate.
  if (nativeRecoveryInProgress) {
    if (platform is CoreStarted) return const CoreStatus.started();
    if (platform is CoreStopping || (platform is CoreStopped && platform.alert == null)) {
      return const CoreStatus.starting();
    }
  }
  // Android publishes Started only after the native runtime, Android TUN and
  // selected route have passed their readiness gate. A new Flutter engine can
  // attach after that transition, so this retained service state must promote
  // its local core snapshot. ConnectionRepository still keeps Android cold
  // attach in Connecting until its own fresh selected-route verification.
  // Do not resurrect a manual stop from a delayed retained callback.
  if (platform is CoreStarted) {
    if (current is CoreStopping) return current;
    return const CoreStatus.started();
  }
  // EventChannel observes LiveData and can immediately replay the shell's
  // stale initial Stopped value while a user-triggered core start is in flight.
  // Keep alert-bearing stops: those represent real service failures.
  if ((current is CoreStarting || current is CoreStarted) && platform is CoreStopped && platform.alert == null) {
    return current;
  }
  return platform;
}
