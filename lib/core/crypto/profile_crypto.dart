import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class ProfileCrypto {
  static const _header = 'MARTEN_ENC_V1:';
  static const _transientReadAttempts = 5;
  static const _transientReadDelay = Duration(milliseconds: 20);
  static final _algorithm = AesGcm.with256bits();

  static bool isEncrypted(String content) => content.startsWith(_header);

  static Future<SecretKey> _deriveKey(String clientSecret) {
    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(clientSecret)),
      nonce: utf8.encode('marten-profile-storage-v1'),
    );
  }

  static Future<String> encrypt(String plaintext, String clientSecret) async {
    final key = await _deriveKey(clientSecret);
    final secretBox = await _algorithm.encrypt(utf8.encode(plaintext), secretKey: key);
    final nonce = base64Encode(secretBox.nonce);
    final ciphertext = base64Encode(Uint8List.fromList([...secretBox.cipherText, ...secretBox.mac.bytes]));
    return '$_header$nonce:$ciphertext';
  }

  static Future<String> decrypt(String encrypted, String clientSecret) async {
    if (!isEncrypted(encrypted)) return encrypted;
    final payload = encrypted.substring(_header.length);
    final colonIdx = payload.indexOf(':');
    final nonce = base64Decode(payload.substring(0, colonIdx));
    final combined = base64Decode(payload.substring(colonIdx + 1));
    final ciphertext = combined.sublist(0, combined.length - 16);
    final mac = Mac(combined.sublist(combined.length - 16));

    final key = await _deriveKey(clientSecret);
    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: mac);
    final plaintext = await _algorithm.decrypt(secretBox, secretKey: key);
    return utf8.decode(plaintext);
  }

  /// Encrypts before touching [file], then promotes an encrypted sibling.
  /// At no point is plaintext written to the destination path.
  static Future<void> encryptContentToFile(File file, String plaintext, String clientSecret) async {
    final encrypted = await encrypt(plaintext, clientSecret);
    await file.parent.create(recursive: true);
    final suffix = '${DateTime.now().microsecondsSinceEpoch}-$pid';
    final staged = File('${file.path}.encrypted-$suffix.tmp');
    final backup = File('${file.path}.encrypted-$suffix.bak');

    try {
      await staged.writeAsString(encrypted, flush: true);
      try {
        await staged.rename(file.path);
      } on FileSystemException {
        // Windows cannot replace an existing file with rename. Preserve the
        // previous encrypted value until the new encrypted file is promoted.
        if (await file.exists()) {
          await file.rename(backup.path);
        }
        try {
          await staged.rename(file.path);
          if (await backup.exists()) await backup.delete();
        } catch (_) {
          if (!await file.exists() && await backup.exists()) {
            await backup.rename(file.path);
          }
          rethrow;
        }
      }
    } finally {
      if (await staged.exists()) await staged.delete();
      if (await file.exists() && await backup.exists()) await backup.delete();
    }
  }

  static Future<File> decryptToTemp(File encryptedFile, File tempFile, String clientSecret) async {
    final content = await _readEncryptedFile(encryptedFile);
    final plaintext = await decrypt(content, clientSecret);
    await tempFile.writeAsString(plaintext);
    return tempFile;
  }

  static Future<String> decryptFile(File file, String clientSecret) async {
    final content = await _readEncryptedFile(file);
    return decrypt(content, clientSecret);
  }

  /// Profile refresh and rollback can replace an encrypted file from another
  /// isolate. Retry the short rename window, but keep genuinely missing files
  /// fail-closed after a small bounded delay.
  static Future<String> _readEncryptedFile(File file) async {
    for (var attempt = 0; attempt < _transientReadAttempts; attempt++) {
      try {
        return await file.readAsString();
      } on FileSystemException catch (error) {
        if (!isMissingFileError(error) || attempt == _transientReadAttempts - 1) {
          rethrow;
        }
        await Future<void>.delayed(_transientReadDelay);
      }
    }
    throw StateError('unreachable encrypted profile read state');
  }

  static bool isMissingFileError(Object error) {
    if (error is PathNotFoundException) return true;
    if (error is! FileSystemException) return false;
    if (error.osError?.errorCode == 2) return true;
    final message = [error.message, error.osError?.message].whereType<String>().join(' ').toLowerCase();
    return message.contains('no such file') || message.contains('cannot open file');
  }
}
