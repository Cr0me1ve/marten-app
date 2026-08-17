import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const sourcePath = 'lib/features/captcha/widget/captcha_page.dart';

  String sourceFile() => File(sourcePath).readAsStringSync();

  String automationScript(String source) {
    const startMarker = "const _captchaAutomationScript = '''";
    final start = source.indexOf(startMarker);
    final end = source.indexOf("''';", start);
    expect(start, greaterThanOrEqualTo(0), reason: 'could not find the captcha automation script');
    expect(end, greaterThanOrEqualTo(0), reason: 'could not find the end of the captcha automation script');
    return source.substring(start + startMarker.length, end);
  }

  String between(String source, String startMarker, String endMarker) {
    final start = source.indexOf(startMarker);
    final end = source.indexOf(endMarker, start);
    expect(start, greaterThanOrEqualTo(0), reason: 'could not find `$startMarker`');
    expect(end, greaterThanOrEqualTo(0), reason: 'could not find `$endMarker` after `$startMarker`');
    return source.substring(start, end);
  }

  group('captcha automation source contract', () {
    test('requires legacy absence or a strict v2 PoW payload with a non-empty hash', () {
      final script = automationScript(sourceFile());
      final pow = between(script, 'function powDiagnosticState()', 'function attemptAutoClick()');

      expect(pow, matches(RegExp(r'''typeof\s+performPoW\s*!==?\s*['"]function['"]''')));
      expect(pow, matches(RegExp(r'''raw\.indexOf\s*\(\s*['"]v2\.['"]\s*\)\s*!==?\s*0''')));
      expect(pow, contains('payload.error'));
      expect(pow, contains('payload.hash'));
      expect(pow, matches(RegExp(r'''payload\.hash\.trim\s*\(\s*\)\s*!==?\s*['"]{2}''')));
      expect(pow, contains("return state === 'function-absent' || state === 'ready'"));
      expect(
        pow,
        isNot(matches(RegExp(r'''captchaPowResult\s*!==?\s*['"]undefined['"]'''))),
        reason: 'the presence of captchaPowResult alone must not make the driver ready',
      );
    });

    test('observes only the exact local result callback as terminal success', () {
      final script = automationScript(sourceFile());
      final classifier = between(script, 'function requestKindAfterClick(', 'function markRequestAfterClick(');
      final responseTracking = between(
        script,
        'function markResponseAfterClick(',
        'function markRequestErrorAfterClick(',
      );
      final attempt = between(script, 'function attemptAutoClick()', 'var autoClickInterval = setInterval');

      expect(classifier, contains("new URL(url, window.location.href).pathname === '/local-captcha-result'"));
      expect(classifier, contains("return 'callback'"));
      expect(classifier, contains("return 'check'"));
      expect(classifier, contains("return ''"));
      expect(responseTracking, contains("post('check-response-received')"));
      expect(responseTracking, contains('__martenCaptchaCallbackAccepted = true'));
      expect(responseTracking, isNot(contains('__martenCaptchaCheckResponseAccepted')));
      expect(attempt, contains('window.__martenCaptchaCallbackAccepted'));
      expect(attempt, isNot(contains('__martenCaptchaCheckResponseAccepted')));
      expect(attempt, contains("if (phase === 'scheduled') return false;"));
      expect(attempt, contains("phase = 'scheduled';"));
      expect(attempt, contains("phase = 'fired';"));
      expect(
        RegExp(r'el\.click\s*\(\s*\)').allMatches(script).length,
        1,
        reason: 'the canonical driver must own at most one synthetic click per page load',
      );
      expect(
        attempt,
        isNot(matches(RegExp(r'''phase\s*=\s*['"](?:scheduled|fired)['"][\s\S]{0,160}return\s+true'''))),
        reason: 'scheduling or firing a click must keep polling for callback evidence',
      );
      expect(
        attempt,
        isNot(matches(RegExp(r'''if\s*\(\s*el\.checked\s*\)[\s\S]{0,160}return\s+true'''))),
        reason: 'a checked checkbox is not terminal success',
      );
    });

    test('click exception is terminal, clears retry state, and cannot schedule another click', () {
      final script = automationScript(sourceFile());
      final attempt = between(script, 'function attemptAutoClick()', 'var autoClickInterval = setInterval');
      final scheduledClick = between(attempt, 'setTimeout(function() {', '}, 400 + Math.random() * 600);');
      final catchStart = scheduledClick.indexOf('} catch (e) {');

      expect(catchStart, greaterThanOrEqualTo(0));
      final clickFailure = scheduledClick.substring(catchStart);
      expect(clickFailure, contains("phase = 'failed';"));
      expect(clickFailure, contains('writeRetryCount(0);'));
      expect(clickFailure, contains("post('autoclick-error')"));
      expect(
        clickFailure.indexOf("phase = 'failed';"),
        lessThan(clickFailure.indexOf('writeRetryCount(0);')),
        reason: 'the click exception must become terminal before releasing retry state',
      );
      expect(
        attempt.indexOf("if (phase === 'failed') return true;"),
        lessThan(attempt.indexOf("phase = 'scheduled';")),
        reason: 'the polling loop must terminate before it could schedule a replacement click',
      );
      expect(RegExp(r'el\.click\s*\(\s*\)').allMatches(script).length, 1);
    });

    test('uses exactly one persisted retry and clears it on every terminal path', () {
      final script = automationScript(sourceFile());
      final retryStorage = between(
        script,
        "var retryStorageKey = '__martenCaptchaRetryCountV1';",
        'function normalizeUrlLike(input)',
      );
      final driver = between(script, "post('driver-installed')", 'var autoClickInterval = setInterval');
      final attempt = between(script, 'function attemptAutoClick()', 'var autoClickInterval = setInterval');

      expect(driver, matches(RegExp(r'maxRetries\s*=\s*1\b')));
      expect(driver, contains('var retries = readRetryCount();'));
      expect(retryStorage, contains("window.sessionStorage.getItem(retryStorageKey) === '1' ? 1 : 0"));
      expect(retryStorage, contains("window.sessionStorage.setItem(retryStorageKey, '1')"));
      expect(retryStorage, contains('window.sessionStorage.removeItem(retryStorageKey)'));
      expect(attempt, matches(RegExp(r'retries\s*\+=\s*1')));
      expect(attempt, matches(RegExp(r'retries\s*>=\s*maxRetries')));
      expect(attempt, contains("post('autoclick-retry')"));

      final callback = between(attempt, 'if (window.__martenCaptchaCallbackAccepted)', 'if (Date.now() > deadline)');
      final timeout = between(attempt, 'if (Date.now() > deadline)', "var el = document.getElementById");
      final exhausted = between(attempt, 'if (retries >= maxRetries)', 'retries += 1;');
      expect(callback, contains('writeRetryCount(0);'));
      expect(timeout, contains('writeRetryCount(0);'));
      expect(exhausted, contains('writeRetryCount(0);'));

      final retryStart = attempt.indexOf('retries += 1;');
      final missingCheckbox = attempt.indexOf('if (!isCheckbox(el)) return false;');
      expect(retryStart, greaterThanOrEqualTo(0));
      expect(missingCheckbox, greaterThanOrEqualTo(0));
      expect(retryStart, lessThan(missingCheckbox), reason: 'retry/reload must survive a vanished checkbox');
      final reloadPath = attempt.substring(retryStart, missingCheckbox);
      expect(
        reloadPath,
        matches(
          RegExp(
            r'''retries\s*\+=\s*1\s*;[\s\S]*?writeRetryCount\(retries\)\s*;[\s\S]*?post\(['"]autoclick-retry['"]\)\s*;[\s\S]*?window\.location\.reload\(\)''',
          ),
        ),
      );
      expect(
        reloadPath,
        matches(
          RegExp(
            r'''catch\s*\(\s*e\s*\)\s*\{[\s\S]*?writeRetryCount\(0\)\s*;[\s\S]*?post\(['"]autoclick-error['"]\)''',
          ),
        ),
        reason: 'a failed reload must release the stored retry budget',
      );
    });

    test('request observers recognize URL-like, Request, check and callback traffic', () {
      final script = automationScript(sourceFile());
      final normalizer = between(script, 'function normalizeUrlLike(input)', 'function requestKindAfterClick(');
      final fetchBridge = between(script, 'var bridgedFetch = function(input, init)', 'bridgedFetch.__marten');
      final xhrBridge = between(script, 'var bridgedOpen = function(method, url)', 'bridgedOpen.__marten');

      expect(normalizer, contains("typeof input === 'string'"));
      expect(normalizer, matches(RegExp(r'input\s+instanceof\s+URL')));
      expect(normalizer, contains('input.href'));
      expect(normalizer, contains('input.url'));
      expect(fetchBridge, contains('isRequestLike(input)'));
      expect(fetchBridge, contains('normalizeUrlLike(input)'));
      expect(fetchBridge, contains('markRequestAfterClick(input)'));
      expect(xhrBridge, contains('normalizeUrlLike(url)'));
      expect(xhrBridge, contains('this.__martenCaptchaOriginalRequest = normalized'));
      expect(xhrBridge, contains('arguments[1] = normalized'));
      expect(script, contains('markRequestAfterClick(this.__martenCaptchaOriginalRequest)'));
    });

    test('diagnostic labels are allowlisted and do not contain private payload categories', () {
      final source = sourceFile();
      final script = automationScript(source);
      final allowlist = between(
        source,
        'const _captchaAutomationDiagnosticEvents',
        "const _captchaAutomationScript = '''",
      );
      final handler = between(
        source,
        'void _handleAutomationSignal(String message)',
        'Future<void> _initWindowsWebView()',
      );

      expect(
        handler,
        matches(
          RegExp(
            r"_captchaAutomationDiagnosticEvents\.contains\(message\)\s*\?\s*message\s*:\s*'unknown'",
            dotAll: true,
          ),
        ),
      );
      expect(handler, isNot(contains(r'$message')), reason: 'Dart must never log the raw WebView message');

      final labels = RegExp("'([^']+)'").allMatches(allowlist).map((match) => match.group(1)!).toSet();
      for (final required in const [
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
        'autoclick-retry',
        'autoclick-unconfirmed',
        'pow-function-absent-compat-ready',
        'pow-result-missing-wait',
        'pow-result-error-wait',
        'pow-result-invalid-wait',
        'pow-hash-missing-wait',
        'pow-ready',
      ]) {
        expect(labels, contains(required), reason: 'privacy-safe diagnostic `$required` must remain allowlisted');
      }
      for (final label in labels) {
        expect(label, matches(RegExp(r'^[a-z0-9-]+$')));
        expect(label, isNot(matches(RegExp('url|host|header|body|token|cookie|authorization', caseSensitive: false))));
      }
      for (final event in RegExp(r"post\s*\(\s*'([^']+)'\s*\)").allMatches(script).map((match) => match.group(1)!)) {
        expect(labels, contains(event), reason: 'posted event `$event` is not allowlisted');
      }
    });

    test('failed core marker closes the pending captcha before prefix matching and permits a fresh URL', () {
      final notifier = File('lib/features/captcha/data/captcha_notifier.dart').readAsStringSync();
      final classify = between(notifier, '_CaptchaCandidate? _classify(String text)', 'String? _extractUrl(');
      final onLogs = between(notifier, 'void _onLogs(List<pb.LogMessage> events)', 'int _nextLogStartIndex(');

      final failed = classify.indexOf('if (text.contains(_captchaFailedMarker))');
      final resolved = classify.indexOf('if (text.contains(_captchaDoneMarker))');
      final generic = classify.indexOf('final idx = text.indexOf(_captchaMarker);');
      expect(failed, greaterThanOrEqualTo(0));
      expect(resolved, greaterThan(failed));
      expect(generic, greaterThan(resolved));
      expect(classify, contains('return const _CaptchaCandidate(done: true, failed: true);'));

      expect(onLogs, contains('if (done) {'));
      expect(onLogs, contains('state = null;'));
      expect(onLogs, contains('if (url != null && url != state?.url)'));
      expect(onLogs, contains('state = CaptchaEvent(url: url, createdAt: DateTime.now());'));
      expect(
        onLogs.indexOf('if (url != null && url != state?.url)'),
        greaterThan(onLogs.indexOf('if (done) {')),
        reason: 'a later fresh captcha URL must be accepted after the FAILED terminal event clears pending state',
      );
    });
  });
}
