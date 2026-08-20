import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/features/app_update/notifier/play_in_app_update_notifier.dart';

class PlayInAppUpdateListener extends HookConsumerWidget {
  const PlayInAppUpdateListener({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    ref.listen(playInAppUpdateNotifierProvider, (previous, next) {
      if (next != PlayInAppUpdateState.readyToInstall || previous == PlayInAppUpdateState.readyToInstall) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t.dialogs.newVersion.title),
            duration: const Duration(days: 1),
            action: SnackBarAction(
              label: t.dialogs.newVersion.updateNow,
              onPressed: () {
                ref.read(playInAppUpdateNotifierProvider.notifier).completeFlexibleUpdate();
              },
            ),
          ),
        );
      });
    });

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(playInAppUpdateNotifierProvider.notifier).checkOnLaunch();
      });
      return null;
    }, const []);

    return child;
  }
}
