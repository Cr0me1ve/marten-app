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

  test('Android-selected-route startup failures should be delegated to native recovery', () async {
    final t = await loadRuTranslations();
    const routeFailure = ConnectionFailure.unexpected('selected route failed startup connectivity check');
    const coreFailure = ConnectionFailure.unexpected('background core is not started yet');
    const configFailure = ConnectionFailure.invalidConfig(missingProfileConfigFailureMessage);

    expect(
      shouldDelegateFailedConnectionToAndroidRecovery(
        isAndroid: true,
        failure: routeFailure,
        platformStatus: const CoreStatus.starting(),
        platformStartedByUser: true,
        nativeRecoveryInProgress: false,
      ),
      isTrue,
      reason: 'android selected-route failure should be recoverable by native path',
    );
    expect(
      shouldDelegateFailedConnectionToAndroidRecovery(
        isAndroid: false,
        failure: routeFailure,
        platformStatus: const CoreStatus.starting(),
        platformStartedByUser: true,
        nativeRecoveryInProgress: false,
      ),
      isFalse,
      reason: 'non-android must not delegate startup route failure to service recovery',
    );
    expect(
      shouldDelegateFailedConnectionToAndroidRecovery(
        isAndroid: true,
        failure: coreFailure,
        platformStatus: const CoreStatus.starting(),
        platformStartedByUser: true,
        nativeRecoveryInProgress: false,
      ),
      isFalse,
      reason: 'non-selected-route startup failure should stay in Flutter recovery',
    );
    expect(
      shouldDelegateFailedConnectionToAndroidRecovery(
        isAndroid: true,
        failure: configFailure,
        platformStatus: const CoreStatus.starting(),
        platformStartedByUser: true,
        nativeRecoveryInProgress: false,
      ),
      isFalse,
      reason: 'config failures should not be delegated to Android startup recovery',
    );
    expect(
      shouldDelegateFailedConnectionToAndroidRecovery(
        isAndroid: true,
        failure: routeFailure,
        platformStatus: const CoreStatus.started(),
        platformStartedByUser: true,
        nativeRecoveryInProgress: false,
      ),
      isTrue,
      reason: 'android selected-route failure should delegate once ownership and a live status are both confirmed',
    );
    expect(
      shouldDelegateFailedConnectionToAndroidRecovery(
        isAndroid: true,
        failure: routeFailure,
        platformStatus: const CoreStatus.starting(),
        platformStartedByUser: false,
        nativeRecoveryInProgress: false,
      ),
      isFalse,
      reason: 'android selected-route failure must be started by platform user to delegate',
    );
    expect(routeFailure.present(t).type, 'сервер недоступен');
  });
}
