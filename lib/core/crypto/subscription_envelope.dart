import 'dart:convert';

import 'package:cryptography/cryptography.dart';

class SubscriptionEnvelope {
  static bool isEnvelope(String content) {
    try {
      final json = jsonDecode(content);
      if (json is! Map<String, dynamic>) return false;
      return json.containsKey('version') &&
          json.containsKey('alg') &&
          json.containsKey('nonce') &&
          json.containsKey('ciphertext');
    } catch (_) {
      return false;
    }
  }

  static Future<String> decrypt(String envelopeJson, String deviceSecret, String clientSecret) async {
    final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;
    final version = envelope['version'] as int;
    if (version != 1) {
      throw UnsupportedError('Unsupported envelope version: $version');
    }

    final alg = envelope['alg'] as String;
    return switch (alg) {
      'aes-256-gcm' => _decryptLegacy(envelope, deviceSecret, clientSecret),
      'HKDF-SHA256+A256GCM' => _decryptServerEnvelope(envelope, deviceSecret, clientSecret),
      _ => throw UnsupportedError('Unsupported algorithm: $alg'),
    };
  }

  static Future<String> _decryptLegacy(Map<String, dynamic> envelope, String deviceSecret, String clientSecret) async {
    final nonce = base64Decode(envelope['nonce'] as String);
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    final aad = envelope['aad'] != null ? utf8.encode(jsonEncode(envelope['aad'])) : <int>[];

    final key = await _deriveLegacyKey(deviceSecret, clientSecret);

    return _decryptAesGcm(ciphertext: ciphertext, nonce: nonce, aad: aad, key: key);
  }

  static Future<String> _decryptServerEnvelope(
    Map<String, dynamic> envelope,
    String deviceSecret,
    String clientSecret,
  ) async {
    if (deviceSecret.isEmpty || clientSecret.isEmpty) {
      throw ArgumentError('deviceSecret and clientSecret are required for encrypted subscription envelope');
    }
    final credentialId = envelope['key_id'] as String? ?? '';
    if (credentialId.isEmpty) {
      throw ArgumentError('encrypted subscription envelope is missing key_id');
    }

    final nonce = _decodeRawBase64Url(envelope['nonce'] as String);
    final ciphertext = _decodeRawBase64Url(envelope['ciphertext'] as String);
    final aad = envelope['aad'] != null ? _decodeRawBase64Url(envelope['aad'] as String) : <int>[];

    final key = await _deriveServerKey(
      credentialId: credentialId,
      deviceSecret: deviceSecret,
      clientSecret: clientSecret,
    );

    return _decryptAesGcm(ciphertext: ciphertext, nonce: nonce, aad: aad, key: key);
  }

  static Future<String> _decryptAesGcm({
    required List<int> ciphertext,
    required List<int> nonce,
    required List<int> aad,
    required SecretKey key,
  }) async {
    final algorithm = AesGcm.with256bits();
    final secretBox = SecretBox(
      ciphertext.sublist(0, ciphertext.length - 16),
      nonce: nonce,
      mac: Mac(ciphertext.sublist(ciphertext.length - 16)),
    );

    final plaintext = await algorithm.decrypt(secretBox, secretKey: key, aad: aad);
    return utf8.decode(plaintext);
  }

  static Future<SecretKey> _deriveLegacyKey(String deviceSecret, String clientSecret) async {
    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
    final ikm = utf8.encode('$deviceSecret:$clientSecret');
    return hkdf.deriveKey(secretKey: SecretKey(ikm), nonce: utf8.encode('marten-subscription-envelope-v1'));
  }

  static Future<SecretKey> _deriveServerKey({
    required String credentialId,
    required String deviceSecret,
    required String clientSecret,
  }) async {
    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
    final ikm = utf8.encode('$deviceSecret\x00$clientSecret');
    return hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: utf8.encode('marten-subscription-envelope-v1'),
      info: utf8.encode(credentialId),
    );
  }

  static List<int> _decodeRawBase64Url(String value) {
    return base64Url.decode(base64Url.normalize(value));
  }
}
