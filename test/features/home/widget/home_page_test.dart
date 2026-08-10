import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('connected reconciliation persists a changed selected tag without a duplicate core select or route probe', () {
    final source = File('lib/features/home/widget/home_page.dart').readAsStringSync();
    final listenerStart = source.indexOf('ref.listen(connectionNotifierProvider');
    final scaffoldStart = source.indexOf('return Scaffold(', listenerStart);
    expect(listenerStart, isNonNegative);
    expect(scaffoldStart, greaterThan(listenerStart));
    final connectedListener = source.substring(listenerStart, scaffoldStart);

    expect(connectedListener, contains('rememberedTagFor(activeProfile.id, tags)'));
    expect(connectedListener, contains('if (remembered != tag)'));
    expect(connectedListener, contains('selectedProxyByProfileProvider.notifier).select('));
    expect(connectedListener, contains('completed\n      // the fresh route probe before Connected is published'));
    expect(connectedListener, isNot(contains('proxyRepositoryProvider')));
    expect(connectedListener, isNot(contains('.selectProxy(')));
    expect(connectedListener, isNot(contains('verifyConnectedRoute')));
  });
}
