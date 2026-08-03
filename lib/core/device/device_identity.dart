import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'device_identity.g.dart';

const _deviceIdKey = 'marten_device_id';
const _clientSecretKey = 'marten_client_secret';
const _methodChannel = MethodChannel('app.marten.client/method');
const _androidStableDeviceIdPrefix = 'android-v1:';

const _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  // macOS: use the legacy login keychain instead of the data-protection
  // keychain so the app does not need a `keychain-access-groups` entitlement
  // (which is unavailable for ad-hoc / unsigned local builds and currently
  // fails with errSecMissingEntitlement = -34018).
  mOptions: MacOsOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    useDataProtectionKeyChain: false,
  ),
);

@Riverpod(keepAlive: true)
Future<DeviceIdentity> deviceIdentity(Ref ref) async {
  final platformDeviceId = await _readPlatformStableDeviceId();
  final storedValues = await _readStorageValues();

  // Do not replace an existing id: the server may already have a subscription
  // bound to that exact value, so app updates must keep sending it.
  var deviceId = _normalizeStorageValue(storedValues[_deviceIdKey]);
  if (deviceId == null) {
    deviceId = platformDeviceId ?? const Uuid().v4();
    await _writeStorageValue(_deviceIdKey, deviceId);
  }

  var clientSecret = _normalizeStorageValue(storedValues[_clientSecretKey]);
  if (clientSecret == null) {
    clientSecret = const Uuid().v4();
    await _writeStorageValue(_clientSecretKey, clientSecret);
  }

  return DeviceIdentity(deviceId: deviceId, clientSecret: clientSecret);
}

Future<String?> _readPlatformStableDeviceId() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return null;
  }

  try {
    final value = await _methodChannel.invokeMethod<String>('get_stable_device_id');
    return _normalizePlatformDeviceId(value);
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

@visibleForTesting
String? normalizePlatformDeviceIdForTest(String? value) => _normalizePlatformDeviceId(value);

String? _normalizePlatformDeviceId(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  if (!normalized.startsWith(_androidStableDeviceIdPrefix)) {
    return null;
  }
  return normalized;
}

Future<Map<String, String>> _readStorageValues() async {
  try {
    return await _storage.readAll();
  } on PlatformException {
    // Android can restore encrypted SharedPreferences without the matching
    // Keystore key after uninstall/reinstall. The values are unrecoverable, so
    // clear them and let the stable platform id recreate device identity.
    await _deleteAllStorageValues();
    return const {};
  }
}

String? _normalizeStorageValue(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

Future<void> _writeStorageValue(String key, String value) async {
  try {
    await _storage.write(key: key, value: value);
  } on PlatformException {
    await _deleteAllStorageValues();
    await _storage.write(key: key, value: value);
  }
}

Future<void> _deleteAllStorageValues() async {
  try {
    await _storage.deleteAll();
  } on PlatformException {
    // Best effort: a following write will surface the real failure if storage
    // is still unavailable.
  }
}

class DeviceIdentity {
  const DeviceIdentity({required this.deviceId, required this.clientSecret});

  final String deviceId;
  final String clientSecret;
}
