import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:marten/core/haptic/haptic_service.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/model/failures.dart';
import 'package:marten/core/notification/in_app_notification_controller.dart';
import 'package:marten/core/preferences/general_preferences.dart';
import 'package:marten/core/router/dialog/dialog_notifier.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/profile/data/profile_auto_update_service.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/model/profile_failure.dart';
import 'package:marten/features/profile/notifier/active_profile_notifier.dart';
import 'package:marten/utils/riverpod_utils.dart';
import 'package:marten/utils/utils.dart';
import 'package:meta/meta.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profile_notifier.g.dart';

@riverpod
class AddProfileNotifier extends _$AddProfileNotifier with AppLogger {
  @override
  AsyncValue<Unit?> build() {
    ref.disposeDelay(const Duration(minutes: 1));
    ref.onDispose(() {
      loggy.debug("disposing");
      _cancelToken?.cancel();
    });
    listenSelf((previous, next) {
      final t = ref.read(translationsProvider).requireValue;
      final notification = ref.read(inAppNotificationControllerProvider);
      switch (next) {
        case AsyncData(value: final _?):
          notification.showSuccessToast(t.pages.profiles.msg.save.success);
        case AsyncError(:final error):
          if (error case ProfileInvalidUrlFailure()) {
            notification.showErrorToast(t.pages.profiles.msg.invalidUrl);
          } else if (error case ProfileCancelByUserFailure()) {
            return;
          } else {
            ref
                .read(dialogNotifierProvider.notifier)
                .showCustomAlertFromErr(t.presentError(error, action: t.pages.profiles.msg.add.failure));
          }
      }
    });
    ref.onDispose(() {
      if (!(_cancelToken?.isCancelled ?? true)) _cancelToken?.cancel();
    });
    return const AsyncData(null);
  }

  CancelToken? _cancelToken;

  Future<void> addClipboard(String rawInput) async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final profilesRepo = await ref.read(profileRepositoryProvider.future);
      final markAsActive = await _shouldMarkImportedProfileActive();
      final TaskEither<ProfileFailure, Unit> task;
      if (LinkParser.parse(rawInput) case (final rs)?) {
        loggy.debug("adding remote profile, mark as active? [$markAsActive]");
        task = profilesRepo.upsertRemote(
          rs.url,
          userOverride: rs.name.isNotEmpty ? UserOverride(name: rs.name) : null,
          cancelToken: _cancelToken = CancelToken(),
          markAsActive: markAsActive,
        );
      } else {
        loggy.debug("adding profile, content, mark as active? [$markAsActive]");
        task = profilesRepo.addLocal(safeDecodeBase64(rawInput), markAsActive: markAsActive);
      }
      return await task
          .match(
            (err) {
              loggy.warning("failed to add profile", err);
              throw err;
            },
            (_) {
              loggy.info("successfully added profile");
              return unit;
            },
          )
          .run();
    });
  }

  Future<void> addManual({required String url, required UserOverride userOverride}) async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final profilesRepo = await ref.read(profileRepositoryProvider.future);
      final markAsActive = await _shouldMarkImportedProfileActive();
      final task = profilesRepo.upsertRemote(url, userOverride: userOverride, markAsActive: markAsActive);
      return await task
          .match(
            (err) {
              loggy.warning("failed to add profile", err);
              throw err;
            },
            (r) {
              loggy.info("successfully added profile, mark as active? [$markAsActive]");
              return r;
            },
          )
          .run();
    });
  }

  Future<bool> _shouldMarkImportedProfileActive() async {
    final activeProfile = await ref.read(activeProfileProvider.future);
    final connectionStatus = ref.read(connectionNotifierProvider).valueOrNull ?? const Disconnected();
    return shouldActivateImportedProfile(
      activeProfile: activeProfile,
      connectionStatus: connectionStatus,
      markNewProfileActive: ref.read(Preferences.markNewProfileActive),
    );
  }
}

@visibleForTesting
bool shouldActivateImportedProfile({
  required ProfileEntity? activeProfile,
  required ConnectionStatus connectionStatus,
  required bool markNewProfileActive,
}) {
  if (activeProfile == null) return true;
  if (!connectionStatus.isDisconnected) return false;
  return markNewProfileActive;
}

@riverpod
class UpdateProfileNotifier extends _$UpdateProfileNotifier with AppLogger {
  static const feedbackDuration = Duration(seconds: 1);

  int _operationId = 0;

  @override
  AsyncValue<Unit?> build(String id) {
    ref.disposeDelay(const Duration(minutes: 1));
    listenSelf((previous, next) {
      final t = ref.read(translationsProvider).requireValue;
      if (next case AsyncError(:final error)) {
        ref
            .read(inAppNotificationControllerProvider)
            .showErrorToast(t.presentShortError(error, action: t.pages.profiles.msg.update.failure), filled: true);
      }
    });
    return const AsyncData(null);
  }

  Future<void> updateProfile(RemoteProfileEntity profile) async {
    if (state.isLoading) return;
    final operationId = ++_operationId;
    state = const AsyncLoading();
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    state = await AsyncValue.guard(() async {
      final result = await ref.read(profileAutoUpdateServiceProvider).updateProfile(profile.id, force: true);
      if (result == null) throw const ProfileFailure.notFound();
      if (result.outcome == ProfileAutoUpdateOutcome.failed) {
        throw result.failure ?? const ProfileFailure.unexpected();
      }
      if (result.outcome != ProfileAutoUpdateOutcome.updated) return unit;

      loggy.info('subscription_refresh outcome=updated source=manual');
      await ref.read(activeProfileProvider.future).then((active) async {
        if (active != null && active.id == profile.id) {
          await ref.read(connectionNotifierProvider.notifier).reconnect(active);
        }
      });
      return unit;
    });

    await Future<void>.delayed(feedbackDuration);
    if (operationId == _operationId) {
      state = const AsyncData(null);
    }
  }
}

@riverpod
class AddProfilePageNotifier extends _$AddProfilePageNotifier {
  @override
  AddProfilePages build() => AddProfilePages.options;

  void goOptions() => state = AddProfilePages.options;
  void goManual() => state = AddProfilePages.manual;
}

enum AddProfilePages { options, manual }
