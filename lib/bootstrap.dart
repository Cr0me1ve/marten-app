import 'dart:async';
import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/analytics/analytics_controller.dart';
import 'package:marten/core/app_info/app_info_provider.dart';
import 'package:marten/core/directories/directories_provider.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/logger/logger.dart';
import 'package:marten/core/logger/logger_controller.dart';
import 'package:marten/core/model/app_info_entity.dart';
import 'package:marten/core/model/environment.dart';
import 'package:marten/core/preferences/general_preferences.dart';
import 'package:marten/core/preferences/preferences_migration.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/features/app/widget/app.dart';
import 'package:marten/features/auto_start/notifier/auto_start_notifier.dart';

import 'package:marten/features/log/data/log_data_providers.dart';
import 'package:marten/features/profile/notifier/background_profiles_update.dart';
import 'package:marten/features/profile/notifier/subscription_push_refresh.dart';
import 'package:marten/features/system_tray/notifier/system_tray_notifier.dart';
import 'package:marten/features/window/notifier/window_notifier.dart';
import 'package:marten/martencore/marten_core_service_provider.dart';
import 'package:marten/riverpod_observer.dart';
import 'package:marten/utils/utils.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

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

  await _init("directories", () => container.read(appDirectoriesProvider.future));
  LoggerController.init(container.read(logPathResolverProvider).appFile().path, debugConsole: !PlatformUtils.isMobile);

  final appInfo = await _init("app info", () => container.read(appInfoProvider.future));
  await _init("preferences", () => container.read(sharedPreferencesProvider.future));

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
  registerSubscriptionPushBackgroundHandler();

  if (PlatformUtils.isDesktop) {
    await _init("window controller", () => container.read(windowNotifierProvider.future));
  }

  await _init("translations", () => container.read(translationsProvider.future));

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

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: SentryUserInteractionWidget(child: const App()),
    ),
  );

  if (!kIsWeb) {
    FlutterNativeSplash.remove();
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    Logger.bootstrap.info("startup phase=first_post_frame elapsed_ms=${stopWatch.elapsedMilliseconds}");
    stopWatch.stop();
    unawaited(_warmUpAfterFirstFrame(container, appInfo, debug));
  });
  // SentryFlutter.s(DateTime.now().toUtc());
}

Future<void> _warmUpAfterFirstFrame(ProviderContainer container, AppInfoEntity appInfo, bool debug) async {
  final stopWatch = Stopwatch()..start();
  final martenCoreWarmUp = PlatformUtils.isAndroid
      ? Future<void>.value()
      : _safeInit("marten-core", () => container.read(martenCoreServiceProvider).init());
  if (PlatformUtils.isAndroid) {
    Logger.bootstrap.info("Android marten-core warm-up follows authoritative service state");
  }

  final enableAnalytics = await _safeInit(
    "analytics preference",
    () => container.read(analyticsControllerProvider.future),
  );
  if (enableAnalytics == true) {
    await _safeInit("analytics", () => container.read(analyticsControllerProvider.notifier).enableAnalytics());
  }

  if (PlatformUtils.isDesktop) {
    await _safeInit("auto start service", () => container.read(autoStartNotifierProvider.future));
  }

  await _safeInit("logs repository", () => container.read(logRepositoryProvider.future));
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
  unawaited(_warmUpDeferredProfileServices(container, debug));
  unawaited(_warmUpDeferredPlatformServices(debug));
}

Future<void> _warmUpDeferredProfileServices(ProviderContainer container, bool debug) async {
  // Push token/profile maintenance is not a prerequisite for rendering,
  // showing the authoritative VPN state, or using an already working
  // subscription. Keep it outside the first-interaction launch window.
  await Future<void>.delayed(const Duration(seconds: 30));
  await _safeInit(
    "deferred subscription push refresh",
    () => container.read(subscriptionPushRefreshServiceProvider).initialize(debug: debug),
  );
}

Future<void> _warmUpDeferredPlatformServices(bool debug) async {
  // Workmanager registration and display-mode negotiation both cross the
  // Android main thread. They are maintenance tasks, not launch prerequisites.
  await Future<void>.delayed(const Duration(seconds: 10));
  await Future.wait([
    _safeInit("deferred background subscription refresh", () => initializeProfilesBackgroundRefresh(debug: debug)),
    if (!kIsWeb && PlatformUtils.isAndroid)
      _safeInit("deferred android display mode", () async {
        await FlutterDisplayMode.setHighRefreshRate();
      }),
  ]);
}

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
