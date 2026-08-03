import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/localization/translations.dart';

class CustomAlertDialog extends HookConsumerWidget {
  const CustomAlertDialog({super.key, this.title, required this.message});

  final String? title;
  final String? message;

  factory CustomAlertDialog.fromErr(({String type, String? message}) err) =>
      CustomAlertDialog(title: err.type, message: err.message);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final hasMessage = message?.trim().isNotEmpty == true;
    final heading = title ?? message ?? t.errors.unexpected;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isCompact = screenWidth < 420;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Material(
          color: colorScheme.surfaceContainerHigh,
          elevation: 18,
          shadowColor: Colors.black.withValues(alpha: 0.32),
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.error.withValues(alpha: 0.22)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer.withValues(alpha: 0.28),
                    border: Border(bottom: BorderSide(color: colorScheme.error.withValues(alpha: 0.18))),
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(isCompact ? 18 : 22, 18, isCompact ? 18 : 22, 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: colorScheme.error.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: colorScheme.error.withValues(alpha: 0.22)),
                          ),
                          child: Icon(FluentIcons.error_circle_24_filled, color: colorScheme.error, size: 25),
                        ),
                        const Gap(14),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              heading,
                              style: textTheme.titleMedium?.copyWith(
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.w800,
                                height: 1.18,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (hasMessage && title != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(isCompact ? 18 : 22, 16, isCompact ? 18 : 22, 0),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.42),
                      child: SingleChildScrollView(
                        child: SelectionArea(
                          child: Text(
                            message!,
                            style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant, height: 1.42),
                          ),
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    isCompact ? 18 : 22,
                    hasMessage && title != null ? 18 : 20,
                    isCompact ? 18 : 22,
                    20,
                  ),
                  child: Align(
                    alignment: isCompact ? AlignmentDirectional.center : AlignmentDirectional.centerEnd,
                    child: SizedBox(
                      width: isCompact ? double.infinity : null,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(104, 44),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: () => context.pop(),
                        child: Text(t.common.ok),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
