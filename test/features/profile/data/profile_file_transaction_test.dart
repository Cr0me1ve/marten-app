import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:marten/features/profile/data/profile_file_transaction.dart';
import 'package:marten/features/profile/model/profile_failure.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('marten-profile-transaction-test-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('restores the previous encrypted file when a later step returns Left', () async {
    final file = File('${directory.path}/profile.json');
    await file.writeAsString('MARTEN_ENC_V1:old');
    final task = withProfileFileRollback<Unit>(
      file,
      () => TaskEither.tryCatch(() async {
        await file.writeAsString('MARTEN_ENC_V1:new');
        throw const ProfileFailure.unexpected('db failed');
      }, (error, stackTrace) => error is ProfileFailure ? error : ProfileFailure.unexpected(error, stackTrace)),
    );

    final result = await task.run();

    expect(result.isLeft(), isTrue);
    expect(await file.readAsString(), 'MARTEN_ENC_V1:old');
    expect(directory.listSync().whereType<File>().map((entry) => entry.path), [file.path]);
  });

  test('removes a newly-created file when insertion fails', () async {
    final file = File('${directory.path}/profile.json');
    final task = withProfileFileRollback<Unit>(
      file,
      () => TaskEither.tryCatch(() async {
        await file.writeAsString('MARTEN_ENC_V1:new');
        throw StateError('insert failed');
      }, ProfileFailure.unexpected),
    );

    final result = await task.run();

    expect(result.isLeft(), isTrue);
    expect(await file.exists(), isFalse);
  });

  test('keeps the promoted file only after the whole operation succeeds', () async {
    final file = File('${directory.path}/profile.json');
    await file.writeAsString('MARTEN_ENC_V1:old');
    final task = withProfileFileRollback(
      file,
      () => TaskEither<ProfileFailure, Unit>.tryCatch(() async {
        await file.writeAsString('MARTEN_ENC_V1:new');
        return unit;
      }, ProfileFailure.unexpected),
    );

    final result = await task.run();

    expect(result.isRight(), isTrue);
    expect(await file.readAsString(), 'MARTEN_ENC_V1:new');
  });

  test('rollback safely promotes the previous encrypted bytes and cleans transaction files', () async {
    final file = File('${directory.path}/profile.json');
    const previous = 'MARTEN_ENC_V1:previous-ciphertext';
    const replacement = 'MARTEN_ENC_V1:replacement-ciphertext';
    await file.writeAsString(previous, flush: true);

    var keepReading = true;
    var sawMissingPath = false;
    final reader = Future<void>(() async {
      while (keepReading) {
        try {
          await file.readAsString();
        } on FileSystemException catch (error) {
          if (error is PathNotFoundException || error.osError?.errorCode == 2) {
            sawMissingPath = true;
          }
        }
        await Future<void>.delayed(Duration.zero);
      }
    });

    final result = await withProfileFileRollback<Unit>(
      file,
      () => TaskEither.tryCatch(() async {
        await file.writeAsString(replacement, flush: true);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw const ProfileFailure.unexpected('db failed');
      }, (error, stackTrace) => error is ProfileFailure ? error : ProfileFailure.unexpected(error, stackTrace)),
    ).run();
    keepReading = false;
    await reader;

    expect(result.isLeft(), isTrue);
    expect(await file.readAsString(), previous);
    expect(sawMissingPath, isFalse, reason: 'rollback promotion must not expose a missing destination path');
    expect(
      directory.listSync().whereType<File>().map((entry) => entry.path).toList(),
      [file.path],
      reason: 'rollback must clean backup, staged, and displaced encrypted files',
    );
  });
}
