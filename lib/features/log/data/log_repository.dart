import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:marten/core/logger/log_file_retention.dart';
import 'package:marten/core/utils/exception_handler.dart';
import 'package:marten/features/log/data/log_parser.dart';
import 'package:marten/features/log/data/log_path_resolver.dart';
import 'package:marten/features/log/model/log_entity.dart';
import 'package:marten/features/log/model/log_failure.dart';
import 'package:marten/martencore/marten_core_service.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:rxdart/rxdart.dart';

abstract interface class LogRepository {
  TaskEither<LogFailure, Unit> init();
  Stream<Either<LogFailure, List<LogEntity>>> watchLogs();
  TaskEither<LogFailure, Unit> clearLogs();
}

class LogRepositoryImpl with ExceptionHandler, InfraLogger implements LogRepository {
  LogRepositoryImpl({required this.singbox, required this.logPathResolver});

  static const _visibleLogLimit = 1000;
  static const _tailReadChunkBytes = 128 * 1024;
  static const _tailMaxReadBytes = 8 * 1024 * 1024;
  static const _persistedCacheRefreshInterval = Duration(seconds: 2);

  final MartenCoreService singbox;
  final LogPathResolver logPathResolver;
  List<LogEntity>? _persistedCache;
  DateTime? _persistedCacheAt;
  Future<List<LogEntity>>? _persistedReadFuture;

  @override
  TaskEither<LogFailure, Unit> init() {
    return exceptionHandler(() async {
      if (!kIsWeb) {
        if (!await logPathResolver.directory.exists()) {
          await logPathResolver.directory.create(recursive: true);
        }
        await Future.wait([
          LogFileRetention.ensureExists(logPathResolver.coreFile()),
          LogFileRetention.ensureExists(logPathResolver.appFile()),
        ]);
        unawaited(
          logPathResolver.deleteUnsafeRawFiles().onError((error, stackTrace) {
            loggy.warning("failed to remove legacy raw log files", error, stackTrace);
          }),
        );
        // Both destinations are owned by BufferedFileWriter instances, which
        // prune in their serialized background write chains. Waiting for the
        // same retention scan here delayed the home screen and scanned each
        // file twice during every cold launch.
        singbox.setCoreLogFilePath(logPathResolver.coreFile().path);
      }
      return right(unit);
    }, LogUnexpectedFailure.new);
  }

  @override
  Stream<Either<LogFailure, List<LogEntity>>> watchLogs() {
    final initialLogs = Stream.fromFuture(_readPersistedLogs(force: true));
    final liveLogs = singbox.watchLogs(logPathResolver.coreFile().path).asyncMap((event) async {
      final persisted = await _readPersistedLogs();
      final live = event.map(LogParser.parseLogProto).toList();
      return _mergeLogs(persisted, live);
    });
    return Rx.concat<List<LogEntity>>([initialLogs, liveLogs]).handleExceptions((error, stackTrace) {
      loggy.warning("error watching logs", error, stackTrace);
      return LogFailure.unexpected(error, stackTrace);
    });
  }

  @override
  TaskEither<LogFailure, Unit> clearLogs() {
    return exceptionHandler(() async {
      final result = await singbox.clearLogs().mapLeft(LogFailure.unexpected).run();
      if (!kIsWeb) {
        await logPathResolver.coreFile().writeAsString('', flush: true);
        await logPathResolver.appFile().writeAsString('', flush: true);
      }
      _persistedCache = const [];
      _persistedCacheAt = DateTime.now();
      _persistedReadFuture = null;
      return result;
    }, LogFailure.unexpected);
  }

  Future<List<LogEntity>> _readPersistedLogs({bool force = false}) async {
    if (kIsWeb) return [];
    final now = DateTime.now();
    final cached = _persistedCache;
    final cachedAt = _persistedCacheAt;
    if (!force && cached != null && cachedAt != null && now.difference(cachedAt) < _persistedCacheRefreshInterval) {
      return cached;
    }

    final runningRead = _persistedReadFuture;
    if (!force && runningRead != null) return runningRead;

    final future = _readPersistedLogsUncached();
    _persistedReadFuture = future;
    try {
      final logs = await future;
      _persistedCache = logs;
      _persistedCacheAt = DateTime.now();
      return logs;
    } finally {
      if (identical(_persistedReadFuture, future)) {
        _persistedReadFuture = null;
      }
    }
  }

  Future<List<LogEntity>> _readPersistedLogsUncached() async {
    final logs = <LogEntity>[];
    logs.addAll(await _readPersistedFile(logPathResolver.coreFile(), createIfMissing: true));
    logs.addAll(await _readPersistedFile(logPathResolver.appFile(), createIfMissing: true));
    return _mergeLogs(logs, const []);
  }

  Future<List<LogEntity>> _readPersistedFile(File file, {bool rawCore = false, bool createIfMissing = false}) async {
    if (!await file.exists()) {
      if (createIfMissing) {
        await file.create(recursive: true);
      }
      return [];
    }
    final tail = await _readLogTail(file);
    if (rawCore) {
      return _readRawCoreEntries(tail.content);
    }
    final entries = LogFileRetention.entries(tail.content);
    final completeEntries = tail.truncated && entries.length > 1 ? entries.skip(1).toList(growable: false) : entries;
    final recentEntries = completeEntries.length > _visibleLogLimit
        ? completeEntries.skip(completeEntries.length - _visibleLogLimit)
        : completeEntries;
    return recentEntries.map(LogParser.parsePersistedEntry).toList();
  }

  List<LogEntity> _readRawCoreEntries(String content) {
    final lines = content
        .replaceAll('\u0000', '')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final recentLines = lines.length > _visibleLogLimit ? lines.skip(lines.length - _visibleLogLimit) : lines;
    return recentLines.map(LogParser.parseRawCoreLine).toList();
  }

  List<LogEntity> _mergeLogs(List<LogEntity> persisted, List<LogEntity> live) {
    final merged = <String, LogEntity>{};
    for (final log in [...persisted, ...live]) {
      merged['${log.time?.toIso8601String()}|${log.level?.name}|${log.message}'] = log;
    }
    final logs = merged.values.toList();
    logs.sort((a, b) {
      final aTime = a.time;
      final bTime = b.time;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return -1;
      if (bTime == null) return 1;
      return aTime.compareTo(bTime);
    });
    final retained = LogFileRetention.retainItems<LogEntity>(
      logs,
      timestampOf: (log) => log.time,
      levelOf: (log) => log.level?.name,
    );
    if (retained.length <= _visibleLogLimit) return retained;
    return retained.sublist(retained.length - _visibleLogLimit);
  }

  Future<({String content, bool truncated})> _readLogTail(File file) async {
    final length = await file.length();
    if (length == 0) return (content: '', truncated: false);

    var bytesToRead = math.min(length, _tailReadChunkBytes);
    while (true) {
      final start = length - bytesToRead;
      final raf = await file.open();
      try {
        await raf.setPosition(start);
        final bytes = await raf.read(bytesToRead);
        final content = utf8.decode(bytes, allowMalformed: true);
        final enoughEntries = LogFileRetention.entries(content).length > _visibleLogLimit;
        if (start == 0 || enoughEntries || bytesToRead >= _tailMaxReadBytes) {
          return (content: content, truncated: start > 0);
        }
      } finally {
        await raf.close();
      }
      bytesToRead = math.min(length, bytesToRead * 2);
    }
  }
}
