import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/analytics/analytics_controller.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/model/constants.dart';
import 'package:marten/core/preferences/general_preferences.dart';
import 'package:marten/features/common/general_pref_tiles.dart';
import 'package:marten/gen/assets.gen.dart';
import 'package:marten/utils/utils.dart';

class IntroPage extends HookConsumerWidget with PresLogger {
  const IntroPage({super.key});

  // for focus management
  KeyEventResult _handleKeyEvent(KeyEvent event, String key) {
    if (KeyboardConst.select.contains(event.logicalKey) && event is KeyUpEvent) {
      UriUtils.tryLaunch(Uri.parse(IntroConst.url[key]!));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final isStarting = useState(false);

    // for focus management
    final focusStates = <String, ValueNotifier<bool>>{
      IntroConst.termsAndConditionsKey: useState<bool>(false),
      IntroConst.githubKey: useState<bool>(false),
      IntroConst.licenseKey: useState<bool>(false),
    };
    final focusNodes = <String, FocusNode>{
      IntroConst.termsAndConditionsKey: useFocusNode(),
      IntroConst.githubKey: useFocusNode(),
      IntroConst.licenseKey: useFocusNode(),
    };
    useEffect(() {
      for (final entry in focusNodes.entries) {
        entry.value.addListener(() => focusStates[entry.key]!.value = entry.value.hasPrimaryFocus);
      }
      return null;
    }, []);

    return Scaffold(
      body: Center(
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth > IntroConst.maxwidth
                          ? IntroConst.maxwidth
                          : constraints.maxWidth;
                      final size = width * 0.4;
                      return Assets.images.logo.image(width: size, height: size);
                    },
                  ),
                  const Gap(16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      t.intro.banner,
                      style: theme.textTheme.bodyLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Gap(24),
                  const LocalePrefTile(),
                  const EnableAnalyticsPrefTile(),
                  const Gap(24),
                  Focus(
                    focusNode: focusNodes[IntroConst.termsAndConditionsKey],
                    onKeyEvent: (node, event) => _handleKeyEvent(event, IntroConst.termsAndConditionsKey),
                    child: Text.rich(
                      t.intro.termsAndPolicyCaution(
                        tap: (text) => TextSpan(
                          text: text,
                          style: TextStyle(
                            color: focusStates[IntroConst.termsAndConditionsKey]!.value ? Colors.green : Colors.blue,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = () async {
                              await UriUtils.tryLaunch(Uri.parse(Constants.termsAndConditionsUrl));
                            },
                        ),
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const Gap(8),
                  Focus(
                    focusNode: focusNodes[IntroConst.githubKey],
                    onKeyEvent: (node, event) => _handleKeyEvent(event, IntroConst.githubKey),
                    child: Text.rich(
                      t.intro.info(
                        tap_source: (text) => TextSpan(
                          text: text,
                          style: TextStyle(
                            color: focusStates[IntroConst.githubKey]!.value ? Colors.green : Colors.blue,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = () async {
                              await UriUtils.tryLaunch(Uri.parse(Constants.githubUrl));
                            },
                        ),
                        tap_license: (text) => TextSpan(
                          text: text,
                          style: TextStyle(
                            color: focusStates[IntroConst.githubKey]!.value ? Colors.green : Colors.blue,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = () async {
                              await UriUtils.tryLaunch(Uri.parse(Constants.licenseUrl));
                            },
                        ),
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  // only for managing license node focus
                  Focus(
                    focusNode: focusNodes[IntroConst.licenseKey],
                    onKeyEvent: (node, event) => _handleKeyEvent(event, IntroConst.licenseKey),
                    child: const Gap(88),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: isStarting.value
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator())
            : const Icon(Icons.rocket_launch),
        label: Text(t.common.start, style: theme.textTheme.titleMedium),
        onPressed: () async {
          if (isStarting.value) return;
          isStarting.value = true;
          if (!ref.read(analyticsControllerProvider).requireValue) {
            loggy.info("disabling analytics per user request");
            try {
              await ref.read(analyticsControllerProvider.notifier).disableAnalytics();
            } catch (error, stackTrace) {
              loggy.error("could not disable analytics", error, stackTrace);
            }
          }
          await ref.read(Preferences.introCompleted.notifier).update(true);
        },
      ),
    );
  }
}
