import 'dart:io';

import 'package:fpdart/fpdart.dart';
import 'package:marten/core/crypto/profile_crypto.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/features/connection/model/connection_failure.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:marten/features/profile/data/profile_parser.dart';
import 'package:marten/features/profile/data/profile_path_resolver.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:marten_native_resume/marten_native_resume.dart';
import 'package:uuid/uuid.dart';

abstract interface class NativeResumeConfigPublisher {
  Future<bool> store({required String path, required String name});

  Future<bool> clear();
}

final class MethodChannelNativeResumeConfigPublisher implements NativeResumeConfigPublisher {
  const MethodChannelNativeResumeConfigPublisher();

  static const _operationTimeout = Duration(seconds: 8);

  @override
  Future<bool> store({required String path, required String name}) =>
      MartenNativeResume.store(path: path, name: name).timeout(_operationTimeout);

  @override
  Future<bool> clear() => MartenNativeResume.clear().timeout(_operationTimeout);
}

typedef NativeResumeSelectedTagResolver = String? Function(ProfileEntity profile, List<String> availableTags);

String notificationDisplayNameForSelectedOutbound(ProfileEntity profile, String? selectedTag) {
  final selectedName = selectedTag == null ? '' : stripTagMetadata(selectedTag).trim();
  return selectedName.isEmpty ? profile.name : selectedName;
}

/// Builds and publishes the minimal encrypted Android resume configuration.
///
/// This component deliberately has no dependency on [MartenCoreService] or
/// [ConnectionRepository]. It is safe to use from a short-lived headless
/// Flutter engine and still preserves the same fail-closed preparation used by
/// foreground connection flows.
final class NativeResumeConfigSynchronizer with InfraLogger {
  NativeResumeConfigSynchronizer({
    required this.profilePathResolver,
    required this.deviceIdentity,
    required this.publisher,
    required this.resolveSelectedTag,
    bool? isAndroid,
  }) : isAndroid = isAndroid ?? Platform.isAndroid;

  final ProfilePathResolver profilePathResolver;
  final Future<DeviceIdentity> deviceIdentity;
  final NativeResumeConfigPublisher publisher;
  final NativeResumeSelectedTagResolver resolveSelectedTag;
  final bool isAndroid;

  TaskEither<ConnectionFailure, Unit> synchronize(ProfileEntity? activeProfile, {bool Function()? isCurrent}) {
    if (!isAndroid) return TaskEither.of(unit);
    final remainsCurrent = isCurrent ?? () => true;

    return TaskEither.tryCatch(
      () async {
        if (activeProfile == null) {
          if (!remainsCurrent()) return unit;
          final cleared = await publisher.clear();
          if (!cleared) throw const ConnectionFailure.unexpected('failed to clear native resume config');
          loggy.info('cleared native resume config because there is no active profile');
          return unit;
        }

        final encryptedFile = profilePathResolver.file(activeProfile.id);
        final plaintextFile = profilePathResolver.tempFile('${activeProfile.id}_native_resume_${const Uuid().v4()}');
        try {
          if (!await encryptedFile.exists()) {
            throw const ConnectionFailure.invalidConfig(missingProfileConfigFailureMessage);
          }
          final identity = await deviceIdentity;
          if (!remainsCurrent()) return unit;
          try {
            await ProfileCrypto.decryptToTemp(encryptedFile, plaintextFile, identity.clientSecret);
          } catch (error) {
            if (!ProfileCrypto.isMissingFileError(error)) rethrow;
            throw const ConnectionFailure.invalidConfig(missingProfileConfigFailureMessage);
          }
          if (!remainsCurrent()) return unit;

          final rawConfig = await plaintextFile.readAsString();
          final coreConfig = ProfileParser.stripMartenSubscriptionMetadata(rawConfig);
          final tags = selectableOutboundTagsFromConfig(coreConfig);
          final selectedTag = resolveSelectedTag(activeProfile, tags);
          final preparedConfig = selectedTag == null
              ? coreConfig
              : prepareConfigForSelectedOutbound(coreConfig, selectedTag);
          await plaintextFile.writeAsString(ProfileParser.stripMartenSubscriptionMetadata(preparedConfig), flush: true);
          if (!remainsCurrent()) return unit;

          final stored = await publisher.store(
            path: plaintextFile.path,
            name: notificationDisplayNameForSelectedOutbound(activeProfile, selectedTag),
          );
          if (!stored) throw const ConnectionFailure.unexpected('failed to store native resume config');
          loggy.info('synchronized native resume config for the active profile');
          return unit;
        } catch (error, stackTrace) {
          if (remainsCurrent()) {
            try {
              final cleared = await publisher.clear();
              if (!cleared) loggy.warning('failed to clear stale native resume config after sync failure');
            } catch (clearError, clearStackTrace) {
              loggy.warning(
                'failed to clear stale native resume config after sync failure',
                clearError,
                clearStackTrace,
              );
            }
          }
          Error.throwWithStackTrace(error, stackTrace);
        } finally {
          if (await plaintextFile.exists()) await plaintextFile.delete();
        }
      },
      (error, stackTrace) {
        return error is ConnectionFailure ? error : ConnectionFailure.unexpected(error, stackTrace);
      },
    );
  }
}
