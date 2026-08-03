import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/crypto/subscription_envelope.dart';

void main() {
  test('decrypts server HKDF-SHA256+A256GCM envelope', () async {
    const envelope = '''
{
  "version": 1,
  "alg": "HKDF-SHA256+A256GCM",
  "key_id": "cred-a",
  "nonce": "ABEiM0RVZneImaq7",
  "ciphertext": "0a2Qtr4ajhzhFl-iGLB5f3ibVOAuYE1iMYMAO2b5CME",
  "aad": "eyJ2ZXJzaW9uIjoxLCJkZXZpY2VfaWQiOiJkZXZpY2UtYSIsImNyZWRlbnRpYWxfaWQiOiJjcmVkLWEifQ"
}
''';

    final plaintext = await SubscriptionEnvelope.decrypt(envelope, 'server-secret', 'client-secret');

    expect(plaintext, equals('{"outbounds":[]}'));
  });
}
