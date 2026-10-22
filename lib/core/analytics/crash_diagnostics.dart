import 'dart:io';

import 'package:flutter/services.dart';
import 'package:marten/core/analytics/analytics_logger.dart';
import 'package:marten/core/logger/crash_diagnostics_redactor.dart';

/// Local event-driven visibility. Never initializes an SDK or opens a socket.
class CrashDiagnostics {
  static const _platform = MethodChannel('app.marten.client/platform');
  static String _phase = 'not_attempted';
  static int _phaseTimeMs = 0;

  static Future<void> notePhase(String phase) async {
    if (!RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(phase)) return;
    _phase = phase;
    _phaseTimeMs = DateTime.now().millisecondsSinceEpoch;
    if (!Platform.isAndroid) return;
    try {
      await _platform.invokeMethod<void>('set_crash_reporting_phase', phase).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Local diagnostics cannot affect initialization or connection lifecycle.
    }
  }

  static Future<String> snapshot({bool? isAndroid}) async {
    if (!(isAndroid ?? Platform.isAndroid)) return '';
    String native;
    try {
      native =
          await _platform.invokeMethod<String>('get_crash_diagnostics').timeout(const Duration(seconds: 5)) ??
          'MARTEN_CRASH_DIAGNOSTICS schema=1 history_status=unavailable';
    } catch (_) {
      native = 'MARTEN_CRASH_DIAGNOSTICS schema=1 history_status=unavailable';
    }
    final local = await crashReporter.localEvidenceSnapshot();
    return redactCrashDiagnostics(
      '$native\n${crashReporter.diagnosticStatus}\n$local\n'
      'MARTEN_REPORTING_ATTEMPT phase=$_phase timestamp_ms=$_phaseTimeMs\n',
    );
  }
}
