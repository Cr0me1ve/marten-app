import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:marten/features/profile/data/subscription_compatibility.dart';

const _androidMetadata = <String, String>{
  'hwid': 'android-hwid-0011223344556677',
  'os': 'android',
  'osVersion': '14',
  'model': 'Pixel 9',
  'locale': 'en_US',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('app.marten.client/method');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
      call,
    ) async {
      if (call.method == 'get_subscription_client_metadata') {
        return _androidMetadata;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('happ Android compatibility', () {
    test('uses 5 for odd days and 6 for even days in Happ UA', () {
      final oddUa = SubscriptionCompatibility.happAndroidUserAgent(DateTime.utc(2026, 8, 11));
      final evenUa = SubscriptionCompatibility.happAndroidUserAgent(DateTime.utc(2026, 8, 12));

      expect(oddUa, equals('Happ/4.1.0/Android/17860740401641591541'));
      expect(evenUa, equals('Happ/4.1.0/Android/17860740401641591641'));
    });

    test('adds Android-specific compatibility headers when metadata is available', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final attempts = await SubscriptionCompatibility.attempts(channel: methodChannel, now: DateTime.utc(2026, 8, 12));

      expect(attempts, hasLength(4));
      expect(attempts[0].userAgent, equals('Happ/4.1.0/Android/17860740401641591641'));
      expect(attempts[0].headers, containsPair('X-HWID', 'android-hwid-0011223344556677'));
      expect(attempts[0].headers, containsPair('X-Device-OS', 'android'));
      expect(attempts[0].headers, containsPair('X-Ver-OS', '14'));
      expect(attempts[0].headers, containsPair('X-Device-model', 'Pixel 9'));
      expect(attempts[0].headers, containsPair('X-Device-Locale', 'en_US'));
      expect(attempts[0].headers.containsKey('Connection'), isFalse);
      expect(attempts[1].userAgent, equals('v2rayNG/1.10.31'));
      expect(attempts[2].userAgent, equals('ClashMetaForAndroid/2.11.20'));
      expect(attempts[3].userAgent, equals('SFA/1.12.0 (1; sing-box 1.12.0; language en_US)'));
    });

    test('reuses cached Android metadata when channel fails in background', () async {
      SharedPreferences.setMockInitialValues({});
      var requestCount = 0;
      final prefs = await SharedPreferences.getInstance();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
        call,
      ) async {
        if (call.method == 'get_subscription_client_metadata') {
          requestCount++;
          if (requestCount == 1) {
            return _androidMetadata;
          }
          throw MissingPluginException('no channel in background');
        }
        return null;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final first = await SubscriptionCompatibility.attempts(
        channel: methodChannel,
        now: DateTime.utc(2026, 8, 12),
        preferences: prefs,
      );
      final second = await SubscriptionCompatibility.attempts(
        channel: methodChannel,
        now: DateTime.utc(2026, 8, 12),
        preferences: prefs,
      );

      expect(requestCount, equals(2));
      expect(
        prefs.getString(SubscriptionCompatibility.androidMetadataCacheKey),
        equals(jsonEncode(_androidMetadata)),
      );
      expect(first, hasLength(4), reason: 'first attempt should include cached fallback candidate');
      expect(second, hasLength(4), reason: 'channel failure in background must keep cached Happ attempt');
      expect(first.first.userAgent, contains('Happ/4.1.0/Android/'));
      expect(second.first.userAgent, equals(first.first.userAgent));
      expect(second.first.headers['X-HWID'], equals('android-hwid-0011223344556677'));
      expect(second.first.headers['X-Device-OS'], equals('android'));
      expect(
        second.map((attempt) => attempt.userAgent),
        orderedEquals([
          first.first.userAgent,
          'v2rayNG/1.10.31',
          'ClashMetaForAndroid/2.11.20',
          'SFA/1.12.0 (1; sing-box 1.12.0; language en_US)',
        ]),
      );
    });

    test('falls back to default user agents when cache is missing and channel is unavailable', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
        call,
      ) async {
        if (call.method == 'get_subscription_client_metadata') {
          throw MissingPluginException('no channel in background');
        }
        return null;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final attempts = await SubscriptionCompatibility.attempts(
        channel: methodChannel,
        now: DateTime.utc(2026, 8, 12),
        preferences: prefs,
      );

      expect(attempts, hasLength(3));
      expect(attempts[0].userAgent, equals('v2rayNG/1.10.31'));
      expect(attempts[1].userAgent, equals('ClashMetaForAndroid/2.11.20'));
      expect(attempts[2].userAgent, equals('SFA/1.12.0 (1; sing-box 1.12.0; language en_US)'));
    });

    test('ignores malformed cached Android metadata and keeps fallback candidates', () async {
      SharedPreferences.setMockInitialValues({
        SubscriptionCompatibility.androidMetadataCacheKey: '{broken-json',
      });
      final prefs = await SharedPreferences.getInstance();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
        call,
      ) async {
        if (call.method == 'get_subscription_client_metadata') {
          throw MissingPluginException('no channel in background');
        }
        return null;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final attempts = await SubscriptionCompatibility.attempts(
        channel: methodChannel,
        now: DateTime.utc(2026, 8, 12),
        preferences: prefs,
      );

      expect(attempts, hasLength(3));
      expect(attempts[0].userAgent, equals('v2rayNG/1.10.31'));
      expect(attempts[1].userAgent, equals('ClashMetaForAndroid/2.11.20'));
      expect(attempts[2].userAgent, equals('SFA/1.12.0 (1; sing-box 1.12.0; language en_US)'));
    });
  });
}
