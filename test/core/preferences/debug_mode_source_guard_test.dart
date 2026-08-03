import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DebugModeNotifier applies the effective runtime level before persisting', () {
    final source = File('lib/core/preferences/general_preferences.dart').readAsStringSync();
    final updateStart = source.indexOf('Future<void> update(bool value)');
    final updateEnd = source.indexOf('\n  }\n}', updateStart);
    expect(updateStart, isNonNegative, reason: 'could not find DebugModeNotifier.update');
    expect(updateEnd, isNonNegative, reason: 'could not find end of DebugModeNotifier.update');
    final update = source.substring(updateStart, updateEnd);

    const apply = 'LoggerController.applyDebugMode(value || kDebugMode);';
    const persist = 'return _pref.write(value);';
    expect(update, contains(apply));
    expect(update, contains(persist));
    expect(update.indexOf(apply), lessThan(update.indexOf(persist)));
  });
}
