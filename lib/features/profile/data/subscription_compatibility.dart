import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _martenMethodChannel = MethodChannel('app.marten.client/method');

@immutable
class SubscriptionCompatibilityAttempt {
  const SubscriptionCompatibilityAttempt({required this.userAgent, this.headers = const {}});

  final String userAgent;
  final Map<String, String> headers;
}

/// Client-compatible content negotiation for subscription panels that return
/// different representations according to the importing application's request.
/// Parsing remains in marten-core; this layer only selects a representation.
abstract final class SubscriptionCompatibility {
  @visibleForTesting
  static const androidMetadataCacheKey = 'subscription.compatibility.android_metadata.v1';

  static Future<List<SubscriptionCompatibilityAttempt>> attempts({
    MethodChannel channel = _martenMethodChannel,
    DateTime? now,
    SharedPreferences? preferences,
  }) async {
    final attempts = <SubscriptionCompatibilityAttempt>[];
    final platformMetadata = await _androidMetadata(channel);
    if (platformMetadata != null) {
      await _cacheAndroidMetadata(platformMetadata, preferences);
    }
    final androidMetadata = platformMetadata ?? await _cachedAndroidMetadata(preferences);
    if (androidMetadata != null) {
      attempts.add(
        SubscriptionCompatibilityAttempt(
          userAgent: happAndroidUserAgent(now ?? DateTime.now()),
          headers: {
            if (androidMetadata.hwid.isNotEmpty) 'X-HWID': androidMetadata.hwid,
            'X-Device-OS': androidMetadata.os,
            'X-Ver-OS': androidMetadata.osVersion,
            'X-Device-model': androidMetadata.model,
            'X-Device-Locale': androidMetadata.locale,
          },
        ),
      );
    }

    return [
      ...attempts,
      const SubscriptionCompatibilityAttempt(userAgent: 'v2rayNG/1.10.31'),
      const SubscriptionCompatibilityAttempt(userAgent: 'ClashMetaForAndroid/2.11.20'),
      const SubscriptionCompatibilityAttempt(userAgent: 'SFA/1.12.0 (1; sing-box 1.12.0; language en_US)'),
    ];
  }

  /// Warms the app-private cache while the activity channel is available so
  /// Workmanager and Firebase headless isolates can negotiate the same format.
  static Future<void> primeAndroidMetadata({
    MethodChannel channel = _martenMethodChannel,
    SharedPreferences? preferences,
  }) async {
    final metadata = await _androidMetadata(channel);
    if (metadata != null) await _cacheAndroidMetadata(metadata, preferences);
  }

  @visibleForTesting
  static String happAndroidUserAgent(DateTime now) {
    final dailyDigit = now.day.isEven ? '6' : '5';
    return 'Happ/4.1.0/Android/17860740401641591${dailyDigit}41';
  }

  static Future<_AndroidSubscriptionMetadata?> _androidMetadata(MethodChannel channel) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final raw = await channel.invokeMapMethod<String, String>('get_subscription_client_metadata');
      if (raw == null) return null;
      final metadata = _AndroidSubscriptionMetadata.fromMap(raw);
      return metadata.isUsable ? metadata : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<void> _cacheAndroidMetadata(
    _AndroidSubscriptionMetadata metadata,
    SharedPreferences? preferences,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      await prefs.setString(androidMetadataCacheKey, jsonEncode(metadata.toMap()));
    } catch (_) {
      // Compatibility negotiation still has the platform value for this run.
    }
  }

  static Future<_AndroidSubscriptionMetadata?> _cachedAndroidMetadata(SharedPreferences? preferences) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      final encoded = prefs.getString(androidMetadataCacheKey);
      if (encoded == null || encoded.isEmpty) return null;
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return null;
      final metadata = _AndroidSubscriptionMetadata.fromMap(
        decoded.map((key, value) => MapEntry(key.toString(), value?.toString() ?? '')),
      );
      return metadata.isUsable ? metadata : null;
    } catch (_) {
      return null;
    }
  }
}

@immutable
class _AndroidSubscriptionMetadata {
  const _AndroidSubscriptionMetadata({
    required this.hwid,
    required this.os,
    required this.osVersion,
    required this.model,
    required this.locale,
  });

  factory _AndroidSubscriptionMetadata.fromMap(Map<String, String> value) => _AndroidSubscriptionMetadata(
    hwid: value['hwid']?.trim() ?? '',
    os: value['os']?.trim() ?? '',
    osVersion: value['osVersion']?.trim() ?? '',
    model: value['model']?.trim() ?? '',
    locale: value['locale']?.trim() ?? '',
  );

  final String hwid;
  final String os;
  final String osVersion;
  final String model;
  final String locale;

  bool get isUsable => hwid.isNotEmpty && os.isNotEmpty && osVersion.isNotEmpty && model.isNotEmpty;

  Map<String, String> toMap() => {'hwid': hwid, 'os': os, 'osVersion': osVersion, 'model': model, 'locale': locale};
}
