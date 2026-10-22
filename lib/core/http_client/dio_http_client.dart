import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';

import 'package:marten/core/network/strict_vpn_egress_gate.dart';
import 'package:marten/utils/custom_loggers.dart';

class DioHttpClient with InfraLogger {
  static const maxRedirects = 5;
  static const maxResponseBytes = 16 * 1024 * 1024;

  final Map<String, Dio> _dio = {};
  DioHttpClient({required this.timeout, required this.userAgent, required this.debug}) {
    strictVpnEgressGate.registerRetirer(this, _retireConnectionPools);
  }

  final Duration timeout;
  final bool debug;

  void _ensureConnectionPools() {
    if (_closed) throw StateError('HTTP client is closed');
    if (_dio.isNotEmpty) return;
    for (final mode in ["proxy", "direct", "both"]) {
      _dio[mode] = Dio(
        BaseOptions(
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
          headers: {"User-Agent": userAgent},
        ),
      );
      _dio[mode]!.interceptors.add(
        RetryInterceptor(
          dio: _dio[mode]!,
          retryDelays: [
            const Duration(seconds: 1),
            if (mode != "proxy") ...[const Duration(seconds: 2), const Duration(seconds: 3)],
          ],
        ),
      );

      _dio[mode]!.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          client.findProxy = (url) {
            if (mode == "proxy") {
              return "PROXY localhost:$port";
            } else if (mode == "direct") {
              return "DIRECT";
            } else {
              return "PROXY localhost:$port; DIRECT";
            }
          };
          return client;
        },
      );
    }

    if (debug) {
      // _dio.interceptors.add(LoggyDioInterceptor(requestHeader: true));
    }
  }

  int port = 0;
  bool _closed = false;

  String userAgent;

  void close({bool force = true}) {
    if (_closed) return;
    _closed = true;
    strictVpnEgressGate.unregisterRetirer(this);
    _retireConnectionPools(force: force);
  }

  void _retireConnectionPools({bool force = true}) {
    for (final dio in _dio.values) {
      dio.close(force: force);
    }
    _dio.clear();
  }

  // bool isPortOpen(String host, int port, {Duration timeout = const Duration(milliseconds: 200)}) async{
  //   try {
  //     Socket.connect(host, port, timeout: timeout).then((socket) {
  //       socket.destroy();
  //     });
  //     return true;
  //   } on SocketException catch (_) {
  //     return false;
  //   } catch (_) {
  //     return false;
  //   }
  // }
  Future<bool> isPortOpen(String host, int port, {Duration timeout = const Duration(seconds: 5)}) {
    final operation = _RetirableNetworkOperation();
    return strictVpnEgressGate.run(
      'TCP reachability probe',
      () => operation.isPortOpen(host, port, timeout: timeout),
      retire: operation.retire,
    );
  }

  void setProxyPort(int port) {
    this.port = port;
    loggy.debug("setting proxy port: [$port]");
  }

  Future<Response<T>> get<T>(
    String url, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
    bool proxyOnly = false,
  }) {
    final operation = _RetirableNetworkOperation(cancelToken: cancelToken);
    return strictVpnEgressGate.run('HTTP GET', () async {
      final dio = await _clientFor(proxyOnly, operation);
      return _requestFollowingRedirects<T>(
        dio,
        url,
        method: 'GET',
        cancelToken: operation.cancelToken,
        userAgent: userAgent,
        credentials: credentials,
        extraHeaders: extraHeaders,
      );
    }, retire: operation.retire);
  }

  Future<Response<T>> post<T>(
    String url, {
    Object? data,
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
    bool proxyOnly = false,
  }) {
    final operation = _RetirableNetworkOperation(cancelToken: cancelToken);
    return strictVpnEgressGate.run('HTTP POST', () async {
      final dio = await _clientFor(proxyOnly, operation);
      return _requestFollowingRedirects<T>(
        dio,
        url,
        method: 'POST',
        data: data,
        cancelToken: operation.cancelToken,
        userAgent: userAgent,
        credentials: credentials,
        extraHeaders: extraHeaders,
      );
    }, retire: operation.retire);
  }

  Future<Response<T>> delete<T>(
    String url, {
    Object? data,
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
    bool proxyOnly = false,
  }) {
    final operation = _RetirableNetworkOperation(cancelToken: cancelToken);
    return strictVpnEgressGate.run('HTTP DELETE', () async {
      final dio = await _clientFor(proxyOnly, operation);
      return _requestFollowingRedirects<T>(
        dio,
        url,
        method: 'DELETE',
        data: data,
        cancelToken: operation.cancelToken,
        userAgent: userAgent,
        credentials: credentials,
        extraHeaders: extraHeaders,
      );
    }, retire: operation.retire);
  }

  Future<Response> download(
    String url,
    String path, {
    String method = 'GET',
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
    bool proxyOnly = false,
  }) {
    final operation = _RetirableNetworkOperation(cancelToken: cancelToken);
    return strictVpnEgressGate.run('HTTP download', () async {
      final dio = await _clientFor(proxyOnly, operation);
      return _downloadFollowingRedirects(
        dio,
        url,
        path,
        method: method,
        cancelToken: operation.cancelToken,
        userAgent: userAgent,
        credentials: credentials,
        extraHeaders: extraHeaders,
      );
    }, retire: operation.retire);
  }

  Future<Dio> _clientFor(bool proxyOnly, _RetirableNetworkOperation operation) async {
    _ensureConnectionPools();
    final mode = proxyOnly
        ? "proxy"
        : await operation.isPortOpen("127.0.0.1", port, timeout: const Duration(seconds: 5))
        ? "both"
        : "direct";
    operation.throwIfRetired();
    final client = _dio[mode];
    if (client == null) {
      if (strictVpnEgressGate.isSealed) {
        operation.retire();
        operation.throwIfRetired();
      }
      throw StateError('HTTP connection pool retired during active request');
    }
    return client;
  }

  Future<Response<T>> _requestFollowingRedirects<T>(
    Dio dio,
    String url, {
    required String method,
    Object? data,
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
  }) async {
    var currentUri = Uri.parse(url);
    var currentMethod = method;
    var currentData = data;
    var allowSensitiveHeaders = true;

    for (var redirectCount = 0; redirectCount <= maxRedirects; redirectCount++) {
      final response = await dio.request<T>(
        currentUri.toString(),
        data: currentData,
        cancelToken: cancelToken,
        options: _options(
          currentUri.toString(),
          method: currentMethod,
          userAgent: userAgent,
          credentials: allowSensitiveHeaders ? credentials : null,
          extraHeaders: redirectHeaders(extraHeaders, allowSensitive: allowSensitiveHeaders),
          allowUrlUserInfo: allowSensitiveHeaders,
        ),
      );
      final next = _nextRedirect(response, currentUri, redirectCount);
      if (next == null) {
        _enforceResponseSize(response);
        return response;
      }
      if (!sameOrigin(currentUri, next)) allowSensitiveHeaders = false;
      if (_redirectChangesMethod(response.statusCode, currentMethod)) {
        currentMethod = 'GET';
        currentData = null;
      }
      currentUri = allowSensitiveHeaders ? next : next.replace(userInfo: '');
    }
    throw StateError('unreachable redirect loop');
  }

  Future<Response> _downloadFollowingRedirects(
    Dio dio,
    String url,
    String path, {
    required String method,
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
  }) async {
    var currentUri = Uri.parse(url);
    var currentMethod = method;
    var allowSensitiveHeaders = true;
    final destination = File(path);

    try {
      for (var redirectCount = 0; redirectCount <= maxRedirects; redirectCount++) {
        if (await destination.exists()) await destination.delete();
        final response = await dio.download(
          currentUri.toString(),
          path,
          cancelToken: cancelToken,
          options: _options(
            currentUri.toString(),
            method: currentMethod,
            userAgent: userAgent,
            credentials: allowSensitiveHeaders ? credentials : null,
            extraHeaders: redirectHeaders(extraHeaders, allowSensitive: allowSensitiveHeaders),
            allowUrlUserInfo: allowSensitiveHeaders,
          )..disableRetry = true,
        );
        final next = _nextRedirect(response, currentUri, redirectCount);
        if (next == null) {
          _enforceResponseSize(response, downloadedFile: destination);
          return response;
        }
        if (!sameOrigin(currentUri, next)) allowSensitiveHeaders = false;
        if (_redirectChangesMethod(response.statusCode, currentMethod)) currentMethod = 'GET';
        currentUri = allowSensitiveHeaders ? next : next.replace(userInfo: '');
      }
      throw StateError('unreachable redirect loop');
    } catch (_) {
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  Uri? _nextRedirect(Response response, Uri currentUri, int redirectCount) {
    final status = response.statusCode ?? 0;
    if (status < 300 || status >= 400) return null;
    final location = response.headers.value('location');
    final next = location == null ? null : currentUri.resolve(location);
    if (next == null || !isAllowedRedirect(currentUri, next) || redirectCount >= maxRedirects) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        error: StateError(redirectCount >= maxRedirects ? 'too many redirects' : 'unsupported redirect target'),
      );
    }
    return next;
  }

  void _enforceResponseSize(Response response, {File? downloadedFile}) {
    final declaredLength = int.tryParse(response.headers.value(Headers.contentLengthHeader) ?? '');
    final actualLength = downloadedFile?.lengthSync() ?? _responseBodyBytes(response.data);
    if ((declaredLength != null && declaredLength > maxResponseBytes) || actualLength > maxResponseBytes) {
      if (downloadedFile?.existsSync() ?? false) downloadedFile!.deleteSync();
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        error: StateError('response exceeds $maxResponseBytes bytes'),
      );
    }
  }

  int _responseBodyBytes(Object? data) {
    return switch (data) {
      null => 0,
      String() => utf8.encode(data).length,
      List<int>() => data.length,
      _ => utf8.encode(jsonEncode(data)).length,
    };
  }

  Options _options(
    String url, {
    String? method,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
    bool allowUrlUserInfo = true,
  }) {
    final uri = Uri.parse(url);

    String? userInfo;
    if (credentials != null) {
      userInfo = "${credentials.username}:${credentials.password}";
    } else if (allowUrlUserInfo && uri.userInfo.isNotEmpty) {
      userInfo = uri.userInfo;
    }

    String? basicAuth;
    if (userInfo != null) {
      basicAuth = "Basic ${base64.encode(utf8.encode(userInfo))}";
    }

    return Options(
      method: method,
      followRedirects: false,
      validateStatus: (status) => status != null && status >= 200 && status < 400,
      headers: {
        if (userAgent != null) "User-Agent": userAgent,
        if (basicAuth != null) "authorization": basicAuth,
        ...?extraHeaders,
      },
    );
  }
}

/// Owns every cancellable resource used by one admitted ordinary-network
/// operation. Sealing the strict VPN boundary retires the exact request and
/// its proxy reachability probe before waiting for the operation to settle.
final class _RetirableNetworkOperation {
  _RetirableNetworkOperation({CancelToken? cancelToken}) : cancelToken = cancelToken ?? CancelToken() {
    cancelToken?.whenCancel.then((_) => _retireTransport());
  }

  final CancelToken cancelToken;
  ConnectionTask<Socket>? _connectTask;
  Socket? _socket;
  bool _retired = false;

  void throwIfRetired() {
    if (!_retired && !cancelToken.isCancelled) return;
    if (!cancelToken.isCancelled) {
      cancelToken.cancel('ordinary network operation retired for VPN transition');
    }
    throw cancelToken.cancelError!;
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _retireTransport();
    if (!cancelToken.isCancelled) {
      cancelToken.cancel('ordinary network operation retired for VPN transition');
    }
  }

  void _retireTransport() {
    _connectTask?.cancel();
    _connectTask = null;
    _socket?.destroy();
    _socket = null;
  }

  Future<bool> isPortOpen(String host, int port, {required Duration timeout}) async {
    if (_retired || cancelToken.isCancelled) return false;
    try {
      final task = await Socket.startConnect(host, port);
      _connectTask = task;
      if (_retired || cancelToken.isCancelled) {
        task.cancel();
        return false;
      }
      final socket = await task.socket.timeout(
        timeout,
        onTimeout: () {
          task.cancel();
          throw TimeoutException('TCP reachability probe timed out');
        },
      );
      _connectTask = null;
      _socket = socket;
      if (_retired || cancelToken.isCancelled) return false;
      await socket.close();
      _socket = null;
      return true;
    } on SocketException catch (_) {
      return false;
    } on TimeoutException catch (_) {
      return false;
    } catch (_) {
      return false;
    } finally {
      _connectTask = null;
      _socket?.destroy();
      _socket = null;
    }
  }
}

bool sameOrigin(Uri first, Uri second) {
  return first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
      first.host.toLowerCase() == second.host.toLowerCase() &&
      first.port == second.port;
}

Map<String, String>? redirectHeaders(Map<String, String>? headers, {required bool allowSensitive}) {
  if (headers == null || headers.isEmpty) return headers;
  if (allowSensitive) return Map<String, String>.from(headers);
  const sensitiveNames = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'x-api-key',
    'api-key',
    'x-device-id',
    'x-hwid',
    'x-client-secret',
  };
  return {
    for (final entry in headers.entries)
      if (!sensitiveNames.contains(entry.key.toLowerCase())) entry.key: entry.value,
  };
}

bool isAllowedRedirect(Uri current, Uri next) {
  final nextScheme = next.scheme.toLowerCase();
  if (nextScheme != 'http' && nextScheme != 'https') return false;
  return current.scheme.toLowerCase() != 'https' || nextScheme == 'https';
}

bool _redirectChangesMethod(int? statusCode, String method) {
  if (method.toUpperCase() == 'GET' || method.toUpperCase() == 'HEAD') return false;
  return statusCode == 301 || statusCode == 302 || statusCode == 303;
}
