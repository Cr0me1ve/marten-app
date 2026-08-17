import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:marten/utils/date_time_formatter.dart';

void main() {
  late String? defaultLocale;

  setUp(() {
    defaultLocale = Intl.defaultLocale;
    Intl.defaultLocale = 'en_US';
  });

  tearDown(() {
    Intl.defaultLocale = defaultLocale;
  });

  test('formatSubscriptionUpdate outputs only time when same local date', () {
    final now = DateTime(2026, 8, 15, 17, 41);
    final updated = DateTime(2026, 8, 15, 9, 18);

    final value = updated.formatSubscriptionUpdate(now: now);
    expect(value, matches(RegExp(r'^\d{1,2}:\d{2}$')));
    expect(value, isNot(contains('2026')));
  });

  test('formatSubscriptionUpdate outputs day/month/time without year when date differs from now', () {
    final now = DateTime(2026, 8, 15, 17, 41);
    final updated = DateTime(2026, 8, 14, 9, 18);
    final expected = DateFormat.MMMd().format(updated);
    final value = updated.formatSubscriptionUpdate(now: now);
    final expectedRegex = RegExp(r'^[A-Za-z]{3}\s+\d{1,2},?\s+\d{1,2}:\d{2}$');

    expect(value, matches(expectedRegex));
    expect(value, isNot(contains('2026')));
    expect(value, startsWith(expected));
  });

  test('formatSubscriptionUpdate works for fixed local input in UTC-equivalent cases', () {
    final now = DateTime.utc(2026, 8, 15, 17, 41).toLocal();
    final updated = DateTime.utc(2026, 8, 14, 9, 18).toLocal();
    final value = updated.formatSubscriptionUpdate(now: now);

    expect(value, isNot(contains('2026')));
    expect(value, isNotEmpty);
  });
}
