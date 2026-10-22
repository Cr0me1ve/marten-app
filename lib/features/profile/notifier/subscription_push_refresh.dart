// ignore_for_file: unreachable_from_main

import 'dart:async';
import 'dart:ui';

import 'package:dio/dio.dart';
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
import 'package:marten/core/network/strict_vpn_egress_gate.dart';
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

abstract interface class SubscriptionPushMessaging {
  Future<void> configure({required bool isIOS});
  Future<String?> getToken();
  Stream<RemoteMessage> get messages;
  Stream<String> get tokens;
}

final class _FirebaseSubscriptionPushMessaging implements SubscriptionPushMessaging {
  bool _isIOS = false;

  @override
  Future<void> configure({required bool isIOS}) async {
    _isIOS = isIOS;
    await FirebaseMessaging.instance.setAutoInitEnabled(true);
    if (isIOS) {
      await FirebaseMessaging.instance.requestPermission(alert: false, badge: false, sound: false);
    }
  }

  @override
  Future<String?> getToken() async {
    // FCM requires APNs registration first. A later token event or resume can
    // retry without converting normal APNs startup into an SDK exception.
    if (_isIOS && await FirebaseMessaging.instance.getAPNSToken() == null) return null;
    return FirebaseMessaging.instance.getToken();
  }

  @override
  Stream<RemoteMessage> get messages => FirebaseMessaging.onMessage;

  @override
  Stream<String> get tokens => FirebaseMessaging.instance.onTokenRefresh;
}

enum _PushRegistrationOutcome { registered, unsupported, failed, obsolete }

class SubscriptionPushRefreshService with WidgetsBindingObserver, AppLogger {
  SubscriptionPushRefreshService(
    this._ref, {
    SubscriptionPushMessaging? messaging,
    Future<bool> Function({bool debug})? firebaseInitializer,
    bool? isMobile,
    bool? isIOS,
    Duration tokenTimeout = const Duration(seconds: 10),
  }) : _messaging = messaging ?? _FirebaseSubscriptionPushMessaging(),
       _firebaseInitializer = firebaseInitializer ?? _ensureFirebaseInitialized,
       _isMobile = isMobile ?? PlatformUtils.isMobile,
       _isIOS = isIOS ?? PlatformUtils.isIOS,
       _tokenTimeout = tokenTimeout {
    if (_isMobile) WidgetsBinding.instance.addObserver(this);
  }

  final Ref _ref;
  final SubscriptionPushMessaging _messaging;
  final Future<bool> Function({bool debug}) _firebaseInitializer;
  final bool _isMobile;
  final bool _isIOS;
  final Duration _tokenTimeout;
  StreamSubscription<RemoteMessage>? _messageSub;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<dynamic>? _profilesSub;
  Future<void>? _initialization;
  Future<void>? _registration;
  String? _pendingToken;
  final Map<String, String> _registeredProfiles = {};
  final Map<String, ({String fingerprint, CancelToken token})> _activeRegistrations = {};
  bool _registrationRequested = false;
  bool _registrationPending = true;
  bool _initialized = false;
  bool _disposed = false;

  bool get _canWork => !_disposed && _isMobile && !strictVpnEgressGate.isSealed;

  Future<void> initialize({bool debug = false}) {
    if (!_canWork) return Future<void>.value();
    final inFlight = _initialization;
    if (inFlight != null) return inFlight;
    final operation = _initialize(debug: debug);
    _initialization = operation;
    return operation.whenComplete(() => _initialization = null);
  }

  Future<void> _initialize({required bool debug}) async {
    if (!_initialized) {
      try {
        registerSubscriptionPushBackgroundHandler();
        if (!await _firebaseInitializer(debug: debug) || !_canWork) return;
        await _messaging.configure(isIOS: _isIOS);
        if (!_canWork) return;
        _messageSub = _messaging.messages.listen((message) {
          if (_canWork) unawaited(_handleMessage(message));
        }, onError: _logOptionalFailure);
        _tokenSub = _messaging.tokens.listen(
          (token) {
            unawaited(_registerCurrentToken(token: token));
          },
          onError: (Object error) {
            _registrationPending = true;
            _logOptionalFailure(error);
          },
        );
        final profilesRepo = await _ref.read(profileRepositoryProvider.future);
        if (!_canWork) {
          await _cancelSubscriptions();
          return;
        }
        // Token failure must not prevent subsequent profile changes from
        // recovering registration in this same service instance.
        _profilesSub = profilesRepo.watchAll().listen((event) {
          event.match(
            (failure) {
              _registrationPending = true;
            },
            (profiles) {
              final current = {
                for (final profile in profiles.whereType<RemoteProfileEntity>())
                  profile.id: _profileRegistrationFingerprint(profile),
              };
              _registeredProfiles.removeWhere((id, _) => !current.containsKey(id));
              for (final registration in _activeRegistrations.entries) {
                if (current[registration.key] != registration.value.fingerprint) {
                  registration.value.token.cancel();
                }
              }
            },
          );
          unawaited(_registerCurrentToken());
        }, onError: _logOptionalFailure);
        _initialized = true;
      } catch (error) {
        await _cancelSubscriptions();
        _logOptionalFailure(error);
        return;
      }
    }
    if (_canWork && _registrationPending) await _registerCurrentToken();
  }

  void _logOptionalFailure(Object error) {
    // SDK errors can contain tokens or subscription endpoints.
    loggy.warning('subscription push temporarily unavailable (${error.runtimeType})');
  }

  Future<void> _handleMessage(RemoteMessage message) async {
    try {
      await handleSubscriptionRefreshPushData(_ref, message.data, isCurrent: () => _canWork);
    } catch (error) {
      _logOptionalFailure(error);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _canWork && (!_initialized || _registrationPending)) {
      unawaited(initialize());
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final registration in _activeRegistrations.values) {
      registration.token.cancel();
    }
    if (_isMobile) WidgetsBinding.instance.removeObserver(this);
    unawaited(_cancelSubscriptions());
  }

  Future<void> _cancelSubscriptions() async {
    final cancellations = <Future<void>>[
      if (_messageSub != null) _messageSub!.cancel(),
      if (_tokenSub != null) _tokenSub!.cancel(),
      if (_profilesSub != null) _profilesSub!.cancel(),
    ];
    _messageSub = null;
    _tokenSub = null;
    _profilesSub = null;
    await Future.wait(cancellations);
  }

  Future<void> _registerCurrentToken({String? token}) {
    if (_disposed || !_isMobile) return Future<void>.value();
    if (token != null && token.trim().isNotEmpty) _pendingToken = token;
    _registrationPending = true;
    if (!_canWork) return Future<void>.value();
    _registrationRequested = true;
    final inFlight = _registration;
    if (inFlight != null) return inFlight;
    final operation = _drainRegistrationRequests();
    _registration = operation;
    return operation.whenComplete(() {
      _registration = null;
      if (_registrationRequested && _canWork) unawaited(_registerCurrentToken());
    });
  }

  Future<void> _drainRegistrationRequests() async {
    while (_registrationRequested && _canWork) {
      _registrationRequested = false;
      try {
        final knownToken = _pendingToken;
        _pendingToken = null;
        final token = knownToken ?? await _messaging.getToken().timeout(_tokenTimeout);
        if (!_canWork) return;
        if (token == null || token.trim().isEmpty) {
          _registrationPending = true;
          continue;
        }
        _registrationPending = !await _registerCurrentProfiles(token);
      } catch (error) {
        _registrationPending = true;
        _logOptionalFailure(error);
      }
    }
  }

  Future<bool> _registerCurrentProfiles(String token) async {
    if (!_canWork) return false;
    final profilesRepo = await _ref.read(profileRepositoryProvider.future);
    if (!_canWork) return false;
    final profiles = await profilesRepo
        .watchAll()
        .map(
          (event) => event
              .getOrElse((failure) {
                throw failure;
              })
              .whereType<RemoteProfileEntity>()
              .toList(),
        )
        .first;
    _registeredProfiles.removeWhere((id, _) => !profiles.any((profile) => profile.id == id));
    var complete = true;
    for (final profile in profiles) {
      if (!_canWork) return false;
      final fingerprint = '$token\n${_profileRegistrationFingerprint(profile)}';
      if (_registeredProfiles[profile.id] == fingerprint) continue;
      final outcome = await _registerProfile(token, profile);
      switch (outcome) {
        case _PushRegistrationOutcome.registered:
        case _PushRegistrationOutcome.unsupported:
          if (_canWork) _registeredProfiles[profile.id] = fingerprint;
        case _PushRegistrationOutcome.failed:
        case _PushRegistrationOutcome.obsolete:
          complete = false;
      }
    }
    return complete && _canWork;
  }

  String _profileRegistrationFingerprint(RemoteProfileEntity profile) =>
      pushTokenRegistrationUrlsFor(profile).map((url) => url.toString()).join('\n');

  Future<_PushRegistrationOutcome> _registerProfile(String token, RemoteProfileEntity profile) async {
    final candidateUrls = pushTokenRegistrationUrlsFor(profile);
    if (candidateUrls.isEmpty) return _PushRegistrationOutcome.unsupported;

    final cancellation = CancelToken();
    _activeRegistrations[profile.id] = (fingerprint: _profileRegistrationFingerprint(profile), token: cancellation);
    try {
      final prefs = _ref.read(sharedPreferencesProvider).requireValue;
      final bindingId = await readPushBindingId(prefs, profile.id, create: true);
      if (bindingId == null || !_canWork) return _PushRegistrationOutcome.failed;

      final deviceIdentity = await _ref.read(deviceIdentityProvider.future);
      if (!_canWork || cancellation.isCancelled) return _PushRegistrationOutcome.obsolete;
      final appInfo = await _ref.read(appInfoProvider.future);
      if (!_canWork || cancellation.isCancelled) return _PushRegistrationOutcome.obsolete;
      final client = _ref.read(httpClientProvider);
      final locale = PlatformDispatcher.instance.locale.toLanguageTag();
      Object? lastError;
      for (final registrationUrl in candidateUrls) {
        if (!_canWork || cancellation.isCancelled) return _PushRegistrationOutcome.obsolete;
        try {
          final repository = await _ref.read(profileRepositoryProvider.future);
          final current = await repository.getById(profile.id).getOrElse((failure) => throw failure).run();
          if (!_canWork ||
              cancellation.isCancelled ||
              current is! RemoteProfileEntity ||
              _profileRegistrationFingerprint(current) != _profileRegistrationFingerprint(profile)) {
            return _PushRegistrationOutcome.obsolete;
          }
          await client.post(
            registrationUrl.toString(),
            cancelToken: cancellation,
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
          loggy.debug('registered push token for profile');
          return cancellation.isCancelled || !_canWork
              ? _PushRegistrationOutcome.obsolete
              : _PushRegistrationOutcome.registered;
        } catch (error) {
          lastError = error;
        }
      }
      if (lastError != null) {
        loggy.warning('push token registration failed for profile (${lastError.runtimeType})');
      }
      return _PushRegistrationOutcome.failed;
    } finally {
      if (identical(_activeRegistrations[profile.id]?.token, cancellation)) {
        _activeRegistrations.remove(profile.id);
      }
      cancellation.cancel();
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
        loggy.debug('push token unregister failed for profile (${error.runtimeType})');
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
  final preferences = await SharedPreferences.getInstance();
  if (PlatformUtils.isAndroid && !(preferences.getBool('strict_vpn_route_verified') ?? false)) {
    // A headless engine may share the VPN app process. Never initialize
    // Firebase unless native Android has proved the current VPN data plane;
    // started_by_user is true while the full-route blocker is intentionally
    // dropping packets and is therefore not a network-admission signal.
    return;
  }
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

Future<void> handleSubscriptionRefreshPushData(Ref ref, Map<String, dynamic> data, {bool Function()? isCurrent}) async {
  if (isCurrent?.call() == false) return;
  final bindingId = _pushBindingIdFromData(data);
  if (bindingId == null) return;

  final prefs = ref.read(sharedPreferencesProvider).requireValue;
  final profilesRepo = await ref.read(profileRepositoryProvider.future);
  if (isCurrent?.call() == false) return;
  final profileId = await _profileIdForPushBinding(prefs, profilesRepo, bindingId);
  if (profileId == null || isCurrent?.call() == false) return;
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
