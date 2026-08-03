import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';

enum AlertType {
  info,
  error,
  success;

  ToastificationType get _toastificationType => switch (this) {
    success => ToastificationType.success,
    error => ToastificationType.error,
    info => ToastificationType.info,
  };
}

class CustomToast extends StatelessWidget {
  const CustomToast(this.message, {this.type = AlertType.info, this.icon, this.duration = const Duration(seconds: 3)});

  const CustomToast.error(this.message, {this.duration = const Duration(seconds: 5)})
    : type = AlertType.error,
      icon = FluentIcons.error_circle_24_regular;

  const CustomToast.success(this.message, {this.duration = const Duration(seconds: 3)})
    : type = AlertType.success,
      icon = FluentIcons.checkmark_24_regular;

  final String message;
  final AlertType type;
  final IconData? icon;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (type) {
      AlertType.info => scheme.primary,
      AlertType.error => scheme.error,
      AlertType.success => scheme.tertiary,
    };

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.22)),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        color: scheme.surfaceContainerHigh,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 20, offset: const Offset(0, 10)),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Text(message, style: TextStyle(color: scheme.onSurface, height: 1.25)),
          ),
        ],
      ),
    );
  }

  void show(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (type) {
      AlertType.info => scheme.primary,
      AlertType.error => scheme.error,
      AlertType.success => scheme.tertiary,
    };

    toastification.show(
      context: context,
      title: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
      icon: icon == null ? null : Icon(icon, color: color, size: 21),
      type: type._toastificationType,
      alignment: Alignment.bottomLeft,
      autoCloseDuration: duration,
      style: ToastificationStyle.flat,
      primaryColor: color,
      backgroundColor: scheme.surfaceContainerHigh,
      foregroundColor: scheme.onSurface,
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: color.withValues(alpha: 0.22)),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 20, offset: const Offset(0, 10))],
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      pauseOnHover: true,
      showProgressBar: false,
      dragToClose: true,
      closeOnClick: true,
      closeButtonShowType: CloseButtonShowType.onHover,
    );
  }
}
