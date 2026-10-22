import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// A storage-wide write lease shared by foreground and headless engines.
///
/// A Dart mutex is isolate-local, and POSIX file locks are process-owned. A
/// SQLite writer lease covers both independent isolates and independent
/// processes, including rollback after the profile DB transaction returns.
/// Network requests and native validation must finish before entering it.
class ProfileMutationCoordinator {
  ProfileMutationCoordinator(this.directory);

  final Directory directory;

  Future<T> run<T>(Future<T> Function() action) async {
    await directory.create(recursive: true);
    final database = _MutationDatabase(File('${directory.path}/.mutations.sqlite'));
    try {
      return await database.transaction(() async {
        // Acquire the writer reservation before reading any profile/file state.
        await database.customUpdate('UPDATE mutation_lock SET value = value WHERE id = 1');
        return action();
      });
    } finally {
      await database.close();
    }
  }
}

class _MutationDatabase extends GeneratedDatabase {
  _MutationDatabase(File file)
    : super(
        NativeDatabase.createInBackground(
          file,
          setup: (database) {
            // Waiting runs on the DB worker. A rejected lease cannot mutate storage.
            database.execute('PRAGMA busy_timeout = 5000');
          },
        ),
      );

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await customStatement(
        'CREATE TABLE IF NOT EXISTS mutation_lock (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)',
      );
      await customStatement('INSERT OR IGNORE INTO mutation_lock VALUES (1, 0)');
    },
  );
}
