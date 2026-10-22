import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/analytics/crash_diagnostics.dart';

void main() {
  const channel = MethodChannel('app.marten.client/platform');

  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('assembles native snapshot, reporter scope, and current local phase', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'get_crash_diagnostics');
      return 'MARTEN_CRASH_DIAGNOSTICS schema=1 collection=enabled history_status=available count=0';
    });
    await CrashDiagnostics.notePhase('export_test_phase');

    final snapshot = await CrashDiagnostics.snapshot(isAndroid: true);

    expect(snapshot, contains('MARTEN_CRASH_DIAGNOSTICS schema=1'));
    expect(snapshot, contains('MARTEN_FLUTTER_REPORTING'));
    expect(snapshot, contains('delivery_scope=sdk_acceptance'));
    expect(snapshot, contains('server_receipt=unknown'));
    expect(snapshot, contains('MARTEN_REPORTING_ATTEMPT phase=export_test_phase'));
    expect(snapshot, contains('timestamp_ms='));
  });

  test('uses privacy-safe fallback when native snapshot is unavailable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      throw PlatformException(code: 'unavailable', message: 'secret.example.com token=private-token');
    });

    final snapshot = await CrashDiagnostics.snapshot(isAndroid: true);

    expect(snapshot, contains('MARTEN_CRASH_DIAGNOSTICS schema=1 history_status=unavailable'));
    expect(snapshot, contains('MARTEN_FLUTTER_REPORTING'));
    expect(snapshot, isNot(contains('secret.example.com')));
    expect(snapshot, isNot(contains('private-token')));
  });

  test('returns no native diagnostics for other platforms', () async {
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      invoked = true;
      return 'should not be read';
    });

    expect(await CrashDiagnostics.snapshot(isAndroid: false), isEmpty);
    expect(invoked, isFalse);
  });
}
