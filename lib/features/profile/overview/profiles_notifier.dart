import 'dart:async';

import 'package:flutter/services.dart';
import 'package:fpdart/fpdart.dart';
import 'package:marten/core/haptic/haptic_service.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/notification/in_app_notification_controller.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/model/profile_sort_enum.dart';
import 'package:marten/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profiles_notifier.g.dart';

@riverpod
class ProfilesSortNotifier extends _$ProfilesSortNotifier with AppLogger {
  @override
  ({ProfilesSort by, SortMode mode}) build() {
    return (by: ProfilesSort.lastUpdate, mode: SortMode.descending);
  }

  void changeSort(ProfilesSort sortBy) => state = (by: sortBy, mode: state.mode);

  void toggleMode() =>
      state = (by: state.by, mode: state.mode == SortMode.ascending ? SortMode.descending : SortMode.ascending);
}

@riverpod
class ProfilesNotifier extends _$ProfilesNotifier with AppLogger {
  @override
  Stream<List<ProfileEntity>> build() async* {
    final sort = ref.watch(profilesSortNotifierProvider);
    final profilesRepo = await ref.watch(profileRepositoryProvider.future);
    yield* profilesRepo.watchAll(sort: sort.by, sortMode: sort.mode).map((event) => event.getOrElse((l) => throw l));
  }

  Future<Unit> selectActiveProfile(String id) async {
    loggy.debug('changing active profile to: [$id]');
    final connection = ref.read(connectionNotifierProvider).valueOrNull;
    if (connection != null && connection is! Disconnected) {
      loggy.info('active profile change ignored while connection is active');
      final t = ref.read(translationsProvider).requireValue;
      ref
          .read(inAppNotificationControllerProvider)
          .showInfoToast(t.pages.profiles.msg.switchWhileConnected, duration: const Duration(seconds: 4));
      return unit;
    }
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    final profilesRepo = await ref.read(profileRepositoryProvider.future);
    return profilesRepo.setAsActive(id).getOrElse((err) {
      loggy.warning('failed to set [$id] as active profile', err);
      throw err;
    }).run();
  }

  Future<void> deleteProfile(ProfileEntity profile) async {
    loggy.debug('deleting profile: ${profile.name}');

    if (profile.active) await ref.read(connectionNotifierProvider.notifier).abortConnection();
    final profilesRepo = await ref.read(profileRepositoryProvider.future);
    await profilesRepo
        .deleteById(profile.id, profile.active)
        .match(
          (err) {
            loggy.warning('failed to delete profile', err);
            throw err;
          },
          (_) {
            loggy.info('successfully deleted profile, was active? [${profile.active}]');
            final t = ref.read(translationsProvider).requireValue;
            ref.read(inAppNotificationControllerProvider).showSuccessToast(t.pages.profiles.msg.delete.success);
            return unit;
          },
        )
        .run();
  }

  Future<void> exportConfigToClipboard(ProfileEntity profile) async {
    final profilesRepo = await ref.read(profileRepositoryProvider.future);
    await profilesRepo
        .generateConfig(profile.id)
        .match(
          (err) {
            loggy.warning('error generating config (${err.runtimeType})');
            throw err;
          },
          (configJson) async {
            await Clipboard.setData(ClipboardData(text: configJson));
            final t = ref.read(translationsProvider).requireValue;
            ref.read(inAppNotificationControllerProvider).showSuccessToast(t.common.msg.export.clipboard.success);
          },
        )
        .run();
  }
}
