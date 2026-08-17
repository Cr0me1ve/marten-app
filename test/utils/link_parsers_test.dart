import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/utils/link_parsers.dart';

void main() {
  Set<String> extractAndroidSchemes() {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final schemePattern = RegExp(r'<data\s+[^>]*android:scheme="([^"]+)"[^>]*/>');
    return schemePattern.allMatches(manifest).map((m) => m.group(1)!).toSet();
  }

  Set<String> extractPlistSchemes(String plistPath) {
    final plist = File(plistPath).readAsStringSync();
    final arrayPattern = RegExp('<key>CFBundleURLSchemes</key>\\s*<array>(.*?)</array>', dotAll: true);
    final stringPattern = RegExp('<string>([^<]+)</string>');
    final schemes = <String>{};

    for (final match in arrayPattern.allMatches(plist)) {
      final content = match.group(1)!;
      for (final scheme in stringPattern.allMatches(content)) {
        schemes.add(scheme.group(1)!);
      }
    }

    return schemes;
  }

  String base64Text(String value) => base64Encode(utf8.encode(value));

  String base64UrlText(String value) => base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  String encodeJson(Map<String, Object> value) => Uri.encodeComponent(jsonEncode(value));

  Set<String> extractProtocolActivationSchemes(String path) {
    final config = File(path).readAsStringSync();
    final directMatch = RegExp(r'^protocol_activation:\s*(.*)$', multiLine: true).firstMatch(config);
    if (directMatch == null) return {};
    final raw = directMatch.group(1)!.trim();
    if (raw.isEmpty) return {};
    return raw.split(',').map((value) => value.trim()).where((value) => value.isNotEmpty).toSet();
  }

  Set<String> extractYamlListSchemes(String path, String key) {
    final lines = File(path).readAsStringSync().split('\n');
    final list = <String>{};
    var collect = false;

    for (final line in lines) {
      if (!collect && RegExp(r'^\s*' + RegExp.escape(key) + r':\s*$').hasMatch(line)) {
        collect = true;
        continue;
      }
      if (collect) {
        final valueMatch = RegExp(r'^\s*-\s*(.+?)\s*$').firstMatch(line);
        if (valueMatch == null) {
          break;
        }
        final raw = valueMatch.group(1)!;
        const prefix = 'x-scheme-handler/';
        if (raw.startsWith(prefix)) {
          list.add(raw.substring(prefix.length));
        }
      }
    }

    return list;
  }

  Set<String> extractAppDataSchemeMimeTypes(String path) {
    final appdata = File(path).readAsStringSync();
    final pattern = RegExp(r'<mime-type>\s*x-scheme-handler/([^<]+)\s*</mime-type>');
    return pattern
        .allMatches(appdata)
        .map((match) => match.group(1)!.trim())
        .where((scheme) => scheme.isNotEmpty)
        .toSet();
  }

  group("LinkParser.deep", () {
    test("marten://?url=... extracts wrapped subscription URL", () {
      final r = LinkParser.deep('marten://import?url=https://sub.example/abc&name=mySub');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/abc'));
      expect(r.name, equals('mySub'));
    });

    test("marten:// without url query falls back to path+fragment", () {
      final r = LinkParser.deep('marten://import/https://sub.example/abc#myName');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/abc'));
      expect(r.name, equals('myName'));
    });

    test("v2rayng://?url=... is recognized", () {
      final r = LinkParser.deep('v2rayng://install-config?url=https://sub.example/abc');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/abc'));
    });

    test("hiddify legacy ?url query form is recognized", () {
      final r = LinkParser.deep('hiddify://import?url=https://sub.example/def&name=legacyHiddify');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/def'));
      expect(r.name, equals('legacyHiddify'));
    });

    test("hiddify path form with fragment name is recognized", () {
      final r = LinkParser.deep('hiddify://import/${Uri.encodeComponent("https://sub.example/ghi")}#myHiddify');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/ghi'));
      expect(r.name, equals('myHiddify'));
    });

    test("hiddify percent-encoded local share-link in path form preserves name and link", () {
      final encodedVless = Uri.encodeComponent("vless://uuid@sub.example:443?security=xtls#node");
      final r = LinkParser.deep('hiddify://import/$encodedVless#myVless');
      expect(r, isNotNull);
      expect(r!.url, equals('vless://uuid@sub.example:443?security=xtls#node'));
      expect(r.name, equals('myVless'));
    });

    test("loon's `import` + `sub` query wrapper extracts remote URL", () {
      final r = LinkParser.deep('loon://import?sub=${Uri.encodeComponent("https://sub.example/loon")}');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/loon'));
      expect(r.name, isEmpty);
    });

    test("quantumult-x add-resource parses first server_remote URL from encoded JSON", () {
      final encodedRemote = encodeJson({
        'server_remote': ['https://sub.example/qx, tag=primary', 'https://sub.example/qx-backup, tag=backup'],
      });
      final r = LinkParser.deep('quantumult-x:///add-resource?remote-resource=$encodedRemote');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/qx'));
      expect(r.name, isEmpty);
    });

    test("sub wrapper decodes base64 payload URL", () {
      final r = LinkParser.deep('sub://aHR0cHM6Ly9zdWIuZXhhbXBsZS9zdWJzY3JpcHQ=');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/subscript'));
    });

    test("happ://add with raw URL is recognized", () {
      final r = LinkParser.deep('happ://add/https://sub.example/happ-raw');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/happ-raw'));
      expect(r.name, isEmpty);
    });

    test("happ://add with percent-encoded URL is recognized", () {
      final r = LinkParser.deep('happ://add/${Uri.encodeComponent("https://sub.example/happ-encoded")}');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/happ-encoded'));
      expect(r.name, isEmpty);
    });

    test("happ://add with base64 URL is recognized", () {
      final r = LinkParser.deep('happ://add/${base64Text("https://sub.example/happ-base64")}');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/happ-base64'));
      expect(r.name, isEmpty);
    });

    test("happ://add with base64url URL is recognized", () {
      final r = LinkParser.deep('happ://add/${base64UrlText("https://sub.example/happ-base64url")}');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/happ-base64url'));
      expect(r.name, isEmpty);
    });

    test("happ://crypt and happ://crypto payloads are rejected", () {
      expect(LinkParser.deep('happ://crypt/https://sub.example/crypto'), isNull);
      expect(LinkParser.deep('happ://crypto/https://sub.example/crypto'), isNull);
      expect(LinkParser.deep('happ://crypts/https://sub.example/crypto'), isNull);
    });

    test("happ raw inner URL keeps query component", () {
      final encodedInner = Uri.encodeComponent('https://sub.example/happ-raw?token=abc');
      final r = LinkParser.deep('happ://add/$encodedInner');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/happ-raw?token=abc'));
    });

    test("happ raw path-wrapped URL keeps `name` query in URL payload", () {
      final r = LinkParser.deep('happ://add/https://sub.example/profile?name=token-value');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/profile?name=token-value'));
      expect(r.name, equals('token-value'));
    });

    test("flclashx/koala-clash/prizrak-box wrappers decode URL payload", () {
      for (final scheme in ['flclashx', 'koala-clash', 'prizrak-box']) {
        final encodedUrl = Uri.encodeComponent('https://sub.example/shared-config');
        final r = LinkParser.deep('$scheme://install-config?url=$encodedUrl&name=$scheme');
        expect(r, isNotNull, reason: scheme);
        expect(r!.url, equals('https://sub.example/shared-config'));
        expect(r.name, equals(scheme));
      }
    });

    test("incy://add and icny://add are both recognized", () {
      for (final scheme in ['incy', 'icny']) {
        final r = LinkParser.deep('$scheme://add/https://sub.example/$scheme');
        expect(r, isNotNull);
        expect(r!.url, equals('https://sub.example/$scheme'));
      }
    });

    test("streisand://import supports percent-encoded URL", () {
      final r = LinkParser.deep('streisand://import/${Uri.encodeComponent("https://sub.example/streisand")}');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/streisand'));
      expect(r.name, isEmpty);
    });

    test("v2box://install-sub uses query-wrapped URL", () {
      final r = LinkParser.deep('v2box://install-sub?url=https://sub.example/v2box&name=v2box');
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/v2box'));
      expect(r.name, equals('v2box'));
    });

    test("shadowrocket://add/sub://<base64 URL> uses remark as name", () {
      final r = LinkParser.deep(
        'shadowrocket://add/sub://${base64Text("https://sub.example/shadowrocket")}?remark=sr-profile',
      );
      expect(r, isNotNull);
      expect(r!.url, equals('https://sub.example/shadowrocket'));
      expect(r.name, equals('sr-profile'));
    });

    test("stash/surge/clash/sing-box query wrappers are recognized", () {
      for (final scheme in ['stash', 'surge', 'clash', 'sing-box']) {
        final r = LinkParser.deep('$scheme://import?url=https://sub.example/$scheme&name=$scheme');
        expect(r, isNotNull);
        expect(r!.url, equals('https://sub.example/$scheme'));
        expect(r.name, equals(scheme));
      }
    });

    test("javascript/file payloads are rejected", () {
      expect(LinkParser.deep('javascript:alert("x")'), isNull);
      expect(LinkParser.deep('file:///tmp/malformed.json'), isNull);
    });

    test("edge import link extracts remote subscription URL", () {
      final r = LinkParser.deep('marten://import?url=https%3A%2F%2Fedge.example.net%2Fsub%2Ftoken-1&name=Alice');
      expect(r, isNotNull);
      expect(r!.url, equals('https://edge.example.net/sub/token-1'));
      expect(r.name, equals('Alice'));
    });

    test("unknown scheme returns null", () {
      expect(LinkParser.deep('legacy://import?url=https://sub.example/abc'), isNull);
      expect(LinkParser.deep('foo://bar'), isNull);
    });

    test("malformed input returns null", () {
      expect(LinkParser.deep(''), isNull);
      expect(LinkParser.deep('not a uri'), isNull);
    });
  });

  group("LinkParser.protocols", () {
    test("uses marten only", () {
      expect(LinkParser.protocols, contains('marten'));
      expect(LinkParser.protocols, isNot(contains('legacy')));
    });

    test("includes turncoat for native single-server share links", () {
      expect(LinkParser.protocols, contains('turncoat'));
    });

    test("contains updated deep-link schemes", () {
      for (final scheme in [
        'hiddify',
        'happ',
        'incy',
        'icny',
        'streisand',
        'v2box',
        'shadowrocket',
        'stash',
        'surge',
        'loon',
        'quantumult-x',
        'flclashx',
        'koala-clash',
        'prizrak-box',
        'sub',
      ]) {
        expect(LinkParser.protocols, contains(scheme));
      }
    });

    test("matches Android manifest URL schemes", () {
      expect(extractAndroidSchemes(), equals(LinkParser.protocols.toSet()));
    });

    test("matches iOS Info.plist URL schemes", () {
      expect(extractPlistSchemes('ios/Runner/Info.plist'), equals(LinkParser.protocols.toSet()));
    });

    test("matches macOS Info.plist URL schemes", () {
      expect(extractPlistSchemes('macos/Runner/Info.plist'), equals(LinkParser.protocols.toSet()));
    });

    test("contains flclashx/koala-clash/prizrak-box in desktop packaging scheme registration", () {
      final desktopSchemes = ['flclashx', 'koala-clash', 'prizrak-box'];
      final protocolActivationSchemes = extractProtocolActivationSchemes('windows/packaging/msix/make_config.yaml');
      final appDataSchemes = extractAppDataSchemeMimeTypes('linux/packaging/app.marten.client.appdata.xml');
      final debSchemes = extractYamlListSchemes('linux/packaging/deb/make_config.yaml', 'supported_mime_type');
      final appImageSchemes = extractYamlListSchemes(
        'linux/packaging/appimage/make_config.yaml',
        'supported_mime_type',
      );

      for (final scheme in desktopSchemes) {
        expect(protocolActivationSchemes, contains(scheme), reason: 'windows msix');
        expect(appDataSchemes, contains(scheme), reason: 'linux appdata');
        expect(debSchemes, contains(scheme), reason: 'linux deb');
        expect(appImageSchemes, contains(scheme), reason: 'linux appimage');
      }
    });
  });

  group("LinkParser.isRemoteProfileUrl", () {
    test("accepts remote HTTPS profile URL and rejects unsupported schemes", () {
      expect(LinkParser.isRemoteProfileUrl('https://sub.example/abc'), isTrue);
      expect(LinkParser.isRemoteProfileUrl('vless://example.com/path'), isFalse);
      expect(LinkParser.isRemoteProfileUrl('file:///tmp/config.json'), isFalse);
      expect(LinkParser.isRemoteProfileUrl('javascript:alert(1)'), isFalse);
    });
  });

  group("LinkParser.parse", () {
    test("keeps manual remote URL import available", () {
      final r = LinkParser.parse('https://edge.example.net/sub/token-1');
      expect(r, isNotNull);
      expect(r!.url, equals('https://edge.example.net/sub/token-1'));
    });

    test("leaves JSON content for local import path", () {
      expect(LinkParser.parse('{"outbounds":[]}'), isNull);
    });

    test("rejects javascript and file payloads in parse flow", () {
      expect(LinkParser.parse('javascript:alert("x")'), isNull);
      expect(LinkParser.parse('file:///tmp/malformed.json'), isNull);
    });

    test("rejects happ://crypto payloads in parse flow", () {
      expect(LinkParser.parse('happ://crypto/https://sub.example/crypto'), isNull);
      expect(LinkParser.parse('happ://crypt/https://sub.example/crypto'), isNull);
    });

    test("leaves malformed turncoat URI for local import path without throwing", () {
      expect(() => LinkParser.parse('turncoat://@@@@'), returnsNormally);
      expect(LinkParser.parse('turncoat://@@@@'), isNull);
    });
  });

  group("safeDecodeBase64", () {
    test("decodes standard base64 payload", () {
      expect(safeDecodeBase64(base64Text("https://sub.example/base")), equals('https://sub.example/base'));
    });

    test("decodes base64url payload", () {
      expect(safeDecodeBase64(base64UrlText("https://sub.example/base64url")), equals('https://sub.example/base64url'));
    });

    test("returns malformed turncoat URI unchanged", () {
      expect(() => safeDecodeBase64('turncoat://@@@@'), returnsNormally);
      expect(safeDecodeBase64('turncoat://@@@@'), equals('turncoat://@@@@'));
    });
  });
}
