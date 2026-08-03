import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:loggy/loggy.dart';
import 'package:marten/core/logger/custom_logger.dart';
import 'package:marten/utils/custom_loggers.dart';

class LoggerController extends LoggyPrinter with InfraLogger {
  LoggerController(this.consolePrinter, this.otherPrinters);

  final LoggyPrinter consolePrinter;
  final Map<String, LoggyPrinter> otherPrinters;

  static LoggerController get instance => _instance;

  static late LoggerController _instance;

  static void preInit() {
    Loggy.initLoggy(logPrinter: const ConsolePrinter());
  }

  static void init(String appLogPath, {bool debugConsole = true}) {
    _instance = LoggerController(ConsolePrinter(minLevel: debugConsole ? LogLevel.debug : LogLevel.info), {
      "app": kIsWeb ? const ConsolePrinter() : FileLogPrinter(appLogPath),
    });
    Loggy.initLoggy(logPrinter: _instance);
  }

  static Future<void> postInit(bool debugMode) async {
    if (kIsWeb) await _instance.removePrinter("app");
    applyDebugMode(debugMode);
  }

  static void applyDebugMode(bool debugMode) {
    final logLevel = debugMode ? LogLevel.debug : LogLevel.info;
    Loggy.initLoggy(logPrinter: _instance, logOptions: LogOptions(logLevel));
  }

  void addPrinter(String name, LoggyPrinter printer) {
    loggy.debug("adding [$name] printer");
    otherPrinters.putIfAbsent(name, () => printer);
  }

  Future<void> removePrinter(String name) async {
    loggy.debug("removing [$name] printer");
    final printer = otherPrinters[name];
    if (printer case FileLogPrinter()) {
      await printer.dispose();
    }
    otherPrinters.remove(name);
  }

  @override
  void onLog(LogRecord record) {
    consolePrinter.onLog(record);
    for (final printer in otherPrinters.values) {
      printer.onLog(record);
    }
  }
}
