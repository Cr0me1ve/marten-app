import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/analytics/analytics_controller.dart';
import 'package:marten/core/preferences/preferences_migration.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('returns true for a clean install without migration marker and analytics preference', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    expect(readCrashReportingEnabledPreference(preferences), isTrue);
  });

  test('returns true when analytics preference is missing but migration marker exists (upgrade path)', () async {
    SharedPreferences.setMockInitialValues({PreferencesMigration.versionKey: 7});
    final preferences = await SharedPreferences.getInstance();

    expect(readCrashReportingEnabledPreference(preferences), isTrue);
  });

  test('preserves explicitly saved false value even with migration marker', () async {
    SharedPreferences.setMockInitialValues({enableAnalyticsPrefKey: false, PreferencesMigration.versionKey: 7});
    final preferences = await SharedPreferences.getInstance();

    expect(readCrashReportingEnabledPreference(preferences), isFalse);
  });

  test('preserves explicitly saved true value even with migration marker', () async {
    SharedPreferences.setMockInitialValues({enableAnalyticsPrefKey: true, PreferencesMigration.versionKey: 7});
    final preferences = await SharedPreferences.getInstance();

    expect(readCrashReportingEnabledPreference(preferences), isTrue);
  });
}
