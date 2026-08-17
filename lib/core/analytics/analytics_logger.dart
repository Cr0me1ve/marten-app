import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:loggy/loggy.dart';
import 'package:marten/core/analytics/analytics_filter.dart';
import 'package:marten/core/analytics/crash_reporting_backend.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';

const int crashContextRecordLimit = 40;
const int crashContextLineLengthLimit = 700;
const Set<String> _allowedCrashStateKeys = <String>{'environment', 'app_lifecycle', 'connection_state', 'last_action'};

final crashReporter = CrashlyticsLoggyIntegration();

class CrashlyticsLoggyIntegration extends LoggyPrinter with WidgetsBindingObserver {
  CrashlyticsLoggyIntegration({
    CrashReportingBackend? backend,
    this.contextRecordLimit = crashContextRecordLimit,
    this.contextLineLengthLimit = crashContextLineLengthLimit,
    this.minContextLevel = LogLevel.info,
    this.minEventLevel = LogLevel.error,
  }) : assert(contextRecordLimit > 0),
       assert(contextRecordLimit <= crashContextRecordLimit),
       assert(contextLineLengthLimit > 0),
       assert(contextLineLengthLimit <= 1024),
       _backend = backend;

  final CrashReportingBackend? _backend;
  final int contextRecordLimit;
  final int contextLineLengthLimit;
  final LogLevel minContextLevel;
  final LogLevel minEventLevel;

  final ListQueue<String> _context = ListQueue<String>();
  final Map<String, Object> _customKeys = <String, Object>{'context_schema': 1, 'reporting_mode': 'privacy_safe'};

  CrashReportingBackend? _activeBackend;
  Future<void> _deliveryTail = Future<void>.value();
  int _nextContextSlot = 0;
  bool _collectContext = false;
  bool _enabled = false;
  bool _lifecycleTrackingStarted = false;

  bool get isEnabled => _enabled;

  List<String> get contextSnapshot => List<String>.unmodifiable(_context);

  void startLifecycleTracking() {
    if (_lifecycleTrackingStarted) return;
    WidgetsBinding.instance.addObserver(this);
    _lifecycleTrackingStarted = true;
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState != null) setContext('app_lifecycle', lifecycleState.name);
  }

  void setContextCollectionEnabled(bool enabled) {
    _collectContext = enabled;
    if (!enabled) {
      _context.clear();
      _nextContextSlot = 0;
    }
  }

  Future<void> enable({CrashReportingBackend? backend, bool discardExistingReports = false}) async {
    final resolvedBackend = backend ?? _backend ?? FirebaseCrashReportingBackend();
    _activeBackend = resolvedBackend;
    _enabled = true;
    _collectContext = true;
    await _enqueue(() async {
      if (discardExistingReports) await _guarded(resolvedBackend.deleteUnsentReports);
      await resolvedBackend.setCollectionEnabled(true);
      for (final entry in _customKeys.entries) {
        await resolvedBackend.setCustomKey(entry.key, entry.value);
      }
      await _seedNativeContext(resolvedBackend);
    });
  }

  Future<void> disable() async {
    _enabled = false;
    _collectContext = false;
    _context.clear();
    final backend = _activeBackend;
    _activeBackend = null;
    _nextContextSlot = 0;
    if (backend != null) await _guarded(() => backend.setCollectionEnabled(false));
    await _deliveryTail;
    if (backend != null) {
      for (var slot = 0; slot < contextRecordLimit; slot++) {
        await _guarded(() => backend.setCustomKey(_contextSlotKey(slot), ''));
      }
      await _guarded(backend.deleteUnsentReports);
    }
  }

  void setContext(String key, Object value) {
    if (!_allowedCrashStateKeys.contains(key)) return;
    final safeKey = _truncate(SensitiveDataRedactor.redact(key), 64);
    final safeValue = _truncate(SensitiveDataRedactor.redactObject(value), 256);
    _customKeys[safeKey] = safeValue;
    final backend = _activeBackend;
    if (_enabled && backend != null) {
      _enqueue(() => backend.setCustomKey(safeKey, safeValue));
    }
  }

  Future<void> recordError(Object error, StackTrace? stackTrace, {required String reason, bool fatal = false}) {
    if (!_enabled || !canSendCrashReport(error)) return Future<void>.value();
    final backend = _activeBackend;
    if (backend == null) return Future<void>.value();
    final context = contextSnapshot;
    final safeReason = _truncate(SensitiveDataRedactor.redact(reason), 256);
    return _enqueue(
      () => backend.recordError(
        sanitizeCrashException(error),
        sanitizeCrashStackTrace(stackTrace),
        reason: safeReason,
        information: context,
        fatal: fatal,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setContext('app_lifecycle', state.name);
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final update = _addContextLine('$timestamp [INFO] [lifecycle] app=${state.name}');
    final backend = _activeBackend;
    if (_enabled && backend != null && update != null) {
      _enqueue(() => _writeNativeContextUpdate(backend, update));
    }
  }

  @override
  void onLog(LogRecord record) {
    if (!_shouldLog(record.level, minContextLevel)) return;

    final line = _formatContextLine(record);
    final contextUpdate = _addContextLine(line);

    final backend = _activeBackend;
    if (!_enabled || backend == null) return;

    final context = contextSnapshot;
    final error = record.error;
    final shouldReport = _shouldLog(record.level, minEventLevel) && error != null && canReportLogRecord(error);
    final fatal = _isUnhandledFatal(record);
    final safeReason = _truncate('loggy ${record.level.name} ${SensitiveDataRedactor.redact(record.loggerName)}', 256);

    _enqueue(() async {
      if (contextUpdate != null) {
        await _writeNativeContextUpdate(backend, contextUpdate);
      }
      if (!shouldReport) return;
      await backend.setCustomKey('last_logger', _truncate(SensitiveDataRedactor.redact(record.loggerName), 128));
      await backend.setCustomKey('last_level', record.level.name);
      await backend.setCustomKey('error_context_records', context.length);
      await backend.recordError(
        sanitizeCrashException(error),
        sanitizeCrashStackTrace(record.stackTrace),
        reason: safeReason,
        information: context,
        fatal: fatal,
      );
    });
  }

  bool _shouldLog(LogLevel level, LogLevel minimum) => level != LogLevel.off && level.priority >= minimum.priority;

  bool _isUnhandledFatal(LogRecord record) {
    if (record.loggerName != 'app') return false;
    if (record.message.startsWith('Flutter Layout Error:') || record.message.contains('RenderFlex overflowed by')) {
      return false;
    }
    return record.message.startsWith('Flutter Error:') || record.message.startsWith('PlatformDispatcherError:');
  }

  String _formatContextLine(LogRecord record) {
    final timestamp = record.time.toUtc().toIso8601String();
    final level = record.level.name.toUpperCase();
    final logger = SensitiveDataRedactor.redact(record.loggerName);
    final message = SensitiveDataRedactor.redact(record.message);
    return _truncate('$timestamp [$level] [$logger] $message', contextLineLengthLimit);
  }

  ({int slot, String line})? _addContextLine(String line) {
    if (!_collectContext) return null;
    final safeLine = _truncate(SensitiveDataRedactor.redact(line), contextLineLengthLimit);
    if (_context.isNotEmpty && _context.last == safeLine) return null;
    final slot = _nextContextSlot;
    _nextContextSlot = (_nextContextSlot + 1) % contextRecordLimit;
    _context.addLast(safeLine);
    while (_context.length > contextRecordLimit) {
      _context.removeFirst();
    }
    return (slot: slot, line: safeLine);
  }

  Future<void> _seedNativeContext(CrashReportingBackend backend) async {
    final lines = _context.toList(growable: false);
    final firstSlot = lines.length == contextRecordLimit ? _nextContextSlot : 0;
    for (var index = 0; index < lines.length; index++) {
      final slot = (firstSlot + index) % contextRecordLimit;
      await backend.setCustomKey(_contextSlotKey(slot), lines[index]);
      await backend.log(lines[index]);
    }
  }

  Future<void> _writeNativeContextUpdate(CrashReportingBackend backend, ({int slot, String line}) update) async {
    await backend.setCustomKey(_contextSlotKey(update.slot), update.line);
    await backend.log(update.line);
  }

  String _contextSlotKey(int slot) => 'context_${slot.toString().padLeft(2, '0')}';

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _deliveryTail.then((_) => _guarded(operation));
    _deliveryTail = result;
    return result;
  }

  Future<void> _guarded(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {
      // Remote diagnostics must never become an app failure or affect VPN state.
    }
  }

  String _truncate(String value, int maxLength) {
    if (value.length <= maxLength) return value;
    return '${value.substring(0, maxLength - 1)}…';
  }
}
