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
    {"type": "selector", "tag": "choose", "outbounds": ["wg", "future", "via-future"]},
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
        expect(rp.options, equals(const ProfileOptions(updateInterval: Duration(hours: 1))));
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
  });

  group('background candidate validation', () {
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
  });
}
