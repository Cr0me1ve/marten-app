import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/db/provider/db_providers.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/core/directories/directories_provider.dart';
import 'package:marten/core/http_client/http_client_provider.dart';
import 'package:marten/features/profile/data/profile_data_source.dart';
import 'package:marten/features/profile/data/profile_parser.dart';
import 'package:marten/features/profile/data/profile_path_resolver.dart';
import 'package:marten/features/profile/data/profile_repository.dart';
import 'package:marten/features/settings/data/config_option_data_providers.dart';
import 'package:marten/martencore/marten_core_service_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profile_data_providers.g.dart';

@Riverpod(keepAlive: true)
Future<ProfileRepository> profileRepository(Ref ref) async {
  final deviceIdentity = await ref.watch(deviceIdentityProvider.future);
  final repo = ProfileRepositoryImpl(
    profileDataSource: ref.watch(profileDataSourceProvider),
    profilePathResolver: ref.watch(profilePathResolverProvider),
    readSingbox: () => ref.read(martenCoreServiceProvider),
    readConfigOptionRepository: () => ref.read(configOptionRepositoryProvider),
    profileParser: ref.watch(profileParserProvider),
    deviceIdentity: deviceIdentity,
  );
  await repo.init().getOrElse((l) => throw l).run();
  return repo;
}

@Riverpod(keepAlive: true)
ProfileDataSource profileDataSource(Ref ref) {
  return ProfileDao(ref.watch(dbProvider));
}

@Riverpod(keepAlive: true)
ProfilePathResolver profilePathResolver(Ref ref) {
  return ProfilePathResolver(ref.watch(appDirectoriesProvider).requireValue.workingDir);
}

@Riverpod(keepAlive: true)
ProfileParser profileParser(Ref ref) {
  return ProfileParser(ref: ref, httpClient: ref.watch(httpClientProvider));
}
