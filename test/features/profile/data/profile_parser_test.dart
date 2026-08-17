import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/core/http_client/dio_http_client.dart';
import 'package:marten/core/http_client/http_client_provider.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/features/profile/data/profile_parser.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class _ProfileParserContext {
  _ProfileParserContext({required this.parser, required this.ref});

  final ProfileParser parser;
  final Ref<Object?> ref;
}

class _RecordingRef implements Ref<Object?> {
  _RecordingRef(this._container);

  final ProviderContainer _container;

  @override
  ProviderContainer get container => _container;

  @override
  T refresh<T>(Refreshable<T> provider) {
    return _container.refresh(provider);
  }

  @override
  void invalidate(ProviderOrFamily provider) {
    _container.invalidate(provider);
  }

  @override
  void notifyListeners() {
    throw UnsupportedError('notifyListeners is not implemented in this test helper');
  }

  @override
  void listenSelf(
    void Function(Object? previous, Object? next) listener, {
    void Function(Object, StackTrace)? onError,
  }) {
    throw UnsupportedError('listenSelf is not implemented in this test helper');
  }

  @override
  void invalidateSelf() {
    throw UnsupportedError('invalidateSelf is not implemented in this test helper');
  }

  @override
  void onAddListener(void Function() cb) {
    throw UnsupportedError('onAddListener is not implemented in this test helper');
  }

  @override
  void onRemoveListener(void Function() cb) {
    throw UnsupportedError('onRemoveListener is not implemented in this test helper');
  }

  @override
  void onResume(void Function() cb) {
    throw UnsupportedError('onResume is not implemented in this test helper');
  }

  @override
  void onCancel(void Function() cb) {
    throw UnsupportedError('onCancel is not implemented in this test helper');
  }

  @override
  void onDispose(void Function() cb) {
    throw UnsupportedError('onDispose is not implemented in this test helper');
  }

  @override
  T read<T>(ProviderListenable<T> provider) {
    return _container.read(provider);
  }

  @override
  bool exists(ProviderBase<Object?> provider) {
    return _container.exists(provider);
  }

  @override
  T watch<T>(ProviderListenable<T> provider) {
    return _container.read(provider);
  }

  @override
  KeepAliveLink keepAlive() {
    throw UnsupportedError('keepAlive is not implemented in this test helper');
  }

  @override
  ProviderSubscription<T> listen<T>(
    ProviderListenable<T> provider,
    void Function(T? previous, T next) listener, {
    void Function(Object error, StackTrace stackTrace)? onError,
    bool fireImmediately = false,
  }) {
    return _container.listen<T>(provider, listener, onError: onError, fireImmediately: fireImmediately);
  }
}

List<String> _linesWithoutTerminalNewline(String text) {
  final lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

class _DownloadCall {
  _DownloadCall({required this.url, required this.method, required this.extraHeaders});

  final String url;
  final String method;
  final Map<String, String> extraHeaders;
}

class _TrackingDioHttpClient extends DioHttpClient {
  _TrackingDioHttpClient({this.body = '{"outbounds":[{"type":"direct","tag":"direct"}]'})
    : super(timeout: const Duration(milliseconds: 1), userAgent: "Marten-Test", debug: false);

  final String body;
  final calls = <_DownloadCall>[];

  @override
  Future<Response> download(
    String url,
    String path, {
    String method = 'GET',
    Object? data,
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
    bool proxyOnly = false,
  }) async {
    calls.add(_DownloadCall(url: url, method: method, extraHeaders: Map<String, String>.from(extraHeaders ?? {})));
    await File(path).writeAsString(body);
    return Response(
      requestOptions: RequestOptions(path: url),
      statusCode: 200,
      data: null,
      headers: Headers(),
    );
  }
}

class _ScriptedDioHttpClient extends _TrackingDioHttpClient {
  _ScriptedDioHttpClient({required this.outcomes, super.body});

  final List<Object?> outcomes;
  var _outcomeIndex = 0;

  @override
  Future<Response> download(
    String url,
    String path, {
    String method = 'GET',
    Object? data,
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
    bool proxyOnly = false,
  }) async {
    calls.add(_DownloadCall(url: url, method: method, extraHeaders: Map<String, String>.from(extraHeaders ?? {})));
    final outcome = outcomes[_outcomeIndex++];
    if (outcome != null) throw outcome;
    await File(path).writeAsString(body);
    return Response(
      requestOptions: RequestOptions(path: url),
      statusCode: 200,
      headers: Headers(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProfileParser> newParser(_TrackingDioHttpClient httpClient) async {
    SharedPreferences.setMockInitialValues({});
    final sharedPreferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((_) => Future.value(sharedPreferences)),
        deviceIdentityProvider.overrideWith(
          (ref) => Future.value(
            const DeviceIdentity(deviceId: 'device-id-for-tests', clientSecret: 'client-secret-for-tests'),
          ),
        ),
        httpClientProvider.overrideWithValue(httpClient),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    return container.read(profileParserProvider);
  }

  Future<_ProfileParserContext> newParserWithRef(_TrackingDioHttpClient httpClient) async {
    SharedPreferences.setMockInitialValues({});
    final sharedPreferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((_) => Future.value(sharedPreferences)),
        deviceIdentityProvider.overrideWith(
          (ref) => Future.value(
            const DeviceIdentity(deviceId: 'device-id-for-tests', clientSecret: 'client-secret-for-tests'),
          ),
        ),
        httpClientProvider.overrideWithValue(httpClient),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    final ref = _RecordingRef(container);
    return _ProfileParserContext(
      parser: ProfileParser(ref: ref, httpClient: container.read(httpClientProvider)),
      ref: ref,
    );
  }

  const validBaseUrl = "https://example.com/configurations/user1/filename.yaml";
  const validExtendedUrl = "https://example.com/configurations/user1/filename.yaml?test#b";
  const validSupportUrl = "https://example.com/support";

  group("parse", () {
    test("Should use filename in url with no headers and fragment", () {
      final profile = ProfileParser.parse(
        tempFilePath: '',
        profile: ProfileEntity.remote(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: validBaseUrl,
          lastUpdate: DateTime.now(),
        ),
      );
      expect(profile.isRight(), true);
      profile.match((l) {}, (r) {
        expect(r is RemoteProfileEntity, true);
        r.map(
          remote: (rp) {
            expect(rp.name, equals("filename"));
            expect(rp.url, equals(validBaseUrl));
            expect(rp.options, equals(const ProfileOptions(updateInterval: Duration(hours: 1))));
            expect(rp.subInfo, isNull);
            expect(rp.expiresAt, isNull);
          },
          local: (lp) {},
        );
      });
    });

    test("Should use fragment in url with no headers", () {
      final profile = ProfileParser.parse(
        tempFilePath: '',
        profile: ProfileEntity.remote(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: validExtendedUrl,
          lastUpdate: DateTime.now(),
        ),
      );
      expect(profile.isRight(), true);
      profile.match((l) {}, (r) {
        expect(r is RemoteProfileEntity, true);
        r.map(
          remote: (rp) {
            expect(rp.name, equals("b"));
            expect(rp.url, equals(validExtendedUrl));
            expect(rp.options, equals(const ProfileOptions(updateInterval: Duration(hours: 1))));
            expect(rp.subInfo, isNull);
          },
          local: (lp) {},
        );
      });
    });

    test("Should use base64 title in headers", () {
      final headers = <String, List<String>>{
        "profile-title": ["base64:ZXhhbXBsZVRpdGxl"],
        "profile-update-interval": ["1"],
        "connection-test-url": [validBaseUrl],
        "Remote-Dns-Address": ["tcp://1.1.1.1"],
        "Direct-Dns-Address": ["udp://1.1.1.1"],
        "subscription-userinfo": ["upload=0;download=1024;total=10240.5;expire=1704054600.55"],
        "profile-web-page-url": [validBaseUrl],
        "support-url": [validSupportUrl],
      };
      // This fix occurs in the _downloadProfile method within ProfileParser, and the fixed headers are passed to populateHeaders
      final fixedHeaders = headers.map((key, value) {
        if (value.length == 1) return MapEntry(key, value.first);
        return MapEntry(key, value);
      });
      final allHeaders = ProfileParser.populateHeaders(content: '', remoteHeaders: fixedHeaders);
      expect(allHeaders.isRight(), true);
      allHeaders.match((l) {}, (r) {
        final profile = ProfileParser.parse(
          tempFilePath: '',
          profile: ProfileEntity.remote(
            id: const Uuid().v4(),
            active: true,
            name: '',
            url: validExtendedUrl,
            lastUpdate: DateTime.now(),
            populatedHeaders: r,
          ),
        );
        expect(profile.isRight(), true);
        profile.match((l) {}, (r) {
          expect(r is RemoteProfileEntity, true);
          r.map(
            remote: (rp) {
              expect(rp.name, equals("exampleTitle"));
              expect(rp.url, equals(validExtendedUrl));
              expect(rp.profileOverride, contains('"remote-dns-address":"tcp://1.1.1.1"'));
              expect(rp.profileOverride, contains('"direct-dns-address":"udp://1.1.1.1"'));
              expect(rp.options, equals(const ProfileOptions(updateInterval: Duration(hours: 1))));
              expect(
                rp.subInfo,
                equals(
                  SubscriptionInfo(
                    upload: 0,
                    download: 1024,
                    total: 10240,
                    expire: DateTime.fromMillisecondsSinceEpoch(1704054600 * 1000),
                    webPageUrl: validBaseUrl,
                    supportUrl: validSupportUrl,
                  ),
                ),
              );
            },
            local: (lp) {},
          );
        });
      });
    });

    test("Should use infinite when given 0 for subscription properties", () {
      final headers = <String, List<String>>{
        "profile-title": ["title"],
        "profile-update-interval": ["1"],
        "subscription-userinfo": ["upload=0;download=1024;total=0;expire=0"],
        "profile-web-page-url": [validBaseUrl],
        "support-url": [validSupportUrl],
      };
      // This fix occurs in the _downloadProfile method within ProfileParser, and the fixed headers are passed to populateHeaders
      final fixedHeaders = headers.map((key, value) {
        if (value.length == 1) return MapEntry(key, value.first);
        return MapEntry(key, value);
      });
      final allHeaders = ProfileParser.populateHeaders(content: '', remoteHeaders: fixedHeaders);
      expect(allHeaders.isRight(), true);
      allHeaders.match((l) {}, (r) {
        final profile = ProfileParser.parse(
          tempFilePath: '',
          profile: RemoteProfileEntity(
            id: const Uuid().v4(),
            active: true,
            name: '',
            url: validBaseUrl,
            lastUpdate: DateTime.now(),
            populatedHeaders: r,
          ),
        );
        expect(profile.isRight(), true);
        profile.match((l) {}, (r) {
          expect(r is RemoteProfileEntity, true);
          r.map(
            remote: (rp) {
              expect(rp.subInfo, isNotNull);
              expect(rp.subInfo!.total, equals(ProfileParser.infiniteTrafficThreshold + 1));
              expect(
                rp.subInfo!.expire,
                equals(DateTime.fromMillisecondsSinceEpoch(ProfileParser.infiniteTimeThreshold * 1000)),
              );
            },
            local: (lp) {},
          );
        });
      });
    });

    test("Should map Marten split tunnel bypass apps to profile override", () {
      final file = File('${Directory.systemTemp.path}/marten-split-tunnel-test.json');
      file.writeAsStringSync('''
{
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "split_tunnel": {
    "bypass_apps": ["ru.sberbankmobile", "com.example.app", "bad package", "ru.sberbankmobile"]
  }
}
''');
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });

      final profile = ProfileParser.parse(
        tempFilePath: file.path,
        profile: ProfileEntity.remote(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: validBaseUrl,
          lastUpdate: DateTime.now(),
        ),
      );

      expect(profile.isRight(), true);
      profile.match((l) {}, (r) {
        final rp = r as RemoteProfileEntity;
        expect(rp.profileOverride, contains('"exclude-package":["ru.sberbankmobile","com.example.app"]'));
      });
    });

    test("Should strip Marten split tunnel metadata before handing config to core", () {
      const content = '''
{
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "split_tunnel": {
    "bypass_apps": ["ru.sberbankmobile"]
  }
}
''';

      final stripped = ProfileParser.stripMartenSubscriptionMetadata(content);
      final decoded = jsonDecode(stripped) as Map<String, dynamic>;

      expect(decoded, isNot(contains('split_tunnel')));
      expect(decoded['outbounds'], isA<List<dynamic>>());
    });

    test("Should strip Marten server metadata before handing config to core", () {
      const content = '''
{
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "servers": [
    {
      "tag": "direct",
      "tunnel_ping_url": "http://example.net:9443/tunnel/ping"
    }
  ]
}
''';

      final stripped = ProfileParser.stripMartenSubscriptionMetadata(content);
      final decoded = jsonDecode(stripped) as Map<String, dynamic>;

      expect(decoded, isNot(contains('servers')));
      expect(decoded['outbounds'], isA<List<dynamic>>());
    });

    test("Should strip Marten subscription endpoint metadata before handing config to core", () {
      const content = '''
{
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "subscription": {
    "endpoints": ["https://sub-a.example.net", "https://sub-b.example.net"]
  }
}
''';

      final stripped = ProfileParser.stripMartenSubscriptionMetadata(content);
      final decoded = jsonDecode(stripped) as Map<String, dynamic>;

      expect(decoded, isNot(contains('subscription')));
      expect(decoded['outbounds'], isA<List<dynamic>>());
    });

    test("Should strip Marten metadata from null-padded JSON before handing config to core", () {
      final content =
          '${jsonEncode({
            'outbounds': [
              {'type': 'direct', 'tag': 'direct'},
            ],
            'split_tunnel': {
              'bypass_apps': ['ru.sberbankmobile'],
            },
            'servers': [
              {'tag': 'direct'},
            ],
          })}\u0000\u0000{"stale":"tail"}';

      final stripped = ProfileParser.stripMartenSubscriptionMetadata(content);
      final decoded = jsonDecode(stripped) as Map<String, dynamic>;

      expect(stripped, isNot(contains('\u0000')));
      expect(decoded, isNot(contains('split_tunnel')));
      expect(decoded, isNot(contains('servers')));
      expect(decoded['outbounds'], isA<List<dynamic>>());
    });

    test("Should normalize stored Marten subscription JSON without dropping app metadata", () {
      final content =
          '${jsonEncode({
            'outbounds': [
              {'type': 'direct', 'tag': 'direct'},
            ],
            'split_tunnel': {
              'bypass_apps': ['ru.sberbankmobile'],
            },
          })}\u0000\u0000{"stale":"tail"}';

      final normalized = ProfileParser.normalizeMartenSubscriptionContent(content);
      final decoded = jsonDecode(normalized) as Map<String, dynamic>;

      expect(normalized, isNot(contains('\u0000')));
      expect(decoded, contains('split_tunnel'));
      expect(decoded['outbounds'], isA<List<dynamic>>());
    });

    test('Should remove unknown outbounds and their dependent references while preserving supported outbounds', () {
      const content = '''
{
  "outbounds": [
    {"type": "wireguard", "tag": "wg"},
    {"type": "icmp", "tag": "icmp"},
    {"type": "future-vpn", "tag": "future"},
    {"type": "vless", "tag": "via-future", "detour": "future"},
    {"type": "wireguard", "tag": "via-via-future", "detour": "via-future"},
    {"type": "selector", "tag": "choose", "outbounds": ["wg", "future", "via-future"], "default": "future"},
    {"type": "urltest", "tag": "test", "outbounds": ["icmp", "future", "via-via-future"]}
  ],
  "servers": [
    {"tag": "wg"},
    {"tag": "icmp"},
    {"tag": "future"},
    {"tag": "via-future"},
    {"tag": "via-via-future"}
  ]
}
''';

      final normalized = jsonDecode(ProfileParser.normalizeMartenSubscriptionContent(content)) as Map<String, dynamic>;
      final outbounds = normalized['outbounds'] as List<dynamic>;
      final byTag = {for (final outbound in outbounds) (outbound as Map<String, dynamic>)['tag'] as String: outbound};

      expect(byTag.keys, unorderedEquals(['wg', 'icmp', 'choose', 'test']));
      expect((byTag['wg']!['type']), 'wireguard');
      expect((byTag['icmp']!['type']), 'icmp');
      expect(byTag['choose']!['outbounds'], ['wg']);
      expect(byTag['choose'], isNot(contains('default')));
      expect(byTag['test']!['outbounds'], ['icmp']);
      expect(
        (normalized['servers'] as List<dynamic>).map((server) => (server as Map<String, dynamic>)['tag']),
        unorderedEquals(['wg', 'icmp']),
      );

      final coreConfig = jsonDecode(ProfileParser.stripMartenSubscriptionMetadata(content)) as Map<String, dynamic>;
      expect(coreConfig, isNot(contains('servers')));
      expect(
        (coreConfig['outbounds'] as List<dynamic>).map(
          (outbound) => (outbound as Map<String, dynamic>)['tag'] as String,
        ),
        unorderedEquals(['wg', 'icmp', 'choose', 'test']),
      );
    });

    test('Should fail closed when all subscription outbounds are unknown', () {
      const content = '''
{
  "outbounds": [
    {"type": "future-vpn", "tag": "future"},
    {"type": "another-future-vpn", "tag": "future-dependent", "detour": "future"}
  ],
  "servers": [{"tag": "future"}, {"tag": "future-dependent"}]
}
''';

      final normalized = jsonDecode(ProfileParser.normalizeMartenSubscriptionContent(content)) as Map<String, dynamic>;
      expect(normalized['outbounds'], isEmpty);
      expect(normalized['servers'], isEmpty);

      final coreConfig = jsonDecode(ProfileParser.stripMartenSubscriptionMetadata(content)) as Map<String, dynamic>;
      expect(coreConfig['outbounds'], isEmpty);
      expect(coreConfig, isNot(contains('servers')));
      expect(ProfileParser.validateBackgroundCandidate(content).isLeft(), isTrue);
    });

    test("Should read LB endpoints from Marten subscription metadata", () {
      final endpoints = ProfileParser.subscriptionEndpointsFromContent('''
{
  "subscription": {
    "endpoints": [
      "https://sub-a.example.net",
      "https://sub-a.example.net/",
      "https://sub-b.example.net"
    ]
  }
}
''');

      expect(endpoints, ["https://sub-a.example.net", "https://sub-b.example.net"]);
    });

    test("Should use Marten subscription metadata name and expiration", () {
      final file = File('${Directory.systemTemp.path}/marten-subscription-metadata-test.json');
      file.writeAsStringSync('''
{
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "subscription": {
    "name": "Семейный VPN",
    "expires_at": "2026-08-14T18:45:00Z"
  }
}
''');
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });

      final profile = ProfileParser.parse(
        tempFilePath: file.path,
        profile: ProfileEntity.remote(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: 'https://edge.example.com/sub/secret-token',
          lastUpdate: DateTime.now(),
        ),
      );

      expect(profile.isRight(), true);
      profile.match((l) => fail('parse failed: $l'), (r) {
        final rp = r as RemoteProfileEntity;
        expect(rp.name, 'Семейный VPN');
        expect(rp.expiresAt?.toUtc(), DateTime.utc(2026, 8, 14, 18, 45));
        expect(rp.subInfo, isNull);
      });
    });

    test("Should keep server subscription name identical despite a local user override", () {
      final file = File('${Directory.systemTemp.path}/marten-subscription-name-override-test.json');
      file.writeAsStringSync('''
{
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "subscription": {"name": "Server name"}
}
''');
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });

      final profile = ProfileParser.parse(
        tempFilePath: file.path,
        profile: ProfileEntity.remote(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: 'https://edge.example.com/sub/secret-token',
          lastUpdate: DateTime.now(),
          userOverride: const UserOverride(name: 'My override'),
        ),
      );

      profile.match((l) => fail('parse failed: $l'), (r) => expect(r.name, 'Server name'));
    });

    test('Should keep UserOverride.pushEndpoint on parse', () {
      final override = const UserOverride(name: 'Manual name', pushEndpoint: 'https://push.example.net/register');
      final profile = ProfileParser.parse(
        tempFilePath: '',
        profile: ProfileEntity.remote(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: validBaseUrl,
          lastUpdate: DateTime.now(),
          userOverride: override,
        ),
      );

      expect(profile.isRight(), isTrue);
      profile.match((l) => fail('parse failed: $l'), (r) {
        final rp = r as RemoteProfileEntity;
        expect(rp.userOverride, equals(override));
      });
    });

    test('Should round-trip UserOverride JSON with pushEndpoint', () {
      final override = const UserOverride(
        name: 'Manual name',
        pushEndpoint: 'https://push.example.net/register',
        isAutoUpdateDisable: false,
      );
      final serialized = override.toStr();
      final parsed = UserOverride.fromStr(serialized);

      expect(parsed, isNotNull);
      expect(parsed?.name, equals(override.name));
      expect(parsed?.pushEndpoint, equals(override.pushEndpoint));
      expect(parsed?.version, equals(latestUserOverrideVersion));
    });

    test('Should preserve UserOverride.pushEndpoint from legacy JSON', () {
      final parsed = UserOverride.fromStr('''{
        "version":1,
        "name":"Legacy",
        "pushEndpoint":"https://push.example.net/legacy"
      }''');

      expect(parsed, isNotNull);
      expect(parsed?.name, equals('Legacy'));
      expect(parsed?.pushEndpoint, equals('https://push.example.net/legacy'));
      expect(parsed?.version, equals(latestUserOverrideVersion));
    });

    test("Should read split_tunneling alias from subscription metadata", () {
      final apps = ProfileParser.splitTunnelBypassApps('''
{
  "split_tunneling": {
    "bypass_apps": "com.example.app"
  }
}
''');

      expect(apps, ['com.example.app']);
    });

    test("Should use default auto update interval when server does not provide one", () {
      final profile = ProfileParser.parse(
        tempFilePath: '',
        profile: ProfileEntity.remote(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: validBaseUrl,
          lastUpdate: DateTime.now(),
        ),
      );

      expect(profile.isRight(), true);
      profile.match((l) {}, (r) {
        final rp = r as RemoteProfileEntity;
        expect(rp.options, equals(ProfileOptions(updateInterval: ProfileParser.defaultUpdateInterval)));
      });
    });

    test("Should preserve profile-title, URL, and metadata on remote parse without user override", () {
      final tempFile = File('${Directory.systemTemp.path}/marten-profile-title-metadata.json');
      const rawContent = '''
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "Berlin § 0",
      "server": "edge.example.net",
      "server_port": 443
    }
  ],
  "split_tunnel": {
    "bypass_apps": ["com.example.app"]
  },
  "subscription": {
    "expires_at": "2026-08-14T18:45:00Z"
  }
}
''';
      tempFile.writeAsStringSync(rawContent);
      addTearDown(() {
        if (tempFile.existsSync()) {
          tempFile.deleteSync();
        }
      });

      final headers = <String, List<String>>{
        "profile-title": ["base64:0JzQvtC5IFZQTg=="],
        "subscription-userinfo": ["upload=100;download=200;total=300;expire=1704054600.55"],
        "profile-web-page-url": [validBaseUrl],
        "support-url": [validSupportUrl],
        "remote-dns-address": ["udp://8.8.8.8"],
        "direct-dns-address": ["udp://9.9.9.9"],
      };
      final fixedHeaders = headers.map((key, value) {
        if (value.length == 1) return MapEntry(key, value.first);
        return MapEntry(key, value);
      });
      final allHeaders = ProfileParser.populateHeaders(content: rawContent, remoteHeaders: fixedHeaders);
      expect(allHeaders.isRight(), true);

      allHeaders.match((l) => fail('populateHeaders failed: $l'), (populated) {
        final profile = ProfileParser.parse(
          tempFilePath: tempFile.path,
          profile: ProfileEntity.remote(
            id: const Uuid().v4(),
            active: true,
            name: '',
            url: validBaseUrl,
            lastUpdate: DateTime.now(),
            populatedHeaders: populated,
          ),
        );

        expect(profile.isRight(), isTrue);
        profile.match((l) => fail('parse failed: $l'), (r) {
          final rp = r as RemoteProfileEntity;
          expect(rp.name, equals("Мой VPN"));
          expect(rp.url, equals(validBaseUrl));
          expect(rp.options, equals(ProfileOptions(updateInterval: ProfileParser.defaultUpdateInterval)));
          expect(rp.expiresAt, isNotNull);
          expect(rp.subInfo?.upload, 100);
          expect(rp.subInfo?.download, 200);
          expect(rp.subInfo?.total, 300);
          expect(
            rp.subInfo?.expire,
            equals(DateTime.fromMillisecondsSinceEpoch(1704054600 * 1000, isUtc: true).toLocal()),
          );
          expect(rp.subInfo?.webPageUrl, equals(validBaseUrl));
          expect(rp.subInfo?.supportUrl, equals(validSupportUrl));
          expect(rp.profileOverride, contains('"remote-dns-address":"udp://8.8.8.8"'));
          expect(rp.profileOverride, contains('"direct-dns-address":"udp://9.9.9.9"'));
          expect(rp.profileOverride, contains('"exclude-package":["com.example.app"]'));
        });
      });
    });

    test("Should disable auto update when user override requests it", () {
      final profile = ProfileParser.parse(
        tempFilePath: '',
        profile: ProfileEntity.remote(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: validBaseUrl,
          lastUpdate: DateTime.now(),
          userOverride: const UserOverride(isAutoUpdateDisable: true),
        ),
      );

      expect(profile.isRight(), true);
      profile.match((l) {}, (r) {
        final rp = r as RemoteProfileEntity;
        expect(rp.options, isNull);
      });
    });

    test("Should build refresh endpoint for Marten subscription URLs", () {
      expect(
        ProfileParser.refreshUrlFor("https://edge.example.com/sub/token-1")?.toString(),
        equals("https://edge.example.com/sub/token-1/refresh"),
      );
      expect(ProfileParser.refreshUrlFor("https://edge.example.com/api/sub/token-1"), isNull);
      expect(ProfileParser.refreshUrlFor("vless://example"), isNull);
    });

    test("Should extract subscription URL from Marten import redirect location", () {
      expect(
        ProfileParser.martenImportRedirectTarget("marten://import?url=https://edge.example.com/sub/token-1&name=Smoke"),
        equals("https://edge.example.com/sub/token-1"),
      );
      expect(ProfileParser.martenImportRedirectTarget("marten://import?url=turncoat://payload"), isNull);
      expect(ProfileParser.martenImportRedirectTarget("https://edge.example.com/sub/token-1"), isNull);
    });

    test("Should derive download URL from Marten public import URL", () {
      expect(
        ProfileParser.martenImportDownloadTarget("https://edge.example.com/sub/token-1/import"),
        equals("https://edge.example.com/sub/token-1"),
      );
      expect(ProfileParser.martenImportDownloadTarget("https://edge.example.com/sub/token-1"), isNull);
      expect(ProfileParser.martenImportDownloadTarget("https://edge.example.com/api/sub/token-1/import"), isNull);
    });

    test("Should include X-Marten-Capabilities with ICMP-v1 in remote import request headers", () async {
      final httpClient = _TrackingDioHttpClient();
      final parser = await newParser(httpClient);
      final directory = await Directory.systemTemp.createTemp('marten-profile-parser-header-test-');
      addTearDown(() => directory.delete(recursive: true));
      final tempFilePath = '${directory.path}/remote-profile.json';

      final result = await parser
          .addRemote(
            id: const Uuid().v4(),
            url: "https://edge.example.com/sub/token-1",
            tempFilePath: tempFilePath,
            userOverride: null,
          )
          .run();

      result.match((l) => fail('addRemote failed: $l'), (r) {});
      expect(httpClient.calls, hasLength(1));
      final call = httpClient.calls.single;
      expect(call.method, equals("GET"));
      expect(call.url, equals("https://edge.example.com/sub/token-1"));
      expect(call.extraHeaders, containsPair("X-Device-ID", "device-id-for-tests"));
      expect(call.extraHeaders, containsPair("X-Client-Secret", "client-secret-for-tests"));
      expect(call.extraHeaders["X-Marten-Capabilities"], contains('icmp-v1'));
    });

    test("Should include X-Marten-Capabilities with ICMP-v1 in remote refresh request headers", () async {
      final httpClient = _TrackingDioHttpClient();
      final parser = await newParser(httpClient);
      final directory = await Directory.systemTemp.createTemp('marten-profile-parser-header-test-refresh-');
      addTearDown(() => directory.delete(recursive: true));
      final tempFilePath = '${directory.path}/remote-profile.json';

      final profile = RemoteProfileEntity(
        id: const Uuid().v4(),
        active: true,
        name: '',
        url: "https://edge.example.com/sub/token-1",
        lastUpdate: DateTime.now(),
      );

      final result = await parser.updateRemote(rp: profile, tempFilePath: tempFilePath).run();

      result.match((l) => fail('updateRemote failed: $l'), (r) {});
      expect(httpClient.calls, hasLength(1));
      final call = httpClient.calls.single;
      expect(call.method, equals("POST"));
      expect(call.url, equals("https://edge.example.com/sub/token-1/refresh"));
      expect(call.extraHeaders, containsPair("X-Device-ID", "device-id-for-tests"));
      expect(call.extraHeaders, containsPair("X-Client-Secret", "client-secret-for-tests"));
      expect(call.extraHeaders["X-Marten-Capabilities"], contains('icmp-v1'));
    });

    test('Should fall back from a connection-error refresh POST to one canonical GET', () async {
      const candidateUrl = 'https://edge.example.com/sub/token-1';
      final httpClient = _ScriptedDioHttpClient(
        outcomes: [
          DioException(
            requestOptions: RequestOptions(path: '$candidateUrl/refresh'),
            type: DioExceptionType.connectionError,
          ),
          null,
        ],
      );
      final parser = await newParser(httpClient);
      final directory = await Directory.systemTemp.createTemp('marten-profile-parser-refresh-fallback-');
      addTearDown(() => directory.delete(recursive: true));
      final profile = RemoteProfileEntity(
        id: const Uuid().v4(),
        active: true,
        name: '',
        url: candidateUrl,
        lastUpdate: DateTime.now(),
      );

      final result = await parser
          .updateRemote(rp: profile, tempFilePath: '${directory.path}/remote-profile.json')
          .run();

      result.match((failure) => fail('updateRemote failed: $failure'), (_) {});
      expect(httpClient.calls, hasLength(2));
      expect(httpClient.calls.map((call) => call.method), ['POST', 'GET']);
      expect(httpClient.calls.map((call) => call.url), ['$candidateUrl/refresh', candidateUrl]);
    });

    test('Should not use canonical GET fallback for terminal refresh failures', () async {
      const candidateUrl = 'https://edge.example.com/sub/token-1';
      final terminalFailures = [
        DioException(
          requestOptions: RequestOptions(path: '$candidateUrl/refresh'),
          type: DioExceptionType.cancel,
        ),
        DioException(
          requestOptions: RequestOptions(path: '$candidateUrl/refresh'),
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: RequestOptions(path: '$candidateUrl/refresh'), statusCode: 403),
        ),
        DioException(
          requestOptions: RequestOptions(path: '$candidateUrl/refresh'),
          type: DioExceptionType.badCertificate,
        ),
        DioException(
          requestOptions: RequestOptions(path: '$candidateUrl/refresh'),
          type: DioExceptionType.connectionTimeout,
        ),
      ];

      for (final failure in terminalFailures) {
        final httpClient = _ScriptedDioHttpClient(outcomes: [failure]);
        final parser = await newParser(httpClient);
        final directory = await Directory.systemTemp.createTemp('marten-profile-parser-terminal-refresh-');
        addTearDown(() => directory.delete(recursive: true));
        final profile = RemoteProfileEntity(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: candidateUrl,
          lastUpdate: DateTime.now(),
        );

        final result = await parser
            .updateRemote(rp: profile, tempFilePath: '${directory.path}/remote-profile.json')
            .run();

        expect(result.isLeft(), isTrue);
        expect(httpClient.calls, hasLength(1));
        expect(httpClient.calls.single.method, 'POST');
        expect(httpClient.calls.single.url, '$candidateUrl/refresh');
      }
    });

    test('should fail remote update when all responses are unsupported client markers', () async {
      const candidateUrl = 'https://edge.example.com/sub/token-1';
      final unsupportedContent = base64Encode(
        utf8.encode(
          'vless://11111111-1111-2222-3333-444455556666@edge.example.com:443#${Uri.encodeComponent("Приложение не поддерживается")}',
        ),
      );
      final httpClient = _ScriptedDioHttpClient(outcomes: [null, null, null, null], body: unsupportedContent);
      final parser = await newParser(httpClient);
      final directory = await Directory.systemTemp.createTemp('marten-profile-parser-update-unsupported-');
      addTearDown(() => directory.delete(recursive: true));
      final profile = RemoteProfileEntity(
        id: const Uuid().v4(),
        active: true,
        name: 'working',
        url: candidateUrl,
        lastUpdate: DateTime.now(),
      );

      final result = await parser
          .updateRemote(rp: profile, tempFilePath: '${directory.path}/remote-profile.json')
          .run();

      expect(httpClient.calls, hasLength(4));
      expect(httpClient.calls.map((call) => call.method), orderedEquals(<String>['POST', 'GET', 'GET', 'GET']));
      expect(
        httpClient.calls.map((call) => call.url),
        orderedEquals(['$candidateUrl/refresh', candidateUrl, candidateUrl, candidateUrl]),
      );
      expect(result.isLeft(), isTrue, reason: 'all responses are unsupported and should fail closed');
      result.match((failure) {
        expect(
          failure.map(
            unexpected: (_) => false,
            notFound: (_) => false,
            invalidUrl: (_) => false,
            invalidConfig: (_) => true,
            cancelByUser: (_) => false,
            deviceMismatch: (_) => false,
          ),
          isTrue,
        );
        expect(failure.toString(), contains('subscription server returned no supported client representation'));
      }, (_) => fail('unsupported compatibility responses should not be treated as successful profile'));
    });

    test("Should rotate subscription URLs across remembered LB endpoints", () {
      final profile = RemoteProfileEntity(
        id: const Uuid().v4(),
        active: true,
        name: '',
        url: "https://sub-a.example.net/sub/token-1",
        lastUpdate: DateTime.now(),
        subscriptionEndpoints: const ["https://sub-a.example.net", "https://sub-b.example.net"],
        currentSubscriptionEndpoint: "https://sub-b.example.net",
      );

      expect(ProfileParser.subscriptionCandidateUrls(profile.url, profile: profile), [
        "https://sub-b.example.net/sub/token-1",
        "https://sub-a.example.net/sub/token-1",
      ]);
    });

    test("Should dedupe duplicated subscription candidate endpoints", () {
      final profile = RemoteProfileEntity(
        id: const Uuid().v4(),
        active: true,
        name: '',
        url: "https://sub-a.example.net/sub/token-1",
        lastUpdate: DateTime.now(),
        subscriptionEndpoints: const [
          "https://sub-b.example.net",
          "https://sub-b.example.net/",
          "https://sub-a.example.net",
          "https://sub-a.example.net",
        ],
        currentSubscriptionEndpoint: "https://sub-b.example.net",
      );

      expect(ProfileParser.subscriptionCandidateUrls(profile.url, profile: profile), [
        "https://sub-b.example.net/sub/token-1",
        "https://sub-a.example.net/sub/token-1",
      ]);
    });

    test("Should skip unavailable LB endpoints after the current endpoint", () {
      final profile = RemoteProfileEntity(
        id: const Uuid().v4(),
        active: true,
        name: '',
        url: "https://sub-a.example.net/sub/token-1",
        lastUpdate: DateTime.now(),
        subscriptionEndpoints: const [
          "https://sub-a.example.net",
          "https://sub-b.example.net",
          "https://sub-c.example.net",
        ],
        currentSubscriptionEndpoint: "https://sub-b.example.net",
        unavailableSubscriptionEndpoints: const ["https://sub-a.example.net"],
      );

      expect(ProfileParser.subscriptionCandidateUrls(profile.url, profile: profile), [
        "https://sub-b.example.net/sub/token-1",
        "https://sub-c.example.net/sub/token-1",
      ]);
    });
  });

  group("unsupported subscription detection", () {
    test("returns true for Base64 VLESS content with percent-encoded Russian unsupported marker", () {
      final content = 'vless://example.com/#${Uri.encodeComponent("Приложение не поддерживается")}';
      final encoded = base64Encode(utf8.encode(content));

      expect(ProfileParser.isUnsupportedClientSubscription(encoded), isTrue);
    });

    test("returns false for a Base64 JSON subscription with eight VLESS outbounds", () {
      final outboundEntries = List.generate(
        8,
        (index) =>
            '''
    {"type":"vless","tag":"Berlin ${index}","server":"203.0.113.${index + 10}","server_port":443}
''',
      ).join(',');
      final subscriptionContent = base64Encode(utf8.encode('{"outbounds":[$outboundEntries]}'));

      expect(ProfileParser.isUnsupportedClientSubscription(subscriptionContent), isFalse);
    });

    test("returns true for plain English unsupported marker", () {
      expect(ProfileParser.isUnsupportedClientSubscription("This client application is not supported"), isTrue);
    });

    test("does not throw and does not mark unsupported for JSON with malformed percent escape", () {
      final content = '''
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "Berlin § 0",
      "server": "203.0.113.10",
      "server_port": 443
    }
  ],
  "remarks": "bad%zz marker"
}
''';

      late bool isUnsupported;
      expect(() {
        isUnsupported = ProfileParser.isUnsupportedClientSubscription(content);
      }, returnsNormally);
      expect(isUnsupported, isFalse);
    });

    test("does not throw and does not mark unsupported for text with lone percent", () {
      const content = '{"type":"vless","remarks":"xray%","server":"203.0.113.10","server_port":443}';

      late bool isUnsupported;
      expect(() {
        isUnsupported = ProfileParser.isUnsupportedClientSubscription(content);
      }, returnsNormally);
      expect(isUnsupported, isFalse);
    });
  });

  group("restoreMartenSubscriptionMetadata", () {
    test('keeps only supported selectable outbounds in source order and removes dependent references', () {
      const sourceContent = '''
{
  "outbounds": [
    {"type":"vless","tag":"first","server":"first.example.test","server_port":443},
    {"type":"future-protocol","tag":"future"},
    {"type":"vless","tag":"depends-on-future","detour":"future","server":"dependent.example.test","server_port":443},
    {"type":"selector","tag":"future-group","outbounds":["future"]},
    {"type":"hysteria2","tag":"second","server":"second.example.test","server_port":443,"password":"test"},
    "malformed outbound"
  ],
  "servers":[{"tag":"future"},{"tag":"first"},{"tag":"future-group"}],
  "route":{"final":"future","rules":[{"outbound":"future"},{"outbound":"first"}]},
  "dns":{"servers":[{"tag":"future-dns","address":"https://dns.example.test/dns-query","detour":"future"}]}
}
''';

      final normalized =
          jsonDecode(ProfileParser.normalizeMartenSubscriptionContent(sourceContent)) as Map<String, dynamic>;
      final outbounds = List<Map<String, dynamic>>.from(normalized['outbounds'] as List);

      expect(outbounds.map((outbound) => outbound['tag']), orderedEquals(['first', 'second']));
      expect(ProfileParser.hasSelectableOutbound(jsonEncode(normalized)), isTrue);
      expect(
        normalized['servers'],
        equals([
          {'tag': 'first'},
        ]),
      );
      expect((normalized['route'] as Map<String, dynamic>)['final'], isNull);
      expect(
        (normalized['route'] as Map<String, dynamic>)['rules'],
        equals([
          {'outbound': 'first'},
        ]),
      );
      expect((normalized['dns'] as Map<String, dynamic>)['servers'], isEmpty);
    });

    test('fails closed when compatibility filtering leaves no selectable outbound', () {
      const sourceContent = '''
{
  "outbounds": [
    {"type":"future-protocol","tag":"future"},
    {"type":"turncoat","tag":"helper §hide§","server":"relay.example.test","server_port":56000},
    {"type":"selector","tag":"future-group","outbounds":["future"]}
  ]
}
''';

      final normalized = ProfileParser.normalizeMartenSubscriptionContent(sourceContent);

      expect(ProfileParser.hasSelectableOutbound(normalized), isFalse);
      expect(ProfileParser.validateBackgroundCandidate(sourceContent).isLeft(), isTrue);
    });

    test('moves turncoat extension metadata out of native content and restores it by exact helper tag', () {
      const helperTag = 'Amsterdam §hide§ turncoat';
      const sourceContent = '''
{
  "outbounds": [
    {
      "type":"turncoat",
      "tag":"Amsterdam §hide§ turncoat",
      "server":"relay.example.test",
      "server_port":56000,
      "credential_cache":{"enabled":true,"nested_future":{"ignored":true}}
    },
    {"type":"vless","tag":"Amsterdam","detour":"Amsterdam §hide§ turncoat","server":"edge.example.test","server_port":443}
  ],
  "subscription": {
    "outbound_options": {
      "Amsterdam §hide§ turncoat": {
        "credential_cache":{"enabled":true,"persist_across_restarts":true,"unknown_key":"ignored"},
        "future_extension":{"nested":{"ignored":true}}
      },
      "unknown-helper": {"unknown_extension":{"nested":true}}
    }
  }
}
''';
      const parsedContent = '''
{
  "outbounds": [
    {"type":"turncoat","tag":"Amsterdam §hide§ turncoat","server":"relay.example.test","server_port":56000},
    {"type":"vless","tag":"Amsterdam","detour":"Amsterdam §hide§ turncoat","server":"edge.example.test","server_port":443}
  ]
}
''';

      final nativeInput =
          jsonDecode(ProfileParser.stripMartenSubscriptionMetadata(sourceContent)) as Map<String, dynamic>;
      final nativeHelper = List<Map<String, dynamic>>.from(nativeInput['outbounds'] as List).first;
      final restored =
          jsonDecode(
                ProfileParser.restoreMartenSubscriptionMetadata(
                  parsedContent: parsedContent,
                  sourceContent: sourceContent,
                ),
              )
              as Map<String, dynamic>;

      expect(nativeHelper.containsKey('credential_cache'), isTrue);
      expect(nativeHelper.containsKey('future_extension'), isFalse);
      expect(nativeInput['subscription'], isNull);
      expect(restored['subscription'], isA<Map<String, dynamic>>());
      final outboundOptions =
          (restored['subscription'] as Map<String, dynamic>)['outbound_options'] as Map<String, dynamic>;
      expect(outboundOptions.keys, contains(helperTag));
      expect(outboundOptions[helperTag], isA<Map<String, dynamic>>());
      final restoredHelper = List<Map<String, dynamic>>.from(restored['outbounds'] as List).first;
      expect(restoredHelper.containsKey('credential_cache'), isFalse);
    });

    test('prunes restored server and outbound-option metadata for a malformed outbound dropped by native parsing', () {
      const sourceContent = '''
{
  "outbounds": [
    {"type":"vless","tag":"survivor","server":"survivor.example.test","server_port":443,"uuid":"00000000-0000-0000-0000-000000000001"},
    {"type":"vless","tag":"malformed","server":"malformed.example.test","server_port":443}
  ],
  "servers": [
    {"tag":"survivor","server":"survivor.example.test"},
    {"tag":"malformed","server":"malformed.example.test"}
  ],
  "subscription": {
    "outbound_options": {
      "survivor":{"future_extension":{"preserve":true}},
      "malformed":{"future_extension":{"drop":true}}
    }
  }
}
''';
      const parsedContent = '''
{
  "outbounds": [
    {"type":"vless","tag":"survivor","server":"survivor.example.test","server_port":443,"uuid":"00000000-0000-0000-0000-000000000001"}
  ]
}
''';

      final restored =
          jsonDecode(
                ProfileParser.restoreMartenSubscriptionMetadata(
                  parsedContent: parsedContent,
                  sourceContent: sourceContent,
                ),
              )
              as Map<String, dynamic>;
      final servers = List<Map<String, dynamic>>.from(restored['servers'] as List);
      final outboundOptions =
          (restored['subscription'] as Map<String, dynamic>)['outbound_options'] as Map<String, dynamic>;

      expect(servers.map((server) => server['tag']), orderedEquals(['survivor']));
      expect(outboundOptions.keys, orderedEquals(['survivor']));
    });

    test("restores app metadata keys while keeping canonical parsed outbounds", () {
      const parsedContent = '''
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "Berlin § 0",
      "server": "edge.example.net",
      "server_port": 443,
      "tls": {
        "enabled": true
      }
    }
  ],
  "route": {"final": "direct"}
}
''';

      const sourceContent = '''
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "Berlin § 0",
      "server": "edge.example.net",
      "server_port": 443
    }
  ],
  "servers": [
    {
      "tag": "Berlin § 0",
      "address": "edge.example.net"
    }
  ],
  "split_tunnel": {
    "bypass_apps": ["com.example.app"]
  },
  "subscription": {
    "endpoints": ["https://endpoint-a.example.net", "https://endpoint-b.example.net"]
  }
}
''';

      final restored = ProfileParser.restoreMartenSubscriptionMetadata(
        parsedContent: parsedContent,
        sourceContent: sourceContent,
      );

      final decoded = jsonDecode(restored) as Map<String, dynamic>;
      final decodedSource = jsonDecode(sourceContent) as Map<String, dynamic>;
      final restoredOutbounds = List<Map<String, dynamic>>.from(decoded['outbounds'] as List);
      final sourceServers = List<Map<String, dynamic>>.from(decodedSource['servers'] as List);
      final sourceSplitTunnel = decodedSource['split_tunnel'] as Map<String, dynamic>;
      final sourceSubscription = decodedSource['subscription'] as Map<String, dynamic>;
      final restoredRoute = decoded['route'] as Map<String, dynamic>?;

      expect(restoredOutbounds, hasLength(1));
      expect(restoredOutbounds.single, isA<Map<String, dynamic>>());
      expect(restoredOutbounds.single['tag'], equals('Berlin § 0'));
      expect(decoded['servers'] as List<dynamic>, equals(sourceServers));
      expect(decoded['split_tunnel'] as Map<String, dynamic>, equals(sourceSplitTunnel));
      expect(decoded['subscription'] as Map<String, dynamic>, equals(sourceSubscription));
      expect(restoredRoute, isNotNull);
    });

    test("base64 or share-form source does not damage canonical output", () {
      const parsedContent = '''
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "Paris § 0",
      "server": "edge.example.net",
      "server_port": 443
    }
  ]
}
''';

      const sourceContent = "c3ViZXNfZXhhbXBsZS9zaGFyZWQ=";
      final restored = ProfileParser.restoreMartenSubscriptionMetadata(
        parsedContent: parsedContent,
        sourceContent: sourceContent,
      );

      expect(restored, equals(parsedContent));
    });

    test("returns parsed content unchanged for non-canonical parsed input", () {
      const parsedContent = '{"outbounds":[{"type":"vless","tag":"Bad"';
      const sourceContent = '''
{
  "outbounds": [{"type":"vless","tag":"Berlin § 0"}],
  "subscription": {"name": "Server name"},
  "servers": [{"tag":"Berlin § 0"}],
  "split_tunnel": {"bypass_apps": ["com.example.app"]}
}
''';

      final restored = ProfileParser.restoreMartenSubscriptionMetadata(
        parsedContent: parsedContent,
        sourceContent: sourceContent,
      );

      expect(restored, equals(parsedContent));
      expect(
        () =>
            ProfileParser.restoreMartenSubscriptionMetadata(parsedContent: parsedContent, sourceContent: sourceContent),
        returnsNormally,
      );
    });
  });

  group('remote include cleanup', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('marten-profile-include-test-');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('deletes the plaintext fragment after a successful read', () async {
      final includeFile = File('${directory.path}/profile.tmp.0');

      final content = await ProfileParser.readRemoteIncludeWithCleanup(includeFile, () async {
        await includeFile.writeAsString('  vless://example  ');
      });

      expect(content, 'vless://example');
      expect(await includeFile.exists(), isFalse);
    });

    test('deletes a partial plaintext fragment when download fails', () async {
      final includeFile = File('${directory.path}/profile.tmp.0');

      await expectLater(
        ProfileParser.readRemoteIncludeWithCleanup(includeFile, () async {
          await includeFile.writeAsString('partial secret');
          throw const FileSystemException('download failed');
        }),
        throwsA(isA<FileSystemException>()),
      );

      expect(await includeFile.exists(), isFalse);
    });

    test('preserves non-URL lines and indentation when expanding remote includes', () async {
      final content =
          '''proxies:
  - name: Format-Test
    type: vless
    server: 203.0.113.10
    port: "443"
    uuid: 00000000-1111-2222-3333-444455556666
    tls: true
    servername: example.test
    network: tcp
    - nested: item
'''
              .trimRight();

      final includeFile = File('${directory.path}/profile.tmp.yaml');
      await includeFile.writeAsString('$content\nhttps://edge.example.com/subscription/format-test');

      final httpClient = _TrackingDioHttpClient(
        body: 'vless://00000000-1111-2222-3333-444455556666@example.test:443#Format-Test',
      );
      final context = await newParserWithRef(httpClient);

      await context.parser.expandRemoteLinesInParallel(
        tempFilePath: includeFile.path,
        httpClient: httpClient,
        cancelToken: CancelToken(),
        ref: context.ref,
      );

      final expanded = await includeFile.readAsString();
      final expected = [
        ...content.split('\n'),
        'vless://00000000-1111-2222-3333-444455556666@example.test:443#Format-Test',
      ];

      expect(
        _linesWithoutTerminalNewline(expanded),
        equals(expected),
        reason: 'non-url lines should preserve indentation and include expansion should keep only trimmed payload',
      );
    });
  });

  group('background candidate validation', () {
    test('accepts selectable outbounds from parsed JSON subscriptions', () {
      const content = '''
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "Germany § 0",
      "server": "edge.example.net",
      "server_port": 443,
      "tls": {
        "enabled": true
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
''';

      expect(ProfileParser.validateBackgroundCandidate(content).isRight(), isTrue);
      expect(ProfileParser.hasSelectableOutbound(content), isTrue);
    });

    test('accepts a base64-wrapped vless URI candidate', () {
      const vless = 'vless://user@example-vless.test:443?security=tls#Germany § 0';
      final base64 = base64Encode(utf8.encode(vless));

      expect(ProfileParser.validateBackgroundCandidate(base64).isRight(), isTrue);
    });

    test('accepts a structural JSON config and preserves unknown transport fields', () {
      const content = '''
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "Germany",
      "transport": {"type": "xhttp", "mode": "stream-one", "future_field": true}
    }
  ]
}
''';

      final result = ProfileParser.validateBackgroundCandidate(content);

      expect(result.isRight(), isTrue);
      final decoded = jsonDecode(result.getOrElse((_) => '{}')) as Map<String, dynamic>;
      final transport = ((decoded['outbounds'] as List).single as Map<String, dynamic>)['transport'];
      expect(transport, containsPair('future_field', true));
    });

    test('accepts known URI subscriptions without native core access', () {
      final result = ProfileParser.validateBackgroundCandidate('vless://id@example.com:443#Germany');

      expect(result.isRight(), isTrue);
    });

    test('rejects HTML, empty and truncated candidates', () {
      for (final candidate in ['', '<html>temporary edge error</html>', '{"outbounds":[']) {
        expect(ProfileParser.validateBackgroundCandidate(candidate).isLeft(), isTrue, reason: candidate);
      }
    });

    test('rejects subscription configs without selectable outbounds', () {
      const noSelectable = '''
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "selector", "tag": "selector", "outbounds": ["direct"]},
    {"type": "urltest", "tag": "urltest", "outbounds": ["direct"]},
    {"type": "vless", "tag": "Germany §hide§ 0", "server": "edge.example.net", "server_port": 443}
  ]
}
''';

      expect(ProfileParser.validateBackgroundCandidate(noSelectable).isLeft(), isTrue);
      expect(ProfileParser.hasSelectableOutbound(noSelectable), isFalse);
    });
  });

  group('selectable outbound guard', () {
    test('accepts a real VLESS outbound as selectable', () {
      const content = '''
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "Berlin § 0",
      "server": "edge.example.net",
      "server_port": 443
    },
    {"type": "dns", "tag": "dns"},
    {"type": "direct", "tag": "direct"}
  ]
}
''';

      expect(ProfileParser.hasSelectableOutbound(content), isTrue);
    });

    test('rejects infrastructure, hidden, and empty outbound lists', () {
      expect(ProfileParser.hasSelectableOutbound('{"outbounds":[]}'), isFalse);
      expect(ProfileParser.hasSelectableOutbound('{"outbounds":[{"type": "direct", "tag": "direct"}]}'), isFalse);
      expect(
        ProfileParser.hasSelectableOutbound('''
{
  "outbounds": [
    {"type": "selector", "tag": "selector", "outbounds": ["direct"]},
    {"type": "urltest", "tag": "urltest", "outbounds": ["direct"]},
    {"type": "block", "tag": "block"},
    {"type": "dns", "tag": "dns"},
    {"type": "vless", "tag": "Frankfurt §hide§ 1", "server": "edge.example.net", "server_port": 443}
  ]
}
'''),
        isFalse,
      );
    });
  });
}
