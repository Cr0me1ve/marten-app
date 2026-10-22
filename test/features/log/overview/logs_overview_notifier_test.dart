import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/features/log/data/log_data_providers.dart';
import 'package:marten/features/log/data/log_path_resolver.dart';
import 'package:marten/features/log/data/log_repository.dart';
import 'package:marten/features/log/model/log_entity.dart';
import 'package:marten/features/log/model/log_failure.dart';
import 'package:marten/features/log/overview/logs_overview_notifier.dart';
import 'package:marten/martencore/init_signal.dart';

void main() {
  group('LogsOverviewNotifier._addListeners race', () {
    test('does not crash when log repository future is still loading', () async {
      final completer = Completer<LogRepository>();
      final container = ProviderContainer(overrides: [logRepositoryProvider.overrideWith((_) => completer.future)]);
      addTearDown(container.dispose);

      final uncaughtErrors = <Object?>[];
      await runZonedGuarded(
        () async {
          expect(() => container.read(logsOverviewNotifierProvider), returnsNormally);
          expect(container.read(logsOverviewNotifierProvider).logs, const AsyncLoading<List<LogEntity>>());
          await Future<void>.delayed(const Duration(milliseconds: 20));
        },
        (error, stackTrace) {
          uncaughtErrors.add(error);
        },
      );

      expect(uncaughtErrors, isEmpty);
      expect(completer.isCompleted, isFalse);
    });

    test('attaches listener after repository future resolves and emits logs', () async {
      final repository = _TrackingLogRepository();
      final completer = Completer<LogRepository>();
      final container = ProviderContainer(overrides: [logRepositoryProvider.overrideWith((_) => completer.future)]);
      final logsArrived = Completer<void>();
      addTearDown(() {
        repository.close();
        container.dispose();
      });

      final uncaughtErrors = <Object?>[];
      await runZonedGuarded(
        () async {
          expect(() => container.read(logsOverviewNotifierProvider), returnsNormally);
          expect(container.read(logsOverviewNotifierProvider).logs, const AsyncLoading<List<LogEntity>>());
          final subscription = container.listen(logsOverviewNotifierProvider, (_, next) {
            if (next.logs.asData?.value.any((log) => log.message == 'first line') == true && !logsArrived.isCompleted) {
              logsArrived.complete();
            }
          }, fireImmediately: true);
          addTearDown(subscription.close);

          completer.complete(repository);
          await repository.watchStarted.future.timeout(const Duration(seconds: 3));

          repository.emit([const LogEntity(message: 'first line')]);
          await logsArrived.future.timeout(const Duration(seconds: 3));
        },
        (error, stackTrace) {
          uncaughtErrors.add(error);
        },
      );

      expect(uncaughtErrors, isEmpty);
      expect(repository.watchCalls, 1);
      final state = container.read(logsOverviewNotifierProvider);
      expect(state.logs, isA<AsyncData<List<LogEntity>>>());
      expect((state.logs as AsyncData<List<LogEntity>>).value.single.message, 'first line');
    });

    test('does not attach listener or leak when disposed before repository resolves', () async {
      final repository = _TrackingLogRepository();
      final completer = Completer<LogRepository>();
      final uncaughtErrors = <Object?>[];

      await runZonedGuarded(
        () async {
          final container = ProviderContainer(overrides: [logRepositoryProvider.overrideWith((_) => completer.future)]);
          expect(() => container.read(logsOverviewNotifierProvider), returnsNormally);
          expect(container.read(logsOverviewNotifierProvider).logs, const AsyncLoading<List<LogEntity>>());

          container.dispose();
          completer.complete(repository);
          await Future<void>.delayed(const Duration(milliseconds: 120));
        },
        (error, stackTrace) {
          uncaughtErrors.add(error);
        },
      );

      expect(uncaughtErrors, isEmpty);
      expect(repository.watchCalls, 0);
    });

    test('keeps one watch call when restart happens while repository is still loading', () async {
      final repository = _TrackingLogRepository();
      final completer = Completer<LogRepository>();
      final container = ProviderContainer(overrides: [logRepositoryProvider.overrideWith((_) => completer.future)]);
      final subscription = container.listen(logsOverviewNotifierProvider, (_, _) {}, fireImmediately: true);
      addTearDown(() {
        repository.close();
        subscription.close();
        container.dispose();
      });

      final uncaughtErrors = <Object?>[];
      await runZonedGuarded(
        () async {
          container.read(coreRestartSignalProvider.notifier).restart();
          completer.complete(repository);
          await Future<void>.delayed(const Duration(milliseconds: 120));
        },
        (error, stackTrace) {
          uncaughtErrors.add(error);
        },
      );

      expect(uncaughtErrors, isEmpty);
      expect(repository.watchCalls, 1);
    });

    test('waits for repository before clear and calls clearLogs exactly once', () async {
      final repository = _TrackingLogRepository();
      final completer = Completer<LogRepository>();
      final container = ProviderContainer(overrides: [logRepositoryProvider.overrideWith((_) => completer.future)]);
      addTearDown(() {
        repository.close();
        container.dispose();
      });

      final uncaughtErrors = <Object?>[];
      await runZonedGuarded(
        () async {
          expect(() => container.read(logsOverviewNotifierProvider), returnsNormally);

          final clearResult = container.read(logsOverviewNotifierProvider.notifier).clear();
          await Future<void>.delayed(const Duration(milliseconds: 40));
          expect(repository.clearCalls, 0);

          completer.complete(repository);
          await clearResult;
          expect(repository.clearCalls, 1);
        },
        (error, stackTrace) {
          uncaughtErrors.add(error);
        },
      );

      expect(uncaughtErrors, isEmpty);
    });
  });
}

final class _TrackingLogRepository implements LogRepository {
  _TrackingLogRepository() : _watchLogsController = StreamController<Either<LogFailure, List<LogEntity>>>.broadcast();

  final StreamController<Either<LogFailure, List<LogEntity>>> _watchLogsController;
  final Completer<void> watchStarted = Completer<void>();
  int watchCalls = 0;
  int clearCalls = 0;

  void emit(List<LogEntity> logs) {
    _watchLogsController.add(right(logs));
  }

  void close() {
    _watchLogsController.close();
  }

  @override
  TaskEither<LogFailure, Unit> init() => TaskEither.right(unit);

  @override
  Stream<Either<LogFailure, List<LogEntity>>> watchLogs() {
    watchCalls++;
    if (!watchStarted.isCompleted) watchStarted.complete();
    return _watchLogsController.stream;
  }

  @override
  TaskEither<LogFailure, Unit> clearLogs() {
    clearCalls++;
    return TaskEither.right(unit);
  }

  @override
  Future<File> prepareShareFile(LogExportMetadata metadata) {
    throw UnimplementedError();
  }
}
