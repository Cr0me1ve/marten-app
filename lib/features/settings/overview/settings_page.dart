import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/preferences/general_preferences.dart';
import 'package:marten/core/router/dialog/dialog_notifier.dart';
import 'package:marten/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:marten/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:marten/features/per_app_proxy/overview/per_app_proxy_notifier.dart';
import 'package:marten/features/settings/notifier/config_option/config_option_notifier.dart';
import 'package:marten/features/settings/notifier/reset_tunnel/reset_tunnel_notifier.dart';
import 'package:marten/utils/utils.dart';

class SettingsPage extends HookConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final perAppProxyMode = ref.watch(Preferences.perAppProxyMode);
    final perAppProxy = perAppProxyMode.enabled;
    // final scrollController = useScrollController();

    // useMemoized(
    //   () {
    //     if (section != null) {
    //       WidgetsBinding.instance.addPostFrameCallback(
    //         (_) {
    //           final box = section!.key.currentContext?.findRenderObject() as RenderBox?;

    //           final offset = box?.localToGlobal(Offset.zero);
    //           if (offset == null) return;
    //           final height = scrollController.offset + offset.dy - MediaQueryData.fromView(View.of(context)).padding.top - kToolbarHeight;
    //           scrollController.animateTo(
    //             height,
    //             duration: const Duration(milliseconds: 500),
    //             curve: Curves.decelerate,
    //           );
    //         },
    //       );
    //     }
    //   },
    // );

    // Settings is a StatefulShellRoute branch root. The system back gesture
    // (Android back button / edge swipe) has no in-branch route to pop, so
    // it propagates up past the shell and closes the app. Intercept it and
    // switch back to the home branch instead — matches the AppBar arrow.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.goNamed('home');
      },
      child: Scaffold(
        appBar: AppBar(
          leading: Breakpoint(context).isMobile()
              ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.goNamed('home'))
              : null,
          title: Text(t.pages.settings.title),
          actions: [
            MenuAnchor(
              menuChildren: <Widget>[
                SubmenuButton(
                  menuChildren: <Widget>[
                    MenuItemButton(
                      onPressed: () async => await ref
                          .read(dialogNotifierProvider.notifier)
                          .showConfirmation(
                            title: t.common.msg.import.confirm,
                            message: t.dialogs.confirmation.settings.import.msg,
                          )
                          .then((shouldImport) async {
                            if (shouldImport) {
                              await ref.read(configOptionNotifierProvider.notifier).importFromClipboard();
                            }
                          }),
                      child: Text(t.pages.settings.options.import.clipboard),
                    ),
                    MenuItemButton(
                      onPressed: () async => await ref
                          .read(dialogNotifierProvider.notifier)
                          .showConfirmation(
                            title: t.common.msg.import.confirm,
                            message: t.dialogs.confirmation.settings.import.msg,
                          )
                          .then((shouldImport) async {
                            if (shouldImport) {
                              await ref.read(configOptionNotifierProvider.notifier).importFromJsonFile();
                            }
                          }),
                      child: Text(t.pages.settings.options.import.file),
                    ),
                  ],
                  child: Text(t.common.import),
                ),
                SubmenuButton(
                  menuChildren: <Widget>[
                    MenuItemButton(
                      onPressed: () async =>
                          await ref.read(configOptionNotifierProvider.notifier).exportJsonClipboard(),
                      child: Text(t.pages.settings.options.export.anonymousToClipboard),
                    ),
                    MenuItemButton(
                      onPressed: () async => await ref.read(configOptionNotifierProvider.notifier).exportJsonFile(),
                      child: Text(t.pages.settings.options.export.anonymousToFile),
                    ),
                    const PopupMenuDivider(),
                    MenuItemButton(
                      onPressed: () async => await ref
                          .read(configOptionNotifierProvider.notifier)
                          .exportJsonClipboard(excludePrivate: false),
                      child: Text(t.pages.settings.options.export.allToClipboard),
                    ),
                    MenuItemButton(
                      onPressed: () async =>
                          await ref.read(configOptionNotifierProvider.notifier).exportJsonFile(excludePrivate: false),
                      child: Text(t.pages.settings.options.export.allToFile),
                    ),
                  ],
                  child: Text(t.common.export),
                ),
                const PopupMenuDivider(),
                MenuItemButton(
                  child: Text(t.pages.settings.options.reset),
                  onPressed: () async => await ref.read(configOptionNotifierProvider.notifier).resetOption(),
                ),
              ],
              builder: (context, controller, child) => IconButton(
                onPressed: () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
                icon: const Icon(Icons.more_vert_rounded),
              ),
            ),
            const Gap(8),
          ],
        ),
        body: ListView(
          children: [
            // TipCard(message: t.settings.experimentalMsg),
            SettingsSection(
              title: t.pages.settings.general.title,
              icon: Icons.layers_rounded,
              namedLocation: context.namedLocation('general'),
            ),
            SettingsSection(
              title: t.pages.settings.routing.title,
              icon: Icons.route_rounded,
              namedLocation: context.namedLocation('routeOptions'),
            ),
            if (PlatformUtils.isAndroid)
              ListTile(
                title: Text(t.pages.settings.routing.perAppProxy.title),
                subtitle: Text(perAppProxyMode.present(t).message),
                leading: const Icon(Icons.apps_rounded),
                trailing: Switch(
                  value: perAppProxy,
                  onChanged: (value) async {
                    final newMode = perAppProxy ? PerAppProxyMode.off : PerAppProxyMode.exclude;
                    if (newMode != PerAppProxyMode.off) {
                      await ref.read(PerAppProxyProvider(newMode.toAppProxy()).notifier).syncNativeSelection();
                    }
                    await ref.read(Preferences.perAppProxyMode.notifier).update(newMode);
                    if (!perAppProxy && context.mounted) context.goNamed('perAppProxy');
                  },
                ),
                onTap: () async {
                  if (!perAppProxy) {
                    await ref.read(PerAppProxyProvider(AppProxyMode.exclude).notifier).syncNativeSelection();
                    await ref.read(Preferences.perAppProxyMode.notifier).update(PerAppProxyMode.exclude);
                  }
                  if (context.mounted) context.goNamed('perAppProxy');
                },
              ),
            SettingsSection(
              title: t.pages.settings.dns.title,
              icon: Icons.dns_rounded,
              namedLocation: context.namedLocation('dnsOptions'),
            ),
            SettingsSection(
              title: t.pages.settings.inbound.title,
              icon: Icons.input_rounded,
              namedLocation: context.namedLocation('inboundOptions'),
            ),
            if (PlatformUtils.isIOS)
              Material(
                child: ListTile(
                  title: Text(t.pages.settings.resetTunnel),
                  leading: const Icon(Icons.autorenew_rounded),
                  onTap: () async {
                    await ref.read(resetTunnelNotifierProvider.notifier).run();
                  },
                ),
              ),
            if (Breakpoint(context).isMobile()) ...[
              SettingsSection(
                title: t.pages.logs.title,
                icon: Icons.description_rounded,
                namedLocation: context.namedLocation('logs'),
              ),
              SettingsSection(
                title: t.pages.about.title,
                icon: Icons.info_rounded,
                namedLocation: context.namedLocation('about'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class SettingsSection extends HookConsumerWidget {
  const SettingsSection({super.key, required this.title, required this.icon, required this.namedLocation});

  final String title;
  final IconData icon;
  final String namedLocation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => context.go(namedLocation),
    );
  }
}
