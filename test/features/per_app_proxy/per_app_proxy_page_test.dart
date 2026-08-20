import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('split tunneling localization strings are explicit for en and ru source locales', () {
    final en = _localeSource('en');
    final ru = _localeSource('ru');

    expect(_valueAt(en, const ['pages', 'settings', 'routing', 'perAppProxy', 'title']), equals('Split tunneling'));
    expect(
      _valueAt(ru, const ['pages', 'settings', 'routing', 'perAppProxy', 'title']),
      equals('Раздельное туннелирование'),
    );

    expect(_valueAt(en, const ['pages', 'settings', 'routing', 'perAppProxy', 'currentMode']), equals('Current mode'));
    expect(_valueAt(ru, const ['pages', 'settings', 'routing', 'perAppProxy', 'currentMode']), equals('Текущий режим'));

    expect(_valueAt(en, const ['pages', 'settings', 'routing', 'perAppProxy', 'modes', 'all']), equals('All apps'));
    expect(
      _valueAt(ru, const ['pages', 'settings', 'routing', 'perAppProxy', 'modes', 'all']),
      equals('Все приложения'),
    );
    expect(
      _valueAt(en, const ['pages', 'settings', 'routing', 'perAppProxy', 'modes', 'proxy']),
      equals('Selected apps only'),
    );
    expect(
      _valueAt(ru, const ['pages', 'settings', 'routing', 'perAppProxy', 'modes', 'proxy']),
      equals('Только выбранные'),
    );
    expect(
      _valueAt(en, const ['pages', 'settings', 'routing', 'perAppProxy', 'modes', 'bypass']),
      equals('All except selected'),
    );
    expect(
      _valueAt(ru, const ['pages', 'settings', 'routing', 'perAppProxy', 'modes', 'bypass']),
      equals('Кроме выбранных'),
    );

    expect(
      _valueAt(en, const ['pages', 'settings', 'routing', 'perAppProxy', 'modes', 'allMsg']),
      equals('All apps use the VPN.'),
    );
    expect(
      _valueAt(en, const ['pages', 'settings', 'routing', 'perAppProxy', 'modes', 'proxyMsg']),
      equals('Selected apps use the VPN. Other apps connect without a VPN.'),
    );
    expect(
      _valueAt(en, const ['pages', 'settings', 'routing', 'perAppProxy', 'modes', 'bypassMsg']),
      equals('Selected apps connect without a VPN. Other apps use the VPN.'),
    );
    expect(
      _valueAt(ru, const ['pages', 'settings', 'routing', 'perAppProxy', 'modes', 'allMsg']),
      equals('Все приложения используют VPN.'),
    );
    expect(
      _valueAt(ru, const ['pages', 'settings', 'routing', 'perAppProxy', 'modes', 'proxyMsg']),
      equals('Выбранные приложения используют VPN. Остальные подключаются без VPN.'),
    );
    expect(
      _valueAt(ru, const ['pages', 'settings', 'routing', 'perAppProxy', 'modes', 'bypassMsg']),
      equals('Выбранные приложения подключаются без VPN. Остальные используют VPN.'),
    );
  });

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

  test('per-app proxy page shows a visible current-mode summary', () {
    final source = File('lib/features/per_app_proxy/overview/per_app_proxy_page.dart').readAsStringSync();
    final bodySummary = _bodyBetween(source, 'body: Column(', 'child: displayedApps.when(');

    expect(
      bodySummary.contains('currentMode.present(t).title'),
      isTrue,
      reason: 'summary should expose current mode title',
    );
    expect(
      bodySummary.contains('currentMode.present(t).message'),
      isTrue,
      reason: 'current mode summary should include the persistent message in the body',
    );
  });

  test('settings split tunneling tile shows current mode as ListTile subtitle', () {
    final source = File('lib/features/settings/overview/settings_page.dart').readAsStringSync();
    final androidTile = _bodyBetween(
      source,
      'if (PlatformUtils.isAndroid)',
      'SettingsSection(\n              title: t.pages.settings.dns.title,',
    );

    expect(androidTile, contains('subtitle:'));
    expect(androidTile, contains('present(t).message'));
  });
}

Map<String, Object?> _localeSource(String locale) {
  final decoded = jsonDecode(File('assets/translations/$locale.i18n.json').readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    fail('locale source is not a valid map: $locale');
  }
  return decoded;
}

String _valueAt(Map<String, Object?> source, List<String> keys) {
  Object? cursor = source;
  for (final key in keys) {
    if (cursor is! Map<String, Object?>) {
      fail('path missing node $key');
    }
    cursor = cursor[key];
  }
  if (cursor is! String) {
    fail('path is not localized string: ${keys.join('.')}');
  }
  return cursor;
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

String _bodyBetween(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  expect(start, isNonNegative, reason: 'missing body start marker $startMarker');
  final end = source.indexOf(endMarker, start + startMarker.length);
  expect(end, isNonNegative, reason: 'missing body end marker $endMarker');
  return source.substring(start, end);
}
