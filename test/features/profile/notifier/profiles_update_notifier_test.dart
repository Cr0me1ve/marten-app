import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/profile/notifier/profiles_update_notifier.dart';

void main() {
  test('foreground profile auto-refresh starts after the bounded startup delay', () {
    expect(ForegroundProfilesUpdateNotifier.initialStartupDelay, const Duration(seconds: 10));
    expect(ForegroundProfilesUpdateNotifier.interval, const Duration(minutes: 15));
  });
}
