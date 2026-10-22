import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/http_client/dio_http_client.dart';

final class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('subscription download returns a 503 after one wire request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    final serving = server.listen((request) async {
      requests++;
      request.response.statusCode = HttpStatus.serviceUnavailable;
      request.response.write('temporary failure');
      await request.response.close();
    });
    final client = DioHttpClient(timeout: const Duration(seconds: 3), userAgent: 'Marten-test', debug: false);
    final directory = await Directory.systemTemp.createTemp('marten-download-no-retry-');
    addTearDown(() async {
      await serving.cancel();
      await server.close(force: true);
      client.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final destination = File('${directory.path}/download.json');
    client.port = server.port;
    final nativeHttpClient = _RealHttpOverrides().createHttpClient(null);

    await HttpOverrides.runZoned(() async {
      await expectLater(
        client.download('http://127.0.0.1:${server.port}/subscription', destination.path, proxyOnly: true),
        throwsA(
          isA<DioException>().having(
            (error) => error.response?.statusCode,
            'status code',
            HttpStatus.serviceUnavailable,
          ),
        ),
      );
    }, createHttpClient: (_) => nativeHttpClient);

    expect(requests, 1);
    expect(await destination.exists(), isFalse);
  });
}
