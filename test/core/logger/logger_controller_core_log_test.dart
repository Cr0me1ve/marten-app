import 'package:flutter_test/flutter_test.dart';
import 'package:loggy/loggy.dart';
import 'package:marten/core/logger/logger_controller.dart';

class _CapturingPrinter extends LoggyPrinter {
  final records = <LogRecord>[];

  @override
  void onLog(LogRecord record) => records.add(record);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('debug core logs are forwarded in debug build', () {
    expect(shouldForwardCoreLogToDiagnosticPrinters(LogLevel.debug, debugBuild: true), isTrue);
    expect(shouldForwardCoreLogToDiagnosticPrinters(LogLevel.info, debugBuild: true), isTrue);
    expect(shouldForwardCoreLogToDiagnosticPrinters(LogLevel.warning, debugBuild: true), isTrue);
    expect(shouldForwardCoreLogToDiagnosticPrinters(LogLevel.error, debugBuild: true), isTrue);
  });

  test('release build forwards only warning and error core logs', () {
    expect(shouldForwardCoreLogToDiagnosticPrinters(LogLevel.debug, debugBuild: false), isFalse);
    expect(shouldForwardCoreLogToDiagnosticPrinters(LogLevel.info, debugBuild: false), isFalse);
    expect(shouldForwardCoreLogToDiagnosticPrinters(LogLevel.warning, debugBuild: false), isTrue);
    expect(shouldForwardCoreLogToDiagnosticPrinters(LogLevel.error, debugBuild: false), isTrue);
  });

  test('onCoreLog forwards to console and non-app diagnostic printers', () {
    final console = _CapturingPrinter();
    final appLog = _CapturingPrinter();
    final diagnostic = _CapturingPrinter();
    final controller = LoggerController(console, {
      'app': appLog,
      'diagnostic': diagnostic,
    });

    controller.onCoreLog(
      LogRecord(
        LogLevel.warning,
        'core warning should be visible to diagnostics',
        'test',
      ),
    );

    expect(console.records, hasLength(1));
    expect(console.records.single.message, 'core warning should be visible to diagnostics');
    expect(appLog.records, isEmpty);
    expect(diagnostic.records, hasLength(1));
    expect(diagnostic.records.single.message, 'core warning should be visible to diagnostics');
  });
}
