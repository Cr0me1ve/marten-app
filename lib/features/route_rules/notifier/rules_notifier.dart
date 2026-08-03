import 'dart:convert';
import 'dart:io';

import 'package:dartx/dartx_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:marten/core/directories/directories_provider.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/notification/in_app_notification_controller.dart';
import 'package:marten/martencore/generated/v2/config/route_rule.pb.dart';
import 'package:marten/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'rules_notifier.g.dart';

const maxRouteRulesImportBytes = 1024 * 1024;

@riverpod
class RulesNotifier extends _$RulesNotifier with AppLogger {
  late File file;

  @override
  List<Rule> build() {
    final directories = ref.watch(appDirectoriesProvider).requireValue;
    file = File('${directories.baseDir.path}/route_rule.proto');
    if (file.existsSync()) {
      return List.unmodifiable(_copyRules(RouteRule.fromBuffer(file.readAsBytesSync()).rules));
    } else {
      return const <Rule>[];
    }
  }

  Future<void> addRule(Rule rule) async {
    if (!isValidRouteRule(rule)) throw ArgumentError.value(rule, 'rule', 'name and outbound are required');
    final current = _copyRules(state);
    final next = _copyRule(rule)
      ..listOrder = current.length
      ..enabled = true;
    await _persist([...current, next]);
  }

  Future<bool> updateRule(Rule rule) async {
    if (!isValidRouteRule(rule) || !rule.hasListOrder() || !rule.hasEnabled()) {
      throw ArgumentError.value(rule, 'rule', 'complete persisted rule is required');
    }
    final current = _copyRules(state);
    final index = current.indexWhere((element) => element.listOrder == rule.listOrder);
    if (index == -1) return false;
    current[index] = _copyRule(rule);
    await _persist(current);
    return true;
  }

  Future<void> deleteRule(int listOrder) async {
    final current = state;
    await _persist(_updateListOrder(current.where((element) => element.listOrder != listOrder).toList()));
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final current = _copyRules(state);
    final rule = current.removeAt(oldIndex);
    current.insert(oldIndex < newIndex ? newIndex - 1 : newIndex, rule);
    await _persist(_updateListOrder(current));
  }

  Future<void> updateEnabled(bool enabled, int listOrder) async {
    final current = _copyRules(state);
    final index = current.indexWhere((rule) => rule.listOrder == listOrder);
    if (index == -1) return;
    current[index].enabled = enabled;
    await _persist(current);
  }

  //export Clipboard
  Future<bool> exportJsonToClipboard() async {
    final t = ref.read(translationsProvider).requireValue;
    try {
      final routeRules = RouteRule(rules: state);
      await Clipboard.setData(ClipboardData(text: routeRules.writeToJson()));
      ref.read(inAppNotificationControllerProvider).showSuccessToast(t.common.msg.export.clipboard.success);
      return true;
    } on PlatformException {
      ref
          .read(inAppNotificationControllerProvider)
          .showInfoToast(t.common.msg.export.clipboard.contentTooLarge, duration: const Duration(seconds: 5));
      return false;
    } catch (e, st) {
      loggy.warning("error exporting route rules to clipboard", e, st);
      ref.read(inAppNotificationControllerProvider).showErrorToast(t.common.msg.export.clipboard.failure);
      return false;
    }
  }

  //import Clipboard
  Future<bool> importRulesFromClipboard() async {
    final t = ref.read(translationsProvider).requireValue;
    try {
      final input = await Clipboard.getData(Clipboard.kTextPlain).then((value) => value?.text);
      if (input == null) return false;
      final routeRules = parseRouteRulesJson(input);
      await _persist(normalizeImportedRouteRules(routeRules.rules));
      ref.read(inAppNotificationControllerProvider).showSuccessToast(t.common.msg.import.success);
      return true;
    } catch (e, st) {
      loggy.warning("error importing route rules from clipboard", e, st);
      ref.read(inAppNotificationControllerProvider).showErrorToast(t.common.msg.import.failure);
      return false;
    }
  }

  //export JSON
  Future<bool> saveRulesAsJsonFile() async {
    final t = ref.read(translationsProvider).requireValue;
    try {
      final bytes = utf8.encode(RouteRule(rules: state).writeToJson());
      final outputFile = await FilePicker.platform.saveFile(
        fileName: 'route_rules.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (outputFile == null) return false;
      if (PlatformUtils.isDesktop) {
        final file = File(outputFile);
        if (file.extension != '.json') return false;
        if (!await file.exists()) await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      }
      ref.read(inAppNotificationControllerProvider).showSuccessToast(t.common.msg.export.file.success);
      return true;
    } catch (e, st) {
      loggy.warning("error exporting route rules to json file", e, st);
      ref.read(inAppNotificationControllerProvider).showErrorToast(t.common.msg.export.file.failure);
      return false;
    }
  }

  //import JSON
  Future<bool> importRulesFromJsonFile() async {
    final t = ref.read(translationsProvider).requireValue;
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
      if (result == null) return false;
      final file = File(result.files.single.path!);
      if (!await file.exists()) return false;
      final bytes = await file.readAsBytes();
      if (bytes.length > maxRouteRulesImportBytes) throw const FormatException('route rules file is too large');
      final routeRules = parseRouteRulesJson(utf8.decode(bytes));
      await _persist(normalizeImportedRouteRules(routeRules.rules));
      ref.read(inAppNotificationControllerProvider).showSuccessToast(t.common.msg.import.success);
      return true;
    } catch (e, st) {
      loggy.warning("error importing route rules from json file", e, st);
      ref.read(inAppNotificationControllerProvider).showErrorToast(t.common.msg.import.failure);
      return false;
    }
  }

  Future<void> resetRules() async {
    if (await file.exists()) {
      await file.delete(recursive: true);
    }
    state = const <Rule>[];
  }

  Future<void> _persist(Iterable<Rule> rules) async {
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
    }
    final sortedRules = _copyRules(rules)..sort((a, b) => a.listOrder.compareTo(b.listOrder));
    final routeRules = RouteRule(rules: sortedRules);
    await file.writeAsBytes(routeRules.writeToBuffer(), flush: true);
    state = List.unmodifiable(sortedRules);
  }

  List<Rule> _updateListOrder(List<Rule> rules) {
    final updated = _copyRules(rules);
    for (var i = 0; i < updated.length; i++) {
      updated[i].listOrder = i;
    }
    return updated;
  }
}

bool isValidRouteRule(Rule rule) => rule.hasName() && rule.name.trim().isNotEmpty && rule.hasOutbound();

RouteRule parseRouteRulesJson(String input) {
  if (utf8.encode(input).length > maxRouteRulesImportBytes) {
    throw const FormatException('route rules input is too large');
  }
  final decoded = jsonDecode(input);
  final json = decoded is String ? decoded : input;
  final routeRules = RouteRule.fromJson(json);
  if (routeRules.rules.any((rule) => !isValidRouteRule(rule))) {
    throw const FormatException('route rules contain an invalid rule');
  }
  return routeRules;
}

List<Rule> normalizeImportedRouteRules(Iterable<Rule> rules) {
  final normalized = _copyRules(rules);
  for (var index = 0; index < normalized.length; index++) {
    normalized[index].listOrder = index;
    if (!normalized[index].hasEnabled()) normalized[index].enabled = true;
  }
  return normalized;
}

Rule _copyRule(Rule rule) => Rule.fromBuffer(rule.writeToBuffer());

List<Rule> _copyRules(Iterable<Rule> rules) => rules.map(_copyRule).toList(growable: true);
