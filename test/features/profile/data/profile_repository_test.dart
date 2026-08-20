import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/crypto/profile_crypto.dart';
import 'package:marten/core/db/db.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/core/http_client/dio_http_client.dart';
import 'package:marten/core/http_client/http_client_provider.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/features/profile/data/profile_data_source.dart';
import 'package:marten/features/profile/data/profile_parser.dart';
import 'package:marten/features/profile/data/profile_path_resolver.dart';
import 'package:marten/features/profile/data/profile_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _RecordingRef implements Ref<Object?> {
  _RecordingRef(this._container);

  final ProviderContainer _container;

  @override
  ProviderContainer get container => _container;

  @override
  bool exists(ProviderBase<Object?> provider) => _container.exists(provider);

  @override
  void invalidate(ProviderOrFamily provider) => _container.invalidate(provider);

  @override
  void invalidateSelf() => throw UnsupportedError('not used by this parser test');

  @override
  KeepAliveLink keepAlive() => throw UnsupportedError('not used by this parser test');

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
  }) => throw UnsupportedError('not used by this parser test');

  @override
  void notifyListeners() => throw UnsupportedError('not used by this parser test');

  @override
  void onAddListener(void Function() cb) => throw UnsupportedError('not used by this parser test');

  @override
  void onCancel(void Function() cb) => throw UnsupportedError('not used by this parser test');

  @override
  void onDispose(void Function() cb) => throw UnsupportedError('not used by this parser test');

  @override
  void onRemoveListener(void Function() cb) => throw UnsupportedError('not used by this parser test');

  @override
  void onResume(void Function() cb) => throw UnsupportedError('not used by this parser test');

  @override
  T read<T>(ProviderListenable<T> provider) => _container.read(provider);

  @override
  T refresh<T>(Refreshable<T> provider) => _container.refresh(provider);

  @override
  T watch<T>(ProviderListenable<T> provider) => _container.read(provider);
}

final class _DownloadedConfigClient extends DioHttpClient {
  _DownloadedConfigClient() : super(timeout: const Duration(seconds: 1), userAgent: 'Marten-test', debug: false);

  int downloads = 0;

  @override
  Future<Response> download(
    String url,
    String path, {
    String method = 'GET',
    Object? data,
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? extraHeaders,
    bool proxyOnly = false,
  }) async {
    downloads++;
    await File(path).writeAsString('''
{"outbounds":[
  {"type":"direct","tag":"direct"},
  {"type":"vless","tag":"remote","server":"198.51.100.1","server_port":443}
]}
''');
    return Response(
      requestOptions: RequestOptions(path: url),
      statusCode: 200,
      headers: Headers(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const identity = DeviceIdentity(deviceId: 'device-id', clientSecret: 'client-secret');
  late Directory directory;
  late Db database;
  late ProviderContainer container;
  late _DownloadedConfigClient httpClient;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('marten-profile-repository-test-');
    database = Db(NativeDatabase.memory());
    httpClient = _DownloadedConfigClient();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        deviceIdentityProvider.overrideWith((_) => Future.value(identity)),
        httpClientProvider.overrideWithValue(httpClient),
        sharedPreferencesProvider.overrideWith((_) => Future.value(preferences)),
      ],
    );
    await container.read(sharedPreferencesProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('background validate:false upserts persist without constructing core-backed dependencies', () async {
    var singboxFactoryCalls = 0;
    var configFactoryCalls = 0;
    final parser = ProfileParser(ref: _RecordingRef(container), httpClient: httpClient);
    final repository = ProfileRepositoryImpl(
      profileDataSource: ProfileDao(database),
      profilePathResolver: ProfilePathResolver(directory),
      profileParser: parser,
      deviceIdentity: identity,
      readSingbox: () {
        singboxFactoryCalls++;
        throw StateError('validate:false must not construct sing-box');
      },
      readConfigOptionRepository: () {
        configFactoryCalls++;
        throw StateError('validate:false must not construct config options');
      },
    );

    final initialized = await repository.init().run();
    initialized.match((failure) => fail('repository initialization failed: $failure'), (_) {});

    final first = await repository.upsertRemote('https://example.test/subscription', validate: false).run();
    final second = await repository.upsertRemote('https://example.test/subscription', validate: false).run();

    first.match((failure) => fail('initial validate:false upsert failed: $failure'), (_) {});
    second.match((failure) => fail('repeat validate:false upsert failed: $failure'), (_) {});
    expect(httpClient.downloads, 2);
    expect(singboxFactoryCalls, 0);
    expect(configFactoryCalls, 0);
    final persisted = await ProfileDao(database).getByUrl('https://example.test/subscription');
    expect(persisted, isNotNull);
    final encrypted = await ProfilePathResolver(directory).file(persisted!.id).readAsString();
    expect(ProfileCrypto.isEncrypted(encrypted), isTrue);
  });
}
