import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Defers optional UI work without putting a rejected task in Flutter's
/// zero-delay task queue. Paused animations may retain frame callbacks forever;
/// only a real frame or lifecycle event may retry this admission.
final class UiIdleGate extends WidgetsBindingObserver {
  UiIdleGate({required this.debugLabel, WidgetsBinding? binding}) : _binding = binding ?? WidgetsBinding.instance {
    _binding.addObserver(this);
    scheduleMicrotask(_check);
  }

  final String debugLabel;
  final WidgetsBinding _binding;
  final _completion = Completer<bool>();
  bool _framePending = false;

  /// False means the owner cancelled before admission.
  Future<bool> get ready => _completion.future;

  void cancel() => _finish(false);

  void _finish(bool admitted) {
    if (_completion.isCompleted) return;
    _binding.removeObserver(this);
    _completion.complete(admitted);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) scheduleMicrotask(_check);
  }

  void _check() {
    if (_completion.isCompleted) return;
    final lifecycle = _binding.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    if (_binding.schedulerPhase == SchedulerPhase.idle &&
        !_binding.hasScheduledFrame &&
        _binding.transientCallbackCount == 0) {
      _finish(true);
      return;
    }
    if (_framePending) return;
    _framePending = true;
    _binding.addPostFrameCallback((_) {
      _framePending = false;
      // The callback itself runs during postFrameCallbacks. Check after that
      // frame has fully returned, without requesting another frame or timer.
      scheduleMicrotask(_check);
    }, debugLabel: debugLabel);
  }
}
