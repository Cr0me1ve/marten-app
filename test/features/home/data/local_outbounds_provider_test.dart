import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('app.marten.client/method');

  group('local outbound ordering', () {
    test('uses the native ordinary Echo probe for ICMP outbounds', () async {
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
        call,
      ) async {
        captured = call;
        return 27;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          methodChannel,
          null,
        ),
      );

      const icmp = LocalOutbound(tag: 'ICMP', type: 'icmp', server: '198.51.100.7', serverPort: 0);
      expect(localOutboundUsesICMPEchoPing(icmp), isTrue);
      expect(await nativeICMPEchoProbe(' 198.51.100.7 ', isAndroid: true), 27);
      expect(captured?.method, 'icmp_ping');
      expect(captured?.arguments, {'host': '198.51.100.7', 'timeoutMs': 4000});
    });

    test('does not request a native Echo probe off Android or without an ICMP host', () async {
      expect(await nativeICMPEchoProbe('198.51.100.7', isAndroid: false), -1);
      expect(await nativeICMPEchoProbe('', isAndroid: true), -1);
      expect(
        localOutboundUsesICMPEchoPing(const LocalOutbound(tag: 'ICMP', type: 'icmp', server: '', serverPort: 0)),
        isFalse,
      );
    });

    test('parses visible outbounds in subscription order', () {
      final raw = jsonEncode({
        'servers': [
          {'tag': 'Beta §id:2§'},
          {'tag': 'Alpha §id:1§'},
        ],
        'outbounds': [
          {'type': 'selector', 'tag': 'select'},
          {'type': 'vless', 'tag': 'Beta §id:2§', 'server': 'beta.example', 'server_port': 443},
          {'type': 'turncoat', 'tag': 'Beta transport §hide§', 'server': 'turn.example', 'server_port': 3478},
          {'type': 'hysteria2', 'tag': 'Alpha §id:1§', 'server': 'alpha.example', 'server_port': 443},
          {'type': 'direct', 'tag': 'direct'},
        ],
      });

      final outbounds = parseLocalOutbounds(raw);

      expect(outbounds.map((outbound) => outbound.displayName), ['Beta', 'Alpha']);
    });

    test('parses base64 wrapped JSON configs for the offline server list', () {
      final raw = base64Encode(
        utf8.encode(
          jsonEncode({
            'outbounds': [
              {'type': 'vless', 'tag': 'US', 'server': 'us.example', 'server_port': 443},
            ],
          }),
        ),
      );

      final outbounds = parseLocalOutbounds(raw);

      expect(outbounds.single.tag, 'US');
    });

    test('parses null-padded JSON configs for the offline server list', () {
      final raw =
          '${jsonEncode({
            'outbounds': [
              {'type': 'vless', 'tag': 'US', 'server': 'us.example', 'server_port': 443},
            ],
          })}\u0000\u0000{"stale":"tail"}';

      final outbounds = parseLocalOutbounds(raw);

      expect(outbounds.single.tag, 'US');
    });

    test('keeps the responsive parser policy at a strict 64 KiB boundary', () async {
      expect(localOutboundsBackgroundParseThreshold, 64 * 1024);

      final belowThreshold = _validLocalOutboundsJsonOfLength(localOutboundsBackgroundParseThreshold - 1);
      final atThreshold = _validLocalOutboundsJsonOfLength(localOutboundsBackgroundParseThreshold);
      expect(belowThreshold.length, localOutboundsBackgroundParseThreshold - 1);
      expect(atThreshold.length, localOutboundsBackgroundParseThreshold);

      expect(
        _outboundSignatures(await parseLocalOutboundsResponsively(belowThreshold)),
        _outboundSignatures(parseLocalOutbounds(belowThreshold)),
      );
      expect(
        _outboundSignatures(await parseLocalOutboundsResponsively(atThreshold)),
        _outboundSignatures(parseLocalOutbounds(atThreshold)),
      );

      final source = File('lib/features/home/data/local_outbounds_provider.dart').readAsStringSync();
      expect(
        RegExp(r'raw\.length\s*<\s*localOutboundsBackgroundParseThreshold').hasMatch(source),
        isTrue,
        reason: 'only inputs below 64 KiB stay on the UI isolate; an exact 64 KiB config uses compute',
      );
    });

    test('responsive parser is functionally equivalent for small and large valid configs', () async {
      final small = jsonEncode({
        'outbounds': [
          {'type': 'hysteria2', 'tag': 'Beta', 'server': 'beta.example', 'server_port': 443},
          {'type': 'vless', 'tag': 'Alpha', 'server': 'alpha.example', 'server_port': 443},
        ],
      });
      final large = _validLocalOutboundsJsonOfLength(localOutboundsBackgroundParseThreshold + 2048);

      expect(
        _outboundSignatures(await parseLocalOutboundsResponsively(small)),
        _outboundSignatures(parseLocalOutbounds(small)),
      );
      expect(
        _outboundSignatures(await parseLocalOutboundsResponsively(large)),
        _outboundSignatures(parseLocalOutbounds(large)),
      );
    });

    test('preserves subscription order even when flag-prefixed names sort differently', () {
      final raw = jsonEncode({
        'servers': [
          {'tag': '🇦🇱 Beta §id:2§'},
          {'tag': '🇺🇸 Alpha §id:1§'},
        ],
        'outbounds': [
          {'type': 'vless', 'tag': '🇦🇱 Beta §id:2§', 'server': 'beta.example', 'server_port': 443},
          {'type': 'vless', 'tag': '🇺🇸 Alpha §id:1§', 'server': 'alpha.example', 'server_port': 443},
        ],
      });

      final outbounds = parseLocalOutbounds(raw);

      expect(outbounds.map((outbound) => outbound.displayName), ['🇦🇱 Beta', '🇺🇸 Alpha']);
    });

    test('keeps selectable outbound tags in subscription order', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['Zulu', 'Alpha', 'Beta'],
          },
          {'type': 'vless', 'tag': 'Zulu', 'server': 'zulu.example', 'server_port': 443},
          {'type': 'hysteria2', 'tag': 'Alpha', 'server': 'alpha.example', 'server_port': 443},
          {'type': 'wireguard', 'tag': 'Beta', 'server': 'beta.example', 'server_port': 51820},
          {'type': 'turncoat', 'tag': 'hidden transport §hide§', 'server': 'turn.example', 'server_port': 3478},
        ],
      });

      expect(selectableOutboundTagsFromConfig(raw), ['Zulu', 'Alpha', 'Beta']);
      expect(parseLocalOutbounds(raw).map((outbound) => outbound.tag), ['Zulu', 'Alpha', 'Beta']);
    });

    test('marks TURNcoat-backed outbounds and extracts hidden helper call URL', () {
      const inviteUrl = 'https://calls.example/call/join/PLACEHOLDERhttps://calls.example/call/join/abc';
      final raw = jsonEncode({
        'servers': [
          {'tag': 'Plain', 'tunnel_ping_url': 'http://plain.example:9443/tunnel/ping'},
          {'tag': 'Turn', 'tunnel_ping_url': 'http://turn-backend.example:9443/tunnel/ping'},
        ],
        'outbounds': [
          {'type': 'vless', 'tag': 'Plain', 'server': 'plain.example', 'server_port': 443},
          {
            'type': 'hysteria2',
            'tag': 'Turn',
            'server': 'turn-backend.example',
            'server_port': 443,
            'detour': 'Turn transport §hide§',
          },
          {
            'type': 'turncoat',
            'tag': 'Turn transport §hide§',
            'server': 'turn.example',
            'server_port': 3478,
            'call_urls': [inviteUrl],
          },
        ],
      });

      final outbounds = parseLocalOutbounds(raw);
      final plain = outbounds.singleWhere((outbound) => outbound.tag == 'Plain');
      final turn = outbounds.singleWhere((outbound) => outbound.tag == 'Turn');
      final endpoint = turncoatPingEndpointFromUrl(inviteUrl);

      expect(plain.usesTurncoat, isFalse);
      expect(turn.usesTurncoat, isTrue);
      expect(turn.callUrls, [inviteUrl]);
      expect(endpoint, isNotNull);
      expect(endpoint!.host, 'calls.example');
      expect(endpoint.port, 443);
    });

    test('uses server port ping for VLESS even when tunnel ping metadata exists', () {
      final raw = jsonEncode({
        'servers': [
          {'tag': 'Germany', 'tunnel_ping_url': 'http://de-01.example:9443/tunnel/ping'},
          {'tag': 'Hysteria', 'tunnel_ping_url': 'http://hy.example:9443/tunnel/ping'},
        ],
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'Germany',
            'server': 'de-01.example',
            'server_port': 443,
            'tls': {'enabled': true, 'server_name': 'site.example'},
          },
          {'type': 'hysteria2', 'tag': 'Hysteria', 'server': 'hy.example', 'server_port': 443},
        ],
      });

      final outbounds = parseLocalOutbounds(raw);
      final germany = outbounds.singleWhere((outbound) => outbound.tag == 'Germany');
      final hysteria = outbounds.singleWhere((outbound) => outbound.tag == 'Hysteria');

      expect(germany.server, 'de-01.example');
      expect(germany.serverPort, 443);
      expect(germany.tlsServerName, 'site.example');
      expect(germany.tunnelPingUrl, 'http://de-01.example:9443/tunnel/ping');
      expect(localOutboundUsesServerPortPing(germany), isTrue);
      expect(localOutboundUsesServerPortPing(hysteria), isFalse);
    });

    test('falls back to TCP ping when tunnel ping endpoint is unhealthy', () async {
      final tcpServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final container = ProviderContainer();

      tcpServer.listen((socket) => socket.destroy());
      httpServer.listen((request) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('{"ok":false}');
        request.response.close();
      });

      addTearDown(() {
        container.dispose();
        tcpServer.close();
        httpServer.close(force: true);
      });

      final host = InternetAddress.loopbackIPv4.address;
      final outbound = LocalOutbound(
        tag: 'Fallback',
        type: 'hysteria2',
        server: host,
        serverPort: tcpServer.port,
        tunnelPingUrl: 'http://$host:${httpServer.port}/tunnel/ping',
      );

      await container.read(localPingProvider.notifier).pingAll([outbound]);

      expect(container.read(localPingProvider)['Fallback'], isNonNegative);
    });

    test('displays legacy Xray VLESS Reality outbounds as vless', () {
      final raw = jsonEncode({
        'servers': [
          {'tag': 'Germany', 'server': 'de-01.example', 'server_port': 443},
        ],
        'outbounds': [
          {
            'type': 'xray',
            'tag': 'Germany',
            'xconfig': {
              'outbounds': [
                {
                  'protocol': 'vless',
                  'settings': {
                    'vnext': [
                      {'address': 'de-01.example', 'port': 443},
                    ],
                  },
                },
              ],
            },
          },
        ],
      });

      final outbounds = parseLocalOutbounds(raw);
      final germany = outbounds.singleWhere((outbound) => outbound.tag == 'Germany');

      expect(germany.type, 'vless');
      expect(germany.server, 'de-01.example');
      expect(germany.serverPort, 443);
      expect(germany.tlsServerName, isNull);
      expect(localOutboundUsesServerPortPing(germany), isTrue);
    });

    test('displays Xray VLESS xHTTP/H3 outbounds as vless', () {
      final raw = jsonEncode({
        'servers': [
          {'tag': 'Germany', 'server': 'de-01.example', 'server_port': 443},
        ],
        'outbounds': [
          {
            'type': 'xray',
            'tag': 'Germany',
            'xconfig': {
              'outbounds': [
                {
                  'protocol': 'vless',
                  'streamSettings': {
                    'network': 'xhttp',
                    'security': 'tls',
                    'tlsSettings': {
                      'serverName': 'de-01.example',
                      'alpn': ['h3'],
                    },
                    'xhttpSettings': {'host': 'de-01.example', 'path': '/assets/api/events', 'mode': 'stream-one'},
                  },
                },
              ],
            },
          },
        ],
      });

      final outbounds = parseLocalOutbounds(raw);
      final germany = outbounds.singleWhere((outbound) => outbound.tag == 'Germany');

      expect(germany.type, 'vless');
      expect(germany.server, 'de-01.example');
      expect(germany.serverPort, 443);
      expect(germany.tlsServerName, 'de-01.example');
      expect(localOutboundUsesServerPortPing(germany), isTrue);
    });

    test('normalizes live Xray VLESS protocol labels as vless', () {
      expect(displayTypeForProxyLabel('Xvless'), 'vless');
      expect(displayTypeForProxyLabel('x-vless'), 'vless');
      expect(displayTypeForProxyLabel('x_vless'), 'vless');
      expect(displayTypeForProxyLabel('hysteria2'), 'hysteria2');
    });

    test('prefers server metadata endpoint and server_name for VLESS ping', () {
      final raw = jsonEncode({
        'servers': [
          {'tag': 'US', 'server': 'usa.example', 'server_port': 443, 'server_name': 'usa.example'},
        ],
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'US',
            'server': '203.0.113.10',
            'server_port': 443,
            'tls': {'enabled': true, 'server_name': 'fallback.example'},
          },
        ],
      });

      final outbounds = parseLocalOutbounds(raw);
      final us = outbounds.singleWhere((outbound) => outbound.tag == 'US');

      expect(us.server, 'usa.example');
      expect(us.serverPort, 443);
      expect(us.tlsServerName, 'usa.example');
      expect(localOutboundUsesServerPortPing(us), isTrue);
    });

    test('keeps IP VLESS endpoint for ping while retaining TLS server name', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'US',
            'server': '203.0.113.10',
            'server_port': 443,
            'tls': {'enabled': true, 'server_name': 'usa.example'},
          },
        ],
      });

      final outbounds = parseLocalOutbounds(raw);
      final us = outbounds.singleWhere((outbound) => outbound.tag == 'US');

      expect(us.server, '203.0.113.10');
      expect(us.serverPort, 443);
      expect(us.tlsServerName, 'usa.example');
      expect(localOutboundUsesServerPortPing(us), isTrue);
    });

    test('scales TURNcoat ping by four plus random jitter', () {
      expect(scaledTurncoatPingDelay(100, randomFraction: 0), 400);
      expect(scaledTurncoatPingDelay(100, randomFraction: 0.5), 450);
      expect(scaledTurncoatPingDelay(100, randomFraction: 1), 500);
      expect(scaledTurncoatPingDelay(-1, randomFraction: 0.5), -1);
    });

    test('uses backend tunnel ping for TURNcoat while connected', () async {
      // flutter_test installs an HttpOverrides that rejects real HTTP. This
      // case intentionally exercises the loopback tunnel-ping endpoint, so
      // remove it only for this test and restore it before another test runs.
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      int tunnelPingRequests = 0;
      final container = ProviderContainer();

      try {
        httpServer.listen((request) {
          tunnelPingRequests++;
          request.response.statusCode = HttpStatus.ok;
          request.response.write('{"ok":true}');
          request.response.close();
        });

        final outbound = LocalOutbound(
          tag: 'Turn',
          type: 'hysteria2',
          server: '203.0.113.10',
          serverPort: 443,
          tunnelPingUrl: 'http://${InternetAddress.loopbackIPv4.address}:${httpServer.port}/tunnel/ping',
          callUrls: const ['https://127.0.0.1:1/call/join/example'],
          usesTurncoat: true,
        );

        await container.read(localPingProvider.notifier).pingAll([outbound], mode: LocalPingMode.connectedRoute);
        expect(tunnelPingRequests, 1);
        expect(container.read(localPingProvider)['Turn'], isNonNegative);
      } finally {
        container.dispose();
        await httpServer.close(force: true);
        HttpOverrides.global = previousHttpOverrides;
      }
    });

    test('filters connected route ping targets to active TURNcoat-backed tags', () {
      const plain = LocalOutbound(tag: 'Plain', type: 'vless', server: 'plain.example', serverPort: 443);
      const turn = LocalOutbound(
        tag: 'Turn',
        type: 'hysteria2',
        server: 'turn.example',
        serverPort: 443,
        tunnelPingUrl: 'http://turn.example:9443/tunnel/ping',
        usesTurncoat: true,
      );

      expect(connectedRoutePingOutbounds([plain, turn], ['Turn']), [turn]);
      expect(connectedRoutePingOutbounds([plain, turn], ['Plain']), isEmpty);
    });

    test('overrides core delay with local ping values for display', () {
      expect(displayDelayWithLocalPing(coreDelay: 65535, localPing: 320), 320);
      expect(displayDelayWithLocalPing(coreDelay: 65535, localPing: 0), 0);
      expect(displayDelayWithLocalPing(coreDelay: 42, localPing: -1), 999999);
      expect(displayDelayWithLocalPing(coreDelay: 42, localPing: null), 42);
    });

    test('records explicit connected route measurements', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const outbound = LocalOutbound(tag: 'Turn', type: 'hysteria2', server: '', serverPort: 0);

      container.read(localPingProvider.notifier)
        ..markPending([outbound])
        ..record(outbound.tag, 287);

      expect(container.read(localPingProvider), {'Turn': 287});
    });

    test('resolves pending, remembered, then first sorted tag', () {
      const tags = ['Alpha', 'Beta', 'Gamma'];

      expect(resolveSelectedOutboundTag(tags, pending: 'Gamma', remembered: 'Beta'), 'Gamma');
      expect(resolveSelectedOutboundTag(tags, pending: 'Missing', remembered: 'Beta'), 'Beta');
      expect(resolveSelectedOutboundTag(tags, remembered: 'Missing'), 'Alpha');
    });

    test('ignores legacy remembered proxy tags without an outbound fingerprint', () async {
      SharedPreferences.setMockInitialValues({
        'selected_proxy_by_profile': jsonEncode({'profile-a': 'Beta'}),
      });
      final prefs = await SharedPreferences.getInstance();
      final notifier = SelectedProxyByProfileNotifier(prefs);

      expect(notifier.state, isEmpty);
      expect(notifier.rememberedTagFor('profile-a', ['Alpha', 'Beta']), isNull);
      expect(
        resolveSelectedOutboundTag([
          'Alpha',
          'Beta',
        ], remembered: notifier.rememberedTagFor('profile-a', ['Alpha', 'Beta'])),
        'Alpha',
      );
    });

    test('keeps remembered proxy only while the outbound list fingerprint matches', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notifier = SelectedProxyByProfileNotifier(prefs);

      await notifier.select('profile-a', 'Beta', availableTags: ['Alpha', 'Beta']);

      expect(notifier.state, {'profile-a': 'Beta'});
      expect(notifier.rememberedTagFor('profile-a', ['Alpha', 'Beta']), 'Beta');
      expect(notifier.rememberedTagFor('profile-a', ['Alpha', 'Beta', 'Gamma']), isNull);
      expect(
        resolveSelectedOutboundTag([
          'Alpha',
          'Beta',
          'Gamma',
        ], remembered: notifier.rememberedTagFor('profile-a', ['Alpha', 'Beta', 'Gamma'])),
        'Alpha',
      );
    });
  });

  group('config preparation', () {
    test('keeps unselected selector members in subscription order', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'selector',
            'tag': 'system routes',
            'outbounds': ['Zulu direct', 'Alpha direct'],
          },
          {'type': 'direct', 'tag': 'Zulu direct'},
          {'type': 'direct', 'tag': 'Alpha direct'},
          {'type': 'vless', 'tag': 'Chosen server', 'server': 'chosen.example', 'server_port': 443},
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Chosen server')) as Map<String, dynamic>;
      final selector = (prepared['outbounds'] as List<dynamic>).whereType<Map>().singleWhere(
        (outbound) => outbound['tag'] == 'system routes',
      );

      expect(selector['outbounds'], ['Zulu direct', 'Alpha direct']);
    });

    test('promotes selected outbound before core builds selector default', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['Zeta', 'Alpha'],
          },
          {'type': 'vless', 'tag': 'Zeta', 'server': 'zeta.example', 'server_port': 443},
          {'type': 'turncoat', 'tag': 'Zeta transport §hide§', 'server': 'turn.example', 'server_port': 3478},
          {'type': 'hysteria2', 'tag': 'Alpha', 'server': 'alpha.example', 'server_port': 443},
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Alpha')) as Map<String, dynamic>;
      final outbounds = prepared['outbounds'] as List<dynamic>;
      final selector = outbounds.first as Map<String, dynamic>;
      final selectable = outbounds.whereType<Map>().where((outbound) {
        final type = outbound['type']?.toString();
        final tag = outbound['tag']?.toString() ?? '';
        return type != 'selector' && type != 'turncoat' && !tag.contains('§hide§');
      }).toList();

      expect(selector['default'], 'Alpha');
      expect(selector['outbounds'], ['Alpha']);
      expect(selectable.first['tag'], 'Alpha');
    });

    test('strips Marten subscription metadata before selected config reaches core', () {
      final raw = jsonEncode({
        'split_tunnel': {
          'bypass_apps': ['ru.example.app'],
        },
        'servers': [
          {'tag': 'US', 'server': 'us.example', 'server_port': 443},
        ],
        'subscription': {'updated_at': '2026-07-03T00:00:00Z'},
        'outbounds': [
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['US'],
          },
          {'type': 'vless', 'tag': 'US', 'server': 'us.example', 'server_port': 443},
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'US')) as Map<String, dynamic>;

      expect(prepared, isNot(contains('split_tunnel')));
      expect(prepared, isNot(contains('servers')));
      expect(prepared, isNot(contains('subscription')));
    });

    test('strips Marten subscription metadata from null-padded selected configs', () {
      final raw =
          '${jsonEncode({
            'split_tunnel': {
              'bypass_apps': ['ru.example.app'],
            },
            'servers': [
              {'tag': 'US', 'server': 'us.example', 'server_port': 443},
            ],
            'subscription': {'updated_at': '2026-07-03T00:00:00Z'},
            'outbounds': [
              {
                'type': 'selector',
                'tag': 'select',
                'outbounds': ['US'],
              },
              {'type': 'vless', 'tag': 'US', 'server': 'us.example', 'server_port': 443},
            ],
          })}\u0000\u0000{"stale":"tail"}';

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'US')) as Map<String, dynamic>;

      expect(prepared, isNot(contains('split_tunnel')));
      expect(prepared, isNot(contains('servers')));
      expect(prepared, isNot(contains('subscription')));
    });

    test('preserves selected direct VLESS endpoint before core starts', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['US'],
          },
          {
            'type': 'vless',
            'tag': 'US',
            'server': '203.0.113.10',
            'server_port': 443,
            'tls': {'enabled': true, 'server_name': 'usa.example'},
          },
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'US')) as Map<String, dynamic>;
      final us = (prepared['outbounds'] as List<dynamic>).whereType<Map>().singleWhere(
        (outbound) => outbound['tag'] == 'US',
      );

      expect(us['server'], '203.0.113.10');
    });

    test('preserves selected Xray VLESS TCP endpoint before core starts', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'xray',
            'tag': 'Germany',
            'xconfig': {
              'outbounds': [
                {
                  'protocol': 'vless',
                  'tag': 'Germany',
                  'settings': {
                    'vnext': [
                      {
                        'address': '203.0.113.20',
                        'port': 443,
                        'users': [
                          {'id': 'uuid', 'encryption': 'none'},
                        ],
                      },
                    ],
                  },
                  'streamSettings': {
                    'network': 'tcp',
                    'security': 'tls',
                    'tlsSettings': {'serverName': 'de.example'},
                  },
                },
              ],
            },
          },
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Germany')) as Map<String, dynamic>;
      final germany = (prepared['outbounds'] as List<dynamic>).whereType<Map>().singleWhere(
        (outbound) => outbound['tag'] == 'Germany',
      );
      final xconfig = germany['xconfig'] as Map<String, dynamic>;
      final xout = (xconfig['outbounds'] as List<dynamic>).whereType<Map>().single;
      final settings = xout['settings'] as Map<String, dynamic>;
      final vnext = (settings['vnext'] as List<dynamic>).whereType<Map>().single;

      expect(vnext['address'], '203.0.113.20');
    });

    test('keeps selected Xray VLESS xHTTP IP endpoint before core starts', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'xray',
            'tag': 'Germany',
            'xconfig': {
              'outbounds': [
                {
                  'protocol': 'vless',
                  'tag': 'Germany',
                  'settings': {
                    'vnext': [
                      {
                        'address': '203.0.113.20',
                        'port': 443,
                        'users': [
                          {'id': 'uuid', 'encryption': 'none'},
                        ],
                      },
                    ],
                  },
                  'streamSettings': {
                    'network': 'xhttp',
                    'security': 'tls',
                    'tlsSettings': {'serverName': 'de.example'},
                    'xhttpSettings': {'host': 'de.example', 'path': '/assets/api/events', 'mode': 'packet-up'},
                  },
                },
              ],
            },
          },
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Germany')) as Map<String, dynamic>;
      final germany = (prepared['outbounds'] as List<dynamic>).whereType<Map>().singleWhere(
        (outbound) => outbound['tag'] == 'Germany',
      );
      final xconfig = germany['xconfig'] as Map<String, dynamic>;
      final xout = (xconfig['outbounds'] as List<dynamic>).whereType<Map>().single;
      final settings = xout['settings'] as Map<String, dynamic>;
      final vnext = (settings['vnext'] as List<dynamic>).whereType<Map>().single;

      expect(vnext['address'], '203.0.113.20');
    });

    test('keeps selected native VLESS xHTTP IP endpoint before core starts', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'Germany',
            'server': '203.0.113.20',
            'server_port': 443,
            'uuid': '00000000-0000-0000-0000-000000000000',
            'tls': {
              'enabled': true,
              'server_name': 'de.example',
              'alpn': ['h2'],
              'utls': {'enabled': true, 'fingerprint': 'firefox'},
            },
            'transport': {'type': 'xhttp', 'host': 'de.example', 'path': '/assets/api/events', 'mode': 'stream-up'},
          },
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Germany')) as Map<String, dynamic>;
      final germany = (prepared['outbounds'] as List<dynamic>).whereType<Map>().singleWhere(
        (outbound) => outbound['tag'] == 'Germany',
      );
      final tls = germany['tls'] as Map<String, dynamic>;
      final transport = germany['transport'] as Map<String, dynamic>;

      expect(germany['server'], '203.0.113.20');
      expect(tls['alpn'], ['h2']);
      expect((tls['utls'] as Map<String, dynamic>)['fingerprint'], 'firefox');
      expect(transport['mode'], 'stream-up');
    });

    test('preserves selected Xray VLESS xHTTP TLS and transport settings before core starts', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'xray',
            'tag': 'Germany',
            'xconfig': {
              'outbounds': [
                {
                  'protocol': 'vless',
                  'tag': 'Germany',
                  'settings': {
                    'vnext': [
                      {
                        'address': '203.0.113.20',
                        'port': 443,
                        'users': [
                          {'id': 'uuid', 'encryption': 'none'},
                        ],
                      },
                    ],
                  },
                  'streamSettings': {
                    'network': 'xhttp',
                    'security': 'tls',
                    'tlsSettings': {
                      'serverName': 'de.example',
                      'alpn': ['h3'],
                    },
                    'xhttpSettings': {'host': 'de.example', 'path': '/assets/api/events', 'mode': 'stream-one'},
                  },
                },
              ],
            },
          },
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Germany')) as Map<String, dynamic>;
      final germany = (prepared['outbounds'] as List<dynamic>).whereType<Map>().singleWhere(
        (outbound) => outbound['tag'] == 'Germany',
      );
      final xconfig = germany['xconfig'] as Map<String, dynamic>;
      final xout = (xconfig['outbounds'] as List<dynamic>).whereType<Map>().single;
      final stream = xout['streamSettings'] as Map<String, dynamic>;
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      final xhttp = stream['xhttpSettings'] as Map<String, dynamic>;

      expect(tls['alpn'], ['h3']);
      expect(tls.containsKey('fingerprint'), isFalse);
      expect(xhttp['mode'], 'stream-one');
    });

    test('preserves selected Xray VLESS xHTTP when ALPN is empty before core starts', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'xray',
            'tag': 'Germany',
            'xconfig': {
              'outbounds': [
                {
                  'protocol': 'vless',
                  'streamSettings': {
                    'network': 'xhttp',
                    'security': 'tls',
                    'tlsSettings': {'serverName': 'de.example'},
                    'xhttpSettings': {'host': 'de.example', 'path': '/assets/api/events', 'mode': 'auto'},
                  },
                },
              ],
            },
          },
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Germany')) as Map<String, dynamic>;
      final germany = (prepared['outbounds'] as List<dynamic>).whereType<Map>().singleWhere(
        (outbound) => outbound['tag'] == 'Germany',
      );
      final xconfig = germany['xconfig'] as Map<String, dynamic>;
      final xout = (xconfig['outbounds'] as List<dynamic>).whereType<Map>().single;
      final stream = xout['streamSettings'] as Map<String, dynamic>;
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      final xhttp = stream['xhttpSettings'] as Map<String, dynamic>;

      expect(tls.containsKey('alpn'), isFalse);
      expect(tls.containsKey('fingerprint'), isFalse);
      expect(xhttp['mode'], 'auto');
    });

    test('preserves h2-only ALPN for selected Xray VLESS xHTTP before core starts', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'xray',
            'tag': 'Germany',
            'xconfig': {
              'outbounds': [
                {
                  'protocol': 'vless',
                  'streamSettings': {
                    'network': 'xhttp',
                    'security': 'tls',
                    'tlsSettings': {
                      'serverName': 'de.example',
                      'alpn': ['h2'],
                    },
                    'xhttpSettings': {'host': 'de.example', 'path': '/assets/api/events', 'mode': 'stream-up'},
                  },
                },
              ],
            },
          },
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Germany')) as Map<String, dynamic>;
      final germany = (prepared['outbounds'] as List<dynamic>).whereType<Map>().singleWhere(
        (outbound) => outbound['tag'] == 'Germany',
      );
      final xconfig = germany['xconfig'] as Map<String, dynamic>;
      final xout = (xconfig['outbounds'] as List<dynamic>).whereType<Map>().single;
      final stream = xout['streamSettings'] as Map<String, dynamic>;
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      final xhttp = stream['xhttpSettings'] as Map<String, dynamic>;

      expect(tls['alpn'], ['h2']);
      expect(tls.containsKey('fingerprint'), isFalse);
      expect(xhttp['mode'], 'stream-up');
    });

    test('preserves mixed ALPN and stream-one mode before core starts', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'xray',
            'tag': 'Germany',
            'xconfig': {
              'outbounds': [
                {
                  'protocol': 'vless',
                  'streamSettings': {
                    'network': 'xhttp',
                    'security': 'tls',
                    'tlsSettings': {
                      'serverName': 'de.example',
                      'alpn': ['h2', 'http/1.1'],
                    },
                    'xhttpSettings': {'host': 'de.example', 'path': '/assets/api/events', 'mode': 'stream-one'},
                  },
                },
              ],
            },
          },
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Germany')) as Map<String, dynamic>;
      final germany = (prepared['outbounds'] as List<dynamic>).whereType<Map>().singleWhere(
        (outbound) => outbound['tag'] == 'Germany',
      );
      final xconfig = germany['xconfig'] as Map<String, dynamic>;
      final xout = (xconfig['outbounds'] as List<dynamic>).whereType<Map>().single;
      final stream = xout['streamSettings'] as Map<String, dynamic>;
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      final xhttp = stream['xhttpSettings'] as Map<String, dynamic>;

      expect(tls['alpn'], ['h2', 'http/1.1']);
      expect(tls.containsKey('fingerprint'), isFalse);
      expect(xhttp['mode'], 'stream-one');
    });

    test('preserves Xray VLESS xHTTP TLS fingerprint before core starts', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'xray',
            'tag': 'Germany',
            'xconfig': {
              'outbounds': [
                {
                  'protocol': 'vless',
                  'streamSettings': {
                    'network': 'xhttp',
                    'security': 'tls',
                    'tlsSettings': {
                      'serverName': 'de.example',
                      'alpn': ['http/1.1'],
                      'fingerprint': 'firefox',
                    },
                    'xhttpSettings': {'host': 'de.example', 'path': '/assets/api/events', 'mode': 'packet-up'},
                  },
                },
              ],
            },
          },
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Germany')) as Map<String, dynamic>;
      final germany = (prepared['outbounds'] as List<dynamic>).whereType<Map>().singleWhere(
        (outbound) => outbound['tag'] == 'Germany',
      );
      final xconfig = germany['xconfig'] as Map<String, dynamic>;
      final xout = (xconfig['outbounds'] as List<dynamic>).whereType<Map>().single;
      final stream = xout['streamSettings'] as Map<String, dynamic>;
      final tls = stream['tlsSettings'] as Map<String, dynamic>;
      final xhttp = stream['xhttpSettings'] as Map<String, dynamic>;

      expect(tls['alpn'], ['http/1.1']);
      expect(tls['fingerprint'], 'firefox');
      expect(xhttp['mode'], 'packet-up');
    });

    test('removes TURNcoat dependencies that belong to another selected server', () {
      final raw = jsonEncode({
        'servers': [
          {'tag': 'Plain'},
          {'tag': 'Turn'},
        ],
        'outbounds': [
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['Plain', 'Turn'],
          },
          {'type': 'vless', 'tag': 'Plain', 'server': 'plain.example', 'server_port': 443},
          {
            'type': 'hysteria2',
            'tag': 'Turn',
            'server': 'turn-backend.example',
            'server_port': 443,
            'detour': 'Turn transport §hide§',
          },
          {'type': 'turncoat', 'tag': 'Turn transport §hide§', 'server': 'turn.example', 'server_port': 3478},
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Plain')) as Map<String, dynamic>;
      final outbounds = prepared['outbounds'] as List<dynamic>;
      final tags = outbounds.whereType<Map>().map((outbound) => outbound['tag']?.toString()).toList();
      final types = outbounds.whereType<Map>().map((outbound) => outbound['type']?.toString()).toList();

      expect(tags, contains('Plain'));
      expect(tags, isNot(contains('Turn')));
      expect(tags, isNot(contains('Turn transport §hide§')));
      expect(types, isNot(contains('turncoat')));
      expect(selectedOutboundUsesTurncoat(raw, 'Plain'), isFalse);
    });

    test('keeps TURNcoat dependency for the selected server and detects it', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['Plain', 'Turn'],
          },
          {'type': 'vless', 'tag': 'Plain', 'server': 'plain.example', 'server_port': 443},
          {
            'type': 'hysteria2',
            'tag': 'Turn',
            'server': 'turn-backend.example',
            'server_port': 443,
            'detour': 'Turn transport §hide§',
          },
          {'type': 'turncoat', 'tag': 'Turn transport §hide§', 'server': 'turn.example', 'server_port': 3478},
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Turn')) as Map<String, dynamic>;
      final outbounds = prepared['outbounds'] as List<dynamic>;
      final tags = outbounds.whereType<Map>().map((outbound) => outbound['tag']?.toString()).toList();

      expect(tags, contains('Turn'));
      expect(tags, contains('Turn transport §hide§'));
      expect(tags, isNot(contains('Plain')));
      expect(selectedOutboundUsesTurncoat(raw, 'Turn'), isTrue);
    });

    test('detects TURNcoat dependency from nested detour fields', () {
      final raw = jsonEncode({
        'outbounds': [
          {
            'type': 'amneziawg',
            'tag': 'Turn AWG',
            'server': 'turn-backend.example',
            'server_port': 443,
            'dialer_options': {'detour': 'Turn transport §hide§'},
          },
          {'type': 'turncoat', 'tag': 'Turn transport §hide§', 'server': 'turn.example', 'server_port': 3478},
        ],
      });

      final prepared = jsonDecode(prepareConfigForSelectedOutbound(raw, 'Turn AWG')) as Map<String, dynamic>;
      final outbounds = prepared['outbounds'] as List<dynamic>;
      final tags = outbounds.whereType<Map>().map((outbound) => outbound['tag']?.toString()).toList();

      expect(tags, contains('Turn AWG'));
      expect(tags, contains('Turn transport §hide§'));
      expect(selectedOutboundUsesTurncoat(raw, 'Turn AWG'), isTrue);
    });

    test('keeps selected TURNcoat route across supported backend protocols', () {
      const cases = [
        (type: 'vless', name: 'VLESS', nestedDetour: false),
        (type: 'hysteria2', name: 'Hysteria2', nestedDetour: false),
        (type: 'wireguard', name: 'WireGuard', nestedDetour: true),
        (type: 'amneziawg', name: 'AWG', nestedDetour: true),
        (type: 'trojan', name: 'Trojan', nestedDetour: false),
        (type: 'tuic', name: 'TUIC', nestedDetour: false),
      ];

      for (final item in cases) {
        final plainTag = '${item.name} Plain';
        final turnTag = '${item.name} Turn';
        final helperTag = '${item.name} transport §hide§';
        final turnOutbound = <String, dynamic>{
          'type': item.type,
          'tag': turnTag,
          'server': 'turn-${item.type}.example',
          'server_port': 443,
          if (item.nestedDetour) 'dialer_options': {'detour': helperTag} else 'detour': helperTag,
        };
        final raw = jsonEncode({
          'outbounds': [
            {
              'type': 'selector',
              'tag': 'select',
              'outbounds': [plainTag, turnTag],
            },
            {'type': item.type, 'tag': plainTag, 'server': 'plain-${item.type}.example', 'server_port': 443},
            turnOutbound,
            {'type': 'turncoat', 'tag': helperTag, 'server': 'turn.example', 'server_port': 3478},
          ],
        });

        final plainPrepared = jsonDecode(prepareConfigForSelectedOutbound(raw, plainTag)) as Map<String, dynamic>;
        final plainTags = (plainPrepared['outbounds'] as List<dynamic>)
            .whereType<Map>()
            .map((outbound) => outbound['tag']?.toString())
            .toList();

        expect(plainTags, contains(plainTag), reason: item.name);
        expect(plainTags, isNot(contains(turnTag)), reason: item.name);
        expect(plainTags, isNot(contains(helperTag)), reason: item.name);
        expect(selectedOutboundUsesTurncoat(raw, plainTag), isFalse, reason: item.name);

        final turnPrepared = jsonDecode(prepareConfigForSelectedOutbound(raw, turnTag)) as Map<String, dynamic>;
        final turnTags = (turnPrepared['outbounds'] as List<dynamic>)
            .whereType<Map>()
            .map((outbound) => outbound['tag']?.toString())
            .toList();

        expect(turnTags, contains(turnTag), reason: item.name);
        expect(turnTags, contains(helperTag), reason: item.name);
        expect(turnTags, isNot(contains(plainTag)), reason: item.name);
        expect(selectedOutboundUsesTurncoat(raw, turnTag), isTrue, reason: item.name);
      }
    });
  });
}

String _validLocalOutboundsJsonOfLength(int length) {
  final config = {
    'outbounds': [
      {'type': 'vless', 'tag': 'Alpha', 'server': 'alpha.example', 'server_port': 443},
    ],
    'padding': '',
  };
  final emptyPaddingConfig = jsonEncode(config);
  final paddingLength = length - emptyPaddingConfig.length;
  if (paddingLength < 0) {
    throw ArgumentError.value(length, 'length', 'must fit the valid config envelope');
  }

  config['padding'] = List<String>.filled(paddingLength, 'x').join();
  final raw = jsonEncode(config);
  if (raw.length != length) {
    throw StateError('expected $length bytes of ASCII JSON, got ${raw.length}');
  }
  return raw;
}

List<({String tag, String type, String server, int port, String? tlsServerName, bool usesTurncoat})>
_outboundSignatures(List<LocalOutbound> outbounds) => [
  for (final outbound in outbounds)
    (
      tag: outbound.tag,
      type: outbound.type,
      server: outbound.server,
      port: outbound.serverPort,
      tlsServerName: outbound.tlsServerName,
      usesTurncoat: outbound.usesTurncoat,
    ),
];
