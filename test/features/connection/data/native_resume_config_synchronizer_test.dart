import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/crypto/profile_crypto.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/features/connection/data/native_resume_config_synchronizer.dart';
import 'package:marten/features/profile/data/profile_path_resolver.dart';
import 'package:marten/features/profile/model/profile_entity.dart';

final class _RecordingPublisher implements NativeResumeConfigPublisher {
  _RecordingPublisher({this.storeResult = true});

  final bool storeResult;
  final List<({String path, String name, String content})> stored = [];
  int clearCalls = 0;

  @override
  Future<bool> clear() async {
    clearCalls++;
    return true;
  }

  @override
  Future<bool> store({required String path, required String name}) async {
    stored.add((path: path, name: name, content: await File(path).readAsString()));
    return storeResult;
  }
}

void main() {
  const identity = DeviceIdentity(deviceId: 'device-id', clientSecret: 'client-secret');
  const config = '''
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "vless", "tag": "Selected outbound", "server": "198.51.100.10", "server_port": 443}
  ]
}
''';

  late Directory workingDirectory;
  late ProfilePathResolver paths;

  setUp(() async {
    workingDirectory = await Directory.systemTemp.createTemp('marten-native-resume-sync-test-');
    paths = ProfilePathResolver(workingDirectory);
  });

  tearDown(() async {
    if (await workingDirectory.exists()) await workingDirectory.delete(recursive: true);
  });

  ProfileEntity activeProfile() => ProfileEntity.remote(
    id: 'active-profile',
    active: true,
    name: 'Profile fallback name',
    url: 'https://example.test/subscription',
    lastUpdate: DateTime.utc(2026),
  );

  Future<void> writeActiveConfig() =>
      ProfileCrypto.encryptContentToFile(paths.file('active-profile'), config, identity.clientSecret);

  NativeResumeConfigSynchronizer synchronizer(_RecordingPublisher publisher) => NativeResumeConfigSynchronizer(
    profilePathResolver: paths,
    deviceIdentity: Future.value(identity),
    publisher: publisher,
    resolveSelectedTag: (_, tags) => tags.singleWhere((tag) => tag == 'Selected outbound'),
    isAndroid: true,
  );

  test('stores a selected active profile and removes plaintext after publishing', () async {
    await writeActiveConfig();
    final publisher = _RecordingPublisher();

    final result = await synchronizer(publisher).synchronize(activeProfile()).run();

    expect(result.isRight(), isTrue);
    expect(publisher.clearCalls, 0);
    expect(publisher.stored, hasLength(1));
    expect(publisher.stored.single.name, 'Selected outbound');
    expect(publisher.stored.single.content, isNot(contains('MARTEN_ENC_V1:')));
    expect(publisher.stored.single.content, contains('Selected outbound'));
    expect(await File(publisher.stored.single.path).exists(), isFalse, reason: 'the native hand-off is plaintext');
  });

  test('clears native resume configuration when no profile is active', () async {
    final publisher = _RecordingPublisher();

    final result = await synchronizer(publisher).synchronize(null).run();

    expect(result.isRight(), isTrue);
    expect(publisher.clearCalls, 1);
    expect(publisher.stored, isEmpty);
  });

  test('clears stale native state after a failed store and removes plaintext', () async {
    await writeActiveConfig();
    final publisher = _RecordingPublisher(storeResult: false);

    final result = await synchronizer(publisher).synchronize(activeProfile()).run();

    expect(result.isLeft(), isTrue);
    expect(publisher.stored, hasLength(1));
    expect(publisher.clearCalls, 1);
    expect(
      await paths.directory.list().where((entry) => entry.path.contains('_native_resume_')).isEmpty,
      isTrue,
      reason: 'failed synchronization must not leave decrypted resume configuration on disk',
    );
  });

  test('stale synchronization performs no native write and still removes its temporary plaintext', () async {
    await writeActiveConfig();
    final publisher = _RecordingPublisher();

    final result = await synchronizer(publisher).synchronize(activeProfile(), isCurrent: () => false).run();

    expect(result.isRight(), isTrue);
    expect(publisher.stored, isEmpty);
    expect(publisher.clearCalls, 0);
    expect(await paths.directory.list().where((entry) => entry.path.contains('_native_resume_')).isEmpty, isTrue);
  });
}
