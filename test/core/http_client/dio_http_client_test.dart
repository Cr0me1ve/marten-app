import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/http_client/dio_http_client.dart';

void main() {
  group('strict VPN egress retirement', () {
    test('every ordinary HTTP operation owns a per-operation gate retirer', () {
      final source = File('lib/core/http_client/dio_http_client.dart').readAsStringSync();

      for (final operation in const <String, ({String declaration, String gate})>{
        'get': (declaration: 'Future<Response<T>> get<T>(', gate: "strictVpnEgressGate.run('HTTP GET'"),
        'post': (declaration: 'Future<Response<T>> post<T>(', gate: "strictVpnEgressGate.run('HTTP POST'"),
        'delete': (declaration: 'Future<Response<T>> delete<T>(', gate: "strictVpnEgressGate.run('HTTP DELETE'"),
        'download': (declaration: 'Future<Response> download(', gate: "strictVpnEgressGate.run('HTTP download'"),
      }.entries) {
        final declaration = source.indexOf(operation.value.declaration);
        final gate = source.indexOf(operation.value.gate, declaration);
        final nextDeclaration = source.indexOf('\n  Future<', gate + operation.value.gate.length);
        final body = source.substring(declaration, nextDeclaration < 0 ? source.length : nextDeclaration);

        expect(declaration, isNonNegative, reason: '${operation.key} must remain an HTTP client operation');
        expect(gate, greaterThan(declaration), reason: '${operation.key} must use the strict VPN gate');
        expect(body, contains('final operation = _RetirableNetworkOperation('));
        expect(body, contains('retire: operation.retire'));
        expect(body, contains('cancelToken: operation.cancelToken'));
      }
    });

    test('TCP probe and request retirement cancel all owned transport resources', () {
      final source = File('lib/core/http_client/dio_http_client.dart').readAsStringSync();
      final probeStart = source.indexOf('Future<bool> isPortOpen(');
      final probeEnd = source.indexOf('\n  void setProxyPort', probeStart);
      final probe = source.substring(probeStart, probeEnd);
      final operationStart = source.indexOf('final class _RetirableNetworkOperation');
      final operation = source.substring(operationStart);

      expect(probe, contains("strictVpnEgressGate.run(\n      'TCP reachability probe'"));
      expect(probe, contains('retire: operation.retire'));
      expect(operation, contains('ConnectionTask<Socket>? _connectTask;'));
      expect(operation, contains('Socket? _socket;'));
      expect(operation, contains('_connectTask?.cancel();'));
      expect(operation, contains('_socket?.destroy();'));
      expect(operation, contains("cancelToken.cancel('ordinary network operation retired for VPN transition')"));
      expect(operation, contains('Socket.startConnect(host, port)'));
      expect(operation, contains('cancelToken?.whenCancel.then((_) => _retireTransport());'));
    });
  });

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
        'X-HWID': 'android-device-hwid',
        'x-client-secret': 'client-secret',
        'Authorization': 'Bearer private',
        'Cookie': 'session=private',
        'Accept-Language': 'ru',
      };

      final sanitized = redirectHeaders(headers, allowSensitive: false)!;

      expect(sanitized, {'Accept-Language': 'ru'});
      expect(headers, containsPair('X-Device-ID', 'device-secret'));
      expect(headers, containsPair('X-HWID', 'android-device-hwid'));
      expect(sanitized.containsKey('X-HWID'), isFalse);
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
