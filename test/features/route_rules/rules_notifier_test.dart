import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/route_rules/notifier/rules_notifier.dart';
import 'package:marten/martencore/generated/v2/config/route_rule.pb.dart';

void main() {
  group('route rules JSON', () {
    final rules = RouteRule(
      rules: [Rule(name: 'Direct docs', outbound: Outbound.direct, enabled: true, listOrder: 0)],
    );

    test('parses raw protobuf JSON exported by the app', () {
      final parsed = parseRouteRulesJson(rules.writeToJson());

      expect(parsed.rules.single.name, 'Direct docs');
    });

    test('keeps compatibility with the old double-encoded clipboard format', () {
      final parsed = parseRouteRulesJson(jsonEncode(rules.writeToJson()));

      expect(parsed.rules.single.outbound, Outbound.direct);
    });

    test('rejects invalid and oversized imports', () {
      expect(() => parseRouteRulesJson('{"1":[{"3":""}]}'), throwsFormatException);
      expect(() => parseRouteRulesJson(''.padRight(maxRouteRulesImportBytes + 1)), throwsFormatException);
    });

    test('normalizes imported order and fills the legacy enabled default', () {
      final normalized = normalizeImportedRouteRules([
        Rule(name: 'First', outbound: Outbound.direct, listOrder: 9),
        Rule(name: 'Second', outbound: Outbound.block, listOrder: 9, enabled: false),
      ]);

      expect(normalized.map((rule) => rule.listOrder), [0, 1]);
      expect(normalized.map((rule) => rule.enabled), [true, false]);
    });
  });
}
