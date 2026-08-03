import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/features/captcha/data/captcha_notifier.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:marten/utils/platform_utils.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as win_webview;

const _captchaAutomationRevealDelay = Duration(seconds: 30);
const _captchaAutomationChannel = 'MartenCaptchaAutomation';
const _captchaWindowsLoadWatchdogDelay = Duration(seconds: 8);
const _captchaAutomationScript = '''
(function(){
  if (window.__martenCaptchaAutomationWatchInstalled) return;
  window.__martenCaptchaAutomationWatchInstalled = true;

  function post(kind) {
    try { MartenCaptchaAutomation.postMessage(kind); } catch (e) {}
    try {
      if (window.chrome && window.chrome.webview) {
        window.chrome.webview.postMessage(kind);
      }
    } catch (e) {}
  }

  function isCheckbox(el) {
    return el && el.tagName === 'INPUT' && String(el.type).toLowerCase() === 'checkbox';
  }

  function watch(el) {
    if (!isCheckbox(el) || el.__martenCaptchaAutomationWatched) return;
    el.__martenCaptchaAutomationWatched = true;
    post('checkbox-seen');
    el.addEventListener('click', function(){ post('checkbox-click'); }, true);
    el.addEventListener('change', function(){
      if (el.checked) post('checkbox-checked');
    }, true);
    if (el.checked) post('checkbox-checked');
  }

  function scan(root) {
    if (!root) return;
    if (isCheckbox(root)) watch(root);
    if (!root.querySelectorAll) return;
    var nodes = root.querySelectorAll('input[type="checkbox"]');
    for (var i = 0; i < nodes.length; i++) watch(nodes[i]);
  }

  scan(document);
  if (window.MutationObserver && document.documentElement) {
    new MutationObserver(function(mutations) {
      for (var i = 0; i < mutations.length; i++) {
        var mutation = mutations[i];
        if (mutation.type === 'attributes') {
          watch(mutation.target);
          if (isCheckbox(mutation.target) && mutation.target.checked) {
            post('checkbox-checked');
          }
          continue;
        }
        for (var j = 0; j < mutation.addedNodes.length; j++) {
          scan(mutation.addedNodes[j]);
        }
      }
    }).observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['checked', 'type']
    });
  }

  if (String(window.location.href).indexOf('blank=1') !== -1 &&
      !window.__martenCaptchaAutoDriveInstalled) {
    window.__martenCaptchaAutoDriveInstalled = true;
    var deadline = Date.now() + 30000;
    var clicked = false;

    function powReady() {
      return typeof performPoW !== 'function' || typeof window.captchaPowResult !== 'undefined';
    }

    function attemptAutoClick() {
      if (clicked) return true;
      if (Date.now() > deadline) {
        post('autoclick-timeout');
        return true;
      }
      var el = document.getElementById('not-robot-captcha-checkbox') ||
          (document.querySelector ? document.querySelector('input[type="checkbox"]') : null);
      if (!isCheckbox(el)) return false;
      watch(el);
      if (el.checked) {
        post('checkbox-checked');
        clicked = true;
        return true;
      }
      if (!powReady()) return false;
      clicked = true;
      post('autoclick-scheduled');
      setTimeout(function() {
        try {
          el.focus();
          el.click();
          post('autoclick-fired');
        } catch (e) {
          post('autoclick-error');
        }
      }, 400 + Math.random() * 600);
      return true;
    }

    if (!attemptAutoClick()) {
      var autoClickInterval = setInterval(function() {
        if (attemptAutoClick()) clearInterval(autoClickInterval);
      }, 120);
    }
  }
})();
''';

/// Fullscreen page that hosts the TURNcoat dialer's captcha proxy.
///
/// The dialer keeps a local HTTP server alive on 127.0.0.1:8765 for the
/// duration of the challenge — this page only needs to render it. Token
/// extraction and the eventual handshake happen entirely on the Go side; we
/// simply close the page when the dialer signals `MARTEN_CAPTCHA_DONE` (state
/// flipping back to null) or when the user dismisses it manually.
class CaptchaPage extends ConsumerStatefulWidget {
  const CaptchaPage({super.key, required this.url, this.revealDelay = Duration.zero, this.background = false});

  final String url;
  final Duration revealDelay;
  final bool background;

  @override
  ConsumerState<CaptchaPage> createState() => _CaptchaPageState();
}

class _CaptchaPageState extends ConsumerState<CaptchaPage> with InfraLogger {
  WebViewController? _controller;
  win_webview.WebviewController? _windowsController;
  final List<StreamSubscription<dynamic>> _windowsSubscriptions = [];
  late final String _resolvedUrl;
  Timer? _revealTimer;
  Timer? _windowsLoadWatchdog;
  bool _loading = true;
  bool _revealed = true;
  bool _automationSignalSeen = false;
  String? _errorMessage;

  bool get _useWindowsWebView => PlatformUtils.isWindows;

  @override
  void initState() {
    super.initState();
    _revealed = widget.revealDelay == Duration.zero || widget.revealDelay.isNegative;
    if (_useWindowsWebView) {
      // WebView2 is sensitive to being initialized inside a hidden 1x1 texture:
      // the captcha page can keep loading forever without a navigationCompleted
      // event. Windows gets the full-size page immediately; mobile still keeps
      // the delayed reveal used for the invisible auto-pass path.
      _revealed = true;
    }
    if (!_revealed) _scheduleReveal(widget.revealDelay);

    // Some Android WebView builds choke on `localhost` (no /etc/hosts entry, or
    // the runtime resolver picks ::1 first and silently fails). Rewrite to the
    // explicit IPv4 loopback for mobile WebView only. Windows WebView2 keeps the
    // original localhost origin because TURNcoat's injected captcha JS expects
    // http://localhost:8765 when rewriting proxied requests.
    _resolvedUrl = _useWindowsWebView
        ? widget.url
        : widget.url.replaceFirst(RegExp('^http://localhost:'), 'http://127.0.0.1:');
    loggy.info('captcha page loading');

    if (_useWindowsWebView) {
      unawaited(_initWindowsWebView());
      return;
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel(_captchaAutomationChannel, onMessageReceived: _handleAutomationMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            loggy.info('captcha page started');
            if (mounted) {
              setState(() {
                _loading = true;
                _errorMessage = null;
              });
            }
          },
          onPageFinished: (url) {
            loggy.info('captcha page finished');
            unawaited(_installAutomationMonitor());
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            // Only report errors for the main frame so we don't display
            // unrelated subresource failures (favicon, analytics, etc).
            final isMain = error.isForMainFrame ?? false;
            loggy.warning(
              'captcha webview error: code=${error.errorCode} type=${error.errorType} '
              'mainFrame=$isMain desc=${error.description}',
            );
            if (!isMain || !mounted) return;
            setState(() {
              _revealed = true;
              _loading = false;
              _errorMessage =
                  'WebView error ${error.errorCode}: ${error.description}\n'
                  '(${error.errorType?.name ?? 'unknown type'})';
            });
          },
          onHttpError: (error) {
            loggy.warning('captcha http error: status=${error.response?.statusCode}');
          },
        ),
      )
      ..loadRequest(Uri.parse(_resolvedUrl));
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    _windowsLoadWatchdog?.cancel();
    for (final subscription in _windowsSubscriptions) {
      unawaited(subscription.cancel());
    }
    final windowsController = _windowsController;
    if (windowsController != null) {
      unawaited(windowsController.dispose());
    }
    super.dispose();
  }

  void _scheduleReveal(Duration delay) {
    _revealTimer?.cancel();
    _revealTimer = Timer(delay, () {
      if (!mounted || ref.read(captchaNotifierProvider) == null || _revealed) {
        return;
      }
      loggy.info(
        'captcha page revealing after ${delay.inMilliseconds}ms '
        'automationSignal=$_automationSignalSeen',
      );
      setState(() => _revealed = true);
    });
  }

  void _handleAutomationMessage(JavaScriptMessage message) {
    _handleAutomationSignal(message.message);
  }

  void _handleAutomationSignal(String message) {
    final firstSignal = !_automationSignalSeen;
    _automationSignalSeen = true;
    loggy.info('captcha automation signal received');
    if (firstSignal && !_revealed && !widget.background) {
      _scheduleReveal(_captchaAutomationRevealDelay);
    }
  }

  Future<void> _initWindowsWebView() async {
    if (mounted) {
      setState(() {
        _errorMessage = null;
        _loading = true;
      });
    }

    try {
      final runtimeVersion = await win_webview.WebviewController.getWebViewVersion();
      if (runtimeVersion == null) {
        throw StateError('Microsoft Edge WebView2 Runtime is not installed');
      }
      loggy.info('captcha windows webview2 runtime=$runtimeVersion');

      final controller = win_webview.WebviewController();
      _windowsController = controller;
      await controller.initialize();
      await controller.setBackgroundColor(Colors.white);
      await controller.setPopupWindowPolicy(win_webview.WebviewPopupWindowPolicy.sameWindow);
      await controller.addScriptToExecuteOnDocumentCreated(_captchaAutomationScript);

      _windowsSubscriptions
        ..add(
          controller.loadingState.listen((state) {
            loggy.info('captcha windows webview loading state: ${state.name}');
            if (!mounted) return;
            if (state == win_webview.LoadingState.loading) {
              _scheduleWindowsLoadWatchdog();
              setState(() {
                _loading = true;
                _errorMessage = null;
              });
              return;
            }
            if (state == win_webview.LoadingState.navigationCompleted) {
              _windowsLoadWatchdog?.cancel();
              unawaited(_installWindowsAutomationMonitor());
              setState(() => _loading = false);
            }
          }),
        )
        ..add(
          controller.onLoadError.listen((error) {
            loggy.warning('captcha windows webview error: ${error.name}');
            if (!mounted) return;
            setState(() {
              _revealed = true;
              _loading = false;
              _errorMessage = 'WebView2 error: ${error.name}\nurl=$_resolvedUrl';
            });
          }),
        )
        ..add(
          controller.webMessage.listen(
            (message) {
              _handleAutomationSignal(message?.toString() ?? 'web-message');
            },
            onError: (Object error) {
              loggy.warning('captcha windows web message failed: $error');
            },
          ),
        );

      await controller.loadUrl(_resolvedUrl);
      _scheduleWindowsLoadWatchdog();
      if (mounted) setState(() {});
    } catch (error) {
      loggy.warning('captcha windows webview init failed: $error');
      if (mounted) {
        setState(() {
          _revealed = true;
          _loading = false;
          _errorMessage = 'Не удалось открыть captcha во встроенном WebView2:\n$error\nurl=$_resolvedUrl';
        });
      }
    }
  }

  Future<void> _installAutomationMonitor() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(_captchaAutomationScript);
    } catch (error) {
      loggy.warning('captcha automation monitor failed: $error');
    }
  }

  Future<void> _installWindowsAutomationMonitor() async {
    final controller = _windowsController;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.executeScript(_captchaAutomationScript);
    } catch (error) {
      loggy.warning('captcha windows automation monitor failed: $error');
    }
  }

  void _scheduleWindowsLoadWatchdog() {
    _windowsLoadWatchdog?.cancel();
    _windowsLoadWatchdog = Timer(_captchaWindowsLoadWatchdogDelay, () {
      if (!mounted || !_useWindowsWebView || !_loading) return;
      loggy.warning(
        'captcha windows webview still loading after '
        '${_captchaWindowsLoadWatchdogDelay.inSeconds}s; showing page anyway',
      );
      unawaited(_installWindowsAutomationMonitor());
      setState(() => _loading = false);
    });
  }

  Future<void> _reloadWindowsWebView() async {
    setState(() => _errorMessage = null);
    final controller = _windowsController;
    if (controller != null && controller.value.isInitialized) {
      setState(() => _loading = true);
      await controller.loadUrl(_resolvedUrl);
      _scheduleWindowsLoadWatchdog();
      return;
    }
    await _initWindowsWebView();
  }

  @override
  Widget build(BuildContext context) {
    // When the notifier clears its state (either because the dialer signalled
    // MARTEN_CAPTCHA_DONE or because another caller dismissed), pop this page.
    ref.listen(captchaNotifierProvider, (previous, next) {
      if (!widget.background && previous != null && next == null && mounted) {
        Navigator.of(context).maybePop();
      }
    });

    if (widget.background) return _buildBackgroundWebView(context);

    if (!_revealed) {
      if (_useWindowsWebView) return _buildHiddenWindowsWebView(context);
      return _buildHiddenMobileWebView(context);
    }

    if (_useWindowsWebView) return _buildWindowsWebViewPage(context);

    final controller = _controller!;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) ref.read(captchaNotifierProvider.notifier).dismiss();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Captcha'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: MaterialLocalizations.of(context).cancelButtonLabel,
            onPressed: () {
              ref.read(captchaNotifierProvider.notifier).dismiss();
              Navigator.of(context).maybePop();
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload',
              onPressed: () {
                setState(() => _errorMessage = null);
                controller.loadRequest(Uri.parse(_resolvedUrl));
              },
            ),
          ],
        ),
        body: Stack(
          children: [
            WebViewWidget(controller: controller),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_errorMessage != null)
              Positioned.fill(
                child: Container(
                  color: Theme.of(context).colorScheme.surface,
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
                      const SizedBox(height: 16),
                      Text('Не удалось загрузить captcha', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      SelectableText(
                        _errorMessage!,
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text('Попробовать снова'),
                        onPressed: () {
                          setState(() => _errorMessage = null);
                          controller.loadRequest(Uri.parse(_resolvedUrl));
                        },
                      ),
                    ],
                  ),
                ),
              ),
            if (kDebugMode)
              Positioned(
                right: 8,
                bottom: 8,
                child: Material(
                  color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(_resolvedUrl, style: Theme.of(context).textTheme.bodySmall),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHiddenWindowsWebView(BuildContext context) {
    final controller = _windowsController;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) ref.read(captchaNotifierProvider.notifier).dismiss();
      },
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: Theme.of(context).colorScheme.surface)),
            if (controller != null && controller.value.isInitialized)
              IgnorePointer(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox.square(dimension: 1, child: ClipRect(child: win_webview.Webview(controller))),
                ),
              ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
          ],
        ),
      ),
    );
  }

  Widget _buildHiddenMobileWebView(BuildContext context) {
    final controller = _controller;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) ref.read(captchaNotifierProvider.notifier).dismiss();
      },
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: Theme.of(context).colorScheme.surface)),
            if (controller != null)
              IgnorePointer(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox.square(
                    dimension: 1,
                    child: ClipRect(child: WebViewWidget(controller: controller)),
                  ),
                ),
              ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
          ],
        ),
      ),
    );
  }

  Widget _buildHiddenBackgroundWebView(Widget child) {
    // Keep the full viewport for captcha JS/layout, but paint it fully hidden
    // so the provider page cannot ghost over Marten while auto-solving.
    return IgnorePointer(
      child: Opacity(opacity: 0, child: SizedBox.expand(child: child)),
    );
  }

  Widget _buildBackgroundWebView(BuildContext context) {
    if (_useWindowsWebView) {
      final controller = _windowsController;
      if (controller == null || !controller.value.isInitialized) {
        return const SizedBox.shrink();
      }
      return _buildHiddenBackgroundWebView(win_webview.Webview(controller));
    }

    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return _buildHiddenBackgroundWebView(WebViewWidget(controller: controller));
  }

  Widget _buildWindowsWebViewPage(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _windowsController;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) ref.read(captchaNotifierProvider.notifier).dismiss();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Captcha'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: MaterialLocalizations.of(context).cancelButtonLabel,
            onPressed: () {
              ref.read(captchaNotifierProvider.notifier).dismiss();
              Navigator.of(context).maybePop();
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload',
              onPressed: () => unawaited(_reloadWindowsWebView()),
            ),
          ],
        ),
        body: Stack(
          children: [
            if (controller != null && controller.value.isInitialized) win_webview.Webview(controller),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (controller == null || !controller.value.isInitialized || _errorMessage != null)
              Positioned.fill(
                child: Container(
                  color: theme.colorScheme.surface,
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _errorMessage == null ? Icons.hourglass_empty : Icons.error_outline,
                        size: 48,
                        color: _errorMessage == null ? theme.colorScheme.primary : theme.colorScheme.error,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage == null ? 'Загрузка captcha' : 'Не удалось загрузить captcha',
                        style: theme.textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 8),
                        SelectableText(_errorMessage!, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.refresh),
                          label: const Text('Попробовать снова'),
                          onPressed: () => unawaited(_reloadWindowsWebView()),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (kDebugMode)
              Positioned(
                right: 8,
                bottom: 8,
                child: Material(
                  color: theme.colorScheme.surface.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(_resolvedUrl, style: theme.textTheme.bodySmall),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
