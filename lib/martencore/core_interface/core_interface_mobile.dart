import 'dart:async';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter/services.dart';
import 'package:grpc/grpc.dart';
import 'package:marten/core/model/directories.dart';
import 'package:marten/core/utils/laststeam.dart';
import 'package:marten/martencore/core_interface/core_interface.dart';
import 'package:marten/martencore/core_interface/mtls_channel_cred.dart';
import 'package:marten/martencore/generated/v2/hcommon/common.pb.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:marten/martencore/generated/v2/hello/hello.pb.dart';
import 'package:marten/martencore/generated/v2/hello/hello_service.pbgrpc.dart';
import 'package:marten/singbox/model/core_status.dart';
import 'package:marten/utils/utils.dart';
import 'package:marten_native_resume/marten_native_resume.dart';
import 'package:rxdart/rxdart.dart';

Duration backgroundAttachStoppedGrace({required bool explicitManualStart, bool? platformStartedByUser}) =>
    explicitManualStart || platformStartedByUser == false ? Duration.zero : const Duration(seconds: 1);

bool backgroundStartCancelled({required int startGeneration, required int lifecycleGeneration}) =>
    startGeneration != lifecycleGeneration;

bool shouldProbeExistingBackgroundCoreForManualStart({
  required bool isAndroid,
  required CoreStatus? platformStatus,
  required bool backgroundChannelKnownAvailable,
}) =>
    !isAndroid ||
    platformStatus is CoreStarting ||
    platformStatus is CoreStarted ||
    (platformStatus == null && backgroundChannelKnownAvailable);

bool shouldJoinAuthoritativeBackgroundStart({required bool isAndroid, required CoreStatus? platformStatus}) =>
    isAndroid && platformStatus is CoreStarting;

bool mayAttachToActiveConfigGeneration({required bool isAndroid, required bool configIdentityMatches}) =>
    !isAndroid || configIdentityMatches;

typedef _BackgroundCoreEndpoint = ({int port, CoreStatus status});

class CoreInterfaceMobile extends CoreInterface with InfraLogger {
  static const channelPrefix = "app.marten.client";
  static const methodChannel = MethodChannel("$channelPrefix/method");
  static const statusChannel = EventChannel("$channelPrefix/service.status", JSONMethodCodec());
  static const alertsChannel = EventChannel("$channelPrefix/service.alerts", JSONMethodCodec());
  // Android's authoritative stop contract includes up to 20 seconds for the
  // native core plus 5 seconds for service/VPN ownership release. Do not let
  // the outer method-channel deadline expire while that bounded cleanup is
  // still legitimately in progress.
  static const _platformStopCallTimeout = Duration(seconds: 30);
  static const _platformStopReconcileTimeout = Duration(seconds: 6);
  static const _platformSetupCallTimeout = Duration(seconds: 8);
  static const _platformStartCallTimeout = Duration(seconds: 8);
  // A failed real VPN GET can consume the bounded connect + read timeouts.
  // Healthy acknowledgements still return immediately; this only prevents
  // Dart from abandoning the native result while its proof is in flight.
  // Native TURNcoat admission retries a real VPN-network GET for up to 75s;
  // one already-started blocking socket attempt may finish just after that
  // deadline. Keep Dart attached until native returns its terminal result.
  static const _platformStartedSyncTimeout = Duration(seconds: 115);
  static const _platformSessionStateTimeout = Duration(seconds: 1);
  static const _foregroundHelloTimeout = Duration(seconds: 3);
  static const _healthCheckTimeout = Duration(milliseconds: 700);
  static const _portProbeTimeout = Duration(milliseconds: 120);
  static const _backgroundAttachTimeout = Duration(seconds: 6);
  static const _backgroundServiceReadyTimeout = Duration(seconds: 30);
  static const _backgroundServiceLateAttachGrace = Duration(seconds: 3);
  static const _backgroundServicePollInterval = Duration(milliseconds: 200);
  static const _portRangeStart = 17078;
  static const _portRangeEnd = 17120;

  late Uint8List serverPublicKey;
  static final cert = CryptoUtils.generateEcKeyPair();

  static const portBack = 17079;
  static const portFront = 17078;

  int _portFront = portFront;
  int _portBack = portBack;
  bool _isBgClientAvailable = false;
  bool _debug = false;
  int _backgroundLifecycleGeneration = 0;
  ChannelCredentials _channelCredentials = const ChannelCredentials.insecure();
  ClientChannel? _backgroundObservationChannel;
  ClientChannel? _backgroundControlChannel;
  CoreClient? _backgroundControlClient;

  late LastStream<CoreStatus> _status;
  Stream<CoreStatus>? _serviceStatus;

  @override
  CoreClient get backgroundControlClient => _backgroundControlClient ?? bgClient;

  @override
  int get backgroundLifecycleGeneration => _backgroundLifecycleGeneration;

  @override
  void beginBackgroundLifecycle() {
    _backgroundLifecycleGeneration++;
    _clearBackgroundControlClient();
  }

  void _ensurePlatformStatusStreams() {
    if (_serviceStatus != null) return;
    final status = statusChannel.receiveBroadcastStream().map(CoreStatus.fromEvent);
    final alerts = alertsChannel.receiveBroadcastStream().map(CoreStatus.fromEvent);
    final serviceStatus = ValueConnectableStream(Rx.merge([status, alerts])).autoConnect();
    _serviceStatus = serviceStatus;
    _status = LastStream(serviceStatus);
  }

  @override
  Future<String> setup(Directories directories, bool debug, int mode) async {
    final channelOption = [1, 2].contains(mode)
        ? MTLSChannelCredentials(serverPublicKey: serverPublicKey, clientKey: cert)
        : const ChannelCredentials.insecure();
    _channelCredentials = channelOption;
    _debug = debug;
    _ensurePlatformStatusStreams();
    final res = await _connectOrStartForegroundCore(directories, debug, mode, channelOption);
    loggy.info(res.toString());

    // serverPublicKey = await methodChannel.invokeMethod<Uint8List>("get_grpc_server_public_key") ?? Uint8List.fromList([]);
    // await methodChannel.invokeMethod(
    //   "add_grpc_client_public_key",
    //   {
    //     "clientPublicKey": ascii.encode(CryptoUtils.encodeEcPublicKeyToPem(cert.publicKey as ECPublicKey)),
    //   },
    // );
    // serverPublicKey = X509Utils.x509CertificateFromPem(String.fromCharCodes(serverPublicKey));
    // var chanelOption = ChannelOptions(
    //   credentials: MTLSChannelCredentials(serverPublicKey: serverPublicKey, clientPrivateKey: cert.privateKey as ECPrivateKey),
    // );
    fgClient = CoreClient(_coreChannel(_portFront, channelOption));

    if (!await _keepCurrentBackgroundPortIfUsable(channelOption)) {
      final attachedBackground = await _findAttachableBackgroundCore(channelOption, includeStarting: true);
      if (attachedBackground != null) {
        _portBack = attachedBackground.port;
        _isBgClientAvailable = true;
      } else {
        _portBack = await _selectAvailablePort(
          preferred: _portBack,
          role: "background",
          channelCredentials: channelOption,
          reservedPorts: {_portFront},
        );
        _isBgClientAvailable = false;
      }
    }
    _replaceBackgroundObservationClient(_coreChannel(_portBack, channelOption));
    _clearBackgroundControlClient();
    // await start("/sdcard/Android/data/app.marten.client/files/configs/cdc633e9-8cfc-4a67-948d-009f779a5c91.json", "marten");
    return "";
  }

  Future<HelloResponse> _connectOrStartForegroundCore(
    Directories directories,
    bool debug,
    int mode,
    ChannelCredentials channelCredentials,
  ) async {
    Object? lastError;
    for (final port in _candidatePorts(_portFront)) {
      if (port == portBack) continue;

      final occupied = await isPortOpen("127.0.0.1", port, timeout: _portProbeTimeout);
      if (occupied) {
        if (await _isMartenCoreHealthy(port, channelCredentials)) {
          if (port == _portFront || port == portFront) {
            _portFront = port;
            loggy.info("foreground core gRPC healthcheck passed on 127.0.0.1:$port");
            return _sayHelloOnPort(port, channelCredentials);
          }
          loggy.warning("foreground port 127.0.0.1:$port is Marten core but not this runtime session; trying next");
        } else {
          loggy.warning("foreground port 127.0.0.1:$port is busy and did not pass Marten gRPC healthcheck");
        }
        continue;
      }

      try {
        await _invokeForegroundSetup(directories, debug, mode, port);
      } on TimeoutException {
        rethrow;
      } catch (e) {
        lastError = e;
        if (_looksLikePortConflict(e)) {
          loggy.warning("foreground port 127.0.0.1:$port became busy during setup: $e");
          continue;
        }
        rethrow;
      }

      try {
        final response = await _waitForMartenCore(port, channelCredentials);
        _portFront = port;
        if (port != portFront) {
          loggy.warning("foreground core gRPC fallback selected 127.0.0.1:$port");
        }
        return response;
      } catch (e) {
        lastError = e;
        throw StateError("foreground core did not answer on 127.0.0.1:$port after setup: $e");
      }
    }
    throw StateError("no available foreground core gRPC port in $_portRangeStart-$_portRangeEnd: $lastError");
  }

  Future<void> _invokeForegroundSetup(Directories directories, bool debug, int mode, int grpcPort) async {
    try {
      await methodChannel
          .invokeMethod("setup", {
            "baseDir": directories.baseDir.path,
            "workingDir": directories.workingDir.path,
            "tempDir": directories.tempDir.path,
            "grpcPort": grpcPort,
            "mode": mode,
            "debug": debug,
          })
          .timeout(_platformSetupCallTimeout);
    } on TimeoutException {
      throw TimeoutException("foreground core setup timed out on 127.0.0.1:$grpcPort", _platformSetupCallTimeout);
    }
  }

  Future<int> _selectAvailablePort({
    required int preferred,
    required String role,
    required ChannelCredentials channelCredentials,
    Set<int> reservedPorts = const {},
    bool acceptExistingMartenCoreOnPreferred = false,
  }) async {
    for (final port in _candidatePorts(preferred)) {
      if (reservedPorts.contains(port)) continue;

      final occupied = await isPortOpen("127.0.0.1", port, timeout: _portProbeTimeout);
      if (!occupied) {
        if (port != preferred) {
          loggy.warning("$role core gRPC fallback selected 127.0.0.1:$port");
        }
        return port;
      }

      if (await _isMartenCoreHealthy(port, channelCredentials)) {
        if (acceptExistingMartenCoreOnPreferred && port == preferred) {
          loggy.info("$role core gRPC healthcheck passed on existing 127.0.0.1:$port");
          return port;
        }
        loggy.warning("$role port 127.0.0.1:$port is Marten core but reserved by another runtime role");
      } else {
        loggy.warning("$role port 127.0.0.1:$port is busy and did not pass Marten gRPC healthcheck");
      }
    }
    throw StateError("no available $role core gRPC port in $_portRangeStart-$_portRangeEnd");
  }

  Future<bool> _keepCurrentBackgroundPortIfUsable(ChannelCredentials channelCredentials) async {
    if (!_isBgClientAvailable || _portBack == _portFront) return false;
    if (await _isMartenCoreHealthy(_portBack, channelCredentials)) {
      loggy.info("background core gRPC keeping existing 127.0.0.1:$_portBack");
      return true;
    }
    _isBgClientAvailable = false;
    return false;
  }

  Future<_BackgroundCoreEndpoint?> _findAttachableBackgroundCore(
    ChannelCredentials channelCredentials, {
    bool includeStarting = false,
    bool includeStopped = false,
  }) async {
    for (final port in _candidatePorts(_portBack)) {
      if (port == _portFront) continue;
      final status = await _coreStatusOnPort(port, channelCredentials);
      if (status == null ||
          !_isAttachableBackgroundStatus(status, includeStarting: includeStarting, includeStopped: includeStopped)) {
        if (status != null) {
          loggy.warning("background core gRPC on 127.0.0.1:$port is $status; not attaching");
        }
        continue;
      }
      if (await _isMartenCoreHealthy(port, channelCredentials)) {
        if (port != _portBack) {
          loggy.warning("background core gRPC attached to existing 127.0.0.1:$port");
        } else {
          loggy.info("background core gRPC healthcheck passed on existing 127.0.0.1:$port");
        }
        return (port: port, status: status);
      }
    }
    return null;
  }

  bool _isAttachableBackgroundStatus(
    CoreStatus? status, {
    required bool includeStarting,
    required bool includeStopped,
  }) {
    return switch (status) {
      CoreStarted() => true,
      CoreStarting() when includeStarting => true,
      CoreStopped() when includeStopped => true,
      _ => false,
    };
  }

  Future<CoreStatus?> _coreStatusOnPort(int port, ChannelCredentials channelCredentials) async {
    final channel = _coreChannel(port, channelCredentials);
    try {
      return await _coreStatusOnClient(CoreClient(channel));
    } catch (_) {
      return null;
    } finally {
      await channel.shutdown();
    }
  }

  Future<CoreStatus?> _coreStatusOnClient(CoreClient client) async {
    try {
      final event = await client
          .coreInfoListener(Empty(), options: CallOptions(timeout: _healthCheckTimeout))
          .first
          .timeout(_healthCheckTimeout);
      return CoreStatus.fromCoreInfo(event);
    } catch (_) {
      return null;
    }
  }

  Future<_BackgroundCoreEndpoint?> _attachExistingBackgroundCore({
    Duration timeout = _backgroundAttachTimeout,
    bool includeStarting = false,
    bool includeStopped = false,
    Duration staleStoppedGrace = Duration.zero,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final tolerateStoppedUntil = DateTime.now().add(staleStoppedGrace);
    while (DateTime.now().isBefore(deadline)) {
      final endpoint = await _findAttachableBackgroundCore(
        _channelCredentials,
        includeStarting: includeStarting,
        includeStopped: includeStopped,
      );
      if (endpoint != null) {
        _portBack = endpoint.port;
        _replaceBackgroundObservationClient(_coreChannel(_portBack, _channelCredentials));
        _isBgClientAvailable = true;
        return endpoint;
      }

      final serviceStatus = await _serviceStatusSnapshot(timeout: const Duration(milliseconds: 250));
      if (serviceStatus == null) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }
      switch (serviceStatus) {
        case CoreStarting() || CoreStarted():
          await Future.delayed(const Duration(milliseconds: 150));
        case CoreStopped() || CoreStopping():
          if (DateTime.now().isBefore(tolerateStoppedUntil)) {
            await Future.delayed(const Duration(milliseconds: 100));
            continue;
          }
          return null;
      }
    }
    return null;
  }

  Future<CoreStatus?> _serviceStatusSnapshot({required Duration timeout}) async {
    try {
      return await _status.get(timeout: timeout);
    } on TimeoutException {
      return null;
    }
  }

  Iterable<int> _candidatePorts(int preferred) sync* {
    if (preferred >= _portRangeStart && preferred <= _portRangeEnd) {
      yield preferred;
    }
    for (var port = _portRangeStart; port <= _portRangeEnd; port++) {
      if (port != preferred) yield port;
    }
  }

  ClientChannel _coreChannel(int port, ChannelCredentials channelCredentials) {
    return ClientChannel(
      '127.0.0.1',
      port: port,
      options: ChannelOptions(credentials: channelCredentials),
    );
  }

  void _replaceBackgroundObservationClient(ClientChannel channel) {
    final previous = _backgroundObservationChannel;
    _backgroundObservationChannel = channel;
    bgClient = CoreClient(channel);
    if (previous != null && !identical(previous, channel)) {
      unawaited(_terminateChannel(previous, "retired background observation"));
    }
  }

  void _clearBackgroundControlClient() {
    final previous = _backgroundControlChannel;
    _backgroundControlChannel = null;
    _backgroundControlClient = null;
    if (previous != null) {
      unawaited(_terminateChannel(previous, "retired background control"));
    }
  }

  Future<void> _terminateChannel(ClientChannel channel, String role) async {
    try {
      await channel.terminate();
    } catch (error) {
      loggy.debug("failed to terminate $role channel: $error");
    }
  }

  bool _platformOwnsCurrentBackgroundLifecycle(CoreStatus? status) {
    return !Platform.isAndroid || status is CoreStarting || status is CoreStarted;
  }

  @override
  Future<CoreStatus?> refreshBackgroundControlSession(int expectedGeneration) async {
    if (expectedGeneration != _backgroundLifecycleGeneration || !_isBgClientAvailable) return null;

    final platformBefore = await readPlatformServiceStatus();
    if (!_platformOwnsCurrentBackgroundLifecycle(platformBefore) ||
        expectedGeneration != _backgroundLifecycleGeneration) {
      return null;
    }

    // Validate the exact connection that will carry SelectOutbound. A separate
    // probe channel would leave the real command transport exposed to the same
    // post-Start race. Do not scan ports or wait: the current lifecycle already
    // owns [_portBack], and healthy handoff is one local gRPC round-trip.
    final controlChannel = _coreChannel(_portBack, _channelCredentials);
    final controlClient = CoreClient(controlChannel);
    final status = await _coreStatusOnClient(controlClient);
    if (status is! CoreStarted) {
      await _terminateChannel(controlChannel, "unconfirmed background control");
      return null;
    }

    final platformAfter = await readPlatformServiceStatus();
    if (!_platformOwnsCurrentBackgroundLifecycle(platformAfter) ||
        expectedGeneration != _backgroundLifecycleGeneration) {
      await _terminateChannel(controlChannel, "stale background control");
      return null;
    }

    // Keep unary control calls independent from long-lived log/status streams:
    // one HTTP/2 connection failure can no longer take both down together.
    final observationChannel = _coreChannel(_portBack, _channelCredentials);
    final previousControl = _backgroundControlChannel;
    _backgroundControlChannel = controlChannel;
    _backgroundControlClient = controlClient;
    _replaceBackgroundObservationClient(observationChannel);
    if (previousControl != null && !identical(previousControl, controlChannel)) {
      unawaited(_terminateChannel(previousControl, "retired background control"));
    }
    return status;
  }

  Future<HelloResponse> _waitForMartenCore(int port, ChannelCredentials channelCredentials) async {
    Object? lastError;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        return await _sayHelloOnPort(port, channelCredentials);
      } catch (e) {
        lastError = e;
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
    throw lastError ?? StateError("Marten core healthcheck failed");
  }

  Future<HelloResponse> _sayHelloOnPort(
    int port,
    ChannelCredentials channelCredentials, {
    String name = "test",
    Duration timeout = _foregroundHelloTimeout,
  }) async {
    final channel = _coreChannel(port, channelCredentials);
    try {
      return await _sayHello(HelloClient(channel), name: name, timeout: timeout);
    } finally {
      await channel.shutdown();
    }
  }

  Future<bool> _isMartenCoreHealthy(int port, ChannelCredentials channelCredentials) async {
    try {
      final healthName = "marten-health-${DateTime.now().microsecondsSinceEpoch}";
      final response = await _sayHelloOnPort(port, channelCredentials, name: healthName, timeout: _healthCheckTimeout);
      return response.message == "Hello, $healthName";
    } catch (_) {
      return false;
    }
  }

  Future<HelloResponse> _sayHello(
    HelloClient helloClient, {
    String name = "test",
    Duration timeout = _foregroundHelloTimeout,
  }) {
    return helloClient.sayHello(
      HelloRequest(name: name),
      options: CallOptions(timeout: timeout),
    );
  }

  bool _looksLikePortConflict(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains("already in use") ||
        message.contains("address already") ||
        message.contains("eaddrinuse") ||
        message.contains("failed to listen");
  }

  @override
  Future<BackgroundCoreSetupResult> setupBackground(String path, String name) async {
    var platformStatus = await readPlatformServiceStatus();
    var configIdentityMatches = !Platform.isAndroid || await _matchesActiveConfigGeneration(path);
    var platformCleanupConfirmed = false;
    if (Platform.isAndroid && !configIdentityMatches) {
      loggy.info("active Android runtime does not own the requested configuration; retiring it before start");
      if (!await stop()) {
        return const BackgroundCoreSetupResult.failed(CoreStatus.stopped(alert: CoreAlert.createService));
      }
      platformCleanupConfirmed = true;
      platformStatus = await readPlatformServiceStatus();
    }
    if (shouldJoinAuthoritativeBackgroundStart(isAndroid: Platform.isAndroid, platformStatus: platformStatus) &&
        mayAttachToActiveConfigGeneration(
          isAndroid: Platform.isAndroid,
          configIdentityMatches: configIdentityMatches,
        )) {
      return _joinAuthoritativeBackgroundStart(path);
    }
    final shouldProbeExisting = shouldProbeExistingBackgroundCoreForManualStart(
      isAndroid: Platform.isAndroid,
      platformStatus: platformStatus,
      backgroundChannelKnownAvailable: _isBgClientAvailable,
    );
    loggy.info(
      "manual background start platform_running=${platformStatus is CoreStarting || platformStatus is CoreStarted} "
      "channel_known=$_isBgClientAvailable probe_existing=$shouldProbeExisting",
    );
    _BackgroundCoreEndpoint? attachedExisting;
    if (shouldProbeExisting) {
      attachedExisting = await _attachExistingBackgroundCore(
        includeStarting: true,
        includeStopped: true,
        // This API is the explicit Flutter Connect path. Persisted native intent
        // can survive a force-stop, so it cannot justify delaying a stopped shell.
        staleStoppedGrace: backgroundAttachStoppedGrace(explicitManualStart: true),
      );
    }
    if (attachedExisting?.status case CoreStarting() || CoreStarted()) {
      configIdentityMatches = !Platform.isAndroid || await _matchesActiveConfigGeneration(path);
      if (mayAttachToActiveConfigGeneration(
        isAndroid: Platform.isAndroid,
        configIdentityMatches: configIdentityMatches,
      )) {
        _clearBackgroundControlClient();
        _backgroundLifecycleGeneration++;
        loggy.info(
          "background service gRPC is already available with ${attachedExisting!.status}; attached to matching runtime",
        );
        return BackgroundCoreSetupResult.attached(attachedExisting.status);
      }
      loggy.info("discarding a healthy background endpoint owned by a superseded configuration");
      attachedExisting = null;
      if (!platformCleanupConfirmed) {
        if (!await stop()) {
          return const BackgroundCoreSetupResult.failed(CoreStatus.stopped(alert: CoreAlert.createService));
        }
        platformCleanupConfirmed = true;
      }
    }

    if (attachedExisting != null) {
      loggy.info("background core gRPC shell is stopped; starting Android service on existing 127.0.0.1:$_portBack");
    } else {
      if (!platformCleanupConfirmed && !await stop()) {
        return const BackgroundCoreSetupResult.failed(CoreStatus.stopped(alert: CoreAlert.createService));
      }
      _status.clean();
      _portBack = await _selectAvailablePort(
        preferred: _portBack,
        role: "background",
        channelCredentials: _channelCredentials,
        reservedPorts: {_portFront},
      );
      _replaceBackgroundObservationClient(_coreChannel(_portBack, _channelCredentials));
    }
    _clearBackgroundControlClient();
    final startGeneration = ++_backgroundLifecycleGeneration;
    await _invokeBackgroundStartAndWait(path, name, _portBack);

    _isBgClientAvailable = true;
    final startStatus = await _waitForBackgroundServiceReady(
      timeout: _backgroundServiceReadyTimeout,
      startGeneration: startGeneration,
    );
    if (backgroundStartCancelled(
      startGeneration: startGeneration,
      lifecycleGeneration: _backgroundLifecycleGeneration,
    )) {
      loggy.info("background core start wait cancelled by stop request");
      _isBgClientAvailable = false;
      return const BackgroundCoreSetupResult.failed(CoreStatus.stopped());
    }
    final setupResult = BackgroundCoreSetupResult.fromStatus(startStatus);
    if (setupResult is! BackgroundCoreSetupFailed) {
      if (!Platform.isAndroid || await _matchesActiveConfigGeneration(path)) {
        return setupResult;
      }
      loggy.warning("Android runtime identity changed while the background service was starting");
      await stop();
      return const BackgroundCoreSetupResult.failed(CoreStatus.stopped(alert: CoreAlert.startService));
    }

    final lateAttached = await _attachExistingBackgroundCore(
      timeout: _backgroundServiceLateAttachGrace,
      includeStarting: true,
    );
    if (lateAttached != null) {
      if (!Platform.isAndroid || await _matchesActiveConfigGeneration(path)) {
        loggy.warning("background core became healthy during late attach grace");
        return BackgroundCoreSetupResult.attached(lateAttached.status);
      }
      loggy.warning("discarding late background attach from a superseded configuration");
      await stop();
      return const BackgroundCoreSetupResult.failed(CoreStatus.stopped(alert: CoreAlert.startService));
    }

    if (startStatus is CoreStopped && startStatus.alert != null) {
      return BackgroundCoreSetupResult.failed(startStatus);
    }

    loggy.warning("background core service did not expose gRPC before timeout; stopping platform service");
    await stop();
    return const BackgroundCoreSetupResult.failed(
      CoreStatus.stopped(alert: CoreAlert.startService, message: "starting background core timed out"),
    );
  }

  Future<BackgroundCoreSetupResult> _joinAuthoritativeBackgroundStart(String path) async {
    _clearBackgroundControlClient();
    final joinGeneration = ++_backgroundLifecycleGeneration;
    final deadline = DateTime.now().add(_platformStartedSyncTimeout);
    loggy.info("Android service is already Starting; joining its authoritative native generation");

    while (DateTime.now().isBefore(deadline)) {
      if (backgroundStartCancelled(
        startGeneration: joinGeneration,
        lifecycleGeneration: _backgroundLifecycleGeneration,
      )) {
        loggy.info("authoritative Android start join cancelled by stop request");
        _isBgClientAvailable = false;
        return const BackgroundCoreSetupResult.failed(CoreStatus.stopped());
      }

      final nativeStatus = await readPlatformServiceStatus();
      switch (nativeStatus) {
        case CoreStarted():
          if (!await _matchesActiveConfigGeneration(path)) {
            loggy.warning("authoritative Android start completed for a superseded configuration");
            await stop();
            return const BackgroundCoreSetupResult.failed(CoreStatus.stopped(alert: CoreAlert.startService));
          }
          // The gRPC shell can survive a native core replacement. Re-read its
          // state only after BoxService has published Started for the current
          // generation; a stale Started response while BoxService is Starting
          // is never sufficient authority.
          final endpoint = await _findAttachableBackgroundCore(_channelCredentials);
          if (endpoint?.status is CoreStarted) {
            _portBack = endpoint!.port;
            _replaceBackgroundObservationClient(_coreChannel(_portBack, _channelCredentials));
            _isBgClientAvailable = true;
            loggy.info("joined authoritative Android core generation on 127.0.0.1:$_portBack");
            return const BackgroundCoreSetupResult.attached(CoreStatus.started());
          }
        case CoreStopping():
          _isBgClientAvailable = false;
          return const BackgroundCoreSetupResult.failed(CoreStatus.stopping());
        case CoreStopped():
          _isBgClientAvailable = false;
          return BackgroundCoreSetupResult.failed(nativeStatus);
        case CoreStarting() || null:
      }

      await Future.delayed(_backgroundServicePollInterval);
    }

    _isBgClientAvailable = false;
    loggy.warning("authoritative Android start did not reach Started before timeout");
    return const BackgroundCoreSetupResult.failed(
      CoreStatus.stopped(alert: CoreAlert.startService, message: "native background core recovery timed out"),
    );
  }

  Future<void> _invokeBackgroundStartAndWait(String path, String name, int grpcPort) async {
    try {
      await _invokeBackgroundStart(path, name, grpcPort).timeout(_platformStartCallTimeout);
    } on TimeoutException {
      loggy.warning(
        "platform background start call timed out after ${_platformStartCallTimeout.inSeconds} s; waiting for gRPC readiness",
      );
    }
  }

  Future<CoreStatus> _waitForBackgroundServiceReady({required Duration timeout, required int startGeneration}) async {
    final deadline = DateTime.now().add(timeout);
    loggy.info("waiting for background service gRPC readiness");
    while (DateTime.now().isBefore(deadline)) {
      if (backgroundStartCancelled(
        startGeneration: startGeneration,
        lifecycleGeneration: _backgroundLifecycleGeneration,
      )) {
        loggy.info("background service gRPC readiness wait cancelled");
        return const CoreStatus.stopped();
      }
      final coreStatus = await _coreStatusOnPort(_portBack, _channelCredentials);
      if (coreStatus != null) {
        loggy.info("background service gRPC ready with $coreStatus");
        return coreStatus;
      }

      final snapshot = await _serviceStatusSnapshot(timeout: const Duration(milliseconds: 250));
      switch (snapshot) {
        case CoreStopped(alert: final alert) when alert != null:
          loggy.info("background service start finished with alert");
          return snapshot;
        case CoreStarted():
        case CoreStarting():
        case CoreStopping():
        case CoreStopped():
        case null:
      }

      await Future.delayed(_backgroundServicePollInterval);
    }

    final coreStatus = await _coreStatusOnPort(_portBack, _channelCredentials);
    if (coreStatus != null) {
      loggy.info("background service gRPC ready with $coreStatus");
      return coreStatus;
    }
    loggy.info("background service gRPC readiness wait timed out");
    return const CoreStatus.stopped(alert: CoreAlert.startService, message: "starting background core timed out");
  }

  Future<void> _invokeBackgroundStart(String path, String name, int grpcPort) async {
    await methodChannel.invokeMethod("start", {
      "path": path,
      "name": name,
      "grpcPort": grpcPort,
      "startBg": true,
      "debug": _debug,
    });
  }

  @override
  Future<bool> stop() async {
    _backgroundLifecycleGeneration++;
    _clearBackgroundControlClient();
    var platformStopSucceeded = false;
    var platformStopReturned = false;
    try {
      platformStopSucceeded = await stopMethodChannel().timeout(_platformStopCallTimeout);
      platformStopReturned = true;
    } on TimeoutException {
      loggy.warning("platform stop method timed out after ${_platformStopCallTimeout.inSeconds} s");
    } catch (e) {
      loggy.warning("platform stop method failed: $e");
    }
    if (!await waitUntilPort(_portBack, false, null, maxTry: 35)) {
      final lingeringStatus = await _coreStatusOnPort(_portBack, _channelCredentials);
      if (lingeringStatus is CoreStopped) {
        loggy.info("background core gRPC shell remains on $_portBack, but core is stopped");
      } else {
        loggy.warning("background core port $_portBack is still open after platform stop");
        return false;
      }
    }

    // A service-started Android session can finish native core/TUN shutdown
    // while the first platform reply is lost during framework owner teardown.
    // Once gRPC independently proves the core is stopped, perform one bounded,
    // idempotent platform reconciliation. The second call still verifies the
    // Android service cleanup and own-VPN release, so it cannot turn a genuine
    // residual VPN into a successful Disconnect.
    if (!platformStopSucceeded && platformStopReturned) {
      loggy.info("native core is stopped; reconciling Android service and VPN release once");
      try {
        platformStopSucceeded = await stopMethodChannel().timeout(_platformStopReconcileTimeout);
      } on TimeoutException {
        loggy.warning("platform stop reconciliation timed out after ${_platformStopReconcileTimeout.inSeconds} s");
      } catch (e) {
        loggy.warning("platform stop reconciliation failed: $e");
      }
    }

    if (!platformStopSucceeded) {
      loggy.warning("platform stop did not confirm Android service and VPN network release");
      return false;
    }

    _isBgClientAvailable = false;
    return true;
  }

  Future<bool> stopMethodChannel() async {
    return await methodChannel.invokeMethod<bool>("stop") ?? false;
  }

  @override
  Future<bool> isBgClientAvailable() async {
    return _isBgClientAvailable;
  }

  @override
  Future<bool> resetTunnel() async {
    await methodChannel.invokeMethod("reset");
    return true;
  }

  @override
  Future<bool> notifyBackgroundStarted() async {
    if (!Platform.isAndroid) return true;
    try {
      return await methodChannel.invokeMethod<bool>("markStarted").timeout(_platformStartedSyncTimeout) ?? false;
    } catch (e) {
      loggy.warning("platform started sync failed: $e");
      return false;
    }
  }

  @override
  Future<bool> storeNativeResumeConfig(String path, String name) async {
    if (!Platform.isAndroid) return true;
    try {
      return await MartenNativeResume.store(path: path, name: name).timeout(_platformStartCallTimeout);
    } catch (e) {
      loggy.warning("failed to store native resume config: $e");
      return false;
    }
  }

  @override
  Future<bool> clearNativeResumeConfig() async {
    if (!Platform.isAndroid) return true;
    try {
      return await MartenNativeResume.clear().timeout(_platformStartCallTimeout);
    } catch (e) {
      loggy.warning("failed to clear native resume config: $e");
      return false;
    }
  }

  @override
  Future<bool?> readPlatformStartedByUser() async {
    if (!Platform.isAndroid) return null;
    try {
      return await methodChannel.invokeMethod<bool>("get_started_by_user").timeout(_platformSessionStateTimeout);
    } catch (e) {
      loggy.warning("failed to read native user-started session flag: $e");
      return null;
    }
  }

  @override
  Future<CoreStatus?> readPlatformServiceStatus() async {
    if (!Platform.isAndroid) return null;
    try {
      final status = await methodChannel
          .invokeMethod<String>("get_service_status")
          .timeout(_platformSessionStateTimeout);
      if (status == null) return null;
      return CoreStatus.fromEvent({"status": status});
    } catch (e) {
      loggy.warning("failed to read native service status: $e");
      return null;
    }
  }

  Future<bool> _matchesActiveConfigGeneration(String path) async {
    if (!Platform.isAndroid) return true;
    try {
      return await methodChannel
              .invokeMethod<bool>("matches_active_config_generation", {"path": path})
              .timeout(_platformSessionStateTimeout) ??
          false;
    } catch (e) {
      loggy.warning("failed to verify active Android runtime configuration: $e");
      return false;
    }
  }

  @override
  Future<int?> tryBeginFlutterRestart() async {
    if (!Platform.isAndroid) return 0;
    try {
      return await methodChannel.invokeMethod<int>("try_begin_flutter_restart").timeout(_platformSessionStateTimeout);
    } catch (e) {
      loggy.warning("failed to reserve native lifecycle for Flutter restart: $e");
      return null;
    }
  }

  @override
  Future<void> endFlutterRestart(int token) async {
    if (!Platform.isAndroid) return;
    try {
      await methodChannel.invokeMethod<void>("end_flutter_restart", token).timeout(_platformSessionStateTimeout);
    } catch (e) {
      loggy.warning("failed to release native lifecycle after Flutter restart: $e");
    }
  }

  @override
  Future<bool> isActiveFg() async {
    return await _isMartenCoreHealthy(_portFront, _channelCredentials);
  }

  @override
  Future<bool> isActiveBg() async {
    return await _isMartenCoreHealthy(_portBack, _channelCredentials);
  }

  @override
  Stream<CoreStatus> watchServiceStatus() {
    _ensurePlatformStatusStreams();
    return _serviceStatus!;
  }
}

Future<bool> waitUntilPort(
  int portNumber,
  bool isOpen,
  Future Function()? callFunctionAfterEachFail, {
  int maxTry = 10,
}) async {
  for (var i = 0; i < maxTry; i++) {
    if (await isPortOpen("127.0.0.1", portNumber) == isOpen) {
      return true;
    }
    if (callFunctionAfterEachFail != null) {
      await callFunctionAfterEachFail();
    }

    await Future.delayed(const Duration(milliseconds: 200));
  }
  return false;
}

Future<bool> isPortOpen(String host, int port, {Duration timeout = const Duration(milliseconds: 300)}) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    await socket.close();
    return true;
  } on SocketException catch (_) {
    return false;
  } catch (_) {
    return false;
  }
}
