import 'dart:io';

import 'package:dio/dio.dart';
import 'package:marten/features/profile/model/profile_failure.dart';

typedef ProfileRefreshFailureDiagnostic = ({String category, String errorType, String httpStatusClass});

ProfileRefreshFailureDiagnostic profileRefreshFailureDiagnostic(ProfileFailure failure) {
  return switch (failure) {
    ProfileUnexpectedFailure(:final error) => profileRefreshUnexpectedErrorDiagnostic(error),
    ProfileNotFoundFailure() => (
      category: 'profile_not_found',
      errorType: 'profile_not_found',
      httpStatusClass: 'none',
    ),
    ProfileInvalidUrlFailure() => (category: 'validation', errorType: 'invalid_url', httpStatusClass: 'none'),
    ProfileInvalidConfigFailure() => (category: 'validation', errorType: 'invalid_config', httpStatusClass: 'none'),
    ProfileCancelByUserFailure() => (category: 'cancelled', errorType: 'cancelled_by_user', httpStatusClass: 'none'),
    ProfileDeviceMismatchFailure() => (category: 'authorization', errorType: 'device_mismatch', httpStatusClass: '4xx'),
  };
}

ProfileRefreshFailureDiagnostic profileRefreshUnexpectedErrorDiagnostic(Object? error) {
  if (error is DioException) {
    final statusClass = _httpStatusClass(error.response?.statusCode);
    return switch (error.type) {
      DioExceptionType.connectionTimeout || DioExceptionType.sendTimeout || DioExceptionType.receiveTimeout => (
        category: 'network_timeout',
        errorType: 'dio_timeout',
        httpStatusClass: statusClass,
      ),
      DioExceptionType.connectionError => (
        category: 'network_connection',
        errorType: 'dio_connection_error',
        httpStatusClass: statusClass,
      ),
      DioExceptionType.badCertificate => (
        category: 'network_tls',
        errorType: 'dio_bad_certificate',
        httpStatusClass: statusClass,
      ),
      DioExceptionType.badResponse => (
        category: switch (statusClass) {
          '4xx' => 'http_client_error',
          '5xx' => 'http_server_error',
          _ => 'http_response_error',
        },
        errorType: 'dio_bad_response',
        httpStatusClass: statusClass,
      ),
      DioExceptionType.cancel => (category: 'cancelled', errorType: 'dio_cancel', httpStatusClass: statusClass),
      DioExceptionType.unknown => (category: 'network_unknown', errorType: 'dio_unknown', httpStatusClass: statusClass),
    };
  }
  if (error is HandshakeException) {
    return (category: 'network_tls', errorType: 'handshake_exception', httpStatusClass: 'none');
  }
  if (error is SocketException || error is HttpException) {
    return (category: 'network_connection', errorType: 'network_exception', httpStatusClass: 'none');
  }
  if (error is FileSystemException) {
    return (category: 'storage', errorType: 'file_system_exception', httpStatusClass: 'none');
  }
  if (error is FormatException) {
    return (category: 'validation', errorType: 'format_exception', httpStatusClass: 'none');
  }
  return (category: 'unexpected', errorType: error == null ? 'missing_error' : 'unclassified', httpStatusClass: 'none');
}

String _httpStatusClass(int? statusCode) {
  if (statusCode == null) return 'none';
  if (statusCode >= 100 && statusCode < 200) return '1xx';
  if (statusCode >= 200 && statusCode < 300) return '2xx';
  if (statusCode >= 300 && statusCode < 400) return '3xx';
  if (statusCode >= 400 && statusCode < 500) return '4xx';
  if (statusCode >= 500 && statusCode < 600) return '5xx';
  return 'other';
}
