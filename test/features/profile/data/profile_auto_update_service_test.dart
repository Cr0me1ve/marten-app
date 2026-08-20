import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/features/profile/data/profile_auto_update_service.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/features/profile/data/profile_refresh_diagnostics.dart';
import 'package:marten/features/profile/data/profile_repository.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/model/profile_failure.dart';
import 'package:marten/features/profile/model/profile_sort_enum.dart';

final class _ServiceRef implements Ref<Object?> {
  _ServiceRef(this._container);

  final ProviderContainer _container;

  @override
  ProviderContainer get container => _container;

  @override
  bool exists(ProviderBase<Object?> provider) => _container.exists(provider);

  @override
  void invalidate(ProviderOrFamily provider) => _container.invalidate(provider);

  @override
  void invalidateSelf() => throw UnsupportedError('not used by this service test');

  @override
  KeepAliveLink keepAlive() => throw UnsupportedError('not used by this service test');

  @override
  ProviderSubscription<T> listen<T>(
    ProviderListenable<T> provider,
    void Function(T? previous, T next) listener, {
    void Function(Object error, StackTrace stackTrace)? onError,
    bool fireImmediately = false,
  }) => _container.listen(provider, listener, onError: onError, fireImmediately: fireImmediately);

  @override
  void listenSelf(
    void Function(Object? previous, Object? next) listener, {
    void Function(Object, StackTrace)? onError,
  }) => throw UnsupportedError('not used by this service test');

  @override
  void notifyListeners() => throw UnsupportedError('not used by this service test');

  @override
  void onAddListener(void Function() cb) => throw UnsupportedError('not used by this service test');

  @override
  void onCancel(void Function() cb) => throw UnsupportedError('not used by this service test');

  @override
  void onDispose(void Function() cb) => throw UnsupportedError('not used by this service test');

  @override
  void onRemoveListener(void Function() cb) => throw UnsupportedError('not used by this service test');

  @override
  void onResume(void Function() cb) => throw UnsupportedError('not used by this service test');

  @override
  T read<T>(ProviderListenable<T> provider) => _container.read(provider);

  @override
  T refresh<T>(Refreshable<T> provider) => _container.refresh(provider);

  @override
  T watch<T>(ProviderListenable<T> provider) => _container.read(provider);
}

final class _RecordingProfileRepository implements ProfileRepository {
  _RecordingProfileRepository(this.profile);

  final RemoteProfileEntity profile;
  final List<CancelToken?> updateTokens = [];

  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) => TaskEither.right(profile);

  @override
  TaskEither<ProfileFailure, Unit> upsertRemote(
    String url, {
    UserOverride? userOverride,
    CancelToken? cancelToken,
    bool markAsActive = true,
    bool validate = true,
  }) {
    updateTokens.add(cancelToken);
    return TaskEither.right(unit);
  }

  @override
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  }) => Stream.value(right([profile]));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
          failure: const ProfileFailure.unexpected(SocketException(sensitiveMessage)),
          category: 'network_connection',
          errorType: 'network_exception',
          httpStatusClass: 'none',
        ),
        (
          name: 'HTTP exception',
          failure: const ProfileFailure.unexpected(HttpException(sensitiveMessage)),
          category: 'network_connection',
          errorType: 'network_exception',
          httpStatusClass: 'none',
        ),
        (
          name: 'TLS handshake exception',
          failure: const ProfileFailure.unexpected(HandshakeException(sensitiveMessage)),
          category: 'network_tls',
          errorType: 'handshake_exception',
          httpStatusClass: 'none',
        ),
        (
          name: 'file system exception',
          failure: const ProfileFailure.unexpected(FileSystemException(sensitiveMessage, sensitiveUrl)),
          category: 'storage',
          errorType: 'file_system_exception',
          httpStatusClass: 'none',
        ),
        (
          name: 'format exception',
          failure: const ProfileFailure.unexpected(FormatException(sensitiveMessage)),
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

  group('ProfileAutoUpdateService background cancellation', () {
    RemoteProfileEntity profile() => RemoteProfileEntity(
      id: 'remote-profile',
      active: true,
      name: 'Remote profile',
      url: 'https://example.test/subscription',
      lastUpdate: DateTime.utc(2026),
    );

    Future<({ProfileAutoUpdateService service, _RecordingProfileRepository repository, ProviderContainer container})>
    newService() async {
      final repository = _RecordingProfileRepository(profile());
      final container = ProviderContainer(
        overrides: [profileRepositoryProvider.overrideWith((_) => Future.value(repository))],
      );
      addTearDown(container.dispose);
      return (service: ProfileAutoUpdateService(_ServiceRef(container)), repository: repository, container: container);
    }

    test('forwards a live background cancellation token to the profile download', () async {
      final context = await newService();
      final cancelToken = CancelToken();

      final results = await context.service.updateProfiles(force: true, cancelToken: cancelToken);

      expect(results.single.outcome, ProfileAutoUpdateOutcome.updated);
      expect(context.repository.updateTokens, [same(cancelToken)]);
    });

    test('does not start another profile refresh after the background task is cancelled', () async {
      final context = await newService();
      final cancelToken = CancelToken()..cancel('workmanager stopped the task');

      final results = await context.service.updateProfiles(force: true, cancelToken: cancelToken);

      expect(results, isEmpty);
      expect(context.repository.updateTokens, isEmpty);
    });
  });
}
