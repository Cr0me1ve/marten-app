import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/app_info/app_info_provider.dart';
import 'package:marten/core/db/db.dart';
import 'package:marten/core/db/provider/db_providers.dart';
import 'package:marten/core/model/environment.dart';
import 'package:marten/riverpod_observer.dart';

/// Owns every process resource created for one short-lived headless refresh.
///
/// Riverpod's synchronous [ProviderContainer.dispose] cannot await an
/// asynchronous Drift shutdown. Keeping the database ownership outside the
/// container makes the teardown order explicit: cancel provider subscriptions,
/// await SQLite shutdown, and only then let the platform destroy the Flutter
/// engine.
final class BackgroundProfileRefreshScope {
  BackgroundProfileRefreshScope._({required this.container, required Db database}) : _database = database;

  factory BackgroundProfileRefreshScope({Db? database}) {
    final ownedDatabase = database ?? Db();
    return BackgroundProfileRefreshScope._(
      database: ownedDatabase,
      container: ProviderContainer(
        overrides: [
          environmentProvider.overrideWithValue(Environment.prod),
          dbProvider.overrideWithValue(ownedDatabase),
        ],
        observers: [RiverpodObserver()],
      ),
    );
  }

  final ProviderContainer container;
  final Db _database;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      container.dispose();
    } finally {
      await _database.close();
    }
  }
}
