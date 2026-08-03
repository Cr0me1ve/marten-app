import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/profile/notifier/subscription_push_refresh.dart';
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
}
