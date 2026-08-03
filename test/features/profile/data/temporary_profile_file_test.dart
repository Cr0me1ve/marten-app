import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:marten/features/profile/data/temporary_profile_file.dart';
import 'package:marten/features/profile/model/profile_failure.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('marten-profile-temp-test-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('keeps the temporary file for the complete lazy task lifetime', () async {
    final file = File('${directory.path}/profile.tmp');
    await file.writeAsString('candidate');
    var entered = false;
    final task = withTemporaryProfileFile(
      file,
      () => TaskEither<ProfileFailure, Unit>.tryCatch(() async {
        entered = true;
        expect(await file.exists(), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(await file.readAsString(), 'candidate');
        return unit;
      }, ProfileFailure.unexpected),
    );

    expect(entered, isFalse);
    expect(await file.exists(), isTrue);

    final result = await task.run();

    expect(result.isRight(), isTrue);
    expect(entered, isTrue);
    expect(await file.exists(), isFalse);
  });

  test('removes the temporary file after a nested Left result', () async {
    final file = File('${directory.path}/profile.tmp');
    await file.writeAsString('candidate');
    final task = withTemporaryProfileFile<Unit>(
      file,
      () => TaskEither.left(const ProfileFailure.invalidConfig('invalid candidate')),
    );

    final result = await task.run();

    expect(result.isLeft(), isTrue);
    expect(await file.exists(), isFalse);
  });
}
