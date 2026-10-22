import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:marten/core/crypto/profile_crypto.dart';
import 'package:marten/core/db/db.dart';
import 'package:marten/core/device/device_identity.dart';

import 'package:marten/core/utils/exception_handler.dart';
import 'package:marten/features/profile/data/profile_data_mapper.dart';
import 'package:marten/features/profile/data/profile_data_source.dart';
import 'package:marten/features/profile/data/profile_file_transaction.dart';
import 'package:marten/features/profile/data/profile_mutation_coordinator.dart';
import 'package:marten/features/profile/data/profile_parser.dart';
import 'package:marten/features/profile/data/profile_path_resolver.dart';
import 'package:marten/features/profile/data/temporary_profile_file.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/model/profile_failure.dart';
import 'package:marten/features/profile/model/profile_sort_enum.dart';
import 'package:marten/features/settings/data/config_option_repository.dart';
import 'package:marten/martencore/marten_core_service.dart';
import 'package:marten/singbox/model/singbox_config_option.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:uuid/uuid.dart';

typedef SubscriptionCanonicalizer = Future<String> Function({required String content, required String settingsJson});

abstract interface class ProfileRepository {
  TaskEither<ProfileFailure, Unit> init();
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id);
  TaskEither<ProfileFailure, Unit> setAsActive(String id);
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive);
  Stream<Either<ProfileFailure, ProfileEntity?>> watchActiveProfile();
  Stream<Either<ProfileFailure, bool>> watchHasAnyProfile();
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  });
  TaskEither<ProfileFailure, Unit> upsertRemote(
    String url, {
    UserOverride? userOverride,
    CancelToken? cancelToken,
    bool markAsActive = true,
    bool validate = true,
  });
  TaskEither<ProfileFailure, Unit> refreshRemote(
    RemoteProfileEntity profile, {
    CancelToken? cancelToken,
    bool validate = true,
  });
  TaskEither<ProfileFailure, Unit> addLocal(
    String content, {
    UserOverride? userOverride,
    bool markAsActive = true,
    CancelToken? cancelToken,
  });
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity nProfile, String nContent);
  TaskEither<ProfileFailure, Unit> validateConfig(String path, String tempPath, String? profileOverride, bool debug);
  TaskEither<ProfileFailure, String> generateConfig(String id);
  TaskEither<ProfileFailure, String> getRawConfig(String id);
}

class ProfileRepositoryImpl with ExceptionHandler, InfraLogger implements ProfileRepository {
  ProfileRepositoryImpl({
    required ProfileDataSource profileDataSource,
    required ProfilePathResolver profilePathResolver,
    required MartenCoreService Function() readSingbox,
    required ConfigOptionRepository Function() readConfigOptionRepository,
    required ProfileParser profileParser,
    required DeviceIdentity deviceIdentity,
    SubscriptionCanonicalizer? canonicalizeSubscription,
  }) : _profileParser = profileParser,
       _readConfigOptionRepository = readConfigOptionRepository,
       _readSingbox = readSingbox,
       _profilePathResolver = profilePathResolver,
       _profileDataSource = profileDataSource,
       _deviceIdentity = deviceIdentity,
       _canonicalizeSubscription = canonicalizeSubscription;

  final ProfileDataSource _profileDataSource;
  final ProfilePathResolver _profilePathResolver;
  final MartenCoreService Function() _readSingbox;
  final ConfigOptionRepository Function() _readConfigOptionRepository;
  final ProfileParser _profileParser;
  final DeviceIdentity _deviceIdentity;
  final SubscriptionCanonicalizer? _canonicalizeSubscription;
  final Map<String, Future<String>> _configRepairs = {};
  final Map<String, CancelToken> _repairCancelTokens = {};
  late final _mutations = ProfileMutationCoordinator(_profilePathResolver.directory);

  @override
  TaskEither<ProfileFailure, Unit> init() {
    return exceptionHandler(() async {
      if (!kIsWeb) {
        if (!await _profilePathResolver.directory.exists()) {
          await _profilePathResolver.directory.create(recursive: true);
        }
        await _profilePathResolver.tempFile('scratch').parent.create(recursive: true);
      }

      return right(unit);
    }, ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) {
    return TaskEither.tryCatch(
      () => _profileDataSource.getById(id).then((value) => value?.toEntity()),
      ProfileUnexpectedFailure.new,
    );
  }

  @override
  TaskEither<ProfileFailure, Unit> setAsActive(String id) => TaskEither.tryCatch(
    () => _mutations.run(() async {
      if (await _profileDataSource.getById(id) == null) throw const ProfileFailure.notFound();
      await _profileDataSource.edit(id, const ProfileEntriesCompanion(active: Value(true)));
      return unit;
    }),
    _profileStorageFailure,
  );

  @override
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive) => TaskEither.tryCatch(() {
    _repairCancelTokens[id]?.cancel();
    // Never wait for network repair while deleting. The shared lease and
    // persisted revision check prevent every late repair/refresh commit.
    return _mutations.run(() async {
      final current = await _profileDataSource.getById(id);
      if (current == null) return unit;
      await _profileDataSource.deleteById(id, current.active);
      await _deleteProfileFileIfExists(id);
      await _deleteIfExists(_profilePathResolver.backupFile(id));
      return unit;
    });
  }, _profileStorageFailure);

  @override
  Stream<Either<ProfileFailure, ProfileEntity?>> watchActiveProfile() {
    return _profileDataSource.watchActiveProfile().map((event) => event?.toEntity()).handleExceptions((
      error,
      stackTrace,
    ) {
      loggy.error("error watching active profile", error, stackTrace);
      return ProfileUnexpectedFailure(error, stackTrace);
    });
  }

  @override
  Stream<Either<ProfileFailure, bool>> watchHasAnyProfile() {
    return _profileDataSource
        .watchProfilesCount()
        .map((event) => event != 0)
        .handleExceptions(ProfileUnexpectedFailure.new);
  }

  @override
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  }) {
    return _profileDataSource
        .watchAll(sort: sort, sortMode: sortMode)
        .map((event) => event.map((e) => e.toEntity()).toList())
        .handleExceptions(ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, Unit> upsertRemote(
    String url, {
    UserOverride? userOverride,
    CancelToken? cancelToken,
    bool markAsActive = true,
    bool validate = true,
  }) => TaskEither.tryCatch(() async {
    // Explicit import may create a new identity. Refresh never enters this path.
    final existing = await _mutations.run(() async => (await _profileDataSource.getByUrl(url))?.toEntity());
    final remote = existing is RemoteProfileEntity ? existing : null;
    final id = remote?.id ?? const Uuid().v4();
    final temp = _profilePathResolver.tempFile(id);
    return (await withTemporaryProfileFile(
      temp,
      () => TaskEither.tryCatch(() async {
        final candidate =
            await (remote == null
                    ? _profileParser.addRemote(
                        id: id,
                        url: url,
                        tempFilePath: temp.path,
                        userOverride: userOverride,
                        active: markAsActive,
                        cancelToken: cancelToken,
                      )
                    : _profileParser.updateRemote(
                        rp: userOverride == null ? remote : remote.copyWith(userOverride: userOverride),
                        tempFilePath: temp.path,
                        cancelToken: cancelToken,
                      ))
                .getOrElse((failure) => throw failure)
                .run();
        await _commitCandidate(
          id: id,
          expected: remote,
          entry: candidate,
          temp: temp,
          validate: validate,
          cancelToken: cancelToken,
          importUrl: remote == null ? url : null,
        );
        return unit;
      }, _profileStorageFailure),
    ).run()).getOrElse((failure) => throw failure);
  }, _profileStorageFailure);

  @override
  TaskEither<ProfileFailure, Unit> refreshRemote(
    RemoteProfileEntity profile, {
    CancelToken? cancelToken,
    bool validate = true,
  }) => TaskEither.tryCatch(() async {
    await _mutations.run(() => _requireCurrent(profile));
    final temp = _profilePathResolver.tempFile(profile.id);
    return (await withTemporaryProfileFile(
      temp,
      () => TaskEither.tryCatch(() async {
        final candidate = await _profileParser
            .updateRemote(rp: profile, tempFilePath: temp.path, cancelToken: cancelToken)
            .getOrElse((failure) => throw failure)
            .run();
        await _commitCandidate(
          id: profile.id,
          expected: profile,
          entry: candidate,
          temp: temp,
          validate: validate,
          cancelToken: cancelToken,
        );
        return unit;
      }, _profileStorageFailure),
    ).run()).getOrElse((failure) => throw failure);
  }, _profileStorageFailure);

  @override
  TaskEither<ProfileFailure, Unit> addLocal(
    String content, {
    UserOverride? userOverride,
    bool markAsActive = true,
    CancelToken? cancelToken,
  }) => TaskEither.tryCatch(() async {
    final id = const Uuid().v4();
    final temp = _profilePathResolver.tempFile(id);
    return (await withTemporaryProfileFile(
      temp,
      () => TaskEither.tryCatch(() async {
        _checkCancellation(cancelToken);
        await temp.writeAsString(content);
        final candidate = await _profileParser
            .addLocal(
              id: id,
              content: content,
              tempFilePath: temp.path,
              userOverride: userOverride,
              active: markAsActive,
              cancelToken: cancelToken,
            )
            .getOrElse((failure) => throw failure)
            .run();
        await _commitCandidate(id: id, entry: candidate, temp: temp, validate: true, cancelToken: cancelToken);
        return unit;
      }, _profileStorageFailure),
    ).run()).getOrElse((failure) => throw failure);
  }, _profileStorageFailure);

  @override
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity profile, String content) =>
      TaskEither.tryCatch(() async {
        await _mutations.run(() => _requireCurrent(profile));
        final temp = _profilePathResolver.tempFile(profile.id);
        return (await withTemporaryProfileFile(
          temp,
          () => TaskEither.tryCatch(() async {
            await temp.writeAsString(content);
            final candidate = _profileParser
                .offlineUpdate(profile: profile, tempFilePath: temp.path)
                .getOrElse((failure) => throw failure);
            await _commitCandidate(id: profile.id, expected: profile, entry: candidate, temp: temp, validate: true);
            return unit;
          }, _profileStorageFailure),
        ).run()).getOrElse((failure) => throw failure);
      }, _profileStorageFailure);

  Future<void> _requireCurrent(ProfileEntity expected) async {
    final current = await _profileDataSource.getById(expected.id);
    if (current == null ||
        current.revision != expected.revision ||
        current.type.name != (expected is RemoteProfileEntity ? 'remote' : 'local') ||
        (expected is RemoteProfileEntity && current.url != expected.url)) {
      throw const ProfileFailure.cancelByUser('profile generation replaced');
    }
  }

  void _checkCancellation(CancelToken? token) {
    if (token?.isCancelled == true) throw const ProfileFailure.cancelByUser();
  }

  Future<void> _commitCandidate({
    required String id,
    ProfileEntity? expected,
    required ProfileEntriesCompanion entry,
    required File temp,
    required bool validate,
    CancelToken? cancelToken,
    String? importUrl,
  }) async {
    final staged = File('${temp.path}.encrypted');
    try {
      _checkCancellation(cancelToken);
      await _persistProfileFile(
        file: staged,
        tempFile: temp,
        profileOverride: entry.profileOverride.value,
        validate: validate,
      ).getOrElse((failure) => throw failure).run();
      _checkCancellation(cancelToken);
      await _mutations.run(() async {
        _checkCancellation(cancelToken);
        if (expected != null) {
          await _requireCurrent(expected);
        } else if (await _profileDataSource.getById(id) != null ||
            (importUrl != null && await _profileDataSource.getByUrl(importUrl) != null)) {
          throw const ProfileFailure.cancelByUser('profile generation replaced');
        }
        final destination = _profilePathResolver.file(id);
        await _withProfileFileRollback(
          destination,
          () => TaskEither.tryCatch(
            () => _profileDataSource.transaction(() async {
              await staged.rename(destination.path);
              _checkCancellation(cancelToken);
              if (expected == null) {
                await _profileDataSource.insert(entry);
              } else {
                await _profileDataSource.edit(id, entry);
              }
              _checkCancellation(cancelToken);
              return unit;
            }),
            _profileStorageFailure,
          ),
        ).getOrElse((failure) => throw failure).run();
      });
    } finally {
      await _deleteIfExists(staged);
    }
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      await file.delete();
    } on FileSystemException catch (error) {
      if (!_isMissingFile(error)) rethrow;
    }
  }

  @override
  TaskEither<ProfileFailure, Unit> validateConfig(String path, String tempPath, String? profileOverride, bool debug) {
    final configOptionRepository = _readConfigOptionRepository();
    return TaskEither.fromEither(configOptionRepository.fullOptionsOverrided(profileOverride))
        .mapLeft((configOptionFailure) => ProfileFailure.invalidConfig(null, configOptionFailure))
        .flatMap(
          (overridedOptions) => TaskEither.tryCatch(() async {
            final rawContent = ProfileParser.normalizeMartenSubscriptionContent(await File(tempPath).readAsString());
            final canonicalContent = await _canonicalizeCandidate(
              rawContent: rawContent,
              options: overridedOptions,
              scratchPath: '$tempPath.core',
              debug: debug,
              allowLegacyCoreFallback: true,
            );
            await ProfileCrypto.encryptContentToFile(File(path), canonicalContent, _deviceIdentity.clientSecret);
            return unit;
          }, (err, st) => err is ProfileFailure ? err : ProfileFailure.unexpected(err, st)),
        );
  }

  TaskEither<ProfileFailure, Unit> _persistProfileFile({
    required File file,
    required File tempFile,
    required String? profileOverride,
    required bool validate,
  }) {
    if (validate) {
      return validateConfig(file.path, tempFile.path, profileOverride, false);
    }
    if (_canonicalizeSubscription == null) {
      // Non-Android background isolates have no pure native bridge. Preserve
      // their conservative no-core guard without constructing settings/core.
      return TaskEither.tryCatch(() async {
        final rawContent = ProfileParser.normalizeMartenSubscriptionContent(await tempFile.readAsString());
        final subscriptionContent = ProfileParser.stripMartenSubscriptionMetadata(rawContent);
        final parsedContent = ProfileParser.validateBackgroundCandidate(
          subscriptionContent,
        ).getOrElse((failure) => throw failure);
        final canonicalContent = ProfileParser.restoreMartenSubscriptionMetadata(
          parsedContent: parsedContent,
          sourceContent: rawContent,
        );
        await ProfileCrypto.encryptContentToFile(file, canonicalContent, _deviceIdentity.clientSecret);
        return unit;
      }, (err, st) => err is ProfileFailure ? err : ProfileFailure.unexpected(err, st));
    }
    return TaskEither.fromEither(_readConfigOptionRepository().fullOptionsOverrided(profileOverride))
        .mapLeft((configOptionFailure) => ProfileFailure.invalidConfig(null, configOptionFailure))
        .flatMap(
          (overridedOptions) => TaskEither.tryCatch(() async {
            final rawContent = ProfileParser.normalizeMartenSubscriptionContent(await tempFile.readAsString());
            final canonicalContent = await _canonicalizeCandidate(
              rawContent: rawContent,
              options: overridedOptions,
              scratchPath: '${tempFile.path}.core',
              debug: false,
              allowLegacyCoreFallback: false,
            );
            await ProfileCrypto.encryptContentToFile(file, canonicalContent, _deviceIdentity.clientSecret);
            return unit;
          }, (err, st) => err is ProfileFailure ? err : ProfileFailure.unexpected(err, st)),
        );
  }

  Future<String> _canonicalizeCandidate({
    required String rawContent,
    required SingboxConfigOption options,
    required String scratchPath,
    required bool debug,
    required bool allowLegacyCoreFallback,
  }) async {
    final subscriptionContent = ProfileParser.stripMartenSubscriptionMetadata(rawContent);
    late final String parsedContent;
    final canonicalizer = _canonicalizeSubscription;

    if (canonicalizer != null) {
      try {
        parsedContent = await canonicalizer(content: subscriptionContent, settingsJson: jsonEncode(options.toJson()));
      } catch (_) {
        throw const ProfileFailure.invalidConfig('subscription candidate is not usable');
      }
    } else if (allowLegacyCoreFallback) {
      // Non-Android platforms retain the existing core-backed foreground path.
      // Android foreground and headless engines both use the pure native bridge.
      final scratchFile = File(scratchPath);
      final parsedFile = File('$scratchPath.parsed');
      await scratchFile.writeAsString(subscriptionContent, flush: true);
      try {
        final singbox = _readSingbox();
        final changeResult = await singbox.changeOptions(options).run();
        final changeError = changeResult.match<String?>((err) => err, (_) => null);
        if (changeError != null) throw ProfileFailure.invalidConfig(changeError);

        final validateResult = await singbox.validateConfigByPath(parsedFile.path, scratchFile.path, debug).run();
        final validateError = validateResult.match<String?>((err) => err, (_) => null);
        if (validateError != null) throw ProfileFailure.invalidConfig(validateError);
        parsedContent = await parsedFile.readAsString();
      } finally {
        if (await scratchFile.exists()) await scratchFile.delete();
        if (await parsedFile.exists()) await parsedFile.delete();
      }
    } else {
      // Platforms without a headless native bridge retain the conservative
      // background guard and never construct an activity-bound core graph.
      parsedContent = ProfileParser.validateBackgroundCandidate(
        subscriptionContent,
      ).getOrElse((failure) => throw failure);
    }

    if (!ProfileParser.hasSelectableOutbound(parsedContent)) {
      throw const ProfileFailure.invalidConfig('profile has no supported outbounds');
    }
    return ProfileParser.restoreMartenSubscriptionMetadata(parsedContent: parsedContent, sourceContent: rawContent);
  }

  @override
  TaskEither<ProfileFailure, String> generateConfig(String id) {
    final singbox = _readSingbox();
    return TaskEither.tryCatch(() async {
      final tempFile = _profilePathResolver.tempFile(id);
      try {
        final raw = await getRawConfig(id).getOrElse((failure) => throw failure).run();
        await tempFile.parent.create(recursive: true);
        await tempFile.writeAsString(raw);
        final result = await singbox.generateFullConfigByPath(tempFile.path).run();
        return result.getOrElse((l) => throw ProfileFailure.unexpected(l));
      } finally {
        if (await tempFile.exists()) await tempFile.delete();
      }
    }, _profileStorageFailure);
  }

  @override
  TaskEither<ProfileFailure, String> getRawConfig(String id) {
    return TaskEither.tryCatch(() async {
      try {
        return await _mutations.run(() async {
          if (await _profileDataSource.getById(id) == null) throw const ProfileFailure.notFound();
          final raw = await _readStoredConfig(_profilePathResolver.file(id));
          if (!await _profilePathResolver.backupFile(id).exists()) {
            await _rememberLastGood(_profilePathResolver.file(id), raw: raw);
          }
          return raw;
        });
      } catch (_) {
        final existing = _configRepairs[id];
        if (existing != null) return existing;
        final token = CancelToken();
        _repairCancelTokens[id] = token;
        final repair = _repairConfig(id, token);
        _configRepairs[id] = repair;
        try {
          return await repair;
        } finally {
          if (identical(_configRepairs[id], repair)) {
            _configRepairs.remove(id);
            _repairCancelTokens.remove(id);
          }
        }
      }
    }, _profileStorageFailure);
  }

  Future<String> _readStoredConfig(File file) async {
    final raw = await ProfileCrypto.decryptFile(file, _deviceIdentity.clientSecret);
    ProfileParser.validateBackgroundCandidate(
      ProfileParser.stripMartenSubscriptionMetadata(raw),
    ).getOrElse((failure) => throw failure);
    return raw;
  }

  Future<String> _repairConfig(String id, CancelToken cancelToken) async {
    final profile = (await _profileDataSource.getById(id))?.toEntity();
    if (profile == null) throw const ProfileFailure.notFound();
    try {
      return await _mutations.run(() async {
        await _requireCurrent(profile);
        _checkCancellation(cancelToken);
        // Another engine may have repaired/updated the canonical file already.
        try {
          return await _readStoredConfig(_profilePathResolver.file(id));
        } catch (_) {}
        final raw = await _readStoredConfig(_profilePathResolver.backupFile(id));
        _checkCancellation(cancelToken);
        await ProfileCrypto.encryptContentToFile(_profilePathResolver.file(id), raw, _deviceIdentity.clientSecret);
        loggy.debug('profile_storage_recovery outcome=restored source=backup');
        return raw;
      });
    } catch (_) {
      _checkCancellation(cancelToken);
      if (profile is! RemoteProfileEntity) rethrow;
    }
    // Use the normal atomic subscription transaction, with the same device
    // identity and no dependency on a foreground native control listener.
    await refreshRemote(profile, validate: false, cancelToken: cancelToken).getOrElse((failure) => throw failure).run();
    final raw = await _mutations.run(() async {
      if (await _profileDataSource.getById(id) == null) throw const ProfileFailure.notFound();
      return _readStoredConfig(_profilePathResolver.file(id));
    });
    loggy.debug('profile_storage_recovery outcome=restored source=subscription');
    return raw;
  }

  TaskEither<ProfileFailure, T> _withProfileFileRollback<T>(
    File destination,
    TaskEither<ProfileFailure, T> Function() operation,
  ) => withProfileFileRollback(destination, operation).flatMap(
    (value) => TaskEither.tryCatch(() async {
      // Update the recovery copy only after the file and DB transaction committed.
      await _rememberLastGood(destination);
      return value;
    }, ProfileFailure.unexpected),
  );

  Future<void> _rememberLastGood(File file, {String? raw}) async {
    try {
      final content = raw ?? await _readStoredConfig(file);
      await ProfileCrypto.encryptContentToFile(File('${file.path}.last-good'), content, _deviceIdentity.clientSecret);
    } catch (_) {
      // An unavailable optional recovery copy cannot undo a committed profile.
      loggy.debug('profile_storage_backup outcome=unavailable');
    }
  }

  Future<void> _deleteProfileFileIfExists(String id) async {
    try {
      await _profilePathResolver.file(id).delete();
    } on FileSystemException catch (error) {
      if (!_isMissingFile(error)) rethrow;
    }
  }
}

ProfileFailure _profileStorageFailure(Object error, StackTrace stackTrace) {
  if (error is ProfileFailure) return error;
  if (_isMissingFile(error)) return const ProfileFailure.notFound();
  return ProfileFailure.unexpected(error, stackTrace);
}

bool _isMissingFile(Object error) {
  if (error is PathNotFoundException) return true;
  if (error is! FileSystemException) return false;

  final osError = error.osError;
  if (osError?.errorCode == 2) return true;

  final message = [error.message, osError?.message].whereType<String>().join(' ').toLowerCase();
  return message.contains('no such file') || message.contains('cannot open file');
}
