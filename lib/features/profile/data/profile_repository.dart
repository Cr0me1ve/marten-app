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
import 'package:marten/features/profile/data/profile_parser.dart';
import 'package:marten/features/profile/data/profile_path_resolver.dart';
import 'package:marten/features/profile/data/temporary_profile_file.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/model/profile_failure.dart';
import 'package:marten/features/profile/model/profile_sort_enum.dart';
import 'package:marten/features/settings/data/config_option_repository.dart';
import 'package:marten/martencore/marten_core_service.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:uuid/uuid.dart';

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
  TaskEither<ProfileFailure, Unit> addLocal(String content, {UserOverride? userOverride, bool markAsActive = true});
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity nProfile, String nContent);
  TaskEither<ProfileFailure, Unit> validateConfig(String path, String tempPath, String? profileOverride, bool debug);
  TaskEither<ProfileFailure, String> generateConfig(String id);
  TaskEither<ProfileFailure, String> getRawConfig(String id);
}

class ProfileRepositoryImpl with ExceptionHandler, InfraLogger implements ProfileRepository {
  ProfileRepositoryImpl({
    required ProfileDataSource profileDataSource,
    required ProfilePathResolver profilePathResolver,
    required MartenCoreService singbox,
    required ConfigOptionRepository configOptionRepository,
    required ProfileParser profileParser,
    required DeviceIdentity deviceIdentity,
  }) : _profileParser = profileParser,
       _configOptionRepo = configOptionRepository,
       _singbox = singbox,
       _profilePathResolver = profilePathResolver,
       _profileDataSource = profileDataSource,
       _deviceIdentity = deviceIdentity;

  final ProfileDataSource _profileDataSource;
  final ProfilePathResolver _profilePathResolver;
  final MartenCoreService _singbox;
  final ConfigOptionRepository _configOptionRepo;
  final ProfileParser _profileParser;
  final DeviceIdentity _deviceIdentity;

  @override
  TaskEither<ProfileFailure, Unit> init() {
    return exceptionHandler(() async {
      if (!kIsWeb) {
        if (!await _profilePathResolver.directory.exists()) {
          await _profilePathResolver.directory.create(recursive: true);
        }
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
  TaskEither<ProfileFailure, Unit> setAsActive(String id) {
    return TaskEither.tryCatch(() async {
      await _profileDataSource.edit(id, const ProfileEntriesCompanion(active: Value(true)));
      return unit;
    }, ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive) {
    return TaskEither.tryCatch(() async {
      await _profileDataSource.deleteById(id, isActive);
      await _deleteProfileFileIfExists(id);
      return unit;
    }, ProfileUnexpectedFailure.new);
  }

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
  }) =>
      TaskEither.tryCatch(
        () async => await _profileDataSource.getByUrl(url).then((profEntry) => profEntry?.toEntity()),
        ProfileFailure.unexpected,
      ).flatMap((profEntity) {
        // if profile is null, generate id
        final id = profEntity?.id ?? const Uuid().v4();
        final file = _profilePathResolver.file(id);
        final tempFile = _profilePathResolver.tempFile(id);
        return withTemporaryProfileFile(
          tempFile,
          () => withProfileFileRollback(file, () {
            if (profEntity != null && profEntity is RemoteProfileEntity) {
              // Update
              final remoteProfile = userOverride != null ? profEntity.copyWith(userOverride: userOverride) : profEntity;
              return _profileParser
                  .updateRemote(rp: remoteProfile, tempFilePath: tempFile.path, cancelToken: cancelToken)
                  .flatMap(
                    (profEntity) =>
                        _persistProfileFile(
                          file: file,
                          tempFile: tempFile,
                          profileOverride: profEntity.profileOverride.value,
                          validate: validate,
                        ).flatMap(
                          (unit) => TaskEither.tryCatch(() async {
                            await _profileDataSource.edit(id, profEntity);
                            return unit;
                          }, ProfileFailure.unexpected),
                        ),
                  );
            } else {
              // Add
              return _profileParser
                  .addRemote(
                    id: id,
                    url: url,
                    tempFilePath: tempFile.path,
                    userOverride: userOverride,
                    active: markAsActive,
                    cancelToken: cancelToken,
                  )
                  .flatMap(
                    (profEntity) =>
                        _persistProfileFile(
                          file: file,
                          tempFile: tempFile,
                          profileOverride: profEntity.profileOverride.value,
                          validate: validate,
                        ).flatMap(
                          (unit) => TaskEither.tryCatch(() async {
                            await _profileDataSource.insert(profEntity);
                            return unit;
                          }, ProfileFailure.unexpected),
                        ),
                  );
            }
          }),
        );
      });

  @override
  TaskEither<ProfileFailure, Unit> addLocal(String content, {UserOverride? userOverride, bool markAsActive = true}) =>
      TaskEither.tryCatch(() async {
        final id = const Uuid().v4();
        final file = _profilePathResolver.file(id);
        final tempFile = _profilePathResolver.tempFile(id);
        return (await withTemporaryProfileFile(
          tempFile,
          () => withProfileFileRollback(
            file,
            () =>
                TaskEither.tryCatch(() async {
                  await tempFile.writeAsString(content);
                  return unit;
                }, ProfileFailure.unexpected).flatMap(
                  (_) => _profileParser
                      .addLocal(
                        id: id,
                        content: content,
                        tempFilePath: tempFile.path,
                        userOverride: userOverride,
                        active: markAsActive,
                      )
                      .flatMap(
                        (profEntity) =>
                            validateConfig(file.path, tempFile.path, profEntity.profileOverride.value, false).flatMap(
                              (unit) => TaskEither.tryCatch(() async {
                                await _profileDataSource.insert(profEntity);
                                return unit;
                              }, ProfileFailure.unexpected),
                            ),
                      ),
                ),
          ),
        ).run()).getOrElse((failure) => throw failure);
      }, (error, stackTrace) => error is ProfileFailure ? error : ProfileFailure.unexpected(error, stackTrace));

  @override
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity profile, String nContent) =>
      TaskEither.tryCatch(
        () async => await _profileDataSource.getById(profile.id).then((profEntry) => profEntry?.toEntity()),
        ProfileFailure.unexpected,
      ).flatMap((oProfile) {
        if (oProfile == null || oProfile.runtimeType != profile.runtimeType) throw const ProfileFailure.notFound();
        if (profile.userOverride == null) loggy.warning('Updaing profile content with "userOverride" == null');
        final id = oProfile.id;
        final file = _profilePathResolver.file(id);
        final tempFile = _profilePathResolver.tempFile(id);
        return withTemporaryProfileFile(
          tempFile,
          () => withProfileFileRollback(
            file,
            () => TaskEither.tryCatch(() async => await tempFile.writeAsString(nContent), ProfileFailure.unexpected)
                .flatMap(
                  (_) =>
                      TaskEither.fromEither(
                        _profileParser.offlineUpdate(
                          profile: oProfile.copyWith(userOverride: profile.userOverride),
                          tempFilePath: tempFile.path,
                        ),
                      ).flatMap(
                        (profEntity) =>
                            validateConfig(file.path, tempFile.path, profEntity.profileOverride.value, false).flatMap(
                              (unit) => TaskEither.tryCatch(() async {
                                await _profileDataSource.edit(id, profEntity);
                                return unit;
                              }, ProfileFailure.unexpected),
                            ),
                      ),
                ),
          ),
        );
      });

  @override
  TaskEither<ProfileFailure, Unit> validateConfig(String path, String tempPath, String? profileOverride, bool debug) =>
      TaskEither.fromEither(_configOptionRepo.fullOptionsOverrided(profileOverride))
          .mapLeft((configOptionFailure) => ProfileFailure.invalidConfig(null, configOptionFailure))
          .flatMap(
            (overridedOptions) => TaskEither.tryCatch(() async {
              final rawContent = ProfileParser.normalizeMartenSubscriptionContent(await File(tempPath).readAsString());
              final sanitizedTemp = File('$tempPath.core');
              await sanitizedTemp.writeAsString(ProfileParser.stripMartenSubscriptionMetadata(rawContent), flush: true);
              try {
                final changeResult = await _singbox.changeOptions(overridedOptions).run();
                final changeError = changeResult.match<String?>((err) => err, (_) => null);
                if (changeError != null) throw ProfileFailure.invalidConfig(changeError);

                final validateResult = await _singbox.validateConfigByPath(path, sanitizedTemp.path, debug).run();
                final validateError = validateResult.match<String?>((err) => err, (_) => null);
                if (validateError != null) throw ProfileFailure.invalidConfig(validateError);
                final parsedContent = await File(path).readAsString();
                if (!ProfileParser.hasSelectableOutbound(parsedContent)) {
                  throw const ProfileFailure.invalidConfig('profile has no supported outbounds');
                }

                final canonicalContent = ProfileParser.restoreMartenSubscriptionMetadata(
                  parsedContent: parsedContent,
                  sourceContent: rawContent,
                );
                await ProfileCrypto.encryptContentToFile(File(path), canonicalContent, _deviceIdentity.clientSecret);
                return unit;
              } finally {
                if (await sanitizedTemp.exists()) await sanitizedTemp.delete();
              }
            }, (err, st) => err is ProfileFailure ? err : ProfileFailure.unexpected(err, st)),
          );

  TaskEither<ProfileFailure, Unit> _persistProfileFile({
    required File file,
    required File tempFile,
    required String? profileOverride,
    required bool validate,
  }) {
    if (validate) {
      return validateConfig(file.path, tempFile.path, profileOverride, false);
    }
    // Background isolates cannot use the Android activity-bound core MethodChannel.
    return TaskEither.tryCatch(() async {
      final rawContent = ProfileParser.normalizeMartenSubscriptionContent(await tempFile.readAsString());
      final validatedContent = ProfileParser.validateBackgroundCandidate(
        rawContent,
      ).getOrElse((failure) => throw failure);
      await ProfileCrypto.encryptContentToFile(file, validatedContent, _deviceIdentity.clientSecret);
      return unit;
    }, ProfileFailure.unexpected);
  }

  @override
  TaskEither<ProfileFailure, String> generateConfig(String id) => TaskEither.tryCatch(() async {
    final configFile = _profilePathResolver.file(id);
    final tempFile = _profilePathResolver.tempFile(id);
    try {
      if (!await configFile.exists()) throw const ProfileFailure.notFound();
      await ProfileCrypto.decryptToTemp(configFile, tempFile, _deviceIdentity.clientSecret);
      final result = await _singbox.generateFullConfigByPath(tempFile.path).run();
      return result.getOrElse((l) => throw ProfileFailure.unexpected(l));
    } finally {
      if (await tempFile.exists()) await tempFile.delete();
    }
  }, _profileStorageFailure);

  @override
  TaskEither<ProfileFailure, String> getRawConfig(String id) {
    return TaskEither.tryCatch(() async {
      final configFile = _profilePathResolver.file(id);
      if (!await configFile.exists()) throw const ProfileFailure.notFound();
      return ProfileCrypto.decryptFile(configFile, _deviceIdentity.clientSecret);
    }, _profileStorageFailure);
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
