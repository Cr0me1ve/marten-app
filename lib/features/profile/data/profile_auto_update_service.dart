import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/features/profile/data/profile_parser.dart';
import 'package:marten/features/profile/data/profile_refresh_diagnostics.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/model/profile_failure.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:meta/meta.dart';

final profileAutoUpdateServiceProvider = Provider<ProfileAutoUpdateService>(ProfileAutoUpdateService.new);

enum ProfileAutoUpdateOutcome { updated, skipped, failed }

typedef ProfileAutoUpdateResult = ({String id, String name, ProfileAutoUpdateOutcome outcome, ProfileFailure? failure});
typedef ProfileRefreshRequest = ({bool force, DateTime? now, bool validate});

class ProfileAutoUpdateService with AppLogger {
  ProfileAutoUpdateService(this._ref);

  final Ref _ref;
  final Map<String, _ProfileRefreshWork> _refreshWorkByProfile = {};

  Future<List<ProfileAutoUpdateResult>> updateProfiles({
    bool force = false,
    DateTime? now,
    bool validate = true,
    CancelToken? cancelToken,
  }) async {
    final profilesRepo = await _ref.read(profileRepositoryProvider.future);
    final remoteProfiles = await profilesRepo
        .watchAll()
        .map(
          (event) => event
              .getOrElse((failure) {
                _logRefreshFailure(phase: 'list_profiles', failure: failure);
                throw failure;
              })
              .whereType<RemoteProfileEntity>()
              .toList(),
        )
        .first;

    final results = <ProfileAutoUpdateResult>[];
    await for (final profile in Stream.fromIterable(remoteProfiles)) {
      if (cancelToken?.isCancelled ?? false) break;
      final result = cancelToken == null
          ? await updateProfile(profile.id, force: force, now: now, validate: validate)
          : await _performProfileUpdate(profile.id, (
              force: force,
              now: now,
              validate: validate,
            ), cancelToken: cancelToken);
      if (result != null) results.add(result);
    }
    return results;
  }

  Future<ProfileAutoUpdateResult?> updateProfile(String id, {bool force = false, DateTime? now, bool validate = true}) {
    final request = (force: force, now: now, validate: validate);
    final existing = _refreshWorkByProfile[id];
    if (existing != null) {
      existing.add(request);
      return existing.future;
    }

    final work = _ProfileRefreshWork(request);
    _refreshWorkByProfile[id] = work;
    final future = _runProfileRefreshWork(id, work);
    work.future = future;
    return future;
  }

  Future<ProfileAutoUpdateResult?> _runProfileRefreshWork(String id, _ProfileRefreshWork work) async {
    ProfileAutoUpdateResult? lastResult;
    try {
      while (true) {
        final request = work.takeNext();
        if (request == null) break;
        lastResult = await _performProfileUpdate(id, request);
      }
      return lastResult;
    } finally {
      if (identical(_refreshWorkByProfile[id], work)) {
        _refreshWorkByProfile.remove(id);
      }
    }
  }

  Future<ProfileAutoUpdateResult?> _performProfileUpdate(
    String id,
    ProfileRefreshRequest request, {
    CancelToken? cancelToken,
  }) async {
    final profilesRepo = await _ref.read(profileRepositoryProvider.future);
    final profileResult = await profilesRepo.getById(id).run();
    final profile = profileResult.getOrElse((failure) {
      _logRefreshFailure(phase: 'lookup', failure: failure);
      throw failure;
    });
    if (profile is! RemoteProfileEntity) return null;

    final checkTime = request.now ?? DateTime.now();
    if (!shouldUpdateProfile(profile, now: checkTime, force: request.force)) {
      loggy.debug('subscription_refresh outcome=skipped reason=interval');
      return (id: profile.id, name: profile.name, outcome: ProfileAutoUpdateOutcome.skipped, failure: null);
    }

    final result = await profilesRepo
        .upsertRemote(profile.url, validate: request.validate, cancelToken: cancelToken)
        .run();
    return result.match(
      (failure) {
        _logRefreshFailure(phase: 'download_or_persist', failure: failure);
        return (id: profile.id, name: profile.name, outcome: ProfileAutoUpdateOutcome.failed, failure: failure);
      },
      (_) {
        loggy.debug('subscription_refresh outcome=updated');
        return (id: profile.id, name: profile.name, outcome: ProfileAutoUpdateOutcome.updated, failure: null);
      },
    );
  }

  void _logRefreshFailure({required String phase, required ProfileFailure failure}) {
    final diagnostic = failureDiagnostic(failure);
    loggy.debug(
      'subscription_refresh outcome=failed phase=$phase category=${diagnostic.category} '
      'error_type=${diagnostic.errorType} http_status_class=${diagnostic.httpStatusClass}',
    );
  }

  @visibleForTesting
  static ProfileRefreshFailureDiagnostic failureDiagnostic(ProfileFailure failure) {
    return profileRefreshFailureDiagnostic(failure);
  }

  @visibleForTesting
  static Duration effectiveUpdateInterval(RemoteProfileEntity profile) {
    final interval = profile.options?.updateInterval ?? ProfileParser.defaultUpdateInterval;
    if (interval <= Duration.zero) return ProfileParser.defaultUpdateInterval;
    return interval;
  }

  @visibleForTesting
  static bool shouldUpdateProfile(RemoteProfileEntity profile, {required DateTime now, bool force = false}) {
    if (force) return true;
    if (profile.userOverride?.isAutoUpdateDisable ?? false) return false;
    return now.difference(profile.lastUpdate) >= effectiveUpdateInterval(profile);
  }
}

class _ProfileRefreshWork {
  _ProfileRefreshWork(ProfileRefreshRequest request) : _pending = request;

  ProfileRefreshRequest? _pending;
  ProfileRefreshRequest? _running;
  late Future<ProfileAutoUpdateResult?> future;

  void add(ProfileRefreshRequest request) {
    final running = _running;
    if (running != null && profileRefreshRequestCovers(running, request)) return;
    _pending = mergeProfileRefreshRequests(_pending, request);
  }

  ProfileRefreshRequest? takeNext() {
    final next = _pending;
    _pending = null;
    _running = next;
    return next;
  }
}

@visibleForTesting
bool profileRefreshRequestCovers(ProfileRefreshRequest running, ProfileRefreshRequest incoming) {
  final forceCovered = running.force || !incoming.force;
  final validationCovered = running.validate || !incoming.validate;
  final timeCovered = incoming.now == null || running.now == incoming.now;
  return forceCovered && validationCovered && timeCovered;
}

@visibleForTesting
ProfileRefreshRequest mergeProfileRefreshRequests(ProfileRefreshRequest? pending, ProfileRefreshRequest incoming) {
  if (pending == null) return incoming;
  return (
    force: pending.force || incoming.force,
    now: incoming.now ?? pending.now,
    validate: pending.validate || incoming.validate,
  );
}
