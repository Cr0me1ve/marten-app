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
const _collapsedProfileMinHeight = 64.0;
const _serverListMaxHeight = 400.0;
const _eagerServerRowLimit = 6;

class SubscriptionPanel extends HookConsumerWidget {
  const SubscriptionPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final activeProfile = ref.watch(activeProfileProvider).valueOrNull;
    final profiles = ref.watch(profilesNotifierProvider).valueOrNull ?? const <ProfileEntity>[];
    final useLive = ref.watch(connectionNotifierProvider.select((value) => value.valueOrNull is Connected));
    final switchingProfileId = useState<String?>(null);

    useEffect(() {
      final profileId = activeProfile?.id;
      if (profileId != null) {
        Future.microtask(() => ref.read(localPingProvider.notifier).clear(profileId));
      }
      // A profile switch deliberately is not a dependency: its ping keeps
      // running and its result remains available when the user returns.
      return null;
    }, [useLive]);

    if (activeProfile == null) {
      return _EmptyPanel(
        onAdd: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
        label: t.pages.profiles.add,
      );
    }

    final seenProfileIds = <String>{activeProfile.id};
    final inactiveProfiles = profiles.where((profile) => seenProfileIds.add(profile.id)).toList(growable: false);
    final maxPanelHeight = math.min(MediaQuery.sizeOf(context).height * 0.68, 560.0);
    final collapsedProfileHeight = math.max(
      _collapsedProfileMinHeight,
      16 + MediaQuery.textScalerOf(context).scale(48),
    );
    final inactiveListHeight = math.min(
      inactiveProfiles.length * collapsedProfileHeight + math.max(0, inactiveProfiles.length - 1),
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
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: DecoratedBox(
          decoration: const BoxDecoration(color: _panelColor),
          child: AnimatedSize(
            alignment: Alignment.topCenter,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PanelHeader(profile: activeProfile),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 400),
                    child: KeyedSubtree(
                      key: ValueKey('subscription-profile-body-${activeProfile.id}'),
                      child: _PanelBody(profile: activeProfile),
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
    final useLive = ref.watch(connectionNotifierProvider.select((value) => value.valueOrNull is Connected));

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
                        t.components.subscriptionInfo.updatedAt(date: profile.lastUpdate.formatSubscriptionUpdate()),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white60),
                      ),
                      if (expiresAt != null)
                        Text(
                          '${t.components.subscriptionInfo.expireDate}: ${expiresAt.toLocal().format()}',
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
                  final outboundsFuture = ref.read(localOutboundsByProfileProvider(profile.id).future);
                  final localPing = ref.read(localPingProvider.notifier);
                  final outbounds = await outboundsFuture;
                  await localPing.pingAll(profile.id, outbounds);
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
    final subtitleParts = switch (profile) {
      RemoteProfileEntity(:final expiresAt) => [
        t.components.subscriptionInfo.updatedAt(date: profile.lastUpdate.formatSubscriptionUpdate()),
        if (expiresAt != null) '${t.components.subscriptionInfo.expireDate}: ${expiresAt.toLocal().format()}',
      ],
      _ => const <String>[],
    };

    return ConstrainedBox(
      key: ValueKey('subscription-profile-${profile.id}-collapsed'),
      constraints: const BoxConstraints(minHeight: _collapsedProfileMinHeight),
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
                        if (subtitleParts.isNotEmpty)
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final part in subtitleParts)
                                Text(part, style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54)),
                            ],
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

class _PanelBody extends HookConsumerWidget {
  const _PanelBody({required this.profile});

  final ProfileEntity profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionNotifierProvider.select((value) => value.valueOrNull));
    final updating =
        profile is RemoteProfileEntity &&
        ref.watch(updateProfileNotifierProvider(profile.id).select((value) => value.isLoading));
    final compactDuringRefresh = useRef(false);
    final effectiveConnection = connection ?? const Disconnected();

    if (updating && !effectiveConnection.isDisconnected) {
      compactDuringRefresh.value = true;
    } else if (!updating) {
      compactDuringRefresh.value = false;
    }

    final currentOnly = !effectiveConnection.isDisconnected || compactDuringRefresh.value;
    final selectionEnabled = effectiveConnection.isDisconnected && !compactDuringRefresh.value;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1, thickness: 1, color: _dividerColor),
        Flexible(
          child: effectiveConnection is Connected
              ? _LiveServerList(profileId: profile.id)
              : _OfflineServerList(profileId: profile.id, selectionEnabled: selectionEnabled, currentOnly: currentOnly),
        ),
      ],
    );
  }
}

class _LiveServerList extends ConsumerWidget {
  const _LiveServerList({required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final proxies = ref.watch(proxiesOverviewNotifierProvider);

    return proxies.when(
      data: (group) {
        if (group == null || group.selected.tag.isEmpty) {
          return _PanelMessage(text: t.pages.proxies.empty);
        }
        final selected = group.items.firstWhere((item) => item.tag == group.selected.tag, orElse: () => group.selected);
        return _ServerListViewport(
          itemCount: 1,
          itemBuilder: (context, index) {
            return _PingAwareServerTile(
              profileId: profileId,
              tag: selected.tag,
              title: selected.tagDisplay,
              type: displayTypeForProxyLabel(selected.type),
              countryCode:
                  countryCodeFromTag(selected.tag) ??
                  (selected.ipinfo.countryCode.isNotEmpty ? selected.ipinfo.countryCode : null),
              organization: selected.ipinfo.org,
              coreDelay: selected.urlTestDelay,
              selected: true,
              onTap: null,
            );
          },
        );
      },
      loading: () => _OfflineServerList(profileId: profileId, selectionEnabled: false, currentOnly: true),
      error: (_, _) => _OfflineServerList(profileId: profileId, selectionEnabled: false, currentOnly: true),
    );
  }
}

class _OfflineServerList extends HookConsumerWidget {
  const _OfflineServerList({required this.profileId, required this.selectionEnabled, this.currentOnly = false});

  final String profileId;
  final bool selectionEnabled;
  final bool currentOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final outbounds = ref.watch(localOutboundsByProfileProvider(profileId));
    final pending = ref.watch(pendingProxySelectionProvider);
    final activeProfile = ref.watch(activeProfileProvider).valueOrNull;
    ref.watch(selectedProxyByProfileProvider);
    final retainedItems = useRef<List<LocalOutbound>>(const []);
    final latestItems = outbounds.valueOrNull;

    if (latestItems != null) {
      retainedItems.value = latestItems;
    }
    final items = latestItems ?? retainedItems.value;
    final tags = useMemoized(() => items.map((item) => item.tag).toList(growable: false), [items]);

    if (items.isNotEmpty) {
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
      final visibleItems = currentOnly && selectedTag != null
          ? items.where((item) => item.tag == selectedTag).take(1).toList(growable: false)
          : items;
      return _ServerListViewport(
        itemCount: visibleItems.length,
        itemBuilder: (context, index) {
          final item = visibleItems[index];
          return _PingAwareServerTile(
            profileId: profileId,
            tag: item.tag,
            title: item.displayName,
            type: item.type,
            countryCode: item.countryCode,
            organization: null,
            coreDelay: 0,
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
    }

    if (latestItems != null || outbounds.hasError) {
      return _PanelMessage(text: t.pages.proxies.empty);
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class _ServerListViewport extends StatelessWidget {
  const _ServerListViewport({required this.itemCount, required this.itemBuilder});

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    Widget buildList({required bool shrinkWrap}) {
      return ListView.separated(
        primary: false,
        shrinkWrap: shrinkWrap,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: itemCount,
        separatorBuilder: (_, _) => const Divider(height: 1, thickness: 1, color: _dividerColor),
        itemBuilder: itemBuilder,
      );
    }

    if (itemCount <= _eagerServerRowLimit) {
      return buildList(shrinkWrap: true);
    }
    return SizedBox(height: _serverListMaxHeight, child: buildList(shrinkWrap: false));
  }
}

class _PingAwareServerTile extends ConsumerWidget {
  const _PingAwareServerTile({
    required this.profileId,
    required this.tag,
    required this.title,
    required this.type,
    required this.countryCode,
    required this.organization,
    required this.coreDelay,
    required this.selected,
    required this.onTap,
  });

  final String profileId;
  final String tag;
  final String title;
  final String type;
  final String? countryCode;
  final String? organization;
  final int coreDelay;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ping = ref.watch(localPingProvider.select((pings) => pings[profileId]?[tag]));
    return _ServerTile(
      tag: tag,
      title: title,
      type: type,
      countryCode: countryCode,
      organization: organization,
      urlTestDelay: displayDelayWithLocalPing(coreDelay: coreDelay, localPing: ping),
      pingPending: ping == 0,
      selected: selected,
      onTap: onTap,
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
