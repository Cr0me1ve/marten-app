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

  group('externalPushTokenRegistrationUrl', () {
    test('accepts only clean HTTPS URLs', () {
      expect(
        externalPushTokenRegistrationUrl('https://push.example.net/device/registration')?.toString(),
        equals('https://push.example.net/device/registration'),
      );
      expect(externalPushTokenRegistrationUrl('http://push.example.net/device/registration'), isNull);
      expect(externalPushTokenRegistrationUrl('https://u:p@push.example.net/device/registration'), isNull);
      expect(externalPushTokenRegistrationUrl('https://push.example.net/device/registration?x=1'), isNull);
      expect(externalPushTokenRegistrationUrl('https://push.example.net/device/registration#frag'), isNull);
      expect(externalPushTokenRegistrationUrl('  '), isNull);
    });
  });

  group('pushTokenRegistrationUrlsFor', () {
    test('prioritizes explicit valid override before derived candidates', () {
      final profile = RemoteProfileEntity(
        id: 'profile-a',
        active: true,
        name: 'Profile A',
        url: 'https://edge.example.com/sub/token-1',
        lastUpdate: DateTime(2026, 8, 18),
        userOverride: const UserOverride(pushEndpoint: 'https://push.example.net/registration'),
      );

      final urls = pushTokenRegistrationUrlsFor(profile);

      expect(
        urls.map((url) => url.toString()),
        orderedEquals([
          'https://push.example.net/registration',
          'https://edge.example.com/sub/token-1/device/push-token',
        ]),
      );
    });

    test('deduplicates override and derived URLs', () {
      final profile = RemoteProfileEntity(
        id: 'profile-a',
        active: true,
        name: 'Profile A',
        url: 'https://edge.example.com/sub/token-1',
        lastUpdate: DateTime(2026, 8, 18),
        userOverride: const UserOverride(pushEndpoint: 'https://edge.example.com/sub/token-1/device/push-token'),
      );

      final urls = pushTokenRegistrationUrlsFor(profile);

      expect(urls, hasLength(1));
      expect(urls.single.toString(), equals('https://edge.example.com/sub/token-1/device/push-token'));
    });

    test('falls back to derived URLs when override is invalid', () {
      final profile = RemoteProfileEntity(
        id: 'profile-a',
        active: true,
        name: 'Profile A',
        url: 'https://edge.example.com/sub/token-1',
        lastUpdate: DateTime(2026, 8, 18),
        userOverride: const UserOverride(pushEndpoint: 'http://push.example.net/registration'),
      );

      final urls = pushTokenRegistrationUrlsFor(profile);

      expect(
        urls.map((url) => url.toString()),
        orderedEquals(['https://edge.example.com/sub/token-1/device/push-token']),
      );
    });
  });
}
