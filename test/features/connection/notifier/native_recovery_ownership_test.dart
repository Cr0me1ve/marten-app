import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/features/connection/model/connection_failure.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/singbox/model/core_status.dart';

void main() {
  Future<TranslationsEn> loadRuTranslations() => AppLocale.ru.build();

  test('Flutter reconnect defers to Android native recovery transitions', () {
    expect(
      shouldDeferFlutterReconnect(
        isAndroid: true,
        nativeRecoveryInProgress: true,
        platformStatus: const CoreStatus.started(),
      ),
      isTrue,
    );
    expect(
      shouldDeferFlutterReconnect(
        isAndroid: true,
        nativeRecoveryInProgress: false,
        platformStatus: const CoreStatus.starting(),
      ),
      isTrue,
    );
    expect(
      shouldDeferFlutterReconnect(
        isAndroid: true,
        nativeRecoveryInProgress: false,
        platformStatus: const CoreStatus.stopping(),
      ),
      isTrue,
    );
  });

  test('Flutter reconnect remains available outside Android native recovery', () {
    expect(
      shouldDeferFlutterReconnect(
        isAndroid: true,
        nativeRecoveryInProgress: false,
        platformStatus: const CoreStatus.started(),
      ),
      isFalse,
    );
    expect(
      shouldDeferFlutterReconnect(
        isAndroid: false,
        nativeRecoveryInProgress: true,
        platformStatus: const CoreStatus.starting(),
      ),
      isFalse,
    );
  });

  test('persistent connection status stream does not self-invalidate lifecycle work', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();

    expect(source, isNot(contains('ref.watch(coreRestartSignalProvider)')));
  });

  test('Android-selected-route startup failures are terminal and never delegated to recovery', () async {
    final t = await loadRuTranslations();
    const routeFailure = ConnectionFailure.unexpected('selected route failed startup connectivity check');

    expect(
      File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync(),
      isNot(contains('shouldDelegateFailedConnectionToAndroidRecovery')),
      reason: 'a failed startup already awaited native Stop/Close and must publish its terminal result',
    );
    expect(routeFailure.present(t).type, 'сервер недоступен');
  });

  test('owned Android cold attach arms CAPTCHA before existing-session route verification', () {
    final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();
    final verificationStart = source.indexOf('Future<void> _verifyExistingStartedRoute() async {');
    final verificationEnd = source.indexOf(
      '\n  void _scheduleExistingStartedRouteVerificationRetry',
      verificationStart,
    );
    expect(verificationStart, isNonNegative);
    expect(verificationEnd, greaterThan(verificationStart));
    final verification = source.substring(verificationStart, verificationEnd);

    final unownedStart = verification.indexOf('if (!ownsSession) {');
    final routeProof = verification.indexOf('verifyConnectedRoute(holdStartupRouteReady: true)');
    final captchaArm = verification.indexOf('captchaNotifierProvider.notifier).arm(enabled: true)');
    final androidGate = verification.lastIndexOf('if (Platform.isAndroid)', captchaArm);
    expect(unownedStart, isNonNegative);
    expect(routeProof, isNonNegative);
    expect(androidGate, greaterThan(unownedStart));
    expect(androidGate, lessThan(captchaArm));
    expect(captchaArm, greaterThan(unownedStart));
    expect(captchaArm, lessThan(routeProof));

    final unownedBranch = verification.substring(unownedStart, captchaArm);
    expect(unownedBranch, contains('await _disconnect(showError: false)'));
    expect(unownedBranch, contains('state = const AsyncData(Disconnected())'));
    expect(unownedBranch, isNot(contains('captchaNotifierProvider.notifier).arm(')));

    final ownedSetup = verification.substring(androidGate, routeProof);
    expect(ownedSetup, contains('if (Platform.isAndroid)'));
    expect(ownedSetup, contains('captchaNotifierProvider.notifier).arm(enabled: true)'));
  });
}
