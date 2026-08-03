import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:toastification/toastification.dart';

part 'in_app_notification_controller.g.dart';

@Riverpod(keepAlive: true)
InAppNotificationController inAppNotificationController(Ref ref) {
  return InAppNotificationController();
}

enum NotificationType { info, error, success }

class InAppNotificationController with AppLogger {
  ToastificationItem _show(
    String message, {
    NotificationType type = NotificationType.info,
    Duration duration = const Duration(seconds: 3),
    ToastificationStyle style = ToastificationStyle.flatColored,
  }) {
    toastification.dismissAll();
    return toastification.show(
      title: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
      type: type._toastificationType,
      alignment: AlignmentDirectional.bottomStart,
      autoCloseDuration: duration,
      style: style,
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide.none,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 20, offset: const Offset(0, 10))],
      pauseOnHover: true,
      showProgressBar: false,
      dragToClose: true,
      closeOnClick: true,
      closeButtonShowType: CloseButtonShowType.onHover,
    );
  }

  ToastificationItem? showErrorToast(String message, {bool filled = false}) => _show(
    message,
    type: NotificationType.error,
    duration: const Duration(seconds: 5),
    style: filled ? ToastificationStyle.fillColored : ToastificationStyle.flatColored,
  );

  ToastificationItem? showSuccessToast(String message) => _show(message, type: NotificationType.success);

  ToastificationItem? showInfoToast(String message, {Duration duration = const Duration(seconds: 3)}) =>
      _show(message, duration: duration);
}

extension NotificationTypeX on NotificationType {
  ToastificationType get _toastificationType => switch (this) {
    NotificationType.success => ToastificationType.success,
    NotificationType.error => ToastificationType.error,
    NotificationType.info => ToastificationType.info,
  };
}
