import 'dart:io';

import 'package:fpdart/fpdart.dart';
import 'package:marten/features/profile/model/profile_failure.dart';

/// Owns a temporary profile file for the full lifetime of a lazy
/// [TaskEither]. The file is removed only after the nested task has completed.
TaskEither<ProfileFailure, T> withTemporaryProfileFile<T>(
  File file,
  TaskEither<ProfileFailure, T> Function() operation,
) {
  return TaskEither(() async {
    try {
      return await operation().run();
    } catch (error, stackTrace) {
      return left(ProfileFailure.unexpected(error, stackTrace));
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }
  });
}
