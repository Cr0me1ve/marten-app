import 'dart:io';

// These Firebase platform interfaces are test-only fakes for initialization.
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/src/pigeon/messages.pigeon.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/src/pigeon/test_api.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/analytics/analytics_controller.dart';
import 'package:marten/core/analytics/analytics_logger.dart';
import 'package:marten/core/preferences/preferences_migration.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('returns true for a clean install without migration marker and analytics preference', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    expect(readCrashReportingEnabledPreference(preferences), isTrue);
  });

  test('returns true when analytics preference is missing but migration marker exists (upgrade path)', () async {
    SharedPreferences.setMockInitialValues({PreferencesMigration.versionKey: 7});
    final preferences = await SharedPreferences.getInstance();

    expect(readCrashReportingEnabledPreference(preferences), isTrue);
  });

  test('preserves explicitly saved false value even with migration marker', () async {
    SharedPreferences.setMockInitialValues({enableAnalyticsPrefKey: false, PreferencesMigration.versionKey: 7});
    final preferences = await SharedPreferences.getInstance();

    expect(readCrashReportingEnabledPreference(preferences), isFalse);
  });

  test('preserves explicitly saved true value even with migration marker', () async {
    SharedPreferences.setMockInitialValues({enableAnalyticsPrefKey: true, PreferencesMigration.versionKey: 7});
    final preferences = await SharedPreferences.getInstance();

    expect(readCrashReportingEnabledPreference(preferences), isTrue);
  });

  test('Firebase initialization failure is retried by the next controller event', () async {
    if (!Platform.isMacOS) return;
    SharedPreferences.setMockInitialValues({enableAnalyticsPrefKey: true});
    final preferences = await SharedPreferences.getInstance();
    final firebase = FailingOnceFirebaseCore();
    TestFirebaseCoreHostApi.setUp(firebase);
    const crashlyticsChannel = MethodChannel('plugins.flutter.io/firebase_crashlytics');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final crashlyticsCalls = <String>[];
    messenger.setMockMethodCallHandler(crashlyticsChannel, (call) {
      crashlyticsCalls.add(call.method);
      if (call.method == 'Crashlytics#setCrashlyticsCollectionEnabled') {
        final arguments = call.arguments! as Map<Object?, Object?>;
        return Future<Object?>.value(<String, Object?>{'isCrashlyticsCollectionEnabled': arguments['enabled']});
      }
      return null;
    });
    // Firebase's platform singleton caches apps between tests in one isolate.
    MethodChannelFirebase.appInstances.clear();
    MethodChannelFirebase.isCoreInitialized = false;

    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) => preferences)]);
    await container.read(sharedPreferencesProvider.future);
    addTearDown(() async {
      container.dispose();
      await crashReporter.disable();
      TestFirebaseCoreHostApi.setUp(null);
      messenger.setMockMethodCallHandler(crashlyticsChannel, null);
      MethodChannelFirebase.appInstances.clear();
      MethodChannelFirebase.isCoreInitialized = false;
    });

    expect(await container.read(analyticsControllerProvider.future), isTrue);
    final controller = container.read(analyticsControllerProvider.notifier);
    await controller.ensureInitialized();
    expect(firebase.initializeCoreCalls, 1);
    expect(crashReporter.isEnabled, isFalse);

    await Future.wait(<Future<void>>[controller.ensureInitialized(), controller.ensureInitialized()]);

    expect(
      firebase.initializeCoreCalls,
      2,
      reason: 'failed initialization must clear its coalescing slot for a later event',
    );
    final callsAfterRetry = List<String>.of(crashlyticsCalls);
    await controller.ensureInitialized();
    expect(firebase.initializeCoreCalls, 2, reason: 'a subsequent healthy event should not reinitialize Firebase Core');
    expect(crashlyticsCalls, callsAfterRetry, reason: 'a subsequent healthy event should not repeat Crashlytics setup');
  });
}

class FailingOnceFirebaseCore implements TestFirebaseCoreHostApi {
  int initializeCoreCalls = 0;

  @override
  Future<List<CoreInitializeResponse>> initializeCore() async {
    initializeCoreCalls++;
    if (initializeCoreCalls == 1) throw PlatformException(code: 'temporary-init-failure');
    return <CoreInitializeResponse>[
      CoreInitializeResponse(
        name: '[DEFAULT]',
        options: CoreFirebaseOptions(apiKey: 'api', appId: 'app', messagingSenderId: 'sender', projectId: 'project'),
        pluginConstants: <String, Object?>{},
      ),
    ];
  }

  @override
  Future<CoreInitializeResponse> initializeApp(String appName, CoreFirebaseOptions initializeAppRequest) async =>
      throw UnsupportedError('initializeCore should provide the default app');

  @override
  Future<CoreFirebaseOptions> optionsFromResource() async =>
      throw UnsupportedError('initializeCore should provide the default app');
}
