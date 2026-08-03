import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/core/directories/directories_provider.dart';
import 'package:marten/features/connection/data/connection_repository.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/features/settings/data/config_option_data_providers.dart';
import 'package:marten/martencore/marten_core_service_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'connection_data_providers.g.dart';

@Riverpod(keepAlive: true)
ConnectionRepository connectionRepository(Ref ref) {
  return ConnectionRepositoryImpl(
    ref: ref,
    directories: ref.watch(appDirectoriesProvider).requireValue,
    configOptionRepository: ref.watch(configOptionRepositoryProvider),
    singbox: ref.watch(martenCoreServiceProvider),
    profilePathResolver: ref.watch(profilePathResolverProvider),
    readDeviceIdentity: () => ref.read(deviceIdentityProvider.future),
  );
}
