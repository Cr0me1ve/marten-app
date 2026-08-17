import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/profile/data/subscription_content_adapter.dart';

Map<String, dynamic> _xrayProfile(int index, String remarks, bool keepRemark) {
  final vlessTag = 'vless-$index';
  final singleTag = 'single-$index';

  return {
    if (keepRemark) 'remarks': remarks,
    'inbounds': [
      {'tag': 'incoming-$index', 'protocol': 'dokodemo-door'},
      {'tag': 'loopback-$index', 'protocol': 'loopback'},
      {'tag': 'service-$index', 'protocol': 'service'},
    ],
    'outbounds': [
      {
        'protocol': 'vless',
        'tag': vlessTag,
        'settings': {
          'vnext': [
            {
              'address': '203.0.113.${10 + index}',
              'port': 443,
              'users': [
                {'id': '00000000-1111-2222-3333-444455556666', 'encryption': 'none'},
              ],
            },
          ],
        },
      },
      {
        'protocol': 'vless',
        'tag': singleTag,
        'settings': {
          'vnext': [
            {
              'address': '203.0.113.${20 + index}',
              'port': 443,
              'users': [
                {'id': '11111111-2222-3333-4444-555566667777', 'encryption': 'none'},
              ],
            },
          ],
        },
      },
      {'protocol': 'loopback', 'tag': 'loopback-out-$index'},
    ],
    'routing': {
      'rules': [
        {
          'type': 'field',
          'inboundTag': ['loopback-$index'],
          'outboundTag': vlessTag,
        },
        {'type': 'field', 'outboundTag': vlessTag},
      ],
      'balancers': [
        {
          'tag': 'lb-single-$index',
          'selector': [singleTag],
          'fallbackTag': 'auto',
        },
        {
          'tag': 'lb-multi-$index',
          'selector': ['missing', vlessTag, singleTag],
          'fallbackTag': 'missing',
        },
      ],
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SubscriptionContentAdapter.normalize', () {
    test('normalizes Xray arrays with deduplicated names and preserves order', () {
      final source = jsonEncode([_xrayProfile(0, 'Format-Test', true), _xrayProfile(1, 'Format-Test', true)]);

      final normalized = SubscriptionContentAdapter.normalize(source);
      final decoded = jsonDecode(normalized) as Map<String, dynamic>;
      final outbounds = decoded['outbounds'] as List<dynamic>;

      expect(outbounds, hasLength(2));
      expect((outbounds[0] as Map<String, dynamic>)['tag'], equals('Format-Test'));
      expect((outbounds[1] as Map<String, dynamic>)['tag'], equals('Format-Test (2)'));

      final second = outbounds[1] as Map<String, dynamic>;
      expect(second['type'], equals('xray'));
      final xconfig = second['xconfig'] as Map<String, dynamic>;
      expect(xconfig.containsKey('inbounds'), isFalse);
      expect(xconfig['routing']['rules'], hasLength(1));
      expect(xconfig['outbounds'], isA<List<dynamic>>());
      final outboundTags = (xconfig['outbounds'] as List<dynamic>)
          .map((item) => (item as Map<String, dynamic>)['tag'])
          .toSet();
      expect(outboundTags, containsAll(['vless-1', 'single-1']));
      expect(outboundTags, isNot(contains('loopback-out-1')));

      final balancers = (xconfig['routing']['balancers'] as List<dynamic>).cast<Map<String, dynamic>>();
      final byTag = {for (final balancer in balancers) balancer['tag'] as String: balancer['fallbackTag']};
      expect(byTag['lb-single-1'], equals('single-1'));
      expect(byTag['lb-multi-1'], equals('vless-1'));
    });

    test('uses derived remarks when source profile has no remarks', () {
      final source = jsonEncode([_xrayProfile(0, 'unused', false)]);
      final normalized = SubscriptionContentAdapter.normalize(source);
      final decoded = jsonDecode(normalized) as Map<String, dynamic>;

      expect((decoded['outbounds'] as List<dynamic>).single, isA<Map<String, dynamic>>());
      final outbound = (decoded['outbounds'] as List<dynamic>).single as Map<String, dynamic>;
      expect(outbound['tag'], equals('vless-0'));
    });
  });
}
