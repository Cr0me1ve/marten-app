import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('per-app apps lists are loaded lazily and the hidden-system result is cached', () {
    final source = File('lib/features/per_app_proxy/overview/per_app_proxy_page.dart').readAsStringSync();

    expect(source, contains('final allAppsFuture = useMemoized(() => getApps(false));'));
    expect(source, contains('final hiddenAppsFuture = useState<Future<Set<AppPackageInfo>>?>(null);'));
    expect(source, contains('final asyncAppsHideSys = useFuture(hiddenAppsFuture.value);'));
    expect(source, isNot(contains('useMemoized(() => getApps(true))')));

    final toggle = _bodyOf(source, 'onSelected: (value)');
    expect(toggle, contains('if (value && hiddenAppsFuture.value == null)'));
    expect(toggle, contains('hiddenAppsFuture.value = getApps(true);'));
    expect(
      toggle.indexOf('hiddenAppsFuture.value = getApps(true);'),
      lessThan(toggle.indexOf('hideSystemApps.value = value;')),
    );
  });
}

String _bodyOf(String source, String marker) {
  final start = source.indexOf(marker);
  expect(start, isNonNegative, reason: 'missing $marker');
  final openingBrace = source.indexOf('{', start);
  expect(openingBrace, isNonNegative, reason: 'missing callback body for $marker');

  var depth = 0;
  for (var index = openingBrace; index < source.length; index++) {
    switch (source[index]) {
      case '{':
        depth++;
      case '}':
        depth--;
        if (depth == 0) return source.substring(openingBrace, index + 1);
    }
  }
  fail('unterminated callback body for $marker');
}
