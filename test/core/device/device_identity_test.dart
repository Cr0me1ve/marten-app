import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/device/device_identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('app.marten.client/method');
  const stableAndroidId = 'android-v1:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      methodChannel,
      (call) async => switch (call.method) {
        'get_stable_device_id' => stableAndroidId,
        _ => null,
      },
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, null);
  });

  test('uses stable Android device id for a fresh install', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final identity = await container.read(deviceIdentityProvider.future);

    expect(identity.deviceId, stableAndroidId);
    expect(identity.clientSecret, isNotEmpty);
  });

  test('keeps existing device id so app updates do not rebind subscriptions', () async {
    FlutterSecureStorage.setMockInitialValues({
      'marten_device_id': 'legacy-random-device-id',
      'marten_client_secret': 'existing-client-secret',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final identity = await container.read(deviceIdentityProvider.future);

    expect(identity.deviceId, 'legacy-random-device-id');
    expect(identity.clientSecret, 'existing-client-secret');
  });

  test('preserves a stored client secret when the device id is recreated from the platform identity', () async {
    FlutterSecureStorage.setMockInitialValues({'marten_client_secret': 'existing-client-secret'});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final identity = await container.read(deviceIdentityProvider.future);

    expect(identity.deviceId, stableAndroidId);
    expect(identity.clientSecret, 'existing-client-secret');
  });

  test('rejects malformed platform ids', () {
    expect(normalizePlatformDeviceIdForTest(null), isNull);
    expect(normalizePlatformDeviceIdForTest(''), isNull);
    expect(normalizePlatformDeviceIdForTest('ios-vendor-id'), isNull);
    expect(normalizePlatformDeviceIdForTest('  $stableAndroidId  '), stableAndroidId);
  });
}
