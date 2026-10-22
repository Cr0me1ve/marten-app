import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/stats/data/stats_data_providers.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:marten/utils/riverpod_utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'stats_notifier.g.dart';

@riverpod
class StatsNotifier extends _$StatsNotifier with WidgetsBindingObserver, AppLogger {
  bool _presentationVisible = true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = _canPresentStats(state);
    if (_presentationVisible == visible) return;
    _presentationVisible = visible;
    // Rebuild cancels the current stream even while the sidebar stays mounted
    // or its provider is retained by the short disposal cache.
    ref.invalidateSelf();
  }

  @override
  Stream<SystemInfo> build() async* {
    var disposed = false;
    ref.onDispose(() => disposed = true);
    ref.disposeDelay(const Duration(seconds: 10));

    final requiresVisibleApp = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (requiresVisibleApp) {
      final binding = WidgetsBinding.instance;
      _presentationVisible = _canPresentStats(binding.lifecycleState);
      binding.addObserver(this);
      ref.onDispose(() => binding.removeObserver(this));
      if (!_presentationVisible) {
        yield SystemInfo.create();
        return;
      }
    }

    final serviceRunning = await ref.watch(serviceRunningProvider.future);
    // A pending service snapshot may complete after pause or provider disposal.
    if (disposed || (requiresVisibleApp && !_presentationVisible)) return;
    if (serviceRunning) {
      yield* ref
          .watch(statsRepositoryProvider)
          .watchStats()
          .map((event) => event.getOrElse((_) => SystemInfo.create()));
    } else {
      yield* Stream.value(SystemInfo.create());
    }
  }
}

bool _canPresentStats(AppLifecycleState? state) =>
    state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
