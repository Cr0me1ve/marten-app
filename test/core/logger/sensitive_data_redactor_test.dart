import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';

void main() {
  group('SensitiveDataRedactor', () {
    test('removes URL path, user info, query and fragment', () {
      final redacted = SensitiveDataRedactor.redact(
        'download https://user:pass@edge.example:8443/sub/private-token?device=secret#fragment',
      );

      expect(redacted, 'download https://[redacted-host]/[redacted]');
      expect(redacted, isNot(contains('private-token')));
      expect(redacted, isNot(contains('user:pass')));
    });

    test('removes deep links, opaque TURNcoat links and named credentials', () {
      final redacted = SensitiveDataRedactor.redact(
        'marten://import?url=https%3A%2F%2Fedge.example%2Fsub%2Ftoken '
        'turncoat://opaque-payload authorization=Bearer-secret X-Client-Secret: abc123',
      );

      expect(redacted, contains('marten://[redacted-host]/[redacted]'));
      expect(redacted, contains('turncoat://[redacted]'));
      expect(redacted, isNot(contains('opaque-payload')));
      expect(redacted, isNot(contains('Bearer-secret')));
      expect(redacted, isNot(contains('abc123')));
    });

    test('removes UUIDs and user package names', () {
      final redacted = SensitiveDataRedactor.redact(
        'uuid=550e8400-e29b-41d4-a716-446655440000 packageName=com.example.privateapp',
      );

      expect(redacted, isNot(contains('550e8400')));
      expect(redacted, isNot(contains('com.example.privateapp')));
      expect(redacted, contains('uuid=[redacted]'));
      expect(redacted, contains('packageName=[redacted]'));
    });

    test('removes proxy links and user home directory names', () {
      final redacted = SensitiveDataRedactor.redact(
        'failed vless://550e8400-e29b-41d4-a716-446655440000@edge.example:443?security=tls '
        r'at /Users/private-user/project/main.dart and C:\Users\private-user\project\main.dart',
      );

      expect(redacted, contains('vless://[redacted]'));
      expect(redacted, isNot(contains('550e8400')));
      expect(redacted, isNot(contains('private-user')));
    });

    test('removes bare domains, FQDNs, IDN, punycode and host ports', () {
      const domains = ['Example.COM', 'dns.example.org.', 'xn--e1afmkfd.xn--p1ai', 'пример.рф', 'edge.example:8443'];
      final redacted = SensitiveDataRedactor.redact(
        'query=${domains[0]} answer ${domains[1]} sni ${domains[2]} idn ${domains[3]} peer ${domains[4]}',
      );

      for (final domain in domains) {
        expect(redacted.toLowerCase(), isNot(contains(domain.toLowerCase())));
      }
      expect(redacted, contains('[redacted-host]'));
    });

    test('redacts full, compressed, bracketed and scoped IPv6 addresses', () {
      const full = '2001:0db8:85a3:0000:0000:8a2e:0370:7334';
      const compressed = '2001:db8::42';
      const bracketed = '[2001:db8:1::10]:443';
      const scoped = 'fe80::1%en0';
      final redacted = SensitiveDataRedactor.redact(
        'full=$full compressed=$compressed peer=$bracketed interface=$scoped',
      );

      for (final address in [full, compressed, bracketed, scoped]) {
        expect(redacted, isNot(contains(address)));
      }
      expect('[redacted-ip]'.allMatches(redacted), hasLength(4));
    });

    test('fully redacts URLs with bracketed IPv6 hosts', () {
      const url = 'https://[2001:db8::42]:8443/private/path?token=secret';

      final redacted = SensitiveDataRedactor.redact('download $url');

      expect(redacted, 'download https://[redacted-host]/[redacted]');
      for (final sensitivePart in ['2001:db8::42', '8443', 'private', 'token=secret']) {
        expect(redacted, isNot(contains(sensitivePart)));
      }
    });

    test('does not mistake timestamps or ordinary colon-separated text for IPv6', () {
      const timestamp = '2026-08-10T23:05:57.123+03:00';
      const text = 'phase 19:05:57; retry after 10:30';

      final redacted = SensitiveDataRedactor.redact('$timestamp $text');

      expect(redacted, '$timestamp $text');
    });

    test('redacts a hostname reconstructed from log chunks', () {
      final chunks = ['outbound packet to split.', 'private.example:443'];
      final redacted = SensitiveDataRedactor.redact(chunks.join());

      expect(redacted, isNot(contains('split.private.example')));
      expect(redacted, contains('[redacted-host]'));
    });

    test('removes session tokens from relative captcha proxy URLs', () {
      final redacted = SensitiveDataRedactor.redact(
        'GET /not_robot_captcha?domain=id.example&session_token=private-session-token&variant=popup',
      );

      expect(redacted, contains('session_token=[redacted]'));
      expect(redacted, contains('&variant=popup'));
      expect(redacted, isNot(contains('private-session-token')));
    });

    test('fully redacts new wrapper links with embedded sensitive payloads', () {
      const happBase64 = 'aHR0cHM6Ly9zZWNyZXQuZXhhbXBsZS9zdWJzY3JpcHQ=';
      const shadowrocketBase64 = 'aHR0cHM6Ly9zZWNyZXQuZXhhbXBsZS9wcm9maWxl';
      const payload =
          'happ://add/$happBase64 '
          'hiddify://import/https://secret.example/sub/token '
          'shadowrocket://add/sub://$shadowrocketBase64?remark=private '
          'incy://add/https://secret.example/iny';

      final redacted = SensitiveDataRedactor.redact(payload);

      expect(redacted, isNot(contains(happBase64)));
      expect(redacted, isNot(contains('secret.example')));
      expect(redacted, isNot(contains('remark=private')));
      expect(redacted, isNot(contains('token')));
      expect(redacted, contains('happ://[redacted-host]/[redacted]'));
      expect(redacted, contains('hiddify://[redacted-host]/[redacted]'));
      expect(redacted, contains('shadowrocket://[redacted-host]/[redacted]'));
      expect(redacted, contains('incy://[redacted-host]/[redacted]'));
    });
  });
}
