import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';

import 'package:marten/utils/custom_loggers.dart';

class DioHttpClient with InfraLogger {
  static const maxRedirects = 5;
  static const maxResponseBytes = 16 * 1024 * 1024;

  final Map<String, Dio> _dio = {};
  DioHttpClient({required Duration timeout, required this.userAgent, required bool debug}) {
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

  String userAgent;
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
  Future<bool> isPortOpen(String host, int port, {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      await socket.close();
      return true;
    } on SocketException catch (_) {
      return false;
    } catch (_) {
      return false;
    }
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
  }) async {
    final mode = proxyOnly
        ? "proxy"
        : await isPortOpen("127.0.0.1", port)
        ? "both"
        : "direct";
    final dio = _dio[mode]!;

    return _requestFollowingRedirects<T>(
      dio,
      url,
      method: 'GET',
      cancelToken: cancelToken,
      userAgent: userAgent,
      credentials: credentials,
      extraHeaders: extraHeaders,
    );
  }

  Future<Response<T>> post<T>(
    String url, {
    Object? data,
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
    bool proxyOnly = false,
  }) async {
    final mode = proxyOnly
        ? "proxy"
        : await isPortOpen("127.0.0.1", port)
        ? "both"
        : "direct";
    final dio = _dio[mode]!;

    return _requestFollowingRedirects<T>(
      dio,
      url,
      method: 'POST',
      data: data,
      cancelToken: cancelToken,
      userAgent: userAgent,
      credentials: credentials,
      extraHeaders: extraHeaders,
    );
  }

  Future<Response<T>> delete<T>(
    String url, {
    Object? data,
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
    bool proxyOnly = false,
  }) async {
    final mode = proxyOnly
        ? "proxy"
        : await isPortOpen("127.0.0.1", port)
        ? "both"
        : "direct";
    final dio = _dio[mode]!;

    return _requestFollowingRedirects<T>(
      dio,
      url,
      method: 'DELETE',
      data: data,
      cancelToken: cancelToken,
      userAgent: userAgent,
      credentials: credentials,
      extraHeaders: extraHeaders,
    );
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
  }) async {
    final mode = proxyOnly
        ? "proxy"
        : await isPortOpen("127.0.0.1", port)
        ? "both"
        : "direct";
    final dio = _dio[mode]!;
    return _downloadFollowingRedirects(
      dio,
      url,
      path,
      method: method,
      cancelToken: cancelToken,
      userAgent: userAgent,
      credentials: credentials,
      extraHeaders: extraHeaders,
    );
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
          ),
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
