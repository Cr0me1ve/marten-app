import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android Started acknowledgement is synchronous and fails closed', () async {
    final source = await File('lib/martencore/core_interface/core_interface_mobile.dart').readAsString();

    expect(source, contains('Future<bool> notifyBackgroundStarted() async'));
    expect(source, contains('invokeMethod<bool>("markStarted").timeout(_platformStartedSyncTimeout) ?? false'));
    expect(source, contains('platform started sync failed'));
    expect(source, contains('return false;'));
  });

  test('route verification rejects a false platform acknowledgement before UI promotion', () async {
    final source = await File('lib/features/connection/data/connection_repository.dart').readAsString();
    const acknowledgement = 'final platformAccepted = await singbox.notifyBackgroundStarted();';
    const reject = 'throw const ConnectionFailure.unexpected("Android VPN TUN did not become ready");';

    final acknowledgementOffset = source.indexOf(acknowledgement);
    final rejectOffset = source.indexOf(reject, acknowledgementOffset);
    final verifiedOffset = source.indexOf('verified = true;', acknowledgementOffset);
    final secondAcknowledgementOffset = source.indexOf(acknowledgement, acknowledgementOffset + acknowledgement.length);
    final secondRejectOffset = source.indexOf(reject, secondAcknowledgementOffset);
    final promotionOffset = source.indexOf('_setStartupRouteReady(true)', secondAcknowledgementOffset);

    expect(acknowledgementOffset, greaterThanOrEqualTo(0));
    expect(rejectOffset, greaterThan(acknowledgementOffset));
    expect(verifiedOffset, greaterThan(rejectOffset));
    expect(secondAcknowledgementOffset, greaterThan(verifiedOffset));
    expect(secondRejectOffset, greaterThan(secondAcknowledgementOffset));
    expect(promotionOffset, greaterThan(secondRejectOffset));
  });
}
