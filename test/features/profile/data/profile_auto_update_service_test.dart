import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/profile/data/profile_auto_update_service.dart';
import 'package:marten/features/profile/data/profile_refresh_diagnostics.dart';
import 'package:marten/features/profile/model/profile_failure.dart';

void main() {
  const sensitiveMessage =
      'refresh failed for profile-private-42 at https://private.example/subscription?token=secret-token';
  const sensitiveUrl = 'https://private.example/subscription?token=secret-token';
  const sensitiveProfileId = 'profile-private-42';

  ProfileFailure dioFailure(DioExceptionType type, {int? statusCode}) {
    final requestOptions = RequestOptions(path: sensitiveUrl);
    return ProfileFailure.unexpected(
      DioException(
        requestOptions: requestOptions,
        type: type,
        message: sensitiveMessage,
        response: statusCode == null ? null : Response(requestOptions: requestOptions, statusCode: statusCode),
      ),
    );
  }

  void expectDiagnostic(
    ProfileFailure failure, {
    required String category,
    required String errorType,
    required String httpStatusClass,
  }) {
    final diagnostic = ProfileAutoUpdateService.failureDiagnostic(failure);

    expect(diagnostic, profileRefreshFailureDiagnostic(failure));
    expect(diagnostic.category, category);
    expect(diagnostic.errorType, errorType);
    expect(diagnostic.httpStatusClass, httpStatusClass);
    expect(diagnostic.category, matches(RegExp(r'^[a-z_]+$')));
    expect(diagnostic.errorType, matches(RegExp(r'^[a-z_]+$')));
    expect(diagnostic.httpStatusClass, matches(RegExp(r'^(none|[1-5]xx|other)$')));

    final loggedValues = '${diagnostic.category}|${diagnostic.errorType}|${diagnostic.httpStatusClass}';
    expect(loggedValues, isNot(contains(sensitiveMessage)));
    expect(loggedValues, isNot(contains(sensitiveUrl)));
    expect(loggedValues, isNot(contains(sensitiveProfileId)));
  }

  group('ProfileAutoUpdateService.failureDiagnostic', () {
    test('classifies every Dio error type without exposing request details', () {
      final cases = [
        (
          name: 'connection timeout',
          failure: dioFailure(DioExceptionType.connectionTimeout),
          category: 'network_timeout',
          errorType: 'dio_timeout',
          httpStatusClass: 'none',
        ),
        (
          name: 'send timeout',
          failure: dioFailure(DioExceptionType.sendTimeout),
          category: 'network_timeout',
          errorType: 'dio_timeout',
          httpStatusClass: 'none',
        ),
        (
          name: 'receive timeout',
          failure: dioFailure(DioExceptionType.receiveTimeout),
          category: 'network_timeout',
          errorType: 'dio_timeout',
          httpStatusClass: 'none',
        ),
        (
          name: 'connection error',
          failure: dioFailure(DioExceptionType.connectionError),
          category: 'network_connection',
          errorType: 'dio_connection_error',
          httpStatusClass: 'none',
        ),
        (
          name: 'bad certificate',
          failure: dioFailure(DioExceptionType.badCertificate),
          category: 'network_tls',
          errorType: 'dio_bad_certificate',
          httpStatusClass: 'none',
        ),
        (
          name: 'bad response 4xx',
          failure: dioFailure(DioExceptionType.badResponse, statusCode: 404),
          category: 'http_client_error',
          errorType: 'dio_bad_response',
          httpStatusClass: '4xx',
        ),
        (
          name: 'bad response 5xx',
          failure: dioFailure(DioExceptionType.badResponse, statusCode: 503),
          category: 'http_server_error',
          errorType: 'dio_bad_response',
          httpStatusClass: '5xx',
        ),
        (
          name: 'bad response without status',
          failure: dioFailure(DioExceptionType.badResponse),
          category: 'http_response_error',
          errorType: 'dio_bad_response',
          httpStatusClass: 'none',
        ),
        (
          name: 'cancel',
          failure: dioFailure(DioExceptionType.cancel),
          category: 'cancelled',
          errorType: 'dio_cancel',
          httpStatusClass: 'none',
        ),
        (
          name: 'unknown',
          failure: dioFailure(DioExceptionType.unknown),
          category: 'network_unknown',
          errorType: 'dio_unknown',
          httpStatusClass: 'none',
        ),
      ];

      for (final testCase in cases) {
        expectDiagnostic(
          testCase.failure,
          category: testCase.category,
          errorType: testCase.errorType,
          httpStatusClass: testCase.httpStatusClass,
        );
      }
    });

    test('classifies non-Dio errors without exposing their messages', () {
      final cases = [
        (
          name: 'socket exception',
          failure: ProfileFailure.unexpected(const SocketException(sensitiveMessage)),
          category: 'network_connection',
          errorType: 'network_exception',
          httpStatusClass: 'none',
        ),
        (
          name: 'HTTP exception',
          failure: ProfileFailure.unexpected(const HttpException(sensitiveMessage)),
          category: 'network_connection',
          errorType: 'network_exception',
          httpStatusClass: 'none',
        ),
        (
          name: 'TLS handshake exception',
          failure: ProfileFailure.unexpected(const HandshakeException(sensitiveMessage)),
          category: 'network_tls',
          errorType: 'handshake_exception',
          httpStatusClass: 'none',
        ),
        (
          name: 'file system exception',
          failure: ProfileFailure.unexpected(const FileSystemException(sensitiveMessage, sensitiveUrl)),
          category: 'storage',
          errorType: 'file_system_exception',
          httpStatusClass: 'none',
        ),
        (
          name: 'format exception',
          failure: ProfileFailure.unexpected(const FormatException(sensitiveMessage)),
          category: 'validation',
          errorType: 'format_exception',
          httpStatusClass: 'none',
        ),
        (
          name: 'unclassified error',
          failure: ProfileFailure.unexpected(StateError(sensitiveMessage)),
          category: 'unexpected',
          errorType: 'unclassified',
          httpStatusClass: 'none',
        ),
        (
          name: 'missing error',
          failure: const ProfileFailure.unexpected(),
          category: 'unexpected',
          errorType: 'missing_error',
          httpStatusClass: 'none',
        ),
      ];

      for (final testCase in cases) {
        expectDiagnostic(
          testCase.failure,
          category: testCase.category,
          errorType: testCase.errorType,
          httpStatusClass: testCase.httpStatusClass,
        );
      }
    });

    test('classifies every explicit profile failure variant', () {
      final cases = [
        (
          failure: const ProfileFailure.notFound(),
          category: 'profile_not_found',
          errorType: 'profile_not_found',
          httpStatusClass: 'none',
        ),
        (
          failure: const ProfileFailure.invalidUrl(sensitiveMessage),
          category: 'validation',
          errorType: 'invalid_url',
          httpStatusClass: 'none',
        ),
        (
          failure: const ProfileFailure.invalidConfig(sensitiveMessage),
          category: 'validation',
          errorType: 'invalid_config',
          httpStatusClass: 'none',
        ),
        (
          failure: const ProfileFailure.cancelByUser(sensitiveMessage),
          category: 'cancelled',
          errorType: 'cancelled_by_user',
          httpStatusClass: 'none',
        ),
        (
          failure: const ProfileFailure.deviceMismatch(sensitiveMessage),
          category: 'authorization',
          errorType: 'device_mismatch',
          httpStatusClass: '4xx',
        ),
      ];

      for (final testCase in cases) {
        expectDiagnostic(
          testCase.failure,
          category: testCase.category,
          errorType: testCase.errorType,
          httpStatusClass: testCase.httpStatusClass,
        );
      }
    });
  });
}
