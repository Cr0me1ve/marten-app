import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Google Play releases are guarded to PlayInAppUpdateListener and UpgradeAlert stays default', () {
    final source = File('lib/features/app/widget/app.dart').readAsStringSync();
    expect(
      source,
      contains('final usePlayInAppUpdate = PlatformUtils.isAndroid && appInfo.release == Release.googlePlay;'),
    );

    final updateAwareStart = source.indexOf('final updateAwareChild =');
    final wrappedStart = source.indexOf('final wrappedChild = CaptchaListener', updateAwareStart);

    expect(updateAwareStart, isNonNegative);
    expect(wrappedStart, isNonNegative);

    final updateAwareBlock = source.substring(updateAwareStart, wrappedStart);

    expect(updateAwareBlock, contains('usePlayInAppUpdate\n                        ? PlayInAppUpdateListener'));
    expect(updateAwareBlock, contains(': UpgradeAlert('));
    expect(updateAwareBlock, contains('upgrader: upgrader'));
  });
}
