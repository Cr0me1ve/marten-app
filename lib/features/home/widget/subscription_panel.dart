import 'dart:math' as math;

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/model/failures.dart';
import 'package:marten/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/notifier/active_profile_notifier.dart';
import 'package:marten/features/profile/notifier/profile_notifier.dart';
import 'package:marten/features/profile/overview/profiles_notifier.dart';
import 'package:marten/features/profile/widget/profile_tile.dart';
import 'package:marten/features/proxy/active/ip_widget.dart';
import 'package:marten/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:marten/gen/fonts.gen.dart';
import 'package:marten/utils/alerts.dart';
import 'package:marten/utils/date_time_formatter.dart';
import 'package:marten/utils/platform_utils.dart';

const _panelColor = Color(0xFF252426);
const _dividerColor = Color(0xFF323135);
const _collapsedProfileHeight = 64.0;

class SubscriptionPanel extends HookConsumerWidget {
  const SubscriptionPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final activeProfile = ref.watch(activeProfileProvider).valueOrNull;
    final profiles = ref.watch(profilesNotifierProvider).valueOrNull ?? const <ProfileEntity>[];
    final connectionStatus = ref.watch(connectionNotifierProvider).valueOrNull ?? const Disconnected();
    final switchingProfileId = useState<String?>(null);
    final useLive = connectionStatus is Connected;

    useEffect(() {
      Future.microtask(() => ref.read(localPingProvider.notifier).clear());
      return null;
    }, [useLive, activeProfile?.id]);

    if (activeProfile == null) {
      return _EmptyPanel(
        onAdd: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
        label: t.pages.profiles.add,
      );
    }

    final seenProfileIds = <String>{activeProfile.id};
    final inactiveProfiles = profiles.where((profile) => seenProfileIds.add(profile.id)).toList(growable: false);
    final maxPanelHeight = math.min(MediaQuery.sizeOf(context).height * 0.68, 560.0);
    final inactiveListHeight = math.min(
      inactiveProfiles.length * _collapsedProfileHeight + math.max(0, inactiveProfiles.length - 1),
      math.min(maxPanelHeight * 0.3, 180.0),
    );

    Future<void> selectProfile(ProfileEntity profile) async {
      if (switchingProfileId.value != null) return;
      switchingProfileId.value = profile.id;
      try {
        await ref.read(profilesNotifierProvider.notifier).selectActiveProfile(profile.id);
      } catch (error) {
        if (context.mounted) {
          CustomToast.error(t.presentShortError(error)).show(context);
        }
      } finally {
        if (context.mounted) switchingProfileId.value = null;
      }
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxPanelHeight),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        clipBehavior: Clip.antiAlias,
        decoration: const BoxDecoration(
          color: _panelColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PanelHeader(profile: activeProfile),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 400),
                child: KeyedSubtree(
                  key: ValueKey('subscription-profile-body-${activeProfile.id}'),
                  child: const _PanelBody(),
                ),
              ),
            ),
            if (inactiveProfiles.isNotEmpty) ...[
              const Divider(height: 1, thickness: 1, color: _dividerColor),
              SizedBox(
                key: const ValueKey('subscription-collapsed-list'),
                height: inactiveListHeight,
                child: ListView.separated(
                  primary: false,
                  itemCount: inactiveProfiles.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, thickness: 1, color: _dividerColor),
                  itemBuilder: (context, index) {
                    final profile = inactiveProfiles[index];
                    return _CollapsedProfileHeader(
                      profile: profile,
                      switching: switchingProfileId.value == profile.id,
                      onTap: () => selectProfile(profile),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.onAdd, required this.label});
  final VoidCallback onAdd;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _panelColor,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: Row(
        children: [
          const Icon(FluentIcons.cloud_add_20_regular, color: Colors.white70),
          const Gap(12),
          Expanded(
            child: TextButton(
              style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: Colors.white),
              onPressed: onAdd,
              child: Text(label),
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelHeader extends HookConsumerWidget {
  const _PanelHeader({required this.profile});

  final ProfileEntity profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final updateState = profile is RemoteProfileEntity ? ref.watch(updateProfileNotifierProvider(profile.id)) : null;
    final updating = updateState?.isLoading ?? false;
    final updateSucceeded = updateState?.valueOrNull != null;
    final updateFailed = updateState?.hasError ?? false;
    final showingFeedback = updateSucceeded || updateFailed;
    final connection = ref.watch(connectionNotifierProvider).valueOrNull ?? const Disconnected();
    final useLive = connection is Connected;

    return Material(
      key: ValueKey('subscription-profile-${profile.id}-expanded'),
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          children: [
            const SizedBox(width: 48, child: Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70)),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontFamily: PlatformUtils.isWindows ? FontFamily.emoji : null,
                      ),
                    ),
                    if (profile case RemoteProfileEntity(:final expiresAt)) ...[
                      Text(
                        t.components.subscriptionInfo.updatedAt(date: profile.lastUpdate.format()),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white60),
                      ),
                      if (expiresAt != null)
                        Text(
                          '${t.components.subscriptionInfo.expireDate}: ${expiresAt.toLocal().format()}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: expiresAt.isBefore(DateTime.now())
                                ? Theme.of(context).colorScheme.error
                                : Colors.white60,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            if (profile is RemoteProfileEntity)
              IconButton(
                tooltip: t.pages.profiles.update,
                onPressed: updating || showingFeedback
                    ? null
                    : () {
                        ref
                            .read(updateProfileNotifierProvider(profile.id).notifier)
                            .updateProfile(profile as RemoteProfileEntity);
                      },
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutBack,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: Tween<double>(begin: 0.72, end: 1).animate(animation), child: child),
                  ),
                  child: updating
                      ? const SizedBox(
                          key: ValueKey('subscription-refresh-loading'),
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                        )
                      : updateSucceeded
                      ? const Icon(
                          Icons.check_rounded,
                          key: ValueKey('subscription-refresh-success'),
                          color: Colors.white70,
                        )
                      : updateFailed
                      ? Icon(
                          Icons.close_rounded,
                          key: const ValueKey('subscription-refresh-failure'),
                          color: Theme.of(context).colorScheme.error,
                        )
                      : const Icon(
                          Icons.refresh_rounded,
                          key: ValueKey('subscription-refresh-idle'),
                          color: Colors.white70,
                        ),
                ),
              ),
            IconButton(
              tooltip: t.pages.proxies.testDelay,
              onPressed: () async {
                if (useLive) {
                  await ref.read(proxiesOverviewNotifierProvider.notifier).urlTest("select");
                } else {
                  final outbounds = await ref.read(localOutboundsProvider.future);
                  await ref.read(localPingProvider.notifier).pingAll(outbounds);
                }
              },
              icon: const Icon(FluentIcons.flash_24_filled, color: Colors.white70),
            ),
            ProfileActionsMenu(profile, (context, toggleVisibility, _) {
              return IconButton(
                tooltip: MaterialLocalizations.of(context).showMenuTooltip,
                onPressed: toggleVisibility,
                icon: const Icon(Icons.more_horiz_rounded, color: Colors.white70),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _CollapsedProfileHeader extends ConsumerWidget {
  const _CollapsedProfileHeader({required this.profile, required this.switching, required this.onTap});

  final ProfileEntity profile;
  final bool switching;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final subtitle = switch (profile) {
      RemoteProfileEntity(:final expiresAt) => [
        t.components.subscriptionInfo.updatedAt(date: profile.lastUpdate.format()),
        if (expiresAt != null) '${t.components.subscriptionInfo.expireDate}: ${expiresAt.toLocal().format()}',
      ].join('  ·  '),
      _ => null,
    };

    return SizedBox(
      key: ValueKey('subscription-profile-${profile.id}-collapsed'),
      height: _collapsedProfileHeight,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: switching ? null : onTap,
          child: Semantics(
            button: true,
            label: t.pages.profiles.nonActiveProfileName(name: profile.name),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.layers_outlined, size: 20, color: Colors.white54),
                  const Gap(12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontFamily: PlatformUtils.isWindows ? FontFamily.emoji : null,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
                          ),
                      ],
                    ),
                  ),
                  const Gap(8),
                  if (switching)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                    )
                  else
                    const Icon(Icons.chevron_right_rounded, color: Colors.white54),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelBody extends ConsumerWidget {
  const _PanelBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionNotifierProvider).valueOrNull ?? const Disconnected();
    final useLive = connection is Connected;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1, thickness: 1, color: _dividerColor),
        Flexible(
          child: useLive ? const _LiveServerList() : _OfflineServerList(selectionEnabled: connection is Disconnected),
        ),
      ],
    );
  }
}

class _LiveServerList extends ConsumerWidget {
  const _LiveServerList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final proxies = ref.watch(proxiesOverviewNotifierProvider);
    final pings = ref.watch(localPingProvider);

    return proxies.when(
      data: (group) {
        if (group == null || group.items.isEmpty) {
          return _PanelMessage(text: t.pages.proxies.empty);
        }
        final items = [...group.items]..sort((a, b) => compareOutboundTagsByName(a.tag, b.tag));
        return ListView.separated(
          primary: false,
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1, thickness: 1, color: _dividerColor),
          itemBuilder: (context, index) {
            final proxy = items[index];
            final ping = pings[proxy.tag];
            return _ServerTile(
              tag: proxy.tag,
              title: proxy.tagDisplay,
              type: displayTypeForProxyLabel(proxy.type),
              countryCode:
                  countryCodeFromTag(proxy.tag) ??
                  (proxy.ipinfo.countryCode.isNotEmpty ? proxy.ipinfo.countryCode : null),
              organization: proxy.ipinfo.org,
              urlTestDelay: displayDelayWithLocalPing(coreDelay: proxy.urlTestDelay, localPing: ping),
              pingPending: ping == 0,
              selected: group.selected.tag == proxy.tag,
              onTap: null,
            );
          },
        );
      },
      loading: () => const _OfflineServerList(selectionEnabled: false),
      error: (_, _) => const _OfflineServerList(selectionEnabled: false),
    );
  }
}

class _OfflineServerList extends ConsumerWidget {
  const _OfflineServerList({required this.selectionEnabled});

  final bool selectionEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final outbounds = ref.watch(localOutboundsProvider);
    final pending = ref.watch(pendingProxySelectionProvider);
    final pings = ref.watch(localPingProvider);
    final activeProfile = ref.watch(activeProfileProvider).valueOrNull;
    ref.watch(selectedProxyByProfileProvider);

    return outbounds.when(
      data: (items) {
        if (items.isEmpty) {
          return _PanelMessage(text: t.pages.proxies.empty);
        }
        final tags = items.map((item) => item.tag).toList(growable: false);
        final remembered = activeProfile == null
            ? null
            : ref.read(selectedProxyByProfileProvider.notifier).rememberedTagFor(activeProfile.id, tags);
        final selectedTag = resolveSelectedOutboundTag(tags, pending: pending, remembered: remembered);
        if (activeProfile != null && selectedTag != null && remembered != selectedTag) {
          Future.microtask(
            () => ref
                .read(selectedProxyByProfileProvider.notifier)
                .select(activeProfile.id, selectedTag, availableTags: tags),
          );
        }
        if (pending != null && pending != selectedTag) {
          Future.microtask(() => ref.read(pendingProxySelectionProvider.notifier).selected = null);
        }
        return ListView.separated(
          primary: false,
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1, thickness: 1, color: _dividerColor),
          itemBuilder: (context, index) {
            final item = items[index];
            final ping = pings[item.tag];
            return _ServerTile(
              tag: item.tag,
              title: item.displayName,
              type: item.type,
              countryCode: item.countryCode,
              organization: null,
              urlTestDelay: switch (ping) {
                null => 0,
                0 => 0,
                -1 => 999999,
                _ => ping,
              },
              pingPending: ping == 0,
              selected: item.tag == selectedTag,
              onTap: selectionEnabled
                  ? () async {
                      ref.read(pendingProxySelectionProvider.notifier).selected = item.tag;
                      if (activeProfile != null) {
                        await ref
                            .read(selectedProxyByProfileProvider.notifier)
                            .select(activeProfile.id, item.tag, availableTags: tags);
                      }
                    }
                  : null,
            );
          },
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => _PanelMessage(text: t.pages.proxies.empty),
    );
  }
}

class _PanelMessage extends StatelessWidget {
  const _PanelMessage({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white60),
        ),
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.tag,
    required this.title,
    required this.type,
    required this.countryCode,
    required this.organization,
    required this.urlTestDelay,
    required this.selected,
    required this.onTap,
    this.pingPending = false,
  });

  final String tag;
  final String title;
  final String type;
  final String? countryCode;
  final String? organization;
  final int urlTestDelay;
  final bool selected;
  final bool pingPending;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delay = urlTestDelay;
    final timeout = delay > 65000;
    final pingColor = _delayColor(delay);
    final enabled = onTap != null;
    final titleColor = enabled || selected ? Colors.white : Colors.white54;
    final subtitleColor = enabled || selected ? Colors.white54 : Colors.white38;

    return Material(
      color: selected ? const Color(0xFF34323A) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              if (selected)
                Container(width: 3, height: 36, color: const Color(0xFFE3A766))
              else
                const SizedBox(width: 3, height: 36),
              const Gap(8),
              IPCountryFlag(
                countryCode: countryCode,
                organization: organization,
                size: 36,
                padding: const EdgeInsetsDirectional.only(end: 8),
              ),
              const Gap(4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: titleColor,
                        fontWeight: FontWeight.w600,
                        fontFamily: PlatformUtils.isWindows ? FontFamily.emoji : null,
                      ),
                    ),
                    const Gap(2),
                    Text(
                      type,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: subtitleColor),
                    ),
                  ],
                ),
              ),
              const Gap(8),
              if (pingPending)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
                )
              else if (delay != 0)
                Text(
                  timeout ? "×" : "$delay ms",
                  style: TextStyle(color: pingColor, fontWeight: FontWeight.w500),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Color _delayColor(int delay) {
    if (delay == 0) return Colors.white38;
    return switch (delay) {
      < 800 => const Color(0xFF7CC678),
      < 1500 => const Color(0xFFE5A14D),
      _ => const Color(0xFFE36F6F),
    };
  }
}
