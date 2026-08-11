import 'dart:async';
import 'dart:io';

import 'package:marten/core/logger/log_file_retention.dart';
import 'package:marten/core/logger/sensitive_data_redactor.dart';

/// Serializes batched log writes away from the UI isolate's synchronous path.
class BufferedFileWriter {
  BufferedFileWriter(
    this.file, {
    this.flushInterval = const Duration(milliseconds: 250),
    this.maxBufferedCharacters = 32 * 1024,
  }) {
    LogFileRetention.ensureExistsSync(file);
    _writeChain = LogFileRetention.prune(file).catchError((_) {});
  }

  final File file;
  final Duration flushInterval;
  final int maxBufferedCharacters;

  final StringBuffer _buffer = StringBuffer();
  late Future<void> _writeChain;
  Timer? _flushTimer;
  DateTime? _latestTimestamp;
  DateTime? _lastPruneAt;
  bool _closed = false;

  void add(String content, {DateTime? timestamp}) {
    if (_closed || content.isEmpty) return;
    _buffer.write(content);
    _latestTimestamp = timestamp ?? DateTime.now();
    if (_buffer.length >= maxBufferedCharacters) {
      _enqueueFlush();
      return;
    }
    _flushTimer ??= Timer(flushInterval, _enqueueFlush);
  }

  Future<void> flush() async {
    _enqueueFlush();
    await _writeChain;
  }

  /// Runs [operation] after every pending write and keeps later writes queued
  /// behind it. This is used for snapshots and other file operations that
  /// must not race with the buffered writer.
  Future<T> runSynchronized<T>(Future<T> Function() operation) {
    if (_closed) {
      return Future<T>.error(StateError('BufferedFileWriter is closed'));
    }

    _enqueueFlush();
    final result = Completer<T>();
    _writeChain = _writeChain.onError((_, _) {}).then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<void> clear() async {
    if (_closed) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    _buffer.clear();
    _writeChain = _writeChain.onError((_, _) {}).then((_) async {
      await file.writeAsString('', flush: true);
    });
    await _writeChain;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    _enqueueFlush();
    await _writeChain;
  }

  void _enqueueFlush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_buffer.isEmpty) return;

    // Redact the complete batch at the persistence boundary as a second line
    // of defence, including values reconstructed across adjacent chunks.
    final content = SensitiveDataRedactor.redact(_buffer.toString());
    final timestamp = _latestTimestamp ?? DateTime.now();
    _buffer.clear();
    _writeChain = _writeChain.onError((_, _) {}).then((_) async {
      await file.writeAsString(content, mode: FileMode.append);
      final lastPruneAt = _lastPruneAt;
      if (lastPruneAt == null || timestamp.difference(lastPruneAt) >= const Duration(minutes: 1)) {
        _lastPruneAt = timestamp;
        await LogFileRetention.prune(file, now: timestamp);
      }
    });
  }
}
