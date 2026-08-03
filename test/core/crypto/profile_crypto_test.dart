import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/crypto/profile_crypto.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('marten-profile-crypto-test-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('encryptContentToFile promotes only encrypted content', () async {
    final file = File('${directory.path}/profile.json');
    const plaintext = '{"outbounds":[{"type":"vless","uuid":"secret"}]}';

    await ProfileCrypto.encryptContentToFile(file, plaintext, 'client-secret');

    final stored = await file.readAsString();
    expect(ProfileCrypto.isEncrypted(stored), isTrue);
    expect(stored, isNot(contains('uuid')));
    expect(await ProfileCrypto.decrypt(stored, 'client-secret'), plaintext);
    expect(directory.listSync().whereType<File>().where((entry) => entry.path.contains('.encrypted-')), isEmpty);
  });

  test('replaces an existing encrypted profile without leaving backup files', () async {
    final file = File('${directory.path}/profile.json');
    await ProfileCrypto.encryptContentToFile(file, '{"version":1}', 'client-secret');

    await ProfileCrypto.encryptContentToFile(file, '{"version":2}', 'client-secret');

    expect(await ProfileCrypto.decryptFile(file, 'client-secret'), '{"version":2}');
    expect(directory.listSync().whereType<File>().map((entry) => entry.path), [file.path]);
  });

  test('decryptFile retries a transient missing encrypted file', () async {
    final file = File('${directory.path}/profile.json');
    const plaintext = '{"outbounds":[{"tag":"transient"}]}';
    final ciphertext = await ProfileCrypto.encrypt(plaintext, 'client-secret');
    final replacement = Future<void>.delayed(
      const Duration(milliseconds: 30),
      () => file.writeAsString(ciphertext, flush: true),
    );

    final decrypted = await ProfileCrypto.decryptFile(file, 'client-secret');
    await replacement;

    expect(decrypted, plaintext);
  });

  test('decryptToTemp retries a transient missing encrypted file', () async {
    final encryptedFile = File('${directory.path}/profile.json');
    final tempFile = File('${directory.path}/profile.dec.json');
    const plaintext = '{"outbounds":[{"tag":"temporary"}]}';
    final ciphertext = await ProfileCrypto.encrypt(plaintext, 'client-secret');
    final replacement = Future<void>.delayed(
      const Duration(milliseconds: 30),
      () => encryptedFile.writeAsString(ciphertext, flush: true),
    );

    final decrypted = await ProfileCrypto.decryptToTemp(encryptedFile, tempFile, 'client-secret');
    await replacement;

    expect(decrypted, tempFile);
    expect(await tempFile.readAsString(), plaintext);
  });

  test('decryptFile keeps a permanently missing encrypted file fail-closed', () async {
    final missing = File('${directory.path}/missing-profile.json');

    await expectLater(
      () => ProfileCrypto.decryptFile(missing, 'client-secret'),
      throwsA(
        isA<FileSystemException>().having(ProfileCrypto.isMissingFileError, 'missing-file classification', isTrue),
      ),
    );
    expect(await missing.exists(), isFalse);
  });
}
