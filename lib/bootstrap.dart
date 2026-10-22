import 'dart:async';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/analytics/analytics_controller.dart';
import 'package:marten/core/analytics/analytics_logger.dart';
import 'package:marten/core/analytics/pending_crash_report.dart';
import 'package:marten/core/app_info/app_info_provider.dart';
import 'package:marten/core/diagnostics/energy_profiler.dart';
import 'package:marten/core/directories/directories_provider.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/logger/logger.dart';
import 'package:marten/core/logger/logger_controller.dart';
import 'package:marten/core/model/app_info_entity.dart';
import 'package:marten/core/model/environment.dart';
import 'package:marten/core/network/strict_vpn_egress_gate.dart';
import 'package:marten/core/preferences/general_preferences.dart';
import 'package:marten/core/preferences/preferences_migration.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/core/utils/ui_idle_gate.dart';
import 'package:marten/features/app/widget/app.dart';
import 'package:marten/features/auto_start/notifier/auto_start_notifier.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';

import 'package:marten/features/log/data/log_data_providers.dart';
import 'package:marten/features/profile/notifier/background_profiles_update.dart';
import 'package:marten/features/profile/notifier/subscription_push_refresh.dart';
import 'package:marten/features/system_tray/notifier/system_tray_notifier.dart';
import 'package:marten/features/window/notifier/window_notifier.dart';
import 'package:marten/martencore/marten_core_service_provider.dart';
import 'package:marten/riverpod_observer.dart';
import 'package:marten/utils/utils.dart';

Future<void> lazyBootstrap(WidgetsBinding widgetsBinding, Environment env) async {
  if (!kIsWeb) {
    FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  }
  LoggerController.preInit();
  FlutterError.onError = Logger.logFlutterError;
  WidgetsBinding.instance.platformDispatcher.onError = Logger.logPlatformDispatcherError;

  final stopWatch = Stopwatch()..start();

  final container = ProviderContainer(
    overrides: [environmentProvider.overrideWithValue(env)],
    observers: [RiverpodObserver()],
  );

  final directoriesFuture = _init("directories", () => container.read(appDirectoriesProvider.future));
  final appInfoFuture = _init("app info", () => container.read(appInfoProvider.future));
  final preferencesFuture = _init("preferences", () => container.read(sharedPreferencesProvider.future));

  final (_, appInfo, _) = await (directoriesFuture, appInfoFuture, preferencesFuture).wait;
  DartEnergyProfiler.start((await directoriesFuture).workingDir);
  LoggerController.init(container.read(logPathResolverProvider).appFile().path, debugConsole: !PlatformUtils.isMobile);
  final crashReportingEnabled = readCrashReportingEnabledPreference(
    container.read(sharedPreferencesProvider).requireValue,
  );
  crashReporter
    ..setContextCollectionEnabled(crashReportingEnabled)
    ..setContext('environment', env.name)
    ..startLifecycleTracking();
  if (PlatformUtils.isAndroid) {
    await _safeInit('local crash capture', () async {
      final path = await const MethodChannel(
        'app.marten.client/platform',
      ).invokeMethod<String>('get_local_crash_directory');
      if (path == null) return;
      await crashReporter.configureLocalCapture(
        store: FilePendingCrashReportStore(Directory(path)),
        enabled: crashReportingEnabled,
      );
    });
  }
  final enableCrashReporting = await _safeInit(
    "crash reporting preference",
    () => container.read(analyticsControllerProvider.future),
  );
  if (enableCrashReporting == true && !PlatformUtils.isAndroid) {
    await _safeInit("crash reporting", () => container.read(analyticsControllerProvider.notifier).ensureInitialized());
  }
  final strictAndroidSessionPending = PlatformUtils.isAndroid && container.read(Preferences.startedByUser);
  // Android must start with every optional network SDK cold. Process network
  // binding applies only to future sockets, so Crashlytics/FCM/WorkManager are
  // initialized later by ConnectionNotifier after a verified VPN route.
  final networkServicesAdmitted = !PlatformUtils.isAndroid;
  if (strictAndroidSessionPending) {
    // A retained route-verified Started generation is already the native
    // network authority. Inspect it before touching the process-wide probe
    // gate: sealing first would invalidate the very admission being joined.
    final retainedAdmission = await _safeInit(
      "retained Android VPN network admission",
      () => container.read(martenCoreServiceProvider).tryJoinVerifiedVpnAdmission(),
    );
    if (retainedAdmission != null) {
      Logger.bootstrap.info('joined retained route-verified Android VPN admission');
    } else {
      await strictVpnEgressGate.sealForVpnTransition();
      final admitted = await _safeInit(
        "strict Android VPN network admission",
        () => container.read(martenCoreServiceProvider).beginVpnStartAdmission(resumeSession: true),
      );
      if (admitted == null) {
        Logger.bootstrap.error('strict Android VPN network admission failed; optional networking remains disabled');
      }
    }
  }

  await _init("preferences migration", () async {
    try {
      await PreferencesMigration(sharedPreferences: container.read(sharedPreferencesProvider).requireValue).migrate();
    } catch (e, stackTrace) {
      Logger.bootstrap.error("preferences migration failed", e, stackTrace);
      if (env == Environment.dev) rethrow;
      Logger.bootstrap.info("clearing preferences");
      await container.read(sharedPreferencesProvider).requireValue.clear();
    }
  });

  final debug = container.read(debugModeNotifierProvider) || kDebugMode;
  if (networkServicesAdmitted) {
    registerSubscriptionPushBackgroundHandler();
  } else {
    Logger.bootstrap.info('deferring subscription push handler until a VPN-admitted process');
  }

  if (PlatformUtils.isDesktop) {
    await _init("window controller", () => container.read(windowNotifierProvider.future));
  }

  await _init("translations", () => container.read(translationsProvider.future));

  if (PlatformUtils.isAndroid) {
    // Android's VpnService survives Activity and Flutter-engine recreation.
    // Resolve its authoritative state while the native splash is still held,
    // so the first rendered Home frame cannot invent an idle/transient state
    // for an already route-verified session.
    await _init("authoritative Android VPN status", () => container.read(connectionNotifierProvider.future));
  }

  Logger.bootstrap.info("startup phase=bootstrap_prerequisites_ready elapsed_ms=${stopWatch.elapsedMilliseconds}");

  void onFirstFrameTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) return;
    WidgetsBinding.instance.removeTimingsCallback(onFirstFrameTimings);
    final timing = timings.first;
    Logger.bootstrap.info(
      "startup phase=first_frame_timing "
      "elapsed_ms=${stopWatch.elapsedMilliseconds} "
      "build_ms=${timing.buildDuration.inMicroseconds / 1000} "
      "raster_ms=${timing.rasterDuration.inMicroseconds / 1000} "
      "total_ms=${timing.totalSpan.inMicroseconds / 1000}",
    );
  }

  WidgetsBinding.instance.addTimingsCallback(onFirstFrameTimings);

  runApp(UncontrolledProviderScope(container: container, child: const App()));

  if (!kIsWeb) {
    FlutterNativeSplash.remove();
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    Logger.bootstrap.info("startup phase=first_post_frame elapsed_ms=${stopWatch.elapsedMilliseconds}");
    stopWatch.stop();
    unawaited(_warmUpAfterFirstFrame(container, appInfo, debug, networkServicesAdmitted: networkServicesAdmitted));
  });
}

Future<void> _warmUpAfterFirstFrame(
  ProviderContainer container,
  AppInfoEntity appInfo,
  bool debug, {
  required bool networkServicesAdmitted,
}) async {
  final stopWatch = Stopwatch()..start();
  final martenCoreWarmUp = PlatformUtils.isAndroid
      ? Future<void>.value()
      : _safeInit("marten-core", () => container.read(martenCoreServiceProvider).init());
  if (PlatformUtils.isAndroid) {
    Logger.bootstrap.info("Android marten-core warm-up follows authoritative service state");
  }

  if (PlatformUtils.isDesktop) {
    await _safeInit("auto start service", () => container.read(autoStartNotifierProvider.future));
  }

  await _safeInit("logger controller", () => LoggerController.postInit(debug));
  Logger.bootstrap.info(appInfo.format());

  await martenCoreWarmUp;

  if (!kIsWeb) {
    // await _safeInit(
    //   "deep link service",
    //   () => container.read(deepLinkNotifierProvider.future),
    //   timeout: 1000,
    // );

    if (PlatformUtils.isDesktop) {
      await _safeInit("system tray", () => container.read(systemTrayNotifierProvider.future), timeout: 1000);
    }
  }

  Logger.bootstrap.info("post-frame warm-up took [${stopWatch.elapsedMilliseconds}ms]");
  stopWatch.stop();
  unawaited(_warmUpDeferredLogServices(container));
  if (networkServicesAdmitted) {
    unawaited(_warmUpDeferredProfileServices(container, debug));
  } else {
    Logger.bootstrap.info('skipping deferred profile networking without strict VPN admission');
  }
  unawaited(_warmUpDeferredPlatformServices(debug));
}

Future<void> _warmUpDeferredLogServices(ProviderContainer container) async {
  // Loading and indexing historical logs is useful after launch, but it is
  // unrelated to the first interaction and may contend with early frames.
  await Future<void>.delayed(const Duration(seconds: 3));
  await _waitForUiIdle("deferred logs repository");
  await _safeInit("deferred logs repository", () => container.read(logRepositoryProvider.future));
}

Future<void> _warmUpDeferredProfileServices(ProviderContainer container, bool debug) async {
  // Push token/profile maintenance is not a prerequisite for rendering,
  // showing the authoritative VPN state, or using an already working
  // subscription. Keep it outside the first-interaction launch window.
  await Future<void>.delayed(const Duration(seconds: 30));
  await _waitForUiIdle("deferred subscription push refresh");
  await _safeInit(
    "deferred subscription push refresh",
    () => container.read(subscriptionPushRefreshServiceProvider).initialize(debug: debug),
  );
}

Future<void> _warmUpDeferredPlatformServices(bool debug) async {
  // These calls cross the Android main thread. Admit each one only when the
  // frame scheduler is idle so a fixed timer cannot interrupt interaction.
  await Future<void>.delayed(const Duration(seconds: 10));
  // Registration itself is local scheduler work. The Android worker decides
  // whether the exact current state admits its networking: a verified Marten
  // route or a fully released terminal state. Registering here means a stale
  // saved route cannot prevent the first background subscription refresh.
  await _waitForUiIdle("deferred background subscription refresh");
  await _safeInit("deferred background subscription refresh", () => initializeProfilesBackgroundRefresh(debug: debug));
  if (!kIsWeb && PlatformUtils.isAndroid) {
    await _waitForUiIdle("deferred android display mode");
    await _safeInit("deferred android display mode", FlutterDisplayMode.setHighRefreshRate);
  }
}

Future<void> _waitForUiIdle(String debugLabel) => UiIdleGate(debugLabel: debugLabel).ready.then((_) {});

Future<T> _init<T>(String name, Future<T> Function() initializer, {int? timeout}) async {
  final stopWatch = Stopwatch()..start();
  Logger.bootstrap.info("initializing [$name]");
  Future<T> func() => timeout != null ? initializer().timeout(Duration(milliseconds: timeout)) : initializer();
  try {
    final result = await func();
    Logger.bootstrap.debug("[$name] initialized in ${stopWatch.elapsedMilliseconds}ms");
    return result;
  } catch (e, stackTrace) {
    Logger.bootstrap.error("[$name] error initializing", e, stackTrace);
    rethrow;
  } finally {
    stopWatch.stop();
  }
}

Future<T?> _safeInit<T>(String name, Future<T> Function() initializer, {int? timeout}) async {
  try {
    return await _init(name, initializer, timeout: timeout);
  } catch (e) {
    return null;
  }
}
