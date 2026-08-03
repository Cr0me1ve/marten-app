import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/app_info/app_info_provider.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:marten/features/home/widget/connection_button.dart';
import 'package:marten/features/home/widget/subscription_panel.dart';
import 'package:marten/features/profile/notifier/active_profile_notifier.dart';
import 'package:marten/features/proxy/data/proxy_data_providers.dart';
import 'package:marten/gen/assets.gen.dart';

const _backgroundColor = Color(0xFF0D0C0E);

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;

    ref.listen(connectionNotifierProvider, (previous, next) async {
      if (previous?.valueOrNull is Connected) return;
      if (next.valueOrNull is! Connected) return;
      final activeProfile = ref.read(activeProfileProvider).valueOrNull;
      if (activeProfile == null) return;
      final outbounds = await ref.read(localOutboundsProvider.future);
      final tags = outbounds.map((outbound) => outbound.tag).toList(growable: false);
      final remembered = ref.read(selectedProxyByProfileProvider.notifier).rememberedTagFor(activeProfile.id, tags);
      final tag = resolveSelectedOutboundTag(
        tags,
        pending: ref.read(pendingProxySelectionProvider),
        remembered: remembered,
      );
      if (tag == null || tag.isEmpty) return;
      await ref.read(selectedProxyByProfileProvider.notifier).select(activeProfile.id, tag, availableTags: tags);
      await ref.read(proxyRepositoryProvider).selectProxy('select', tag).run();
      ref.read(pendingProxySelectionProvider.notifier).selected = null;
    });

    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: _backgroundColor,
        title: Row(
          children: [
            Assets.images.logo.image(height: 24),
            const Gap(8),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: t.common.appTitle),
                  const TextSpan(text: " "),
                  const WidgetSpan(child: AppVersionLabel(), alignment: PlaceholderAlignment.middle),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Semantics(
            key: const ValueKey("profile_add_button"),
            label: t.pages.profiles.add,
            child: IconButton(
              icon: Icon(Icons.add_rounded, color: theme.colorScheme.primary),
              onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
            ),
          ),
          Semantics(
            key: const ValueKey("settings_button"),
            label: t.pages.settings.title,
            child: IconButton(
              icon: Icon(Icons.settings_rounded, color: theme.colorScheme.primary),
              onPressed: () => context.goNamed('settings'),
            ),
          ),
          const Gap(8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: const Column(
              children: [
                Expanded(child: Center(child: ConnectionButton())),
                SubscriptionPanel(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AppVersionLabel extends HookConsumerWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final version = ref.watch(appInfoProvider).requireValue.presentVersion;
    if (version.isBlank) return const SizedBox();

    return Semantics(
      label: t.common.version,
      button: false,
      child: Container(
        decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          version,
          textDirection: TextDirection.ltr,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
        ),
      ),
    );
  }
}
