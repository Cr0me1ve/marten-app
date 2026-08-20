import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppProxyDao.getActivePackages reads active app packages without installed-app scan', () {
    final source = File('lib/features/per_app_proxy/data/app_proxy_data_source.dart').readAsStringSync();
    final getActivePackages = _extractFunctionBody(
      source,
      'Future<List<String>> getActivePackages({required AppProxyMode mode})',
    );

    expect(getActivePackages.contains('isForceDeselectionSet'), isTrue);
    expect(getActivePackages, isNot(contains('InstalledApps')));
    expect(
      getActivePackages.contains('query.where(appProxyEntries.mode.equalsValue(mode) & isForceDeselectionSet.not())'),
      isTrue,
    );
    expect(getActivePackages, isNot(contains('phonePkgs')));
  });

  test('Per-app notifier syncs native package lists after each mutation', () {
    final source = File('lib/features/per_app_proxy/overview/per_app_proxy_notifier.dart').readAsStringSync();
    final update = _extractFunctionBody(source, 'Future<void> updatePkg(String pkg)');
    expect(update.indexOf('updatePkg(pkg: pkg, mode: _mode!)'), greaterThan(-1));
    expect(update.indexOf('syncNativeSelection()'), greaterThan(update.indexOf('updatePkg(pkg: pkg, mode: _mode!)')));

    final apply = _extractFunctionBody(source, 'Future<bool> applyAutoSelection()');
    final applyMutation = apply.indexOf('applyAutoSelection(autoList: autoList, mode: _mode!);');
    final applySync = apply.indexOf('syncNativeSelection()');
    expect(applyMutation, greaterThan(-1));
    expect(applySync, greaterThan(applyMutation));
    expect(apply.indexOf('autoAppsSelectionLastUpdate.notifier'), greaterThan(applySync));

    final clearAll = _extractFunctionBody(source, 'Future<void> clearAll()');
    expect(clearAll.indexOf('ref.read(appProxyDataSourceProvider).clearAll(mode: _mode!);'), greaterThan(-1));
    expect(
      clearAll.indexOf('syncNativeSelection()'),
      greaterThan(clearAll.indexOf('ref.read(appProxyDataSourceProvider).clearAll(mode: _mode!);')),
    );

    final revert = _extractFunctionBody(source, 'Future<void> revertForceDeselection()');
    expect(revert.indexOf('revertForceDeselection(mode: _mode!)'), greaterThan(-1));
    expect(
      revert.indexOf('syncNativeSelection()'),
      greaterThan(revert.indexOf('revertForceDeselection(mode: _mode!)')),
    );

    final clearAuto = _extractFunctionBody(source, 'Future<void> clearAutoSelected()');
    expect(clearAuto.indexOf('clearAutoSelected(mode: _mode!)'), greaterThan(-1));
    expect(
      clearAuto.indexOf('syncNativeSelection()'),
      greaterThan(clearAuto.indexOf('clearAutoSelected(mode: _mode!)')),
    );
  });

  test('import path syncs both include and exclude native lists', () {
    final source = File('lib/features/per_app_proxy/overview/per_app_proxy_notifier.dart').readAsStringSync();
    final import = _extractFunctionBody(source, 'Future<bool> importClipboard()');
    expect(import.indexOf('_importJson('), greaterThan(-1));
    final imported = _extractFunctionBody(source, 'Future<void> _importJson(String input)');
    expect(
      imported.indexOf('_syncAllNativeSelections()'),
      greaterThan(imported.indexOf('importPkgs(backup: backup);')),
    );

    final syncAll = _extractFunctionBody(source, 'Future<void> _syncAllNativeSelections()');
    expect(
      syncAll.indexOf('includePackages = await dataSource.getActivePackages(mode: AppProxyMode.include);'),
      greaterThan(-1),
    );
    expect(
      syncAll.indexOf('excludePackages = await dataSource.getActivePackages(mode: AppProxyMode.exclude);'),
      greaterThan(-1),
    );
    expect(syncAll.indexOf('includePackages'), greaterThan(0));
    expect(syncAll.indexOf('excludePackages'), greaterThan(syncAll.indexOf('includePackages')));
    expect(
      syncAll.indexOf('ref.read(Preferences.includeApps.notifier).update(includePackages),'),
      greaterThan(syncAll.indexOf('excludePackages')),
    );
    expect(
      syncAll.indexOf('ref.read(Preferences.excludeApps.notifier).update(excludePackages),'),
      greaterThan(syncAll.indexOf('ref.read(Preferences.includeApps.notifier).update(includePackages),')),
    );
  });

  test('mode switch synchronizes the selected mode before persisting preference', () {
    final source = File('lib/features/per_app_proxy/overview/per_app_proxy_page.dart').readAsStringSync();
    final switchMode = _extractCallbackBody(source, 'onSelected: (e) async {');

    final sync = switchMode.indexOf('syncNativeSelection();');
    final updateMode = switchMode.indexOf('Preferences.perAppProxyMode.notifier).update(e);');

    expect(sync, greaterThan(-1));
    expect(updateMode, greaterThan(-1));
    expect(sync, lessThan(updateMode));
  });
}

String _extractFunctionBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1));
  var openBrace = source.indexOf('{', start + signature.length);
  final semicolon = source.indexOf(';', start + signature.length);
  if (openBrace != -1 && semicolon != -1 && semicolon < openBrace) {
    final nextStart = source.indexOf(signature, start + signature.length);
    expect(nextStart, isNot(-1));
    return _extractFunctionBody(source.substring(nextStart), signature);
  }
  expect(openBrace, isNot(-1));

  var depth = 0;
  for (var index = openBrace; index < source.length; index++) {
    if (source[index] == '{') {
      depth++;
    } else if (source[index] == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(openBrace, index + 1);
      }
    }
  }

  fail('unclosed function body for `$signature`');
}

String _extractCallbackBody(String source, String marker) {
  final start = source.indexOf(marker);
  expect(start, isNot(-1));
  final openBrace = source.indexOf('{', start);
  expect(openBrace, isNot(-1));

  var depth = 0;
  for (var index = openBrace; index < source.length; index++) {
    if (source[index] == '{') {
      depth++;
    } else if (source[index] == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(openBrace, index + 1);
      }
    }
  }

  fail('unclosed callback body for `$marker`');
}
