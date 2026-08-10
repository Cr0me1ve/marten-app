import 'dart:async';

import 'package:dartx/dartx.dart';

import 'package:marten/core/haptic/haptic_service.dart';
import 'package:marten/features/connection/data/connection_data_providers.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:marten/features/profile/notifier/active_profile_notifier.dart';
import 'package:marten/features/proxy/data/proxy_data_providers.dart';
import 'package:marten/features/proxy/model/proxy_failure.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart';
import 'package:marten/martencore/init_signal.dart';
import 'package:marten/utils/riverpod_utils.dart';
import 'package:marten/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'proxies_overview_notifier.g.dart';

@riverpod
class ProxiesOverviewNotifier extends _$ProxiesOverviewNotifier with AppLogger {
  @override
  Stream<OutboundGroup?> build() async* {
    ref.disposeDelay(const Duration(seconds: 15));
    ref.watch(coreRestartSignalProvider);
    final serviceRunning = await ref.watch(serviceRunningProvider.future);
    if (!serviceRunning) {
      throw const ServiceNotRunning();
    }
    yield* ref
        .watch(proxyRepositoryProvider)
        .watchProxies()
        .map(
          (event) => event.getOrElse((err) {
            loggy.warning("error receiving proxies", err);
            throw err;
          }),
        );
  }

  // Future<void> changeProxy(String groupTag, String outboundTag) async {
  //   loggy.debug(
  //     "changing proxy, group: [$groupTag] - outbound: [$outboundTag]",
  //   );
  //   if (state case AsyncData(value: final outbounds)) {
  //     await ref.read(hapticServiceProvider.notifier).lightImpact();
  //     await ref.read(proxyRepositoryProvider).selectProxy(groupTag, outboundTag).getOrElse((err) {
  //       loggy.warning("error selecting outbound", err);
  //       throw err;
  //     }).run();
  //     final outboundg = outbounds.where((e) => e.tag == groupTag).firstOrNull;
  //     if (outboundg != null) {
  //       final newselected = outboundg.items.where((e) => e.tag == outboundTag).firstOrNull;
  //       if (newselected != null) {
  //         newselected.isSelected = true;
  //         outboundg.selected = newselected;
  //       }
  //     }
  //     state = AsyncData(
  //       [...outbounds],
  //     ).copyWithPrevious(state);
  //   }
  // }

  Future<void> changeProxy(String groupTag, String outboundTag) async {
    loggy.debug("changing proxy, group: [$groupTag] - outbound: [$outboundTag]");
    final connection = ref.read(connectionNotifierProvider).valueOrNull ?? const Disconnected();
    if (connection is! Disconnected) {
      loggy.info("proxy change ignored while connection is active");
      return;
    }
    if (!state.hasValue) return;
    final outbounds = state.value!;
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    await ref.read(proxyRepositoryProvider).selectProxy(groupTag, outboundTag).getOrElse((err) {
      loggy.warning("error selecting outbound", err);
      throw err;
    }).run();
    final activeProfile = ref.read(activeProfileProvider).valueOrNull;
    if (activeProfile != null) {
      final tags = outbounds.items.map((item) => item.tag).toList(growable: false);
      await ref
          .read(selectedProxyByProfileProvider.notifier)
          .select(activeProfile.id, outboundTag, availableTags: tags);
    }
    final newselected = outbounds.items.where((e) => e.tag == outboundTag).firstOrNull;
    if (newselected != null) {
      newselected.isSelected = true;
      outbounds.selected = newselected;
      state = AsyncValue.data(outbounds);
    }
  }

  Future<void> urlTest(String groupTag) async {
    loggy.debug("testing group: [$groupTag]");
    if (state case AsyncData()) {
      await ref.read(hapticServiceProvider.notifier).lightImpact();
      final localTargets = await _connectedRoutePingTargets();
      if (localTargets.isNotEmpty) {
        await _pingConnectedRoute(localTargets);
        return;
      }
      await ref.read(proxyRepositoryProvider).urlTest(groupTag).getOrElse((err) {
        loggy.error("error testing group", err);
        throw err;
      }).run();
    }
  }

  Future<List<LocalOutbound>> _connectedRoutePingTargets() async {
    final connection = ref.read(connectionNotifierProvider).valueOrNull ?? const Disconnected();
    if (connection is! Connected) return const [];
    final group = state.valueOrNull;
    if (group == null) return const [];
    final outbounds = await ref.read(localOutboundsProvider.future);
    return connectedRoutePingOutbounds(outbounds, [group.selected.tag]);
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
