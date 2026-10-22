import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/stats/data/stats_data_providers.dart';
import 'package:marten/features/stats/data/stats_repository.dart';
import 'package:marten/features/stats/model/stats_failure.dart';
import 'package:marten/features/stats/notifier/stats_notifier.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _sendLifecycle(AppLifecycleState.resumed);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('Android hidden, paused, and detached cancel while mounted and resume once', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final repository = _ControlledStatsRepository();
    final context = _createContext(repository: repository, serviceRunning: Future.value(true));
    addTearDown(() => _disposeContext(context));

    for (final backgroundState in <AppLifecycleState>[
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      await _settle();
      expect(repository.activeSubscriptions, 1);
      final previousWatchCalls = repository.watchCalls;

      _sendLifecycle(backgroundState);
      await _settle();
      expect(repository.activeSubscriptions, 0, reason: '$backgroundState must cancel with its consumer mounted');
      expect(repository.cancelledSubscriptions, previousWatchCalls);

      _sendLifecycle(AppLifecycleState.resumed);
      await _settle();
      expect(repository.activeSubscriptions, 1);
      expect(repository.watchCalls, previousWatchCalls + 1);
    }

    // Repeating a pause/resume cycle must never leave a stale live stream.
    for (var cycle = 0; cycle < 3; cycle++) {
      _sendLifecycle(AppLifecycleState.paused);
      await _settle();
      expect(repository.activeSubscriptions, 0);
      _sendLifecycle(AppLifecycleState.resumed);
      await _settle();
      expect(repository.activeSubscriptions, 1);
      expect(repository.watchCalls, repository.cancelledSubscriptions + 1);
    }
    expect(repository.activeSubscriptions, 1, reason: 'the mounted consumer has exactly one active stats stream');
    expect(repository.maximumActiveSubscriptions, 1);
  });

  test('stats samples flow after resume and canceled streams cannot overwrite paused state', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final repository = _ControlledStatsRepository();
    final context = _createContext(repository: repository, serviceRunning: Future.value(true));
    addTearDown(() => _disposeContext(context));
    await _settle();

    repository.emit(0, SystemInfo(connectionsIn: 17));
    await _settle();
    expect(context.latestValue?.connectionsIn, 17);

    final cancelledController = repository.controllerAt(0);
    _sendLifecycle(AppLifecycleState.paused);
    await _settle();
    expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.paused);
    expect(repository.activeSubscriptions, 0);
    expect(context.latestValue?.connectionsIn, 0, reason: 'background invalidation publishes empty stats');

    cancelledController.add(right<StatsFailure, SystemInfo>(SystemInfo(connectionsIn: 29)));
    await _settle();
    expect(context.latestValue?.connectionsIn, 0, reason: 'a canceled stream cannot replace paused stats');

    _sendLifecycle(AppLifecycleState.resumed);
    await _settle();
    expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.resumed);
    expect(repository.watchCalls, 2);
    expect(repository.activeSubscriptions, 1);
    repository.emit(1, SystemInfo(connectionsIn: 43));
    await _settle();
    expect(context.latestValue?.connectionsIn, 43);
    expect(repository.maximumActiveSubscriptions, 1);
  });

  test('Android inactive and notification shade transitions retain the subscription', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final repository = _ControlledStatsRepository();
    final context = _createContext(repository: repository, serviceRunning: Future.value(true));
    addTearDown(() => _disposeContext(context));
    await _settle();

    _sendLifecycle(AppLifecycleState.inactive);
    await _settle();
    expect(repository.activeSubscriptions, 1);
    _sendLifecycle(AppLifecycleState.resumed);
    await _settle();
    expect(repository.watchCalls, 1);
    expect(repository.cancelledSubscriptions, 0);

    // Notification shade interaction may repeat inactive without entering background.
    _sendLifecycle(AppLifecycleState.inactive);
    _sendLifecycle(AppLifecycleState.inactive);
    await _settle();
    expect(repository.activeSubscriptions, 1);
    expect(repository.watchCalls, 1);
    expect(repository.cancelledSubscriptions, 0);
  });

  test('Android provider created while initially paused waits until resume', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    _sendLifecycle(AppLifecycleState.paused);
    final repository = _ControlledStatsRepository();
    final context = _createContext(repository: repository, serviceRunning: Future.value(true));
    addTearDown(() => _disposeContext(context));
    await _settle();

    expect(repository.watchCalls, 0);
    expect(repository.activeSubscriptions, 0);

    _sendLifecycle(AppLifecycleState.resumed);
    await _settle();
    expect(repository.watchCalls, 1);
    expect(repository.activeSubscriptions, 1);
  });

  test('Android pause before service status resolves prevents a late subscription', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final serviceRunning = Completer<bool>();
    final repository = _ControlledStatsRepository();
    final context = _createContext(repository: repository, serviceRunning: serviceRunning.future);
    addTearDown(() => _disposeContext(context));
    await _settle();

    _sendLifecycle(AppLifecycleState.paused);
    serviceRunning.complete(true);
    await _settle();
    expect(repository.watchCalls, 0, reason: 'a result arriving after pause must not attach a stale stream');
    expect(repository.activeSubscriptions, 0);

    _sendLifecycle(AppLifecycleState.resumed);
    await _settle();
    expect(repository.watchCalls, 1, reason: 'resume should create exactly one fresh subscription');
    expect(repository.activeSubscriptions, 1);
  });

  test('non-Android desktop keeps the existing stats subscription in background', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final repository = _ControlledStatsRepository();
    final context = _createContext(repository: repository, serviceRunning: Future.value(true));
    addTearDown(() => _disposeContext(context));
    await _settle();

    _sendLifecycle(AppLifecycleState.paused);
    await _settle();
    expect(repository.activeSubscriptions, 1);
    expect(repository.watchCalls, 1);
    expect(repository.cancelledSubscriptions, 0);
  });

  test('disconnected service publishes empty stats without watching the repository', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final repository = _ControlledStatsRepository();
    final context = _createContext(repository: repository, serviceRunning: Future.value(false));
    addTearDown(() => _disposeContext(context));
    await _settle();

    expect(repository.watchCalls, 0);
    expect(repository.activeSubscriptions, 0);
    expect(context.latestValue, isNotNull);
  });
}

_StatsTestContext _createContext({
  required _ControlledStatsRepository repository,
  required Future<bool> serviceRunning,
}) {
  final container = ProviderContainer(
    overrides: [
      serviceRunningProvider.overrideWith((ref) => serviceRunning),
      statsRepositoryProvider.overrideWith((ref) => repository),
    ],
  );
  SystemInfo? latestValue;
  final subscription = container.listen<AsyncValue<SystemInfo>>(statsNotifierProvider, (_, next) {
    if (next case AsyncData<SystemInfo>(:final value)) latestValue = value;
  }, fireImmediately: true);
  return _StatsTestContext(container, subscription, repository, () => latestValue);
}

Future<void> _disposeContext(_StatsTestContext context) async {
  context.subscription.close();
  context.container.dispose();
}

final class _StatsTestContext {
  const _StatsTestContext(this.container, this.subscription, this.repository, this._latestValue);

  final ProviderContainer container;
  final ProviderSubscription<AsyncValue<SystemInfo>> subscription;
  final _ControlledStatsRepository repository;
  final SystemInfo? Function() _latestValue;

  SystemInfo? get latestValue => _latestValue();
}

void _sendLifecycle(AppLifecycleState state) {
  WidgetsBinding.instance.handleAppLifecycleStateChanged(state);
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _ControlledStatsRepository implements StatsRepository {
  int watchCalls = 0;
  int activeSubscriptions = 0;
  int cancelledSubscriptions = 0;
  int maximumActiveSubscriptions = 0;
  final List<StreamController<Either<StatsFailure, SystemInfo>>> _controllers = [];

  StreamController<Either<StatsFailure, SystemInfo>> controllerAt(int index) => _controllers[index];

  void emit(int index, SystemInfo sample) {
    _controllers[index].add(right<StatsFailure, SystemInfo>(sample));
  }

  @override
  Stream<Either<StatsFailure, SystemInfo>> watchStats() {
    watchCalls++;
    late final StreamController<Either<StatsFailure, SystemInfo>> controller;
    controller = StreamController<Either<StatsFailure, SystemInfo>>(
      onListen: () {
        activeSubscriptions++;
        if (activeSubscriptions > maximumActiveSubscriptions) {
          maximumActiveSubscriptions = activeSubscriptions;
        }
      },
      onCancel: () {
        activeSubscriptions--;
        cancelledSubscriptions++;
      },
    );
    _controllers.add(controller);
    return controller.stream;
  }
}
