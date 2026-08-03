import 'dart:convert';

import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/model/failures.dart';
import 'package:marten/core/notification/in_app_notification_controller.dart';
import 'package:marten/core/router/dialog/dialog_notifier.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/features/profile/details/profile_details_state.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/model/profile_failure.dart';
import 'package:marten/utils/utils.dart';
import 'package:meta/meta.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profile_details_notifier.g.dart';

@riverpod
class ProfileDetailsNotifier extends _$ProfileDetailsNotifier with AppLogger {
  String _rawConfigContent = '';
  bool _contentChanged = false;

  @override
  Future<ProfileDetailsState> build(String id) async {
    final profilesRepo = await ref.watch(profileRepositoryProvider.future);
    final prof = (await profilesRepo.getById(id).run()).match((l) => throw l, (prof) {
      // _originalProfile = prof;
      if (prof == null) {
        loggy.warning('profile with id: [$id] does not exist');
        throw const ProfileNotFoundFailure();
      }
      return prof;
    });
    _rawConfigContent = (await profilesRepo.getRawConfig(id).run()).match(
      (failure) => throw failure,
      (content) => content,
    );
    _contentChanged = false;
    var profContent = _rawConfigContent;
    try {
      profContent = (await profilesRepo.generateConfig(id).run()).match(
        (l) => throw Exception('Failed to generate config: $l'),
        (content) => content,
      );
    } catch (error) {
      loggy.error('Error generating config for profile $id (${error.runtimeType})');
      profContent = _rawConfigContent;
    }
    try {
      final jsonObject = jsonDecode(profContent);
      final List<Map<String, dynamic>> outbounds = [];
      final List<dynamic> endpoints;
      if (jsonObject is Map<String, dynamic> && jsonObject['outbounds'] is List) {
        for (final outbound in jsonObject['outbounds'] as List<dynamic>) {
          if (outbound is Map<String, dynamic> &&
              outbound['type'] != null &&
              !['selector', 'urltest', 'dns', 'block'].contains(outbound['type']) &&
              !['direct', 'bypass', 'direct-fragment'].contains(outbound['tag'])) {
            outbounds.add(outbound);
          }
        }
        endpoints = jsonObject['endpoints'] is List ? jsonObject['endpoints'] as List<dynamic> : const [];
      } else {
        // print('No outbounds found in the config');
        endpoints = const [];
      }
      profContent = '{"outbounds": ${json.encode(outbounds)},"endpoints":${json.encode(endpoints)} }';
      loggy.debug('profile details content prepared: outbounds=${outbounds.length}, endpoints=${endpoints.length}');
    } catch (e, st) {
      loggy.error('Error parsing profile-content JSON', e, st);
      // rethrow;
    }
    return ProfileDetailsState(
      loadingState: const AsyncData(null),
      profile: prof,
      configContent: profContent,
      isDetailsChanged: false,
    );
  }

  Future<T?> doAsync<T>(Future<T> Function() operation) async {
    if (state case AsyncData(value: final ProfileDetailsState data)) {
      state = AsyncData(data.copyWith(loadingState: const AsyncLoading()));
      final T? result = await operation();
      state = AsyncData(data.copyWith(loadingState: const AsyncData(null)));
      return result;
    }
    return null;
  }

  void setUserOverride(UserOverride userOverride) {
    if (state case AsyncData(value: final ProfileDetailsState data)) {
      state = AsyncData(
        data.copyWith(profile: data.profile.copyWith(userOverride: userOverride), isDetailsChanged: true),
      );
    }
  }

  void setContent(String configContent) {
    if (state case AsyncData(value: final ProfileDetailsState data)) {
      _contentChanged = true;
      state = AsyncData(data.copyWith(configContent: configContent, isDetailsChanged: true));
    }
  }

  Future<bool> save() async {
    bool success = false;
    if (state case AsyncData(:final value)) {
      if (value.loadingState case AsyncLoading()) return false;

      success =
          await doAsync<bool>(() async {
            final t = await ref.read(translationsProvider.future);
            final profilesRepo = await ref.read(profileRepositoryProvider.future);
            final content = profileContentForSave(
              rawConfigContent: _rawConfigContent,
              displayedConfigContent: value.configContent,
              contentChanged: _contentChanged,
            );
            return (await profilesRepo.offlineUpdate(value.profile, content).run()).match(
              (l) async {
                await ref
                    .read(dialogNotifierProvider.notifier)
                    .showCustomAlertFromErr(
                      t.presentError(l, action: t.pages.profiles.msg.update.failureNamed(name: value.profile.name)),
                    );
                return false;
              },
              (r) {
                _rawConfigContent = content;
                _contentChanged = false;
                ref.read(inAppNotificationControllerProvider).showSuccessToast(t.pages.profiles.msg.update.success);
                return true;
              },
            );
          }) ??
          false;
    }
    return success;
  }
}

@visibleForTesting
String profileContentForSave({
  required String rawConfigContent,
  required String displayedConfigContent,
  required bool contentChanged,
}) => contentChanged ? displayedConfigContent : rawConfigContent;
