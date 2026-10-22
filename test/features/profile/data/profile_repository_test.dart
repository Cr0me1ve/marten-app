import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/crypto/profile_crypto.dart';
import 'package:marten/core/db/db.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/core/http_client/dio_http_client.dart';
import 'package:marten/core/http_client/http_client_provider.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/features/profile/data/profile_data_source.dart';
import 'package:marten/features/profile/data/profile_data_mapper.dart';
import 'package:marten/features/profile/data/profile_parser.dart';
import 'package:marten/features/profile/data/profile_path_resolver.dart';
import 'package:marten/features/profile/data/profile_repository.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/settings/data/config_option_repository.dart';
import 'package:marten/martencore/core_interface/core_interface.dart';
import 'package:marten/martencore/marten_core_service.dart';
import 'package:marten/singbox/model/singbox_config_option.dart';
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
  int activeDownloads = 0;
  int maxConcurrentDownloads = 0;
  int? failOnDownloadNumber;
  Completer<void>? downloadStarted;
  Completer<void>? concurrentDownloadsStarted;
  Completer<void>? downloadGate;
  Completer<void>? downloadFinished;
  String content = '''
{"outbounds":[
  {"type":"direct","tag":"direct"},
  {"type":"vless","tag":"remote","server":"remote.example.test","server_port":443}
]}
''';

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
    final callNumber = ++downloads;
    activeDownloads++;
    if (activeDownloads > maxConcurrentDownloads) maxConcurrentDownloads = activeDownloads;
    if (downloadStarted case final started? when !started.isCompleted) started.complete();
    final bothStarted = concurrentDownloadsStarted;
    if (activeDownloads >= 2 && bothStarted != null && !bothStarted.isCompleted) {
      bothStarted.complete();
    }
    try {
      await downloadGate?.future;
      if (failOnDownloadNumber == callNumber) throw StateError('scripted request failure');
      await File(path).writeAsString(content);
      return Response(
        requestOptions: RequestOptions(path: url),
        statusCode: 200,
        headers: Headers(),
      );
    } finally {
      activeDownloads--;
      final finished = downloadFinished;
      if (finished != null && !finished.isCompleted) finished.complete();
    }
  }
}

final class _ValidatingMartenCoreService extends MartenCoreService {
  _ValidatingMartenCoreService(super.ref, {required this.parsedContent}) : super(core: CoreInterface());

  final String parsedContent;
  File? canonicalFile;
  String? parsedOutputPath;
  String? canonicalBytesDuringValidation;

  @override
  TaskEither<String, Unit> changeOptions(SingboxConfigOption options) => TaskEither.right(unit);

  @override
  TaskEither<String, Unit> validateConfigByPath(String path, String tempPath, bool debug) =>
      TaskEither.tryCatch(() async {
        parsedOutputPath = path;
        canonicalBytesDuringValidation = await canonicalFile!.readAsString();
        await File(path).writeAsString(parsedContent, flush: true);
        return unit;
      }, (error, stackTrace) => error.toString());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const identity = DeviceIdentity(deviceId: 'device-id', clientSecret: 'client-secret');
  late Directory directory;
  late Db database;
  late ProviderContainer container;
  late _DownloadedConfigClient httpClient;
  late SharedPreferences preferences;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('marten-profile-repository-test-');
    database = Db(NativeDatabase.memory());
    httpClient = _DownloadedConfigClient();
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
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

  test(
    'foreground and background refresh use the injected canonicalizer and preserve the old transaction on failure',
    () async {
      var singboxFactoryCalls = 0;
      var canonicalizerCalls = 0;
      var failCanonicalization = false;
      final receivedContents = <String>[];
      final receivedSettings = <String>[];
      final parser = ProfileParser(ref: _RecordingRef(container), httpClient: httpClient);
      final repository = ProfileRepositoryImpl(
        profileDataSource: ProfileDao(database),
        profilePathResolver: ProfilePathResolver(directory),
        profileParser: parser,
        deviceIdentity: identity,
        readSingbox: () {
          singboxFactoryCalls++;
          throw StateError('an injected canonicalizer must keep refresh off the activity-bound core');
        },
        readConfigOptionRepository: () => ConfigOptionRepository(
          preferences: preferences,
          getConfigOptions: () => container.read(ConfigOptions.singboxConfigOptions),
        ),
        canonicalizeSubscription: ({required content, required settingsJson}) async {
          canonicalizerCalls++;
          receivedContents.add(content);
          receivedSettings.add(settingsJson);
          if (failCanonicalization) throw StateError('canonicalization failed');
          return '''
{"outbounds":[
  {"type":"vless","tag":"canonical-$canonicalizerCalls","server":"canonical.example.test","server_port":443,"uuid":"00000000-0000-0000-0000-000000000001"}
]}
''';
        },
      );

      await repository.init().run();
      final foreground = await repository.upsertRemote('https://example.test/subscription', validate: true).run();
      foreground.match((failure) => fail('foreground refresh failed: $failure'), (_) {});

      final afterForeground = await ProfileDao(database).getByUrl('https://example.test/subscription');
      expect(afterForeground, isNotNull);
      final profileFile = ProfilePathResolver(directory).file(afterForeground!.id);
      expect(ProfileCrypto.isEncrypted(await profileFile.readAsString()), isTrue);
      expect(await ProfileCrypto.decryptFile(profileFile, identity.clientSecret), contains('canonical-1'));

      httpClient.content = '''
{"outbounds":[{"type":"vless","tag":"background-source","server":"background.example.test","server_port":443}]}
''';
      final background = await repository.upsertRemote('https://example.test/subscription', validate: false).run();
      background.match((failure) => fail('background refresh failed: $failure'), (_) {});

      expect(
        canonicalizerCalls,
        2,
        reason: 'both foreground and headless refresh must share the injected admission boundary',
      );
      expect(singboxFactoryCalls, 0);
      expect(receivedContents, everyElement(contains('outbounds')));
      expect(receivedSettings, everyElement(contains('execute-config-as-is')));
      expect(await ProfileCrypto.decryptFile(profileFile, identity.clientSecret), contains('canonical-2'));

      final encryptedBeforeFailure = await profileFile.readAsString();
      final backupFile = ProfilePathResolver(directory).backupFile(afterForeground.id);
      final encryptedBackupBeforeFailure = await backupFile.readAsString();
      expect(ProfileCrypto.isEncrypted(encryptedBackupBeforeFailure), isTrue);
      final databaseBeforeFailure = await ProfileDao(database).getByUrl('https://example.test/subscription');
      failCanonicalization = true;
      httpClient.content = '''
{"outbounds":[{"type":"vless","tag":"failed-source","server":"failed.example.test","server_port":443}]}
''';
      final failed = await repository.upsertRemote('https://example.test/subscription', validate: false).run();

      expect(failed.isLeft(), isTrue);
      expect(
        await profileFile.readAsString(),
        encryptedBeforeFailure,
        reason: 'failed refresh must restore existing encrypted file',
      );
      expect(
        await backupFile.readAsString(),
        encryptedBackupBeforeFailure,
        reason: 'failed refresh must leave the last-good encrypted backup intact',
      );
      expect(
        await ProfileDao(database).getByUrl('https://example.test/subscription'),
        databaseBeforeFailure,
        reason: 'failed refresh must not commit a partial database update',
      );
    },
  );

  test('repairs a corrupt canonical profile from its encrypted last-good copy', () async {
    final parser = ProfileParser(ref: _RecordingRef(container), httpClient: httpClient);
    final paths = ProfilePathResolver(directory);
    final repository = ProfileRepositoryImpl(
      profileDataSource: ProfileDao(database),
      profilePathResolver: paths,
      profileParser: parser,
      deviceIdentity: identity,
      readSingbox: () => throw StateError('config recovery must not construct sing-box'),
      readConfigOptionRepository: () => throw StateError('config recovery must not read settings'),
    );
    await repository.init().run();
    final inserted = await repository.upsertRemote('https://example.test/recover-from-backup', validate: false).run();
    inserted.match((failure) => fail('profile insertion failed: $failure'), (_) {});
    final profile = await ProfileDao(database).getByUrl('https://example.test/recover-from-backup');
    expect(profile, isNotNull);
    final canonical = paths.file(profile!.id);
    final backup = paths.backupFile(profile.id);
    final expected = await ProfileCrypto.decryptFile(canonical, identity.clientSecret);
    final backupContents = await backup.readAsString();
    expect(ProfileCrypto.isEncrypted(backupContents), isTrue);
    expect(await ProfileCrypto.decryptFile(backup, identity.clientSecret), expected);

    await canonical.writeAsString('truncated encrypted profile');
    final result = await repository.getRawConfig(profile.id).run();

    result.match((failure) => fail('profile recovery failed: $failure'), (raw) => expect(raw, expected));
    expect(await ProfileCrypto.decryptFile(canonical, identity.clientSecret), expected);
    expect(ProfileCrypto.isEncrypted(await canonical.readAsString()), isTrue);
    expect(await ProfileCrypto.decryptFile(backup, identity.clientSecret), expected);
  });

  test('foreground core canonicalization writes parsed plaintext only to cache scratch', () async {
    const parsedContent = '''
{"outbounds":[{"type":"vless","tag":"foreground-parsed","server":"parsed.example.test","server_port":443}]}
''';
    final paths = ProfilePathResolver(directory);
    final core = _ValidatingMartenCoreService(_RecordingRef(container), parsedContent: parsedContent);
    final repository = ProfileRepositoryImpl(
      profileDataSource: ProfileDao(database),
      profilePathResolver: paths,
      profileParser: ProfileParser(ref: _RecordingRef(container), httpClient: httpClient),
      deviceIdentity: identity,
      readSingbox: () => core,
      readConfigOptionRepository: () => ConfigOptionRepository(
        preferences: preferences,
        getConfigOptions: () => container.read(ConfigOptions.singboxConfigOptions),
      ),
    );
    await repository.init().run();
    const url = 'https://example.test/foreground-native-canonicalization';
    final inserted = await repository.upsertRemote(url, validate: false).run();
    inserted.match((failure) => fail('profile insertion failed: $failure'), (_) {});
    final entry = await ProfileDao(database).getByUrl(url);
    expect(entry, isNotNull);
    final profile = entry!.toEntity() as RemoteProfileEntity;
    final canonical = paths.file(profile.id);
    core.canonicalFile = canonical;
    final encryptedBefore = await canonical.readAsString();
    httpClient.content = '''
{"outbounds":[{"type":"vless","tag":"foreground-source","server":"source.example.test","server_port":443}]}
''';

    final refreshed = await repository.refreshRemote(profile, validate: true).run();

    refreshed.match((failure) => fail('foreground canonicalization failed: $failure'), (_) {});
    expect(core.parsedOutputPath, isNotNull);
    expect(core.parsedOutputPath, isNot(canonical.path));
    expect(core.parsedOutputPath, endsWith('.core.parsed'));
    expect(core.canonicalBytesDuringValidation, encryptedBefore);
    expect(ProfileCrypto.isEncrypted(core.canonicalBytesDuringValidation!), isTrue);
    expect(await File(core.parsedOutputPath!).exists(), isFalse, reason: 'parsed plaintext scratch should be cleaned');
    expect(ProfileCrypto.isEncrypted(await canonical.readAsString()), isTrue);
    expect(await ProfileCrypto.decryptFile(canonical, identity.clientSecret), contains('foreground-parsed'));
    expect(
      await _storageFilesExceptCoordinator(paths.directory),
      {canonical.path, paths.backupFile(profile.id).path},
      reason: 'canonical storage must contain only the encrypted profile and its encrypted backup',
    );
  });

  test('coalesces missing-profile repairs into one subscription refresh and backs it up', () async {
    final parser = ProfileParser(ref: _RecordingRef(container), httpClient: httpClient);
    final paths = ProfilePathResolver(directory);
    final repository = ProfileRepositoryImpl(
      profileDataSource: ProfileDao(database),
      profilePathResolver: paths,
      profileParser: parser,
      deviceIdentity: identity,
      readSingbox: () => throw StateError('config recovery must not construct sing-box'),
      readConfigOptionRepository: () => throw StateError('config recovery must not read settings'),
    );
    await repository.init().run();
    const url = 'https://example.test/recover-from-subscription';
    final inserted = await repository.upsertRemote(url, validate: false).run();
    inserted.match((failure) => fail('profile insertion failed: $failure'), (_) {});
    final entry = await ProfileDao(database).getByUrl(url);
    expect(entry, isNotNull);
    final profile = entry!.toEntity() as RemoteProfileEntity;
    final canonical = paths.file(profile.id);
    final backup = paths.backupFile(profile.id);
    await canonical.delete();
    await backup.delete();
    httpClient.content = '''
{"outbounds":[{"type":"vless","tag":"subscription-recovered","server":"recovered.example.test","server_port":443}]}
''';
    final initialDownloadCount = httpClient.downloads;
    final started = Completer<void>();
    final gate = Completer<void>();
    httpClient.downloadStarted = started;
    httpClient.downloadGate = gate;

    final firstRead = repository.getRawConfig(profile.id).run();
    await started.future;
    final secondRead = repository.getRawConfig(profile.id).run();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(httpClient.downloads, initialDownloadCount + 1, reason: 'concurrent readers should share one repair');
    gate.complete();
    final results = await Future.wait([firstRead, secondRead]);
    httpClient.downloadStarted = null;
    httpClient.downloadGate = null;

    for (final result in results) {
      result.match((failure) => fail('subscription recovery failed: $failure'), (raw) {
        expect(raw, contains('subscription-recovered'));
      });
    }
    expect(await ProfileCrypto.decryptFile(canonical, identity.clientSecret), contains('subscription-recovered'));
    expect(ProfileCrypto.isEncrypted(await backup.readAsString()), isTrue);
    expect(await ProfileCrypto.decryptFile(backup, identity.clientSecret), contains('subscription-recovered'));
    final stableDownloadCount = httpClient.downloads;
    final repeated = await repository.getRawConfig(profile.id).run();
    repeated.match((failure) => fail('repeated profile read failed: $failure'), (_) {});
    expect(httpClient.downloads, stableDownloadCount, reason: 'a repaired profile should not trigger another refresh');
  });

  test('repairs a local profile from its encrypted last-good copy without a subscription request', () async {
    const id = 'local-profile-recovery';
    const raw = '''
{"outbounds":[{"type":"vless","tag":"local-recovered","server":"local.example.test","server_port":443}]}
''';
    final paths = ProfilePathResolver(directory);
    final dao = ProfileDao(database);
    final repository = ProfileRepositoryImpl(
      profileDataSource: dao,
      profilePathResolver: paths,
      profileParser: ProfileParser(ref: _RecordingRef(container), httpClient: httpClient),
      deviceIdentity: identity,
      readSingbox: () => throw StateError('local recovery must not construct sing-box'),
      readConfigOptionRepository: () => throw StateError('local recovery must not read settings'),
    );
    await repository.init().run();
    await dao.insert(
      ProfileEntriesCompanion.insert(
        id: id,
        type: ProfileType.local,
        active: true,
        name: 'Local profile',
        url: const Value(null),
        lastUpdate: DateTime.utc(2026, 10, 10),
      ),
    );
    final canonical = paths.file(id);
    final backup = paths.backupFile(id);
    await ProfileCrypto.encryptContentToFile(canonical, raw, identity.clientSecret);
    await ProfileCrypto.encryptContentToFile(backup, raw, identity.clientSecret);
    await canonical.writeAsString('unreadable local profile');

    final result = await repository.getRawConfig(id).run();

    result.match((failure) => fail('local profile recovery failed: $failure'), (content) => expect(content, raw));
    expect(await ProfileCrypto.decryptFile(canonical, identity.clientSecret), raw);
    expect(httpClient.downloads, 0, reason: 'local profiles have no remote subscription to refresh');
  });

  test('a late cancelled refresh cannot replace the transaction target or last-good backup', () async {
    final paths = ProfilePathResolver(directory);
    final bootstrapParser = ProfileParser(ref: _RecordingRef(container), httpClient: httpClient);
    final bootstrapRepository = ProfileRepositoryImpl(
      profileDataSource: ProfileDao(database),
      profilePathResolver: paths,
      profileParser: bootstrapParser,
      deviceIdentity: identity,
      readSingbox: () => throw StateError('validate:false refresh must not construct sing-box'),
      readConfigOptionRepository: () => throw StateError('validate:false refresh must not read settings'),
    );
    await bootstrapRepository.init().run();
    const url = 'https://example.test/late-refresh';
    final inserted = await bootstrapRepository.upsertRemote(url, validate: false).run();
    inserted.match((failure) => fail('profile insertion failed: $failure'), (_) {});
    final entry = await ProfileDao(database).getByUrl(url);
    expect(entry, isNotNull);
    final profile = entry!.toEntity() as RemoteProfileEntity;
    final shortBudgetRepository = ProfileRepositoryImpl(
      profileDataSource: ProfileDao(database),
      profilePathResolver: paths,
      profileParser: ProfileParser(
        ref: _RecordingRef(container),
        httpClient: httpClient,
        downloadTimeout: const Duration(milliseconds: 25),
      ),
      deviceIdentity: identity,
      readSingbox: () => throw StateError('validate:false refresh must not construct sing-box'),
      readConfigOptionRepository: () => throw StateError('validate:false refresh must not read settings'),
    );
    await shortBudgetRepository.init().run();
    final canonical = paths.file(profile.id);
    final backup = paths.backupFile(profile.id);
    final canonicalBefore = await canonical.readAsString();
    final backupBefore = await backup.readAsString();
    final databaseBefore = await ProfileDao(database).getByUrl(url);
    httpClient.content = '''
{"outbounds":[{"type":"vless","tag":"late-replacement","server":"late.example.test","server_port":443}]}
''';
    final started = Completer<void>();
    final gate = Completer<void>();
    final downloadFinished = Completer<void>();
    httpClient.downloadStarted = started;
    httpClient.downloadGate = gate;
    httpClient.downloadFinished = downloadFinished;

    final refresh = shortBudgetRepository.refreshRemote(profile, validate: false).run();
    await started.future;
    final result = await refresh;

    expect(result.isLeft(), isTrue);
    expect(canonical.readAsStringSync(), canonicalBefore);
    expect(await backup.readAsString(), backupBefore);
    expect(await ProfileDao(database).getByUrl(url), databaseBefore);
    expect(httpClient.downloads, 2, reason: 'a deadline must not schedule a second endpoint attempt');

    final scratchRemoved = paths.directory
        .watch(events: FileSystemEvent.delete)
        .firstWhere((event) => event.path.contains('.tmp.json.download-'));
    gate.complete();
    await downloadFinished.future;
    await scratchRemoved.timeout(const Duration(seconds: 5));

    expect(await canonical.readAsString(), canonicalBefore);
    expect(await backup.readAsString(), backupBefore);
    expect(await ProfileCrypto.decryptFile(canonical, identity.clientSecret), contains('remote'));
    expect(
      await _storageFilesExceptCoordinator(paths.directory),
      {canonical.path, backup.path},
      reason: 'late scratch writes must be removed without touching either durable profile copy',
    );
    httpClient.downloadStarted = null;
    httpClient.downloadGate = null;
    httpClient.downloadFinished = null;
  });

  test('automatic repair and manual refresh overlap network while the failed candidate preserves the commit', () async {
    final paths = ProfilePathResolver(directory);
    final repository = ProfileRepositoryImpl(
      profileDataSource: ProfileDao(database),
      profilePathResolver: paths,
      profileParser: ProfileParser(ref: _RecordingRef(container), httpClient: httpClient),
      deviceIdentity: identity,
      readSingbox: () => throw StateError('validate:false refresh must not construct sing-box'),
      readConfigOptionRepository: () => throw StateError('validate:false refresh must not read settings'),
    );
    await repository.init().run();
    const url = 'https://example.test/serialized-repair';
    final inserted = await repository.upsertRemote(url, validate: false).run();
    inserted.match((failure) => fail('profile insertion failed: $failure'), (_) {});
    final entry = await ProfileDao(database).getByUrl(url);
    expect(entry, isNotNull);
    final profile = entry!.toEntity() as RemoteProfileEntity;
    final canonical = paths.file(profile.id);
    final backup = paths.backupFile(profile.id);
    await canonical.delete();
    await backup.delete();
    httpClient.content = '''
{"outbounds":[{"type":"vless","tag":"repair-committed","server":"repair.example.test","server_port":443}]}
''';
    final initialCalls = httpClient.downloads;
    final started = Completer<void>();
    final bothStarted = Completer<void>();
    final gate = Completer<void>();
    httpClient.downloadStarted = started;
    httpClient.concurrentDownloadsStarted = bothStarted;
    httpClient.downloadGate = gate;
    httpClient.failOnDownloadNumber = initialCalls + 2;

    final repair = repository.getRawConfig(profile.id).run();
    await started.future;
    final manualRefresh = repository.refreshRemote(profile, validate: false).run();
    await bothStarted.future;
    expect(httpClient.downloads, initialCalls + 2, reason: 'network waits must not hold the shared commit lease');
    expect(httpClient.maxConcurrentDownloads, 2);
    gate.complete();
    final repairResult = await repair;
    final databaseAfterRepair = await ProfileDao(database).getByUrl(url);
    final refreshResult = await manualRefresh;

    repairResult.match((failure) => fail('automatic repair failed: $failure'), (raw) {
      expect(raw, contains('repair-committed'));
    });
    expect(refreshResult.isLeft(), isTrue, reason: 'the queued second operation is scripted to fail');
    expect(
      httpClient.downloads,
      greaterThanOrEqualTo(initialCalls + 2),
      reason: 'both admitted operations may finish network attempts before commit-time revision validation',
    );
    expect(httpClient.maxConcurrentDownloads, 2, reason: 'independent network waits may overlap before commit');
    expect(await ProfileCrypto.decryptFile(canonical, identity.clientSecret), contains('repair-committed'));
    expect(await ProfileCrypto.decryptFile(backup, identity.clientSecret), contains('repair-committed'));
    expect(ProfileCrypto.isEncrypted(await canonical.readAsString()), isTrue);
    expect(ProfileCrypto.isEncrypted(await backup.readAsString()), isTrue);
    expect(await ProfileDao(database).getByUrl(url), databaseAfterRepair);
    httpClient.downloadStarted = null;
    httpClient.concurrentDownloadsStarted = null;
    httpClient.downloadGate = null;
    httpClient.failOnDownloadNumber = null;
  });

  test(
    'deleting a profile during delayed refresh prevents resurrection and explicit reimport can recreate it',
    () async {
      final paths = ProfilePathResolver(directory);
      final dao = ProfileDao(database);
      final repository = ProfileRepositoryImpl(
        profileDataSource: dao,
        profilePathResolver: paths,
        profileParser: ProfileParser(
          ref: _RecordingRef(container),
          httpClient: httpClient,
          downloadTimeout: const Duration(seconds: 2),
        ),
        deviceIdentity: identity,
        readSingbox: () => throw StateError('validate:false refresh must not construct sing-box'),
        readConfigOptionRepository: () => throw StateError('validate:false refresh must not read settings'),
      );
      await repository.init().run();
      const url = 'https://example.test/delete-during-repair';
      const activeUrl = 'https://example.test/active-sentinel';
      final inserted = await repository.upsertRemote(url, validate: false, markAsActive: false).run();
      inserted.match((failure) => fail('profile insertion failed: $failure'), (_) {});
      final activeInserted = await repository.upsertRemote(activeUrl, validate: false).run();
      activeInserted.match((failure) => fail('active sentinel insertion failed: $failure'), (_) {});
      final profile = await dao.getByUrl(url);
      expect(profile, isNotNull);
      final remoteProfile = profile!.toEntity() as RemoteProfileEntity;
      final canonical = paths.file(remoteProfile.id);
      final backup = paths.backupFile(remoteProfile.id);
      expect(await canonical.exists(), isTrue);
      expect(await backup.exists(), isTrue);
      final activeBefore = await dao.getByUrl(activeUrl);
      expect(activeBefore, isNotNull);
      final started = Completer<void>();
      final gate = Completer<void>();
      httpClient.downloadStarted = started;
      httpClient.downloadGate = gate;

      final refresh = repository.refreshRemote(remoteProfile, validate: false).run();
      await started.future;
      final deleted = await repository.deleteById(remoteProfile.id, false).run();
      deleted.match((failure) => fail('profile deletion failed: $failure'), (_) {});
      expect((await dao.getById(remoteProfile.id)), isNull);
      expect(await canonical.exists(), isFalse);
      expect(await backup.exists(), isFalse);
      gate.complete();
      expect((await refresh).isLeft(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await dao.getById(remoteProfile.id), isNull);
      expect(await canonical.exists(), isFalse);
      expect(await backup.exists(), isFalse);
      expect((await dao.getByUrl(activeUrl))?.id, activeBefore!.id);

      final reimport = await repository.upsertRemote(url, validate: false, markAsActive: false).run();
      reimport.match((failure) => fail('explicit reimport after deletion failed: $failure'), (_) {});
      final reimported = await dao.getByUrl(url);
      expect(reimported, isNotNull);
      expect(reimported!.id, isNot(remoteProfile.id));
      expect(await paths.file(reimported.id).exists(), isTrue);
      expect((await dao.getByUrl(activeUrl))?.id, activeBefore.id);
      httpClient.downloadStarted = null;
      httpClient.downloadGate = null;
    },
  );

  test(
    'independent repository connections reject a stale refresh without rolling back the committed generation',
    () async {
      final sharedDirectory = await Directory.systemTemp.createTemp('marten-profile-shared-storage-');
      final sqliteFile = File('${sharedDirectory.path}/profiles.sqlite');
      final dbA = Db(NativeDatabase(sqliteFile));
      final dbB = Db(NativeDatabase(sqliteFile));
      addTearDown(() async {
        await dbB.close();
        await dbA.close();
        if (await sharedDirectory.exists()) await sharedDirectory.delete(recursive: true);
      });
      final clientA = _DownloadedConfigClient();
      final clientB = _DownloadedConfigClient();
      final daoA = ProfileDao(dbA);
      final daoB = ProfileDao(dbB);
      final paths = ProfilePathResolver(sharedDirectory);
      final repoA = ProfileRepositoryImpl(
        profileDataSource: daoA,
        profilePathResolver: paths,
        profileParser: ProfileParser(ref: _RecordingRef(container), httpClient: clientA),
        deviceIdentity: identity,
        readSingbox: () => throw StateError('validate:false refresh must stay off the core'),
        readConfigOptionRepository: () => throw StateError('validate:false refresh must not read settings'),
      );
      final repoB = ProfileRepositoryImpl(
        profileDataSource: daoB,
        profilePathResolver: paths,
        profileParser: ProfileParser(ref: _RecordingRef(container), httpClient: clientB),
        deviceIdentity: identity,
        readSingbox: () => throw StateError('validate:false refresh must stay off the core'),
        readConfigOptionRepository: () => throw StateError('validate:false refresh must not read settings'),
      );
      await repoA.init().run();
      await repoB.init().run();
      const url = 'https://example.test/shared-generation';
      final inserted = await repoA.upsertRemote(url, validate: false).run();
      inserted.match((failure) => fail('initial import failed: $failure'), (_) {});
      final stale = (await daoB.getByUrl(url))!.toEntity() as RemoteProfileEntity;
      final canonical = paths.file(stale.id);
      final backup = paths.backupFile(stale.id);
      final oldRevision = stale.revision;

      final lateStarted = Completer<void>();
      final lateGate = Completer<void>();
      clientB.downloadStarted = lateStarted;
      clientB.downloadGate = lateGate;
      clientB.content = '''
{"outbounds":[{"type":"vless","tag":"stale-candidate","server":"stale.example.test","server_port":443}]}
''';
      final lateRefresh = repoB.refreshRemote(stale, validate: false).run();
      await lateStarted.future;

      clientA.content = '''
{"outbounds":[{"type":"vless","tag":"committed-candidate","server":"committed.example.test","server_port":443}]}
''';
      final winningRefresh = await repoA.refreshRemote(stale, validate: false).run();
      winningRefresh.match((failure) => fail('winning refresh failed: $failure'), (_) {});
      lateGate.complete();
      final staleResult = await lateRefresh;

      expect(staleResult.isLeft(), isTrue, reason: 'the second DB connection must fail its persisted revision check');
      final persisted = await daoB.getById(stale.id);
      expect(persisted, isNotNull);
      expect(persisted!.revision, greaterThan(oldRevision));
      expect(await ProfileCrypto.decryptFile(canonical, identity.clientSecret), contains('committed-candidate'));
      expect(await ProfileCrypto.decryptFile(backup, identity.clientSecret), contains('committed-candidate'));
      expect(
        await _storageFilesExceptCoordinator(paths.directory),
        {canonical.path, backup.path},
        reason: 'neither connection may leave plaintext or stale transaction scratch beside durable copies',
      );
      clientB.downloadStarted = null;
      clientB.downloadGate = null;
    },
  );
}

Future<Set<String>> _storageFilesExceptCoordinator(Directory directory) async => (await directory.list().toList())
    .map((entity) => entity.path)
    .where((path) => !path.split(Platform.pathSeparator).last.startsWith('.mutations.sqlite'))
    .toSet();
