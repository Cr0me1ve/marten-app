import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/core/directories/directories_provider.dart';
import 'package:marten/features/connection/data/connection_repository.dart';
import 'package:marten/features/connection/data/native_resume_config_synchronizer.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/features/settings/data/config_option_data_providers.dart';
import 'package:marten/martencore/marten_core_service_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'connection_data_providers.g.dart';

final nativeResumeConfigPublisherProvider = Provider<NativeResumeConfigPublisher>(
  (_) => const MethodChannelNativeResumeConfigPublisher(),
);

final nativeResumeConfigSynchronizerProvider = Provider<NativeResumeConfigSynchronizer>((ref) {
  final pendingSelection = ref.watch(pendingProxySelectionProvider.notifier);
  final rememberedSelection = ref.watch(selectedProxyByProfileProvider.notifier);
  return NativeResumeConfigSynchronizer(
    profilePathResolver: ref.watch(profilePathResolverProvider),
    deviceIdentity: ref.watch(deviceIdentityProvider.future),
    publisher: ref.watch(nativeResumeConfigPublisherProvider),
    resolveSelectedTag: (profile, tags) => resolveSelectedOutboundTag(
      tags,
      pending: pendingSelection.selected,
      remembered: rememberedSelection.rememberedTagFor(profile.id, tags),
    ),
  );
});

@Riverpod(keepAlive: true)
ConnectionRepository connectionRepository(Ref ref) {
  return ConnectionRepositoryImpl(
    ref: ref,
    directories: ref.watch(appDirectoriesProvider).requireValue,
    configOptionRepository: ref.watch(configOptionRepositoryProvider),
    singbox: ref.watch(martenCoreServiceProvider),
    profilePathResolver: ref.watch(profilePathResolverProvider),
    readDeviceIdentity: () => ref.read(deviceIdentityProvider.future),
    nativeResumeConfigSynchronizer: ref.watch(nativeResumeConfigSynchronizerProvider),
  );
}
