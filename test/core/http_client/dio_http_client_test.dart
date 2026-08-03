import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/http_client/dio_http_client.dart';

void main() {
  group('redirect security policy', () {
    test('compares scheme, host and effective port', () {
      expect(sameOrigin(Uri.parse('https://edge.example/a'), Uri.parse('https://edge.example/b')), isTrue);
      expect(sameOrigin(Uri.parse('https://edge.example/a'), Uri.parse('https://edge.example:443/b')), isTrue);
      expect(sameOrigin(Uri.parse('https://edge.example/a'), Uri.parse('http://edge.example/b')), isFalse);
      expect(sameOrigin(Uri.parse('https://edge.example/a'), Uri.parse('https://other.example/b')), isFalse);
    });

    test('drops credentials after a cross-origin redirect', () {
      const headers = {
        'X-Device-ID': 'device-secret',
        'x-client-secret': 'client-secret',
        'Authorization': 'Bearer private',
        'Cookie': 'session=private',
        'Accept-Language': 'ru',
      };

      final sanitized = redirectHeaders(headers, allowSensitive: false)!;

      expect(sanitized, {'Accept-Language': 'ru'});
      expect(headers, containsPair('X-Device-ID', 'device-secret'));
    });

    test('rejects insecure or non-HTTP redirect targets', () {
      final source = Uri.parse('https://edge.example/sub/token');

      expect(isAllowedRedirect(source, Uri.parse('https://other.example/sub/token')), isTrue);
      expect(isAllowedRedirect(source, Uri.parse('http://edge.example/sub/token')), isFalse);
      expect(isAllowedRedirect(source, Uri.parse('marten://import?url=private')), isFalse);
    });

    test('copies all headers for the original origin', () {
      const headers = {'X-Device-ID': 'device-secret'};

      final copied = redirectHeaders(headers, allowSensitive: true)!;

      expect(copied, headers);
      expect(identical(copied, headers), isFalse);
    });
  });
}
