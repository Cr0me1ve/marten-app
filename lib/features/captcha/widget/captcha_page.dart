import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/features/captcha/data/captcha_event.dart';
import 'package:marten/features/captcha/data/captcha_notifier.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:marten/utils/platform_utils.dart';
import 'package:marten_native_resume/marten_native_resume.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as win_webview;

const _captchaAutomationRevealDelay = Duration(seconds: 30);
const _captchaAutomationChannel = 'MartenCaptchaAutomation';
const _captchaWindowsLoadWatchdogDelay = Duration(seconds: 8);
const _captchaAutomationDiagnosticEvents = <String>{
  'monitor-installed',
  'driver-installed',
  'request-bridge-installed',
  'fetch-input-normalized',
  'fetch-request-normalized',
  'fetch-request-content-preserved',
  'fetch-normalization-error',
  'xhr-input-normalized',
  'check-request-observed',
  'check-response-received',
  'check-response-rejected',
  'check-request-error',
  'callback-request-observed',
  'callback-response-accepted',
  'callback-response-rejected',
  'callback-request-error',
  'checkbox-seen',
  'checkbox-click',
  'checkbox-checked',
  'autoclick-scheduled',
  'autoclick-fired',
  'autoclick-retry',
  'autoclick-unconfirmed',
  'autoclick-error',
  'autoclick-timeout',
  'pow-function-absent-compat-ready',
  'pow-result-missing-wait',
  'pow-result-error-wait',
  'pow-result-invalid-wait',
  'pow-hash-missing-wait',
  'pow-ready',
};
const _captchaAutomationImmediateRevealEvents = <String>{
  'fetch-normalization-error',
  'check-response-rejected',
  'check-request-error',
  'callback-response-rejected',
  'callback-request-error',
  'autoclick-unconfirmed',
  'autoclick-error',
  'autoclick-timeout',
};
const _captchaAutomationScript = '''
(function(){
  var retryStorageKey = '__martenCaptchaRetryCountV1';

  function post(kind) {
    try { MartenCaptchaAutomation.postMessage(kind); } catch (e) {}
    try {
      if (window.chrome && window.chrome.webview) {
        window.chrome.webview.postMessage(kind);
      }
    } catch (e) {}
  }

  function readRetryCount() {
    try {
      return window.sessionStorage.getItem(retryStorageKey) === '1' ? 1 : 0;
    } catch (e) {
      return 0;
    }
  }

  function writeRetryCount(value) {
    try {
      if (value === 1) window.sessionStorage.setItem(retryStorageKey, '1');
      else window.sessionStorage.removeItem(retryStorageKey);
    } catch (e) {}
  }

  function normalizeUrlLike(input) {
    if (typeof input === 'string') return input;
    if (!input) return null;
    try {
      if (typeof URL === 'function' && input instanceof URL) return input.href;
    } catch (e) {}
    try {
      if (typeof input.href === 'string') return input.href;
    } catch (e) {}
    try {
      if (typeof input.url === 'string') return input.url;
    } catch (e) {}
    return null;
  }

  function requestKindAfterClick(input) {
    if (!window.__martenCaptchaClickFiredAt) return '';
    var url = normalizeUrlLike(input);
    if (!url) return '';

    try {
      if (new URL(url, window.location.href).pathname === '/local-captcha-result') {
        return 'callback';
      }
    } catch (e) {}

    var detectors = window.__captchaDetectors || [];
    for (var i = 0; i < detectors.length; i++) {
      try {
        if (detectors[i] && typeof detectors[i].match === 'function' && detectors[i].match(url)) {
          return 'check';
        }
      } catch (e) {}
    }
    return '';
  }

  function markRequestAfterClick(input) {
    var kind = requestKindAfterClick(input);
    if (kind === 'check' && !window.__martenCaptchaCheckRequestSeen) {
      window.__martenCaptchaCheckRequestSeen = true;
      post('check-request-observed');
    } else if (kind === 'callback' && !window.__martenCaptchaCallbackRequestSeen) {
      window.__martenCaptchaCallbackRequestSeen = true;
      post('callback-request-observed');
    }
    return kind;
  }

  function markResponseAfterClick(kind, accepted) {
    if (!window.__martenCaptchaClickFiredAt || !kind) return;
    if (kind === 'check') {
      if (accepted) {
        post('check-response-received');
        return;
      }
      window.__martenCaptchaCheckRequestFailed = true;
      post('check-response-rejected');
      return;
    }
    if (accepted) {
      window.__martenCaptchaCallbackAccepted = true;
      writeRetryCount(0);
      post('callback-response-accepted');
      return;
    }
    window.__martenCaptchaCheckRequestFailed = true;
    post('callback-response-rejected');
  }

  function markRequestErrorAfterClick(kind) {
    if (!window.__martenCaptchaClickFiredAt || !kind) return;
    window.__martenCaptchaCheckRequestFailed = true;
    post(kind === 'callback' ? 'callback-request-error' : 'check-request-error');
  }

  function observeFetchResult(result, kind) {
    if (!kind) return result;
    return Promise.resolve(result).then(function(response) {
      markResponseAfterClick(kind, !!response && response.ok === true);
      return response;
    }, function(error) {
      markRequestErrorAfterClick(kind);
      throw error;
    });
  }

  function isRequestLike(input) {
    if (!input || typeof input !== 'object') return false;
    try {
      if (typeof Request === 'function' && input instanceof Request) return true;
    } catch (e) {}
    try {
      return typeof input.url === 'string' &&
          typeof input.method === 'string' &&
          typeof input.clone === 'function' &&
          input.headers != null;
    } catch (e) {
      return false;
    }
  }

  function requestInit(request) {
    var init = {
      method: request.method,
      headers: request.headers,
      credentials: request.credentials,
      cache: request.cache,
      redirect: request.redirect,
      referrer: request.referrer,
      referrerPolicy: request.referrerPolicy,
      integrity: request.integrity,
      keepalive: request.keepalive,
      signal: request.signal
    };
    // `navigate` is valid on a browser-created Request but cannot be supplied
    // in RequestInit. Captcha checks use cors/same-origin modes.
    if (request.mode && request.mode !== 'navigate') init.mode = request.mode;
    return init;
  }

  function forwardRequest(previousFetch, receiver, input, suppliedInit) {
    var effective = suppliedInit === undefined
        ? input.clone()
        : new Request(input, suppliedInit);
    var url = effective.url;
    var init = requestInit(effective);
    var method = String(effective.method || 'GET').toUpperCase();
    post('fetch-request-normalized');
    if (method === 'GET' || method === 'HEAD' || effective.body == null) {
      return previousFetch.call(receiver, url, init);
    }
    return effective.arrayBuffer().then(function(body) {
      init.body = body;
      post('fetch-request-content-preserved');
      return previousFetch.call(receiver, url, init);
    }, function(error) {
      post('fetch-normalization-error');
      throw error;
    });
  }

  function installRequestBridge() {
    var installed = false;
    try {
      var previousFetch = window.fetch;
      if (typeof previousFetch === 'function' && !previousFetch.__martenCaptchaRequestBridge) {
        var bridgedFetch = function(input, init) {
          var kind = markRequestAfterClick(input);
          try {
            if (isRequestLike(input)) {
              return observeFetchResult(forwardRequest(previousFetch, this, input, init), kind);
            }
            var normalized = normalizeUrlLike(input);
            if (typeof input !== 'string' && normalized !== null) {
              post('fetch-input-normalized');
              return observeFetchResult(previousFetch.call(this, normalized, init), kind);
            }
            return observeFetchResult(previousFetch.apply(this, arguments), kind);
          } catch (e) {
            post('fetch-normalization-error');
            if (kind) markRequestErrorAfterClick(kind);
            return Promise.reject(e);
          }
        };
        bridgedFetch.__martenCaptchaRequestBridge = true;
        window.fetch = bridgedFetch;
        installed = true;
      }
    } catch (e) {
      post('fetch-normalization-error');
    }

    try {
      var proto = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
      if (proto) {
        var previousOpen = proto.open;
        if (typeof previousOpen === 'function' && !previousOpen.__martenCaptchaRequestBridge) {
          var bridgedOpen = function(method, url) {
            var normalized = normalizeUrlLike(url);
            this.__martenCaptchaOriginalRequest = normalized;
            if (typeof url !== 'string' && normalized !== null) {
              arguments[1] = normalized;
              post('xhr-input-normalized');
            }
            return previousOpen.apply(this, arguments);
          };
          bridgedOpen.__martenCaptchaRequestBridge = true;
          proto.open = bridgedOpen;
          installed = true;
        }

        var previousSend = proto.send;
        if (typeof previousSend === 'function' && !previousSend.__martenCaptchaRequestBridge) {
          var bridgedSend = function() {
            var kind = markRequestAfterClick(this.__martenCaptchaOriginalRequest);
            if (kind && typeof this.addEventListener === 'function') {
              var xhr = this;
              this.addEventListener('load', function() {
                markResponseAfterClick(kind, xhr.status >= 200 && xhr.status < 400);
              }, {once: true});
              var onError = function() { markRequestErrorAfterClick(kind); };
              this.addEventListener('error', onError, {once: true});
              this.addEventListener('abort', onError, {once: true});
              this.addEventListener('timeout', onError, {once: true});
            }
            return previousSend.apply(this, arguments);
          };
          bridgedSend.__martenCaptchaRequestBridge = true;
          proto.send = bridgedSend;
          installed = true;
        }
      }
    } catch (e) {
      post('fetch-normalization-error');
    }

    if (installed) post('request-bridge-installed');
  }

  // The local proxy installs its own fetch/XHR wrappers from page JavaScript.
  // Re-running this function makes our compatibility layer the outer wrapper
  // regardless of whether it executes before or after the proxy script.
  installRequestBridge();

  function isCheckbox(el) {
    return el && el.tagName === 'INPUT' && String(el.type).toLowerCase() === 'checkbox';
  }

  function watch(el) {
    if (!isCheckbox(el) || el.__martenCaptchaAutomationWatched) return;
    el.__martenCaptchaAutomationWatched = true;
    post('checkbox-seen');
    el.addEventListener('click', function(){
      window.__martenCaptchaClickFiredAt = Date.now();
      post('checkbox-click');
    }, true);
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

  if (!window.__martenCaptchaAutomationWatchInstalled) {
    window.__martenCaptchaAutomationWatchInstalled = true;
    post('monitor-installed');
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
  }

  if (String(window.location.href).indexOf('blank=1') !== -1 &&
      !window.__martenCaptchaAutoDriveInstalled) {
    window.__martenCaptchaAutoDriveInstalled = true;
    post('driver-installed');
    var deadline = Date.now() + 30000;
    var phase = 'idle';
    var firedAt = 0;
    var retries = readRetryCount();
    var maxRetries = 1;
    var lastPowDiagnostic = '';

    function powDiagnosticState() {
      if (typeof performPoW !== 'function') return 'function-absent';
      if (typeof window.captchaPowResult === 'undefined') return 'result-missing';

      var raw = window.captchaPowResult;
      if (typeof raw !== 'string' || raw.indexOf('v2.') !== 0) return 'result-invalid';
      try {
        var encoded = raw.slice(3).replace(/-/g, '+').replace(/_/g, '/');
        while (encoded.length % 4 !== 0) encoded += '=';
        var payload = JSON.parse(atob(encoded));
        if (payload && payload.error) return 'result-error';
        if (payload && typeof payload.hash === 'string' && payload.hash.trim() !== '') return 'ready';
        return 'hash-missing';
      } catch (e) {
        return 'result-invalid';
      }
    }

    function reportPowDiagnostic(state) {
      var event;
      if (state === 'function-absent') event = 'pow-function-absent-compat-ready';
      else if (state === 'ready') event = 'pow-ready';
      else event = 'pow-' + state + '-wait';
      if (event === lastPowDiagnostic) return;
      lastPowDiagnostic = event;
      post(event);
    }

    function powReady() {
      var state = powDiagnosticState();
      reportPowDiagnostic(state);
      return state === 'function-absent' || state === 'ready';
    }

    function attemptAutoClick() {
      installRequestBridge();
      if (window.__martenCaptchaCallbackAccepted) {
        writeRetryCount(0);
        return true;
      }
      if (phase === 'failed') return true;
      if (Date.now() > deadline) {
        writeRetryCount(0);
        post('autoclick-timeout');
        return true;
      }
      var el = document.getElementById('not-robot-captcha-checkbox') ||
          (document.querySelector ? document.querySelector('input[type="checkbox"]') : null);
      if (isCheckbox(el)) watch(el);

      if (phase === 'scheduled') return false;
      if (phase === 'fired' || (isCheckbox(el) && el.checked)) {
        if (!firedAt) firedAt = window.__martenCaptchaClickFiredAt || Date.now();
        phase = 'fired';
        if (!window.__martenCaptchaCheckRequestFailed && Date.now() - firedAt < 6000) return false;
        if (retries >= maxRetries) {
          writeRetryCount(0);
          post('autoclick-unconfirmed');
          return true;
        }
        retries += 1;
        writeRetryCount(retries);
        post('autoclick-retry');
        // A completed check may leave the widget in a terminal internal state
        // or remove its checkbox. Reload once to obtain a fresh widget and PoW;
        // sessionStorage keeps this retry bounded across the reload.
        try {
          window.location.reload();
        } catch (e) {
          writeRetryCount(0);
          post('autoclick-error');
        }
        return true;
      }
      if (!isCheckbox(el)) return false;
      if (!powReady()) return false;
      phase = 'scheduled';
      post('autoclick-scheduled');
      setTimeout(function() {
        try {
          installRequestBridge();
          el.focus();
          firedAt = Date.now();
          window.__martenCaptchaClickFiredAt = firedAt;
          el.click();
          phase = 'fired';
          post('autoclick-fired');
        } catch (e) {
          phase = 'failed';
          writeRetryCount(0);
          post('autoclick-error');
        }
      }, 400 + Math.random() * 600);
      return false;
    }

    var autoClickInterval = setInterval(function() {
      if (attemptAutoClick()) clearInterval(autoClickInterval);
    }, 120);
    if (attemptAutoClick()) clearInterval(autoClickInterval);
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
  const CaptchaPage({
    super.key,
    required this.url,
    this.revealDelay = Duration.zero,
    this.background = false,
    this.persistentBackgroundRunner = false,
  }) : assert(!persistentBackgroundRunner || background);

  final String url;
  final Duration revealDelay;
  final bool background;

  /// Keeps one already-mounted Android WebView ready to receive replayable
  /// CAPTCHA events while Flutter is paused behind another application.
  final bool persistentBackgroundRunner;

  @override
  ConsumerState<CaptchaPage> createState() => _CaptchaPageState();
}

class _CaptchaPageState extends ConsumerState<CaptchaPage> with InfraLogger {
  WebViewController? _controller;
  win_webview.WebviewController? _windowsController;
  final List<StreamSubscription<dynamic>> _windowsSubscriptions = [];
  ProviderSubscription<CaptchaEvent?>? _persistentCaptchaSubscription;
  String _resolvedUrl = 'about:blank';
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
    _resolvedUrl = _resolveUrl(widget.url);
    loggy.info(
      'captcha page loading webview=${_useWindowsWebView ? 'windows' : 'mobile'} '
      'background=${widget.background} delayedReveal=${!_revealed}',
    );

    if (_useWindowsWebView) {
      unawaited(_initWindowsWebView());
      return;
    }

    final controller = WebViewController();
    _controller = controller;
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel(_captchaAutomationChannel, onMessageReceived: _handleAutomationMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            loggy.info('captcha page started background=${widget.background}');
            // Android may postpone onPageFinished indefinitely when Marten is
            // behind another app even though the local proxy already returned
            // the CAPTCHA HTML. Install against the new document as soon as
            // navigation starts; the script observes later DOM additions and
            // onPageFinished still re-injects it for WebView/OEM variance.
            unawaited(_installAutomationMonitor());
            if (mounted) {
              setState(() {
                _loading = true;
                _errorMessage = null;
              });
            }
          },
          onPageFinished: (url) {
            loggy.info('captcha page finished background=${widget.background}');
            unawaited(_installAutomationMonitor());
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            // Only report errors for the main frame so we don't display
            // unrelated subresource failures (favicon, analytics, etc).
            final isMain = error.isForMainFrame ?? false;
            loggy.warning(
              'captcha webview error: code=${error.errorCode} type=${error.errorType} '
              'mainFrame=$isMain',
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

    if (widget.persistentBackgroundRunner) {
      _persistentCaptchaSubscription = ref.listenManual<CaptchaEvent?>(captchaNotifierProvider, (previous, next) {
        final nextUrl = next?.url;
        if (nextUrl != null && _isBackgroundChallenge(nextUrl)) {
          unawaited(_loadPersistentBackgroundUrl(nextUrl));
          return;
        }
        if (next == null && _resolvedUrl != 'about:blank') {
          unawaited(_loadPersistentBackgroundUrl('about:blank'));
        }
      }, fireImmediately: true);
    }
  }

  @override
  void dispose() {
    _persistentCaptchaSubscription?.close();
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

  String _resolveUrl(String url) {
    if (_useWindowsWebView) return url;
    return url.replaceFirst(RegExp('^http://localhost:'), 'http://127.0.0.1:');
  }

  bool _isBackgroundChallenge(String url) => Uri.tryParse(url)?.queryParameters['blank'] == '1';

  Future<void> _loadPersistentBackgroundUrl(String url) async {
    final resolvedUrl = _resolveUrl(url);
    if (_resolvedUrl == resolvedUrl) {
      loggy.info('captcha persistent runner: challenge already loaded');
      return;
    }
    _resolvedUrl = resolvedUrl;
    _automationSignalSeen = false;
    _errorMessage = null;
    _loading = resolvedUrl != 'about:blank';
    loggy.info('captcha persistent runner: loading challenge=${resolvedUrl != 'about:blank'}');

    if (PlatformUtils.isAndroid) {
      var nativeAccepted = false;
      try {
        nativeAccepted = resolvedUrl == 'about:blank'
            ? await MartenNativeResume.clearHeadlessCaptcha()
            : await MartenNativeResume.loadHeadlessCaptcha(
                url: resolvedUrl,
                automationScript: _captchaAutomationScript,
              );
        if (!nativeAccepted) loggy.warning('captcha native headless runner rejected navigation');
      } catch (_) {
        // The platform error may embed a private challenge URL. Keep the log
        // fixed and let the still-mounted Flutter WebView remain a foreground
        // fallback rather than exposing exception contents.
        loggy.warning('captcha native headless runner navigation failed');
      }
      if (nativeAccepted) return;
    }

    final controller = _controller;
    if (controller == null || !mounted) return;
    try {
      await controller.loadRequest(Uri.parse(resolvedUrl));
    } catch (_) {
      // Do not include the platform exception: some WebView implementations
      // embed the challenge URL in it, and provider URLs are private.
      loggy.warning('captcha persistent runner navigation failed');
    }
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
    final event = _captchaAutomationDiagnosticEvents.contains(message) ? message : 'unknown';
    loggy.info(
      'captcha automation event=$event first=$firstSignal '
      'revealed=$_revealed background=${widget.background}',
    );
    if (!_revealed && !widget.background && _captchaAutomationImmediateRevealEvents.contains(event)) {
      _revealTimer?.cancel();
      setState(() => _revealed = true);
      return;
    }
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
      loggy.info('captcha automation monitor install completed webview=mobile');
    } catch (error) {
      loggy.warning('captcha automation monitor failed: $error');
    }
  }

  Future<void> _installWindowsAutomationMonitor() async {
    final controller = _windowsController;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.executeScript(_captchaAutomationScript);
      loggy.info('captcha automation monitor install completed webview=windows');
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
