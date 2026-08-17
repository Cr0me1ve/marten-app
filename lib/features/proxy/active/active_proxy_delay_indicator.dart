import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/widget/shimmer_skeleton.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:marten/features/profile/notifier/active_profile_notifier.dart';
import 'package:marten/features/proxy/active/active_proxy_notifier.dart';
import 'package:marten/utils/custom_loggers.dart';

class ActiveProxyDelayIndicator extends HookConsumerWidget with InfraLogger {
  const ActiveProxyDelayIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final theme = Theme.of(context);

    if (activeProxy is! AsyncData) {
      return const SizedBox(); // Avoid building widget if data is not available
    }

    final proxy = activeProxy.value!;
    final profileId = ref.watch(activeProfileProvider.select((profile) => profile.valueOrNull?.id));
    final localPing = profileId == null
        ? null
        : ref.watch(localPingProvider.select((pings) => pings[profileId]?[proxy.tag]));
    final delay = displayDelayWithLocalPing(coreDelay: proxy.urlTestDelay, localPing: localPing);
    final timeout = delay > 65000;

    return Center(
      child: InkWell(
        onTap: () async {
          try {
            await ref.read(activeProxyNotifierProvider.notifier).urlTest("");
          } catch (e) {
            // Handle error here
            loggy.error("Error during URL test: $e");
          }
        },
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(FluentIcons.wifi_1_24_regular),
              const Gap(8),
              if (delay > 0)
                Text.rich(
                  semanticsLabel: timeout ? t.pages.proxies.delay.timeout : t.pages.proxies.delay.result(delay: delay),
                  TextSpan(
                    children: [
                      if (timeout)
                        TextSpan(
                          text: t.common.timeout,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.error,
                          ),
                        )
                      else ...[
                        TextSpan(
                          text: delay.toString(),
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const TextSpan(text: " ms"),
                      ],
                    ],
                  ),
                )
              else
                Semantics(label: t.pages.proxies.delay.testing, child: const ShimmerSkeleton(width: 48, height: 18)),
            ],
          ),
        ),
      ),
    );
  }
}
