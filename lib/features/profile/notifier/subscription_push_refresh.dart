// ignore_for_file: unreachable_from_main

import 'dart:async';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart';
import 'package:marten/core/app_info/app_info_provider.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/core/directories/directories_provider.dart';
import 'package:marten/core/http_client/http_client_provider.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/features/profile/data/background_profile_refresh_scope.dart';
import 'package:marten/features/profile/data/profile_auto_update_service.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/features/profile/data/profile_parser.dart';
import 'package:marten/features/profile/data/profile_repository.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/notifier/background_profiles_update.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:marten/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const subscriptionRefreshPushType = 'subscription_refresh';
const _pushBindingPrefix = 'subscription_push_binding.';

bool _backgroundHandlerRegistered = false;

final subscriptionPushRefreshServiceProvider = Provider<SubscriptionPushRefreshService>((ref) {
  final service = SubscriptionPushRefreshService(ref);
  ref.onDispose(service.dispose);
  return service;
});

class SubscriptionPushRefreshService with AppLogger {
  SubscriptionPushRefreshService(this._ref);

  final Ref _ref;
  StreamSubscription<RemoteMessage>? _messageSub;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<dynamic>? _profilesSub;
  bool _initialized = false;

  Future<void> initialize({bool debug = false}) async {
    if (_initialized || !PlatformUtils.isMobile) return;
    registerSubscriptionPushBackgroundHandler();
    _initialized = true;
    if (!await _ensureFirebaseInitialized(debug: debug)) return;

    final messaging = FirebaseMessaging.instance;
    await messaging.setAutoInitEnabled(true);
    if (PlatformUtils.isIOS) {
      await messaging.requestPermission(alert: false, badge: false, sound: false);
    }

    _messageSub = FirebaseMessaging.onMessage.listen((message) {
      unawaited(handleSubscriptionRefreshPushData(_ref, message.data));
    });
    _tokenSub = messaging.onTokenRefresh.listen((token) {
      unawaited(_registerCurrentProfiles(token));
    });

    final token = await messaging.getToken();
    if (token != null && token.trim().isNotEmpty) {
      await _registerCurrentProfiles(token);
    }

    final profilesRepo = await _ref.read(profileRepositoryProvider.future);
    _profilesSub = profilesRepo.watchAll().listen((event) {
      unawaited(_registerCurrentToken());
    });
  }

  void dispose() {
    unawaited(_messageSub?.cancel());
    unawaited(_tokenSub?.cancel());
    unawaited(_profilesSub?.cancel());
  }

  Future<void> _registerCurrentToken() async {
    if (!PlatformUtils.isMobile) return;
    if (!await _ensureFirebaseInitialized()) return;
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.trim().isEmpty) return;
    await _registerCurrentProfiles(token);
  }

  Future<void> _registerCurrentProfiles(String token) async {
    final profilesRepo = await _ref.read(profileRepositoryProvider.future);
    final profiles = await profilesRepo
        .watchAll()
        .map(
          (event) => event
              .getOrElse((failure) {
                loggy.warning('could not read profiles for push registration: $failure');
                return const <ProfileEntity>[];
              })
              .whereType<RemoteProfileEntity>()
              .toList(),
        )
        .first;
    for (final profile in profiles) {
      await _registerProfile(token, profile);
    }
  }

  Future<void> _registerProfile(String token, RemoteProfileEntity profile) async {
    final candidateUrls = pushTokenRegistrationUrlsFor(profile);
    if (candidateUrls.isEmpty) return;

    final prefs = _ref.read(sharedPreferencesProvider).requireValue;
    final bindingId = await readPushBindingId(prefs, profile.id, create: true);
    if (bindingId == null) return;

    final deviceIdentity = await _ref.read(deviceIdentityProvider.future);
    final appInfo = await _ref.read(appInfoProvider.future);
    final client = _ref.read(httpClientProvider);
    final locale = PlatformDispatcher.instance.locale.toLanguageTag();
    Object? lastError;
    for (final registrationUrl in candidateUrls) {
      try {
        await client.post(
          registrationUrl.toString(),
          data: {
            'provider': 'fcm',
            'platform': PlatformUtils.isIOS ? 'ios' : 'android',
            'push_token': token,
            'push_binding_id': bindingId,
            'app_version': '${appInfo.version}+${appInfo.buildNumber}',
            'locale': locale,
          },
          extraHeaders: {'X-Device-ID': deviceIdentity.deviceId, 'X-Client-Secret': deviceIdentity.clientSecret},
        );
        loggy.debug('registered push token for profile [${profile.id}]');
        return;
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) {
      loggy.warning('push token registration failed for profile [${profile.id}] (${lastError.runtimeType})');
    }
  }

  Future<void> unregisterProfile(RemoteProfileEntity profile) async {
    if (!PlatformUtils.isMobile) return;
    final prefs = _ref.read(sharedPreferencesProvider).requireValue;
    final bindingId = await readPushBindingId(prefs, profile.id, create: false);
    if (bindingId == null) return;
    await prefs.remove('$_pushBindingPrefix${profile.id}');

    final candidateUrls = pushTokenRegistrationUrlsFor(profile);
    final deviceIdentity = await _ref.read(deviceIdentityProvider.future);
    final client = _ref.read(httpClientProvider);
    for (final registrationUrl in candidateUrls) {
      try {
        await client.delete(
          registrationUrl.toString(),
          data: {'push_binding_id': bindingId},
          extraHeaders: {'X-Device-ID': deviceIdentity.deviceId, 'X-Client-Secret': deviceIdentity.clientSecret},
        );
        break;
      } catch (error) {
        loggy.debug('push token unregister failed for profile [${profile.id}] (${error.runtimeType})');
      }
    }
  }
}

void registerSubscriptionPushBackgroundHandler() {
  if (!PlatformUtils.isMobile || _backgroundHandlerRegistered) return;
  _backgroundHandlerRegistered = true;
  FirebaseMessaging.onBackgroundMessage(subscriptionRefreshPushBackgroundHandler);
}

@pragma('vm:entry-point')
Future<void> subscriptionRefreshPushBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  if (!await _ensureFirebaseInitialized()) return;
  await _runBackgroundSubscriptionPushRefresh(message.data);
}

Future<void> _runBackgroundSubscriptionPushRefresh(Map<String, dynamic> data) async {
  final scope = BackgroundProfileRefreshScope();
  final container = scope.container;
  try {
    await container.read(appDirectoriesProvider.future);
    await container.read(appInfoProvider.future);
    await container.read(sharedPreferencesProvider.future);
    await container.read(deviceIdentityProvider.future);
    await container.read(profileRepositoryProvider.future);
    await handleSubscriptionRefreshPushDataInContainer(container, data);
    if (!await syncBackgroundNativeResumeConfig(container)) {
      throw StateError('background native resume sync failed');
    }
  } finally {
    await scope.close();
  }
}

Future<void> handleSubscriptionRefreshPushData(Ref ref, Map<String, dynamic> data) async {
  final bindingId = _pushBindingIdFromData(data);
  if (bindingId == null) return;

  final prefs = ref.read(sharedPreferencesProvider).requireValue;
  final profilesRepo = await ref.read(profileRepositoryProvider.future);
  final profileId = await _profileIdForPushBinding(prefs, profilesRepo, bindingId);
  if (profileId == null) return;
  await ref.read(profileAutoUpdateServiceProvider).updateProfile(profileId, force: true);
}

Future<void> handleSubscriptionRefreshPushDataInContainer(
  ProviderContainer container,
  Map<String, dynamic> data,
) async {
  final bindingId = _pushBindingIdFromData(data);
  if (bindingId == null) return;

  final prefs = container.read(sharedPreferencesProvider).requireValue;
  final profilesRepo = await container.read(profileRepositoryProvider.future);
  final profileId = await _profileIdForPushBinding(prefs, profilesRepo, bindingId);
  if (profileId == null) return;
  await container.read(profileAutoUpdateServiceProvider).updateProfile(profileId, force: true, validate: false);
}

String? _pushBindingIdFromData(Map<String, dynamic> data) {
  final type = data['type']?.toString().trim();
  if (type != subscriptionRefreshPushType) return null;
  final bindingId = data['push_binding_id']?.toString().trim();
  if (bindingId == null || bindingId.isEmpty) return null;
  return bindingId;
}

Future<String?> _profileIdForPushBinding(
  SharedPreferences prefs,
  ProfileRepository profilesRepo,
  String bindingId,
) async {
  final profiles = await profilesRepo
      .watchAll()
      .map((event) => event.getOrElse((_) => const <ProfileEntity>[]).whereType<RemoteProfileEntity>().toList())
      .first;
  for (final profile in profiles) {
    final existing = await readPushBindingId(prefs, profile.id, create: false);
    if (existing == bindingId) {
      return profile.id;
    }
  }
  return null;
}

@visibleForTesting
Future<String?> readPushBindingId(SharedPreferences prefs, String profileId, {required bool create}) async {
  final key = '$_pushBindingPrefix$profileId';
  final existing = prefs.getString(key)?.trim();
  if (existing != null && existing.isNotEmpty) return existing;
  if (!create) return null;
  final generated = const Uuid().v4();
  await prefs.setString(key, generated);
  return generated;
}

@visibleForTesting
List<Uri> pushTokenRegistrationUrlsFor(RemoteProfileEntity profile) {
  final urls = <Uri>[];
  final seen = <String>{};
  final explicit = externalPushTokenRegistrationUrl(profile.userOverride?.pushEndpoint);
  if (explicit != null && seen.add(explicit.toString())) {
    urls.add(explicit);
  }
  for (final url in ProfileParser.subscriptionCandidateUrls(profile.url, profile: profile)) {
    final derived = pushTokenRegistrationUrlFor(url);
    if (derived != null && seen.add(derived.toString())) {
      urls.add(derived);
    }
  }
  return urls;
}

@visibleForTesting
Uri? externalPushTokenRegistrationUrl(String? value) {
  if (value == null) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return null;
  return uri;
}

@visibleForTesting
Uri? pushTokenRegistrationUrlFor(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  final segments = uri.pathSegments;
  if (segments.length != 2 || segments[0] != 'sub' || segments[1].isEmpty) return null;
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    pathSegments: ['sub', segments[1], 'device', 'push-token'],
  );
}

Future<bool> _ensureFirebaseInitialized({bool debug = false}) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    return true;
  } catch (error, stackTrace) {
    if (debug) {
      debugPrint('subscription push disabled: Firebase is not configured (${error.runtimeType})');
    }
    Loggy('subscriptionPush').warning('subscription push disabled: Firebase is not configured', error, stackTrace);
    return false;
  }
}
