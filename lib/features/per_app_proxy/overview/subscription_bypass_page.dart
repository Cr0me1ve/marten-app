import 'dart:convert';

import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:installed_apps/index.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/overview/profiles_notifier.dart';
import 'package:marten/utils/utils.dart';

class SubscriptionBypassPage extends HookConsumerWidget with PresLogger {
  const SubscriptionBypassPage({super.key});

  static List<String> _extractBypassApps(String? profileOverride) {
    if (profileOverride == null || profileOverride.isBlank) return const [];
    try {
      final decoded = jsonDecode(profileOverride);
      if (decoded is! Map<String, dynamic>) return const [];
      final value = decoded['exclude-package'];
      if (value is List) {
        return value.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final localizations = MaterialLocalizations.of(context);

    final asyncProfiles = ref.watch(profilesNotifierProvider);
    final selectedId = useState<String?>(null);

    void exitToPerAppProxy() => context.goNamed('perAppProxy');

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) exitToPerAppProxy();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: exitToPerAppProxy,
            icon: const Icon(Icons.arrow_back),
            tooltip: localizations.backButtonTooltip,
          ),
          title: Text(t.pages.settings.routing.perAppProxy.subscriptionBypass.title),
        ),
        body: asyncProfiles.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => SliverErrorBodyPlaceholder(error.toString()),
          data: (allProfiles) {
            final profilesWithBypass = allProfiles.whereType<RemoteProfileEntity>().where((p) {
              return _extractBypassApps(p.profileOverride).isNotEmpty;
            }).toList(growable: false);

            if (profilesWithBypass.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    t.pages.settings.routing.perAppProxy.subscriptionBypass.empty,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              );
            }

            final knownIds = profilesWithBypass.map((p) => p.id).toSet();
            final RemoteProfileEntity selected;
            if (selectedId.value != null && knownIds.contains(selectedId.value)) {
              selected = profilesWithBypass.firstWhere((p) => p.id == selectedId.value);
            } else {
              selected = profilesWithBypass.firstWhere((p) => p.active, orElse: () => profilesWithBypass.first);
            }
            final packages = _extractBypassApps(selected.profileOverride);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: t.pages.settings.routing.perAppProxy.subscriptionBypass.profilePicker,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selected.id,
                        isExpanded: true,
                        items: profilesWithBypass
                            .map(
                              (p) => DropdownMenuItem(
                                value: p.id,
                                child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) selectedId.value = value;
                        },
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    t.pages.settings.routing.perAppProxy.subscriptionBypass.subtitle(count: packages.length),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: packages.length,
                    itemBuilder: (context, index) => _BypassAppTile(packageName: packages[index]),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _BypassAppTile extends HookConsumerWidget {
  const _BypassAppTile({required this.packageName});

  final String packageName;

  Future<AppInfo?> _getAppInfo() async {
    if (!PlatformUtils.isAndroid) return null;
    try {
      return await InstalledApps.getAppInfo(packageName, BuiltWith.flutter);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final app = useFuture<AppInfo?>(useMemoized(_getAppInfo, [packageName]));

    final loaded = app.connectionState == ConnectionState.done;
    final info = app.data;
    final icon = info?.icon;
    final displayName = loaded ? (info?.name ?? packageName) : packageName;

    return ListTile(
      leading: icon != null
          ? Image.memory(icon, width: 40, height: 40, cacheWidth: 40, cacheHeight: 40)
          : SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.android_rounded, color: theme.colorScheme.onSurfaceVariant),
            ),
      title: Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        packageName,
        style: theme.textTheme.bodySmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(Icons.lock_outline, size: 18, color: theme.colorScheme.onSurfaceVariant),
      enabled: false,
    );
  }
}
