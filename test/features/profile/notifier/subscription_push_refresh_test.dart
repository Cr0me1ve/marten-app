import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/profile/notifier/subscription_push_refresh.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('pushTokenRegistrationUrlFor', () {
    test('builds edge registration URL for Marten subscription endpoint', () {
      final url = pushTokenRegistrationUrlFor('https://edge.example/sub/token-a');

      expect(url.toString(), 'https://edge.example/sub/token-a/device/push-token');
    });

    test('ignores non subscription endpoints', () {
      expect(pushTokenRegistrationUrlFor('https://edge.example/other/token-a'), isNull);
      expect(pushTokenRegistrationUrlFor('marten://import?url=https%3A%2F%2Fedge.example%2Fsub%2Ft'), isNull);
    });

    test('ignores unsafe external push registration endpoints', () {
      expect(externalPushTokenRegistrationUrl('http://push.example.net/registration'), isNull);
      expect(externalPushTokenRegistrationUrl('https://push.example.net/registration?token=a'), isNull);
      expect(externalPushTokenRegistrationUrl('https://user:pass@push.example.net/registration'), isNull);
    });
  });

  group('pushTokenRegistrationUrlsFor', () {
    test('prioritizes explicit HTTPS push endpoint and deduplicates derived URLs', () {
      final profile = RemoteProfileEntity(
        id: 'profile-a',
        active: true,
        name: 'Family',
        url: 'https://edge.example.net/sub/token-1',
        lastUpdate: DateTime.now(),
        subscriptionEndpoints: const ['https://edge-alt.example.net'],
        currentSubscriptionEndpoint: 'https://edge-alt.example.net',
        userOverride: const UserOverride(pushEndpoint: 'https://edge-alt.example.net/sub/token-1/device/push-token'),
      );

      final urls = pushTokenRegistrationUrlsFor(profile).map((uri) => uri.toString()).toList();
      expect(
        urls,
        equals([
          'https://edge-alt.example.net/sub/token-1/device/push-token',
          'https://edge.example.net/sub/token-1/device/push-token',
        ]),
      );
    });

    test('falls back to derived endpoints when explicit override is invalid', () {
      final profile = RemoteProfileEntity(
        id: 'profile-b',
        active: true,
        name: 'Fallback',
        url: 'https://edge.example.net/sub/token-1',
        lastUpdate: DateTime.now(),
        userOverride: const UserOverride(pushEndpoint: 'http://push.example.net/registration'),
      );

      final urls = pushTokenRegistrationUrlsFor(profile).map((uri) => uri.toString()).toList();
      expect(urls, equals(['https://edge.example.net/sub/token-1/device/push-token']));
    });
  });

  group('readPushBindingId', () {
    test('creates and reuses stable binding id per profile', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final first = await readPushBindingId(prefs, 'profile-a', create: true);
      final second = await readPushBindingId(prefs, 'profile-a', create: true);

      expect(first, isNotNull);
      expect(second, first);
    });

    test('does not create binding when create is false', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final binding = await readPushBindingId(prefs, 'profile-a', create: false);

      expect(binding, isNull);
    });
  });
}
