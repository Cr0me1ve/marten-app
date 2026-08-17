import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _between(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex);
  expect(startIndex, isNonNegative, reason: 'missing `$start`');
  expect(endIndex, isNonNegative, reason: 'missing `$end` after `$start`');
  return source.substring(startIndex, endIndex);
}

String _withoutLineComments(String source) =>
    source.split('\n').map((line) => line.trimLeft().startsWith('//') ? '' : line).join('\n');

void main() {
  const listenerPath = 'lib/features/captcha/widget/captcha_listener.dart';
  const pagePath = 'lib/features/captcha/widget/captcha_page.dart';
  const coreServicePath = 'lib/martencore/marten_core_service.dart';
  const appPath = 'lib/features/app/widget/app.dart';
  const nativeHeadlessPath =
      'packages/marten_native_resume/android/src/main/kotlin/app/marten/native_resume/HeadlessCaptchaWebView.kt';

  group('Android CAPTCHA background runner contract', () {
    test('closeFront drops foreground listener but preserves Android background listener', () {
      final source = File(coreServicePath).readAsStringSync();
      final closeFront = _between(source, 'Future<void> closeFront() async {', '\n  }\n}');

      expect(closeFront, contains('await stopListenSingle("fg")'));
      expect(closeFront, contains('if (!PlatformUtils.isAndroid)'));
      final androidGate = closeFront.indexOf('if (!PlatformUtils.isAndroid)');
      final stopBackground = closeFront.indexOf('await stopListenSingle("bg")');
      expect(stopBackground, greaterThan(androidGate));
      final nonAndroidBranch = _between(closeFront, 'if (!PlatformUtils.isAndroid) {', '\n      }');
      expect(nonAndroidBranch, contains('await stopListenSingle("bg")'));
      expect(RegExp(r'await stopListenSingle\("bg"\)').allMatches(closeFront).length, 1);
      expect(closeFront, contains('await core.fgClient.pause('));
    });

    test('app mounts one persistent Android runner while the listener stays single at the router shell', () {
      final app = File(appPath).readAsStringSync();
      final listener = File(listenerPath).readAsStringSync();

      expect(RegExp(r'CaptchaListener\s*\(').allMatches(app).length, 1);
      expect(listener, contains("ValueKey('persistent-android-captcha-runner')"));
      expect(RegExp(r"ValueKey\('persistent-android-captcha-runner'\)").allMatches(listener).length, 1);
      expect(listener, contains('if (PlatformUtils.isAndroid)'));
      expect(listener, contains('persistentBackgroundRunner: true'));
      expect(listener, contains("url: 'about:blank'"));
    });

    test(
      'persistent runner receives replay and live blank challenges immediately, clears terminal state, and deduplicates URL loads',
      () {
        final page = File(pagePath).readAsStringSync();
        final initState = _between(page, 'void initState() {', '\n  @override\n  void dispose()');
        final loader = _between(
          page,
          'Future<void> _loadPersistentBackgroundUrl(String url) async {',
          '\n  void _scheduleReveal',
        );

        expect(initState, contains('ref.listenManual<CaptchaEvent?>'));
        expect(initState, contains('fireImmediately: true'));
        expect(initState, contains('_isBackgroundChallenge(nextUrl)'));
        expect(initState, contains('unawaited(_loadPersistentBackgroundUrl(nextUrl))'));
        expect(initState, contains("_loadPersistentBackgroundUrl('about:blank')"));
        expect(_withoutLineComments(initState), isNot(contains('addPostFrameCallback')));
        expect(loader, contains('if (_resolvedUrl == resolvedUrl)'));
        expect(loader, contains('return;'));
        expect(loader, contains('await controller.loadRequest(Uri.parse(resolvedUrl))'));
      },
    );

    test('mobile WebView bootstraps automation on page start and reinjects it on page finish', () {
      final page = File(pagePath).readAsStringSync();
      final navigationDelegate = _between(page, 'NavigationDelegate(', '\n        ),\n      )');
      final onPageStarted = _between(
        navigationDelegate,
        'onPageStarted: (url) {',
        '\n          },\n          onPageFinished',
      );
      final onPageFinished = _between(
        navigationDelegate,
        'onPageFinished: (url) {',
        '\n          },\n          onWebResourceError',
      );

      expect(
        navigationDelegate.indexOf('onPageStarted: (url) {'),
        lessThan(navigationDelegate.indexOf('onPageFinished: (url) {')),
      );
      expect(_withoutLineComments(onPageStarted), contains('unawaited(_installAutomationMonitor())'));
      expect(_withoutLineComments(onPageFinished), contains('unawaited(_installAutomationMonitor())'));
    });

    test(
      'Android persistent blank challenge uses detached native runner and falls back to Flutter only on rejection',
      () {
        final page = File(pagePath).readAsStringSync();
        final resolver = _between(page, 'String _resolveUrl(String url) {', '\n  bool _isBackgroundChallenge');
        final loader = _between(
          page,
          'Future<void> _loadPersistentBackgroundUrl(String url) async {',
          '\n  void _scheduleReveal',
        );
        final nativeBranch = _between(loader, 'if (PlatformUtils.isAndroid) {', '\n    }\n\n    final controller');
        final flutterFallbackStart = loader.indexOf('final controller = _controller;');
        expect(flutterFallbackStart, isNonNegative);
        final flutterFallback = loader.substring(flutterFallbackStart);

        expect(resolver, contains("url.replaceFirst(RegExp('^http://localhost:'), 'http://127.0.0.1:')"));
        expect(nativeBranch, contains("resolvedUrl == 'about:blank'"));
        expect(nativeBranch, contains('await MartenNativeResume.clearHeadlessCaptcha()'));
        expect(nativeBranch, contains('await MartenNativeResume.loadHeadlessCaptcha('));
        expect(nativeBranch, contains('url: resolvedUrl'));
        expect(nativeBranch, contains('automationScript: _captchaAutomationScript'));
        expect(nativeBranch, contains('if (nativeAccepted) return;'));
        expect(flutterFallback, contains('await controller.loadRequest(Uri.parse(resolvedUrl))'));
      },
    );

    test('detached native CAPTCHA WebView keeps the renderer alive and exposes only safe automation events', () {
      final native = File(nativeHeadlessPath).readAsStringSync();
      final create = _between(native, 'private fun create(context: Context): WebView =', '\n\n    private fun inject');
      final validateUrl = _between(
        native,
        'private fun validateUrl(rawUrl: String) {',
        '\n\n    private object AutomationEvents',
      );

      expect(native, contains('create(context.applicationContext).also { webView = it }'));
      expect(create, contains('WebView(context).apply {'));
      expect(create, isNot(contains('addView(')));
      expect(create, contains('settings.javaScriptEnabled = true'));
      expect(create, contains('settings.domStorageEnabled = true'));
      expect(create, contains('setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false)'));
      expect(create, contains('addJavascriptInterface(AutomationEvents, "MartenCaptchaAutomation")'));
      final onPageStarted = _between(
        create,
        'override fun onPageStarted',
        '\n\n            override fun onPageFinished',
      );
      final onPageFinished = _between(
        create,
        'override fun onPageFinished',
        '\n\n            override fun onRenderProcessGone',
      );
      expect(onPageStarted, contains('inject(view)'));
      expect(onPageFinished, contains('inject(view)'));
      expect(create, contains('view.destroy()'));
      expect(create, contains('if (webView === view) webView = null'));
      expect(create, contains('return true'));
      expect(validateUrl, contains('uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port in 1..65535'));
      expect(native, contains('message.takeIf(allowedEvents::contains) ?: "unknown"'));
      expect(native, contains(r'Log.i(TAG, "phase=automation event=$event")'));
    });

    test('blank challenges stay background while all other challenges navigate directly on the foreground route', () {
      final listener = File(listenerPath).readAsStringSync();
      final subscription = _between(
        listener,
        '_sub = ref.listenManual<CaptchaEvent?>',
        '\n  @override\n  void dispose',
      );
      final open = _between(listener, 'void _open(CaptchaEvent event) {', '\n  bool _shouldRunInBackground');

      expect(listener, contains("queryParameters['blank'] == '1'"));
      expect(subscription, contains('if (_shouldRunInBackground(next.url))'));
      expect(subscription, contains('if (mounted) _open(next)'));
      expect(_withoutLineComments(subscription), isNot(contains('addPostFrameCallback')));
      expect(open, contains('final navigator = rootNavKey.currentState'));
      expect(open, contains('navigator\n        .push('));
    });
  });
}
