import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android background refresh only skips an active unverified user session', () {
    final source = File(
      'lib/features/profile/notifier/background_profiles_update.dart',
    ).readAsStringSync();
    final refresh = _sourceSection(
      source,
      'Future<bool> _runBackgroundRefresh({CancelToken? cancelToken}) async {',
      '\nFuture<bool> syncBackgroundNativeResumeConfig',
    );

    final androidAdmission = refresh.indexOf('if (Platform.isAndroid');
    final activeSession = refresh.indexOf(
      'container.read(Preferences.startedByUser)',
      androidAdmission,
    );
    final unverifiedRoute = refresh.indexOf(
      '!container.read(Preferences.strictVpnRouteVerified)',
      activeSession,
    );
    final skip = refresh.indexOf('return true;', unverifiedRoute);
    final identitySetup = refresh.indexOf('await container.read(deviceIdentityProvider.future);');
    final update = refresh.indexOf('.updateProfiles(validate: false, cancelToken: cancelToken);');

    expect(androidAdmission, greaterThanOrEqualTo(0));
    expect(
      activeSession,
      greaterThan(androidAdmission),
      reason: 'only an Android session that remains user-active may be blocked',
    );
    if (activeSession < 0) return;
    expect(
      unverifiedRoute,
      greaterThan(activeSession),
      reason: 'the active-session block must require an unverified VPN route',
    );
    if (unverifiedRoute < 0) return;
    expect(
      skip,
      greaterThan(unverifiedRoute),
      reason: 'an active unverified Android session must skip optional refresh networking',
    );
    expect(
      identitySetup,
      greaterThan(skip),
      reason: 'terminally disconnected Android runs must continue into refresh setup',
    );
    expect(
      update,
      greaterThan(identitySetup),
      reason: 'verified routes and terminally disconnected runs must update subscriptions',
    );
  });
}

String _sourceSection(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $startMarker');
  final end = source.indexOf(endMarker, start);
  expect(end, greaterThan(start), reason: 'missing $endMarker after $startMarker');
  return source.substring(start, end);
}
