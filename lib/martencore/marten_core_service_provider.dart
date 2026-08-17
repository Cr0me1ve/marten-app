import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/directories/directories_provider.dart';
import 'package:marten/core/notification/in_app_notification_controller.dart';
import 'package:marten/core/preferences/general_preferences.dart';
import 'package:marten/martencore/marten_core_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'marten_core_service_provider.g.dart';

@Riverpod(keepAlive: true, dependencies: [AppDirectories, DebugModeNotifier, inAppNotificationController])
MartenCoreService martenCoreService(Ref ref) {
  final service = MartenCoreService(ref);
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
}
