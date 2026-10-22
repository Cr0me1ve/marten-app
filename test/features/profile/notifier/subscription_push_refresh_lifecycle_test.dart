import 'dart:async';

import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/app_info/app_info_provider.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/features/profile/data/profile_repository.dart';
import 'package:marten/core/http_client/dio_http_client.dart';
import 'package:marten/core/http_client/http_client_provider.dart';
import 'package:marten/core/model/app_info_entity.dart';
import 'package:marten/core/model/environment.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/model/profile_failure.dart';
import 'package:marten/features/profile/model/profile_sort_enum.dart';
import 'package:marten/features/profile/notifier/subscription_push_refresh.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _FakeMessaging implements SubscriptionPushMessaging {
  _FakeMessaging({this.configureAction, this.tokenAction})
    : messageController = StreamController<RemoteMessage>.broadcast(),
      tokenController = StreamController<String>.broadcast();

  final Future<void> Function({required bool isIOS})? configureAction;
  Future<String?> Function()? tokenAction;
  final StreamController<RemoteMessage> messageController;
  final StreamController<String> tokenController;
  int configureCalls = 0;
  int tokenCalls = 0;

  @override
  Future<void> configure({required bool isIOS}) async {
    configureCalls++;
    await configureAction?.call(isIOS: isIOS);
  }

  @override
  Future<String?> getToken() async {
    tokenCalls++;
    return tokenAction?.call();
  }

  @override
  Stream<RemoteMessage> get messages => messageController.stream;

  @override
  Stream<String> get tokens => tokenController.stream;

  Future<void> close() async {
    await messageController.close();
    await tokenController.close();
  }
}

final class _FakeProfileRepository implements ProfileRepository {
  final _changes = StreamController<Either<ProfileFailure, List<ProfileEntity>>>.broadcast();
  int watchCalls = 0;
  List<ProfileEntity> profiles = [];
  Completer<void>? getByIdEntered;
  Completer<void>? getByIdRelease;
  int getByIdCalls = 0;

  @override
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  }) {
    // The service installs the long-lived watcher before it gets the current
    // token. Subsequent calls provide the current profile snapshot for token
    // registration without adding another long-lived listener.
    if (watchCalls++ == 0) return _changes.stream;
    return Stream.value(right<ProfileFailure, List<ProfileEntity>>(profiles));
  }

  void emitChange() => _changes.add(right<ProfileFailure, List<ProfileEntity>>(profiles));

  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) => TaskEither(() async {
    getByIdCalls++;
    if (getByIdEntered case final entered? when !entered.isCompleted) entered.complete();
    await getByIdRelease?.future;
    ProfileEntity? found;
    for (final profile in profiles) {
      if (profile.id == id) found = profile;
    }
    return right<ProfileFailure, ProfileEntity?>(found);
  });

  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeAppInfo extends AppInfo {
  @override
  Future<AppInfoEntity> build() async => const AppInfoEntity(
    name: 'Marten test',
    version: '1.0.0',
    buildNumber: '1',
    release: Release.general,
    operatingSystem: 'android',
    operatingSystemVersion: 'test',
    environment: Environment.prod,
  );
}

final class _PostCall {
  _PostCall(this.url, this.data, this.cancelToken);
  final String url;
  final Object? data;
  final CancelToken? cancelToken;
}

final class _FakePushHttpClient extends DioHttpClient {
  _FakePushHttpClient() : super(timeout: const Duration(seconds: 1), userAgent: 'Marten test', debug: false);

  final calls = <_PostCall>[];
  final failingUrls = <String>{};
  final entered = Completer<void>();
  Completer<void>? gate;
  bool ignoreCancellation = false;

  @override
  Future<Response<T>> post<T>(
    String url, {
    Object? data,
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
    bool proxyOnly = false,
  }) async {
    calls.add(_PostCall(url, data, cancelToken));
    if (!entered.isCompleted) entered.complete();
    final blocked = gate;
    if (blocked != null) {
      if (ignoreCancellation) {
        await blocked.future;
      } else {
        await Future.any<void>([
          blocked.future,
          if (cancelToken != null) cancelToken.whenCancel.then<void>((error) => throw error),
        ]);
      }
    }
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    if (failingUrls.contains(url)) {
      final options = RequestOptions(path: url);
      throw DioException(
        requestOptions: options,
        response: Response<T>(requestOptions: options, statusCode: 503),
      );
    }
    return Response<T>(
      requestOptions: RequestOptions(path: url),
      statusCode: 200,
      headers: Headers(),
    );
  }
}

final class _ContainerRef implements Ref<Object?> {
  _ContainerRef(this._container);

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

Future<({ProviderContainer container, SubscriptionPushRefreshService service})> _createService({
  required SubscriptionPushMessaging messaging,
  required _FakeProfileRepository repository,
  required Future<bool> Function({bool debug}) initializer,
  _FakePushHttpClient? httpClient,
  List<ProfileEntity> initialProfiles = const [],
  Duration tokenTimeout = const Duration(seconds: 10),
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  repository.profiles = initialProfiles;
  final pushClient = httpClient ?? _FakePushHttpClient();
  final container = ProviderContainer(
    overrides: [
      profileRepositoryProvider.overrideWith((_) => Future.value(repository)),
      sharedPreferencesProvider.overrideWith((_) => Future.value(preferences)),
      deviceIdentityProvider.overrideWith(
        (_) async => const DeviceIdentity(deviceId: 'test-device', clientSecret: 'test-secret'),
      ),
      appInfoProvider.overrideWith(_FakeAppInfo.new),
      httpClientProvider.overrideWith((_) => pushClient),
    ],
  );
  await container.read(sharedPreferencesProvider.future);
  addTearDown(pushClient.close);
  final service = SubscriptionPushRefreshService(
    _ContainerRef(container),
    messaging: messaging,
    firebaseInitializer: initializer,
    isMobile: true,
    isIOS: false,
    tokenTimeout: tokenTimeout,
  );
  return (container: container, service: service);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SubscriptionPushRefreshService initialization', () {
    test('retries when Firebase readiness is initially false', () async {
      final messaging = _FakeMessaging(tokenAction: () async => null);
      final repository = _FakeProfileRepository();
      var readinessCalls = 0;
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => ++readinessCalls > 1,
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      await context.service.initialize();
      expect(messaging.configureCalls, 0);
      expect(repository.watchCalls, 0);

      await context.service.initialize();
      expect(readinessCalls, 2);
      expect(messaging.configureCalls, 1);
      expect(repository.watchCalls, 1);
    });

    test('retries setup after a configure error and installs only one listener set', () async {
      var shouldFail = true;
      final messaging = _FakeMessaging(
        configureAction: ({required bool isIOS}) async {
          if (shouldFail) {
            shouldFail = false;
            throw StateError('configuration failed');
          }
        },
        tokenAction: () async => null,
      );
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      await context.service.initialize();
      expect(messaging.messageController.hasListener, isFalse);

      await context.service.initialize();
      expect(messaging.configureCalls, 2);
      expect(messaging.messageController.hasListener, isTrue);
      expect(messaging.tokenController.hasListener, isTrue);
      expect(repository.watchCalls, 1);
    });

    test('installs the profile watcher despite a token timeout and retries on profile change', () async {
      final firstToken = Completer<String?>();
      var tokenCall = 0;
      final messaging = _FakeMessaging(
        tokenAction: () {
          tokenCall++;
          return tokenCall == 1 ? firstToken.future : Future<String?>.value();
        },
      );
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
        tokenTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      await context.service.initialize();
      expect(repository.watchCalls, 1, reason: 'the watcher survives a current-token timeout');
      expect(messaging.tokenCalls, 1);

      repository.emitChange();
      await Future<void>.delayed(Duration.zero);
      expect(messaging.tokenCalls, greaterThanOrEqualTo(2));

      firstToken.complete(null);
    });

    test('coalesces concurrent initialize calls into one setup', () async {
      final configureStarted = Completer<void>();
      final configureRelease = Completer<void>();
      final messaging = _FakeMessaging(
        configureAction: ({required bool isIOS}) async {
          if (!configureStarted.isCompleted) configureStarted.complete();
          await configureRelease.future;
        },
        tokenAction: () async => null,
      );
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      final first = context.service.initialize();
      await configureStarted.future;
      final second = context.service.initialize();
      configureRelease.complete();
      await Future.wait([first, second]);

      expect(messaging.configureCalls, 1);
      expect(messaging.messageController.hasListener, isTrue);
      expect(messaging.tokenController.hasListener, isTrue);
      expect(repository.watchCalls, 1);
    });

    test('coalesces profile and token refresh events while token acquisition is pending', () async {
      final firstToken = Completer<String?>();
      var tokenCalls = 0;
      final messaging = _FakeMessaging(
        tokenAction: () {
          tokenCalls++;
          return firstToken.future;
        },
      );
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      final initialization = context.service.initialize();
      while (tokenCalls == 0 || repository.watchCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      repository.emitChange();
      repository.emitChange();
      repository.emitChange();
      messaging.tokenController.add('refreshed-token');
      await Future<void>.delayed(Duration.zero);

      expect(tokenCalls, 1, reason: 'events arriving during a fetch must not start parallel token requests');
      expect(repository.watchCalls, 1, reason: 'registration waits until the current token fetch completes');

      firstToken.complete('initial-token');
      await initialization;

      expect(tokenCalls, 1);
      expect(repository.watchCalls, 3, reason: 'one initial pass plus one coalesced follow-up pass');
    });

    test('rolls back message subscription after partial listener installation failure', () async {
      final messaging = _FakeMessaging(tokenAction: () async => null);
      var failTokenStream = true;
      final messages = messaging.messageController.stream;
      final fake = _PartialFailureMessaging(messaging, messages, () => failTokenStream, (value) {
        failTokenStream = value;
      });
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: fake,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      await context.service.initialize();
      expect(messaging.messageController.hasListener, isFalse);

      fake.setFailTokenStream(false);
      await context.service.initialize();
      expect(messaging.messageController.hasListener, isTrue);
      expect(messaging.tokenController.hasListener, isTrue);
      expect(repository.watchCalls, 1);
    });

    test('disposal during setup prevents late subscriptions and retry callbacks', () async {
      final configureStarted = Completer<void>();
      final configureRelease = Completer<void>();
      final messaging = _FakeMessaging(
        configureAction: ({required bool isIOS}) async {
          configureStarted.complete();
          await configureRelease.future;
        },
        tokenAction: () async => null,
      );
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
      );
      final initialize = context.service.initialize();
      await configureStarted.future;
      context.service.dispose();
      configureRelease.complete();
      await initialize;
      await context.service.initialize();

      expect(messaging.messageController.hasListener, isFalse);
      expect(messaging.tokenController.hasListener, isFalse);
      expect(repository.watchCalls, 0);

      context.container.dispose();
      await messaging.close();
      await repository.close();
    });

    test('resume retries token acquisition after an initial token timeout', () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      final firstToken = Completer<String?>();
      var tokenCall = 0;
      final messaging = _FakeMessaging(
        tokenAction: () {
          tokenCall++;
          return tokenCall == 1 ? firstToken.future : Future<String?>.value();
        },
      );
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
        tokenTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      await context.service.initialize();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(messaging.tokenCalls, greaterThanOrEqualTo(2));

      firstToken.complete(null);
    });

    test('contains token stream errors and continues handling token events', () async {
      final messaging = _FakeMessaging(tokenAction: () async => null);
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      await context.service.initialize();
      messaging.tokenController.addError(StateError('private SDK details'));
      messaging.tokenController.add('token-after-error');
      await Future<void>.delayed(Duration.zero);

      expect(repository.watchCalls, greaterThanOrEqualTo(2));
      expect(messaging.tokenController.hasListener, isTrue);
    });

    test('ignores a token that arrives after disposal', () async {
      final lateToken = Completer<String?>();
      final messaging = _FakeMessaging(tokenAction: () => lateToken.future);
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
      );
      final initialization = context.service.initialize();
      while (messaging.tokenCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      context.service.dispose();
      lateToken.complete('late-token');
      await initialization;
      messaging.tokenController.add('later-token-event');
      await Future<void>.delayed(Duration.zero);

      expect(repository.watchCalls, 1, reason: 'only the profile watcher was installed before disposal');
      expect(messaging.messageController.hasListener, isFalse);
      expect(messaging.tokenController.hasListener, isFalse);

      context.container.dispose();
      await messaging.close();
      await repository.close();
    });

    test('resume retries every failed registration with the same token and profile set', () async {
      final profile = _pushProfile('resume-failed');
      final client = _FakePushHttpClient();
      final urls = pushTokenRegistrationUrlsFor(profile).map((url) => url.toString()).toList();
      client.failingUrls.addAll(urls);
      final messaging = _FakeMessaging(tokenAction: () async => 'stable-push-token');
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
        initialProfiles: [profile],
        httpClient: client,
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      await context.service.initialize();
      expect(messaging.tokenCalls, 1);
      expect(repository.watchCalls, greaterThanOrEqualTo(2));
      expect(repository.getByIdCalls, 1);
      expect(client.calls.map((call) => call.url), urls);
      expect(client.calls.map((call) => (call.data as Map)['push_token']), everyElement('stable-push-token'));

      client.failingUrls.clear();
      context.service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await context.service.initialize();

      expect(client.calls.map((call) => call.url), [...urls, ...urls]);
      expect(client.calls.map((call) => (call.data as Map)['push_token']), everyElement('stable-push-token'));
      final bindingIds = client.calls.map((call) => (call.data as Map)['push_binding_id']).toSet();
      expect(bindingIds, hasLength(1), reason: 'a retry must reuse the profile binding id');
    });

    test('resume retries only profiles whose push registration failed', () async {
      final firstProfile = _pushProfile('partial-first');
      final failedProfile = _pushProfile('partial-failed');
      final client = _FakePushHttpClient();
      final firstUrl = pushTokenRegistrationUrlsFor(firstProfile).single.toString();
      final failedUrl = pushTokenRegistrationUrlsFor(failedProfile).single.toString();
      client.failingUrls.add(failedUrl);
      final messaging = _FakeMessaging(tokenAction: () async => 'partial-token');
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
        initialProfiles: [firstProfile, failedProfile],
        httpClient: client,
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      await context.service.initialize();
      expect(client.calls.map((call) => call.url), [firstUrl, failedUrl]);
      client.failingUrls.clear();
      await context.service.initialize();

      expect(client.calls.map((call) => call.url), [firstUrl, failedUrl, failedUrl]);
      expect((client.calls.first.data as Map)['push_token'], 'partial-token');
      expect((client.calls.last.data as Map)['push_token'], 'partial-token');
    });

    test('deleting a profile while registration prerequisites wait prevents a late POST', () async {
      final profile = _pushProfile('delete-during-preflight');
      final client = _FakePushHttpClient();
      final messaging = _FakeMessaging(tokenAction: () async => 'delete-token');
      final repository = _FakeProfileRepository()
        ..getByIdEntered = Completer<void>()
        ..getByIdRelease = Completer<void>();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
        initialProfiles: [profile],
        httpClient: client,
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      final initialization = context.service.initialize();
      await repository.getByIdEntered!.future;
      repository.profiles = [];
      repository.emitChange();
      await Future<void>.delayed(Duration.zero);
      repository.getByIdRelease!.complete();
      await initialization;

      expect(client.calls, isEmpty, reason: 'a deleted profile must not register after its lookup returns');
    });

    test('disposal cancels an active POST and ignores its late response', () async {
      final profile = _pushProfile('dispose-during-post');
      final client = _FakePushHttpClient()
        ..gate = Completer<void>()
        ..ignoreCancellation = true;
      final messaging = _FakeMessaging(tokenAction: () async => 'dispose-token');
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
        initialProfiles: [profile],
        httpClient: client,
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      final initialization = context.service.initialize();
      await client.entered.future;
      expect(client.calls, hasLength(1));
      final token = client.calls.single.cancelToken;
      context.service.dispose();
      expect(token?.isCancelled, isTrue);
      client.gate!.complete();
      await initialization;
      await context.service.initialize();

      expect(
        client.calls,
        hasLength(1),
        reason: 'late completion after disposal must not trigger another endpoint call',
      );
    });

    test('deleting a profile cancels its active POST and ignores its late response', () async {
      final profile = _pushProfile('delete-during-post');
      final client = _FakePushHttpClient()
        ..gate = Completer<void>()
        ..ignoreCancellation = true;
      final messaging = _FakeMessaging(tokenAction: () async => 'delete-token');
      final repository = _FakeProfileRepository();
      final context = await _createService(
        messaging: messaging,
        repository: repository,
        initializer: ({bool debug = false}) async => true,
        initialProfiles: [profile],
        httpClient: client,
      );
      addTearDown(() async {
        context.service.dispose();
        context.container.dispose();
        await messaging.close();
        await repository.close();
      });

      final initialization = context.service.initialize();
      await client.entered.future;
      final cancelToken = client.calls.single.cancelToken;
      repository.profiles = [];
      repository.emitChange();
      await Future<void>.delayed(Duration.zero);
      expect(cancelToken?.isCancelled, isTrue);

      client.gate!.complete();
      await initialization;
      await context.service.initialize();
      expect(client.calls, hasLength(1));
    });
  });
}

RemoteProfileEntity _pushProfile(String id) => RemoteProfileEntity(
  id: id,
  active: false,
  name: id,
  url: 'https://edge.example.test/sub/$id',
  lastUpdate: DateTime.utc(2026, 10, 16),
  revision: 0,
  userOverride: UserOverride(pushEndpoint: 'https://edge.example.test/sub/$id/device/push-token'),
);

final class _PartialFailureMessaging implements SubscriptionPushMessaging {
  _PartialFailureMessaging(this.delegate, this._messages, this._shouldFail, this._setFail);

  final _FakeMessaging delegate;
  final Stream<RemoteMessage> _messages;
  final bool Function() _shouldFail;
  final void Function(bool value) _setFail;

  void setFailTokenStream(bool value) => _setFail(value);

  @override
  Future<void> configure({required bool isIOS}) => delegate.configure(isIOS: isIOS);

  @override
  Future<String?> getToken() => delegate.getToken();

  @override
  Stream<RemoteMessage> get messages => _messages;

  @override
  Stream<String> get tokens {
    if (_shouldFail()) throw StateError('token stream unavailable');
    return delegate.tokens;
  }
}
