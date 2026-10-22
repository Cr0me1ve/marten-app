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

    test('redacts outbound tags, peer fingerprints, and startup route profile labels', () {
      final outbound = SensitiveDataRedactor.redact('outbound/icmp[SECRET PROFILE] failed on startup');
      final peer = SensitiveDataRedactor.redact('peer(1USf…2wVA) handshake error');
      final startupRoute = SensitiveDataRedactor.redact('verifying startup route [SECRET PROFILE]');

      expect(outbound, contains('outbound/icmp'));
      expect(outbound, isNot(contains('SECRET PROFILE')));
      expect(outbound, contains('[redacted]'));
      expect(peer, contains('peer('));
      expect(peer, contains(')'));
      expect(peer, isNot(contains('1USf…2wVA')));
      expect(startupRoute, contains('verifying startup route'));
      expect(startupRoute, isNot(contains('SECRET PROFILE')));
    });

    test('redacts Xray route labels in tags and taking detour phrases', () {
      final route = SensitiveDataRedactor.redact('tags [SECRET PROFILE] on route, taking detour [INTERNAL]');
      final detour = SensitiveDataRedactor.redact('detouring through taking detour [PRODUCTION]');
      final platformDetour = SensitiveDataRedactor.redact('taking platform initialized detour [PRIVATE LABEL]');

      expect(route, contains('tags [redacted]'));
      expect(route, contains('taking detour [redacted]'));
      expect(route, isNot(contains('SECRET PROFILE')));
      expect(route, isNot(contains('INTERNAL')));
      expect(detour, contains('taking detour [redacted]'));
      expect(detour, isNot(contains('PRODUCTION')));
      expect(platformDetour, contains('taking platform initialized detour [redacted]'));
      expect(platformDetour, isNot(contains('PRIVATE LABEL')));
    });

    test('redacts complete nested-bracket route labels in legacy selected outbound and Xray logs', () {
      const nestedTag = 'Synthetic [Private] Route';
      final redacted = SensitiveDataRedactor.redact('''
verifying startup route [$nestedTag]
selected route [$nestedTag]
outbound/vless[$nestedTag] failed
tags [$nestedTag] taking detour [$nestedTag]''');

      expect(redacted, isNot(contains(nestedTag)));
      expect(redacted, isNot(contains('Private')));
      for (final stage in ['verifying startup route', 'selected route', 'outbound/vless', 'tags', 'taking detour']) {
        expect(redacted, contains(stage));
      }
      expect(SensitiveDataRedactor.redact(redacted), redacted);
    });

    test(
      'redacts nested selected-route watchdog labels and raw url-test failures without consuming later log lines',
      () {
        const privateTag = 'Synthetic [Private] Route';
        const rawError = 'synthetic private core diagnostic';
        final redacted = SensitiveDataRedactor.redact('''
selected route watchdog failed [$privateTag]: delay=65535
selected route watchdog url test failed: $rawError
route watchdog verified [Follow-up [Private] Route]: 42ms''');

        expect(redacted, isNot(contains(privateTag)));
        expect(redacted, isNot(contains(rawError)));
        expect(redacted, isNot(contains('Follow-up [Private] Route')));
        expect(redacted, contains('selected route watchdog failed [redacted]: delay=65535'));
        expect(redacted, contains('selected route watchdog url test failed: [redacted]'));
        expect(redacted, contains('route watchdog verified [redacted]: 42ms'));
        expect(SensitiveDataRedactor.redact(redacted), redacted);
      },
    );

    test('does not re-mask already redacted Xray labels', () {
      final redacted = SensitiveDataRedactor.redact('tags [redacted] taking detour [redacted]');

      expect(redacted, 'tags [redacted] taking detour [redacted]');
    });

    test('redacts legacy selected-route lifecycle labels while preserving stages and measurements', () {
      const routeTag = 'Synthetic Route North 42';
      const nestedRouteTag = 'Synthetic [Private] Route';
      const livenessPayload = 'raw synthetic private diagnostic';
      const selectorTail = 'Synthetic Selector Route';
      final redacted = SensitiveDataRedactor.redact('''
startup route timed out [$routeTag]
startup route verified [$routeTag]
stopping failed startup route [$routeTag]
route watchdog verified [$routeTag]
route watchdog verified [$nestedRouteTag]
route watchdog verified by endpoint fallback [$routeTag]
manual connected-route ping verified [$routeTag] by source: 42ms
verifying startup endpoint [$routeTag]: diagnostic.invalid:443
startup endpoint [$routeTag]: diagnostic.invalid:443
startup endpoint verified [$routeTag]: 19ms
falling back to startup endpoint probe [$routeTag]
turncoat liveness armed generation=7 inUse=true selectedTag=$routeTag
turncoat liveness: selected route active ($livenessPayload)
outbound not found in selector: $selectorTail''');

      expect(redacted, isNot(contains(routeTag)));
      expect(redacted, isNot(contains(nestedRouteTag)));
      expect(redacted, isNot(contains(livenessPayload)));
      expect(redacted, isNot(contains(selectorTail)));
      for (final stage in [
        'startup route timed out',
        'startup route verified',
        'stopping failed startup route',
        'route watchdog verified',
        'endpoint fallback',
        'manual connected-route ping verified',
        'verifying startup endpoint',
        'startup endpoint verified',
        'falling back to startup endpoint probe',
        'turncoat liveness: selected route active',
        'outbound not found in selector',
      ]) {
        expect(redacted, contains(stage));
      }
      expect(redacted, contains('42ms'));
      expect(redacted, contains('19ms'));
      expect(redacted, contains('generation=7'));
      expect(redacted, contains('inUse=true'));
    });

    test('redacts legacy group outbound profile and push-profile identifiers', () {
      const group = 'Synthetic Group Alpha';
      const outbound = 'Synthetic Outbound Beta';
      const profileName = 'Synthetic Profile Gamma';
      const profileId = 'synthetic-profile-id-42';
      final redacted = SensitiveDataRedactor.redact('''
changing proxy, group: [$group] - outbound: [$outbound]
testing group: [$group]
failed to read url test snapshot for [$group/$outbound]
failed to read selected url test snapshot for [$group/$outbound]
deleting profile: $profileName
active profile config file missing [$profileId]
active profile config file disappeared [$profileId]
active profile config file is missing [$profileId]
active profile config file disappeared during encrypted read [$profileId]
push token registered for profile [$profileId]
registered push token for profile [$profileId]
push token registration failed for profile [$profileId]
push token unregistered for profile [$profileId]
push token unregister failed for profile [$profileId]''');

      for (final identifier in [group, outbound, profileName, profileId]) {
        expect(redacted, isNot(contains(identifier)));
      }
      for (final category in [
        'changing proxy',
        'testing group',
        'failed to read url test snapshot',
        'failed to read selected url test snapshot',
        'deleting profile',
        'active profile config file missing',
        'active profile config file disappeared',
        'active profile config file is missing',
        'active profile config file disappeared during encrypted read',
        'push token registered',
        'registered push token',
        'push token registration failed',
        'push token unregistered',
        'push token unregister failed',
      ]) {
        expect(redacted, contains(category));
      }
    });

    test('redacts multiline legacy exports idempotently', () {
      const routeTag = 'Synthetic Route With Spaces';
      const group = 'Synthetic Group With Spaces';
      const profileId = 'synthetic-profile-id-multiline';
      final export =
          '''
route watchdog verified [$routeTag]
turncoat liveness armed generation=7 inUse=true selectedTag=$routeTag
startup endpoint verified [$routeTag]: 19ms
turncoat liveness: selected route active (raw synthetic private diagnostic)
changing proxy, group: [$group] - outbound: [$routeTag]
push token unregister failed for profile [$profileId]''';

      final redacted = SensitiveDataRedactor.redact(export);

      expect(redacted, isNot(contains(routeTag)));
      expect(redacted, isNot(contains(group)));
      expect(redacted, isNot(contains(profileId)));
      expect(redacted, isNot(contains('raw synthetic private diagnostic')));
      expect(redacted, contains('generation=7'));
      expect(redacted, contains('inUse=true'));
      expect(redacted, contains('19ms'));
      expect(SensitiveDataRedactor.redact(redacted), redacted);
    });

    test('redacts native select-outbound group and outbound labels without brackets', () {
      const group = 'Synthetic Private Group';
      const outbound = 'Synthetic Private Outbound';
      final redacted = SensitiveDataRedactor.redact('select outbound: $group -> $outbound');

      expect(redacted, contains('select outbound:'));
      expect(redacted, isNot(contains(group)));
      expect(redacted, isNot(contains(outbound)));
      expect(SensitiveDataRedactor.redact(redacted), redacted);
    });

    test('fast-path gates still redact mixed-case quoted credential keys and endpoint identifiers', () {
      const credentials = '''
{"AUTHORIZATION": "Bearer-Credential", "X-Client-Secret": 'client-credential',
"Device-ID": "private-device", PUSH_TOKEN: push-credential, refresh-token=refresh-credential,
private-key: key-credential, password=pass-credential, call_url=https://private.example/call,
uuid=550e8400-e29b-41d4-a716-446655440000}''';
      final redactedCredentials = SensitiveDataRedactor.redact(credentials);

      for (final secret in [
        'Bearer-Credential',
        'client-credential',
        'private-device',
        'push-credential',
        'refresh-credential',
        'key-credential',
        'pass-credential',
        'private.example',
        '550e8400-e29b-41d4-a716-446655440000',
      ]) {
        expect(redactedCredentials, isNot(contains(secret)), reason: secret);
      }
      for (final key in [
        'AUTHORIZATION',
        'X-Client-Secret',
        'Device-ID',
        'PUSH_TOKEN',
        'refresh-token',
        'private-key',
        'password',
      ]) {
        expect(redactedCredentials, contains(key));
      }

      const endpoints =
          'https://edge.private.example:8443/subscription/private-sub-token?access_token=endpoint-secret '
          'fallback=198.51.100.27 local=[2001:db8::42]';
      final redactedEndpoints = SensitiveDataRedactor.redact(endpoints);

      for (final privateValue in [
        'edge.private.example',
        '8443',
        'private-sub-token',
        'endpoint-secret',
        '198.51.100.27',
        '2001:db8::42',
      ]) {
        expect(redactedEndpoints, isNot(contains(privateValue)), reason: privateValue);
      }
      expect(redactedEndpoints, contains('https://[redacted-host]/[redacted]'));
      expect(redactedEndpoints, contains('[redacted-ip]'));
    });

    test('ordinary numeric metric lines without candidate markers are unchanged', () {
      const metrics = 'CORE_RECORDING schema=3 elapsed_ms=1700000 requests=42 cpu_us=987654 metric=123456';

      expect(SensitiveDataRedactor.redact(metrics), metrics);
    });
  });
}
