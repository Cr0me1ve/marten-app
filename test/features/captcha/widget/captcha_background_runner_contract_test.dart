import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _section(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex);
  expect(startIndex, isNonNegative, reason: 'missing `$start`');
  expect(endIndex, isNonNegative, reason: 'missing `$end` after `$start`');
  return source.substring(startIndex, endIndex);
}

void main() {
  const pagePath = 'lib/features/captcha/widget/captcha_page.dart';
  const listenerPath = 'lib/features/captcha/widget/captcha_listener.dart';
  const serviceControlPath = 'android/app/src/main/kotlin/app/marten/client/bg/ServiceOwnedCaptchaControlPlane.kt';

  group('Android CAPTCHA background runner contract', () {
    test('Android never mounts a persistent Flutter CaptchaPage/WebView', () {
      final page = File(pagePath).readAsStringSync();
      final listener = File(listenerPath).readAsStringSync();
      final build = _section(listener, 'Widget build(BuildContext context)', '\n  }\n}');

      expect(page, isNot(contains('persistentBackgroundRunner')));
      expect(page, isNot(contains('_persistentCaptchaSubscription')));
      expect(page, isNot(contains('_loadPersistentBackgroundEvent')));
      expect(page, isNot(contains('_clearPersistentBackgroundEvent')));
      expect(page, isNot(contains('MartenNativeResume.loadHeadlessCaptcha')));
      expect(page, isNot(contains('MartenNativeResume.clearHeadlessCaptcha')));
      expect(listener, isNot(contains('persistent-android-captcha-runner')));
      expect(build, isNot(contains('PlatformUtils.isAndroid')));
    });

    test('Android blank challenges stay with the service-owned native control plane', () {
      final listener = File(listenerPath).readAsStringSync();
      final control = File(serviceControlPath).readAsStringSync();
      final subscription = _section(
        listener,
        '_sub = ref.listenManual<CaptchaEvent?>',
        '\n  @override\n  void dispose',
      );

      expect(listener, contains("queryParameters['blank'] == '1'"));
      expect(subscription, contains('if (_shouldRunInBackground(next.url))'));
      expect(subscription, contains('if (PlatformUtils.isAndroid)'));
      final androidBranch = _section(subscription, 'if (PlatformUtils.isAndroid) {', '\n        }');
      expect(androidBranch, isNot(contains('setState(')));
      expect(androidBranch, isNot(contains('_open(next)')));
      expect(subscription, contains('if (mounted) _open(next)'));

      expect(control, contains('class ServiceOwnedCaptchaControlPlane'));
      expect(control, contains('MartenNativeCaptchaRunner.load(applicationContext, event.url, event.revision)'));
      expect(control, contains('MartenNativeCaptchaRunner.clear(event.revision)'));
    });

    test('foreground challenges still navigate directly to the visible CaptchaPage', () {
      final listener = File(listenerPath).readAsStringSync();
      final open = _section(listener, 'void _open(CaptchaEvent event) {', '\n  bool _shouldRunInBackground');

      expect(open, contains('final navigator = rootNavKey.currentState'));
      expect(open, contains('navigator\n        .push('));
      expect(open, contains('CaptchaPage(url: url, revision: event.revision'));
    });
  });
}
