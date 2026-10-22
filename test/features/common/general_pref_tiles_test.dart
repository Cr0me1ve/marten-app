import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _enableAnalyticsTile(String source) {
  const start = 'class EnableAnalyticsPrefTile';
  const end = '\nclass ThemeModePrefTile';
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex);
  expect(startIndex, isNonNegative, reason: 'EnableAnalyticsPrefTile is missing');
  expect(endIndex, isNonNegative, reason: 'ThemeModePrefTile marker is missing');
  return source.substring(startIndex, endIndex);
}

void main() {
  test('EnableAnalyticsPrefTile is inert while its async preference is loading or failed', () {
    final tile = _enableAnalyticsTile(File('lib/features/common/general_pref_tiles.dart').readAsStringSync());

    expect(tile, isNot(contains('analyticsControllerProvider).requireValue')));
    expect(tile, contains('analytics.when('));
    expect(tile, contains('loading:'));
    expect(tile, contains('error:'));
    expect(tile, contains('value: enabled'));

    // Loading/error states must render an off switch and must not expose an
    // action until the preference has a concrete value.
    final loadingStart = tile.indexOf('loading:');
    final errorStart = tile.indexOf('error:', loadingStart);
    expect(loadingStart, isNonNegative);
    expect(errorStart, greaterThan(loadingStart));
    final loading = tile.substring(loadingStart, errorStart);
    final error = tile.substring(errorStart);
    expect(loading, contains('enabled: false'));
    expect(loading, contains('change: null'));
    expect(error, contains('enabled: false'));
    expect(error, contains('change: null'));
  });
}
