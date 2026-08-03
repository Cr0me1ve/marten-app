import 'dart:io';

import 'package:fpdart/fpdart.dart';
import 'package:marten/features/profile/model/profile_failure.dart';

/// Restores the previous encrypted profile file when a later DB/file step
/// returns Left or throws. Backup files contain only the already-encrypted
/// destination bytes.
TaskEither<ProfileFailure, T> withProfileFileRollback<T>(
  File destination,
  TaskEither<ProfileFailure, T> Function() operation,
) {
  return TaskEither(() async {
    final suffix = '${DateTime.now().microsecondsSinceEpoch}-$pid';
    final backup = File('${destination.path}.rollback-$suffix.bak');
    var hadPrevious = false;
    var backupReady = false;
    var operationStarted = false;
    var committed = false;
    try {
      hadPrevious = await destination.exists();
      if (hadPrevious) {
        await destination.copy(backup.path);
        backupReady = true;
      }
      operationStarted = true;
      final result = await operation().run();
      if (result.isLeft()) {
        await _restoreProfileFile(destination, backup, restoreBackup: backupReady);
      } else {
        committed = true;
      }
      return result;
    } catch (error, stackTrace) {
      if (operationStarted) {
        await _restoreProfileFile(destination, backup, restoreBackup: backupReady);
      }
      return left(ProfileFailure.unexpected(error, stackTrace));
    } finally {
      final destinationSafe = !operationStarted || committed || await destination.exists();
      if (destinationSafe && await backup.exists()) {
        await backup.delete();
      }
    }
  });
}

Future<void> _restoreProfileFile(File destination, File backup, {required bool restoreBackup}) async {
  if (!restoreBackup) {
    if (await destination.exists()) await destination.delete();
    return;
  }
  if (!await backup.exists()) {
    throw FileSystemException('encrypted profile rollback backup is missing', backup.path);
  }

  final suffix = '${DateTime.now().microsecondsSinceEpoch}-$pid';
  final staged = File('${destination.path}.rollback-restore-$suffix.tmp');
  final displaced = File('${destination.path}.rollback-displaced-$suffix.tmp');
  var displacedReady = false;
  try {
    await backup.copy(staged.path);
    try {
      // POSIX/Android promotes this atomically over the current destination,
      // so a concurrent Connect never observes an unlink window.
      await staged.rename(destination.path);
    } on FileSystemException {
      // Some platforms cannot replace an existing file with rename. Preserve
      // the current encrypted value until the staged backup is ready.
      if (await destination.exists()) {
        await destination.rename(displaced.path);
        displacedReady = true;
      }
      try {
        await staged.rename(destination.path);
      } catch (_) {
        if (!await destination.exists() && displacedReady && await displaced.exists()) {
          await displaced.rename(destination.path);
          displacedReady = false;
        }
        rethrow;
      }
    }
  } finally {
    if (await staged.exists()) await staged.delete();
    if (await destination.exists() && displacedReady && await displaced.exists()) {
      await displaced.delete();
    }
  }
}
