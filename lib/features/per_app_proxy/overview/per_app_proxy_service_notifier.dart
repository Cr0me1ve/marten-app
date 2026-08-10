import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:installed_apps/index.dart';
import 'package:marten/core/preferences/general_preferences.dart';
import 'package:marten/features/per_app_proxy/data/selected_data_provider.dart';
import 'package:marten/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'per_app_proxy_service_notifier.g.dart';

@riverpod
class PerAppProxyService extends _$PerAppProxyService {
  static const initialStartupDelay = Duration(seconds: 60);

  StreamSubscription? _includeSubscription;
  StreamSubscription? _excludeSubscription;
  Timer? _timer;

  @override
  Future<void> build() async {
    var disposed = false;
    ref.onDispose(() {
      disposed = true;
      _includeSubscription?.cancel();
      _excludeSubscription?.cancel();
      _timer?.cancel();
    });

    await Future<void>.delayed(initialStartupDelay);
    if (disposed) return;
    await SchedulerBinding.instance.scheduleTask<void>(() {}, Priority.idle, debugLabel: 'installed apps maintenance');
    if (disposed) return;

    final phonePkgs = (await InstalledApps.getInstalledApps(false)).map((e) => e.packageName).toSet();
    if (disposed) return;

    _includeSubscription = ref
        .read(appProxyDataSourceProvider)
        .watchActivePackages(phonePkgs: phonePkgs, mode: AppProxyMode.include)
        .listen((pkgs) => ref.read(Preferences.includeApps.notifier).update(pkgs));
    _excludeSubscription = ref
        .read(appProxyDataSourceProvider)
        .watchActivePackages(phonePkgs: phonePkgs, mode: AppProxyMode.exclude)
        .listen((pkgs) => ref.read(Preferences.excludeApps.notifier).update(pkgs));

    _timer = Timer.periodic(const Duration(days: 1), (_) async => await _autoSelectionUpdate());
    await _autoSelectionUpdate();
  }

  Future<void> _autoSelectionUpdate() async {
    final autoRegion = ref.read(Preferences.autoAppsSelectionRegion);
    if (autoRegion != null) {
      await ref.read(Preferences.autoAppsSelectionRegion.notifier).update(null);
      await ref.read(Preferences.autoAppsSelectionLastUpdate.notifier).update(null);
    }
  }
}
