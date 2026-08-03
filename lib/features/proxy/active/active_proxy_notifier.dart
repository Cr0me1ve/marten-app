import 'dart:async';

import 'package:dio/dio.dart';
import 'package:marten/core/haptic/haptic_service.dart';
import 'package:marten/core/preferences/general_preferences.dart';
import 'package:marten/core/utils/throttler.dart';
import 'package:marten/features/connection/data/connection_data_providers.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:marten/features/proxy/data/proxy_data_providers.dart';
import 'package:marten/features/proxy/model/ip_info_entity.dart' as oldipinfo;
import 'package:marten/features/proxy/model/proxy_failure.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart';
import 'package:marten/martencore/init_signal.dart';
import 'package:marten/utils/riverpod_utils.dart';
import 'package:marten/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'active_proxy_notifier.g.dart';

@riverpod
class IpInfoNotifier extends _$IpInfoNotifier with AppLogger {
  @override
  Future<oldipinfo.IpInfo> build() async {
    ref.disposeDelay(const Duration(seconds: 20));
    final cancelToken = CancelToken();
    Timer? timer;
    ref.onDispose(() {
      loggy.debug("disposing");
      cancelToken.cancel();
      timer?.cancel();
    });

    ref.listen(serviceRunningProvider, (_, next) => _idle = false);

    final autoCheck = ref.watch(Preferences.autoCheckIp);
    final serviceRunning = await ref.watch(serviceRunningProvider.future);
    // loggy.debug(
    //   "idle? [$_idle], forced? [$_forceCheck], connected? [$serviceRunning]",
    // );
    if (!_forceCheck && !serviceRunning) {
      throw const ServiceNotRunning();
    } else if ((_idle && !_forceCheck) || (!_forceCheck && serviceRunning && !autoCheck)) {
      throw const UnknownIp();
    }

    _forceCheck = false;
    final info = await ref.watch(proxyRepositoryProvider).getCurrentIpInfo(cancelToken).getOrElse((err) {
      loggy.warning("error getting proxy ip info", err, StackTrace.current);
      // throw err;
      throw const UnknownIp();
    }).run();

    timer = Timer(const Duration(seconds: 10), () {
      loggy.debug("entering idle mode");
      _idle = true;
      ref.invalidateSelf();
    });

    return info;
  }

  bool _idle = false;
  bool _forceCheck = false;

  Future<void> refresh() async {
    if (state.isLoading) return;
    loggy.debug("refreshing");
    state = const AsyncLoading();
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    _forceCheck = true;
    ref.invalidateSelf();
  }
}

@Riverpod(keepAlive: true)
class ActiveProxyNotifier extends _$ActiveProxyNotifier with AppLogger {
  @override
  Stream<OutboundInfo> build() async* {
    // ref.disposeDelay(const Duration(seconds: 20));
    ref.watch(coreRestartSignalProvider);
    final serviceRunning = await ref.watch(serviceRunningProvider.future);
    if (!serviceRunning) {
      throw const ServiceNotRunning();
    }
    final proxyprovider = ref.watch(proxyRepositoryProvider);
    yield* proxyprovider
        .watchActiveProxies()
        .map((event) => event.getOrElse((l) => List<OutboundGroup>.empty()))
        .map((event) => event.firstOrNull?.items.first ?? OutboundInfo());
  }

  final _urlTestThrottler = Throttler(const Duration(seconds: 1));

  Future<void> urlTest(String? groupTag_) async {
    final groupTag = groupTag_ ?? "";
    _urlTestThrottler(() async {
      if (state case AsyncData()) {
        await ref.read(hapticServiceProvider.notifier).lightImpact();
        final localTargets = await _connectedRoutePingTargets();
        if (localTargets.isNotEmpty) {
          await _pingConnectedRoute(localTargets);
          return;
        }
        await ref.read(proxyRepositoryProvider).urlTest(groupTag).getOrElse((err) {
          loggy.warning("error testing group", err);
          throw err;
        }).run();
      }
    });
  }

  Future<List<LocalOutbound>> _connectedRoutePingTargets() async {
    final connection = ref.read(connectionNotifierProvider).valueOrNull;
    if (connection == null || !connection.isConnected) return const [];
    final active = state.valueOrNull;
    if (active == null || active.tag.isEmpty) return const [];
    final outbounds = await ref.read(localOutboundsProvider.future);
    return connectedRoutePingOutbounds(outbounds, [active.tag]);
  }

  Future<void> _pingConnectedRoute(List<LocalOutbound> targets) async {
    final localPing = ref.read(localPingProvider.notifier)..markPending(targets);
    final result = await ref.read(connectionRepositoryProvider).measureConnectedRouteDelay().run();
    await result.match(
      (failure) {
        loggy.warning('core connected-route ping failed; trying endpoint fallback', failure);
        return localPing.pingAll(targets, mode: LocalPingMode.connectedRoute);
      },
      (delay) {
        localPing.record(targets.first.tag, delay);
        return Future<void>.value();
      },
    );
  }
}
