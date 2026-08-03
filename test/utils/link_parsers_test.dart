import 'package:flutter_test/flutter_test.dart';
import 'package:marten/utils/link_parsers.dart';

void main() {
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

    test("leaves malformed turncoat URI for local import path without throwing", () {
      expect(() => LinkParser.parse('turncoat://@@@@'), returnsNormally);
      expect(LinkParser.parse('turncoat://@@@@'), isNull);
    });
  });

  group("safeDecodeBase64", () {
    test("returns malformed turncoat URI unchanged", () {
      expect(() => safeDecodeBase64('turncoat://@@@@'), returnsNormally);
      expect(safeDecodeBase64('turncoat://@@@@'), equals('turncoat://@@@@'));
    });
  });
}
