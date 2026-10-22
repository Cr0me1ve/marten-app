import 'dart:async';

import 'package:marten/features/log/data/log_data_providers.dart';
import 'package:marten/features/log/model/log_entity.dart';
import 'package:marten/features/log/model/log_level.dart';
import 'package:marten/features/log/overview/logs_overview_state.dart';
import 'package:marten/martencore/init_signal.dart';
import 'package:marten/utils/riverpod_utils.dart';
import 'package:marten/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';

part 'logs_overview_notifier.g.dart';

@riverpod
class LogsOverviewNotifier extends _$LogsOverviewNotifier with AppLogger {
  @override
  LogsOverviewState build() {
    final generation = ++_listenerGeneration;
    ref.watch(coreRestartSignalProvider);
    ref.disposeDelay(const Duration(seconds: 20));
    state = const LogsOverviewState();
    ref.onDispose(() {
      if (!_isCurrent(generation)) return;
      _listenerGeneration++;
      loggy.debug("disposing");
      final listener = _listener;
      _listener = null;
      if (listener != null) unawaited(listener.cancel());
    });
    ref.onCancel(() {
      if (!_isCurrent(generation)) return;
      if (_listener?.isPaused != true) {
        loggy.debug("pausing");
        _listener?.pause();
      }
    });
    ref.onResume(() {
      if (!_isCurrent(generation)) return;
      if (!state.paused && (_listener?.isPaused ?? false)) {
        loggy.debug("resuming");
        _listener?.resume();
      }
    });

    unawaited(_addListeners(generation));
    return const LogsOverviewState();
  }

  StreamSubscription? _listener;
  int _listenerGeneration = 0;

  bool _isCurrent(int generation) => generation == _listenerGeneration;

  Future<void> _addListeners(int generation) async {
    loggy.debug("adding listeners");
    // Capture the provider future before the first await. Reading ref after the
    // notifier has been disposed is invalid, and the logs page can be restored
    // while the deferred repository initialization is still in flight.
    final repositoryFuture = ref.read(logRepositoryProvider.future);
    try {
      final previousListener = _listener;
      _listener = null;
      await previousListener?.cancel();

      final repository = await repositoryFuture;
      if (!_isCurrent(generation)) return;

      final listener = repository
          .watchLogs()
          .throttle((_) => const Stream<void>.empty(), leading: false, trailing: true)
          .throttleTime(const Duration(milliseconds: 250), leading: false, trailing: true)
          .asyncMap((event) async {
            if (!_isCurrent(generation)) return;
            await event.fold<Future<void>>(
              (f) => Future<void>.sync(() {
                if (!_isCurrent(generation)) return;
                _logs = [];
                state = state.copyWith(logs: AsyncError(f, StackTrace.current));
              }),
              (a) async {
                if (!_isCurrent(generation)) return;
                _logs = a.reversed;
                final logs = await _computeLogs();
                if (!_isCurrent(generation)) return;
                state = state.copyWith(logs: AsyncData(logs));
              },
            );
          })
          .listen((event) {});
      if (!_isCurrent(generation)) {
        await listener.cancel();
        return;
      }
      _listener = listener;
    } catch (error, stackTrace) {
      if (!_isCurrent(generation)) return;
      loggy.warning("error adding log listeners", error, stackTrace);
      state = state.copyWith(logs: AsyncError(error, stackTrace));
    }
  }

  Iterable<LogEntity> _logs = [];
  final _debouncer = CallbackDebouncer(const Duration(milliseconds: 200));
  LogLevel? _levelFilter;
  String _filter = "";

  Future<List<LogEntity>> _computeLogs() async {
    if (_levelFilter == null && _filter.isEmpty) return _logs.toList();
    return _logs.where((e) {
      return (_filter.isEmpty || e.message.contains(_filter)) &&
          (_levelFilter == null || e.level == null || e.level!.index >= _levelFilter!.index);
    }).toList();
  }

  void pause() {
    loggy.debug("pausing");
    _listener?.pause();
    state = state.copyWith(paused: true);
  }

  void resume() {
    loggy.debug("resuming");
    _listener?.resume();
    state = state.copyWith(paused: false);
  }

  Future<void> clear() async {
    loggy.debug("clearing");
    final generation = _listenerGeneration;
    try {
      final repositoryFuture = ref.read(logRepositoryProvider.future);
      final repository = await repositoryFuture;
      if (!_isCurrent(generation)) return;
      final result = await repository.clearLogs().run();
      if (!_isCurrent(generation)) return;
      result.match(
        (l) {
          loggy.warning("error clearing logs", l);
        },
        (_) {
          _logs = [];
          state = state.copyWith(logs: const AsyncData([]));
        },
      );
    } catch (error, stackTrace) {
      if (!_isCurrent(generation)) return;
      loggy.warning("error clearing logs", error, stackTrace);
      state = state.copyWith(logs: AsyncError(error, stackTrace));
    }
  }

  void filterMessage(String? filter) {
    _filter = filter ?? '';
    _debouncer(() async {
      if (state.logs case AsyncData()) {
        state = state.copyWith(filter: _filter, logs: AsyncData(await _computeLogs()));
      }
    });
  }

  Future<void> filterLevel(LogLevel? level) async {
    _levelFilter = level;
    if (state.logs case AsyncData()) {
      state = state.copyWith(levelFilter: _levelFilter, logs: AsyncData(await _computeLogs()));
    }
  }
}
