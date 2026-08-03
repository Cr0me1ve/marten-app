import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:marten/core/haptic/haptic_service.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/utils/ip_utils.dart';
import 'package:marten/gen/fonts.gen.dart';
import 'package:marten/utils/riverpod_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final _showIp = StateProvider.autoDispose((ref) {
  ref.disposeDelay(const Duration(seconds: 20));
  ref.listenSelf((previous, next) {
    if (previous == false && next == true) {
      ref.read(hapticServiceProvider.notifier).mediumImpact();
    }
  });
  return false;
});

class IPText extends HookConsumerWidget {
  const IPText({required this.ip, required this.onLongPress, this.constrained = false, super.key});

  final String ip;
  final VoidCallback onLongPress;
  final bool constrained;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final isVisible = ref.watch(_showIp);
    final textTheme = Theme.of(context).textTheme;
    final ipStyle = (constrained ? textTheme.labelMedium : textTheme.labelLarge)?.copyWith(
      fontFamily: FontFamily.emoji,
    );

    return Semantics(
      label: t.pages.proxies.ipInfo.address,
      child: InkWell(
        onTap: () {
          ref.read(_showIp.notifier).state = !isVisible;
        },
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: AnimatedCrossFade(
            firstChild: Text(ip, style: ipStyle, textDirection: TextDirection.ltr, overflow: TextOverflow.ellipsis),
            secondChild: Padding(
              padding: constrained ? EdgeInsets.zero : const EdgeInsetsDirectional.only(end: 48),
              child: Text(
                obscureIp(ip),
                semanticsLabel: t.common.hidden,
                style: ipStyle,
                textDirection: TextDirection.ltr,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            crossFadeState: isVisible ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            duration: const Duration(milliseconds: 200),
          ),
        ),
      ),
    );
  }
}

class UnknownIPText extends HookConsumerWidget {
  const UnknownIPText({required this.text, required this.onTap, this.constrained = false, super.key});

  final String text;
  final VoidCallback onTap;
  final bool constrained;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final textTheme = Theme.of(context).textTheme;
    final style = constrained ? textTheme.bodySmall : textTheme.labelMedium;

    return Semantics(
      label: t.pages.proxies.ipInfo.address,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(text, style: style, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

class IPCountryFlag extends HookConsumerWidget {
  const IPCountryFlag({
    required this.countryCode,
    this.organization,
    this.size = 16,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final String? countryCode;
  final double size;

  final EdgeInsetsGeometry padding;

  final String? organization;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return Semantics(
      label: t.pages.proxies.ipInfo.country,
      child: Padding(
        padding: padding,
        child: (countryCode?.isEmpty ?? true)
            ? Icon(FluentIcons.question_circle_20_regular, size: size)
            : SizedBox(
                width: size,
                height: size,
                child: Stack(
                  textDirection: Directionality.of(context),
                  alignment: Alignment.center,
                  children: [
                    Text(
                      _countryFlagEmoji(countryCode!),
                      style: TextStyle(fontFamily: FontFamily.emoji, fontSize: size - 4),
                    ),
                    if (organization != null)
                      Positioned.directional(
                        textDirection: Directionality.of(context),
                        bottom: 0,
                        end: 0,
                        child: OrganisationFlag(organization: organization!, size: size / 2.5),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

String _countryFlagEmoji(String countryCode) {
  final code = countryCode.trim().toUpperCase();
  if (code.length != 2) return code;
  final first = code.codeUnitAt(0);
  final second = code.codeUnitAt(1);
  if (first < 65 || first > 90 || second < 65 || second > 90) return code;
  return String.fromCharCodes([0x1F1E6 + first - 65, 0x1F1E6 + second - 65]);
}

class OrganisationFlag extends HookConsumerWidget {
  const OrganisationFlag({required this.organization, this.size = 24, super.key});

  final String organization;
  final double size;

  // Function to create flag widget with icon and color
  Widget getFlagWidget({
    required Widget widget,
    required String organization,
    required double size,
    required String label,
    required Color color,
  }) {
    return Semantics(
      label: "$label $organization",
      child: Container(
        width: size,
        height: size,

        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(100)),
        // padding: const ,
        child: widget,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return getFlagWidget(
      widget: Icon(FluentIcons.server_20_filled, color: Colors.white, size: size - 6),
      color: Theme.of(context).colorScheme.primary,
      organization: organization,
      size: size,
      label: t.pages.proxies.ipInfo.organization,
    );
  }
}
