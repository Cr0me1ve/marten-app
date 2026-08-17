import 'dart:async';

import 'package:marten/features/captcha/data/captcha_event.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart' as pb;
import 'package:marten/martencore/marten_core_service_provider.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'captcha_notifier.g.dart';

/// Marker prefix emitted by marten-core's `installCaptchaBridge` whenever the
/// TURNcoat dialer needs the user to solve a captcha. Kept in sync with
/// `LogTurncoatCaptchaMarker` in `marten-core/v2/hcore/captcha_bridge.go`.
const String _captchaMarker = 'MARTEN_TURNCOAT_CAPTCHA';

/// Counterpart marker emitted once the captcha proxy has accepted a solution
/// token, used to auto-dismiss the WebView. Matches
/// `LogTurncoatCaptchaResolvedMarker` in marten-core.
const String _captchaDoneMarker = 'MARTEN_TURNCOAT_CAPTCHA_DONE';

/// Terminal marker for an explicitly rejected or timed-out captcha attempt.
/// It must be checked before [_captchaMarker] because the failed marker shares
/// that prefix. TURNcoat may emit a fresh request immediately after it rotates
/// provider app credentials.
const String _captchaFailedMarker = 'MARTEN_TURNCOAT_CAPTCHA_FAILED';

/// Local origin the TURNcoat dialer always uses for its captcha HTTP server.
/// Kept in sync with `captchaListenPort` in `TURNcoat/dialer/manual_captcha.go`.
const String _captchaLocalOrigin = 'http://localhost:8765';

/// TURNcoat cancels one manual CAPTCHA attempt after 60 seconds. A request
/// observed while the connection flow is arming is therefore safe to replay
/// only inside that same bounded window.
const Duration _deferredCaptchaMaxAge = Duration(seconds: 65);

/// Watches the marten-core log stream for captcha events and exposes them as
/// a single-shot state for the UI to react to.
///
/// The state is the most recent unresolved [CaptchaEvent], or null when the
/// dialer is not currently asking for a captcha (or the user already dismissed
/// the active request).
@Riverpod(keepAlive: true)
class CaptchaNotifier extends _$CaptchaNotifier with InfraLogger {
  StreamSubscription<List<pb.LogMessage>>? _subscription;
  bool _armed = false;
  pb.LogMessage? _lastProcessedLog;
  CaptchaEvent? _deferredEvent;

  @override
  CaptchaEvent? build() {
    final core = ref.watch(martenCoreServiceProvider);
    _lastProcessedLog = core.runtimeLogBuffer.lastOrNull;
    _subscription = core.runtimeLogController.stream.listen(_onLogs);
    ref.onDispose(() {
      _subscription?.cancel();
      _subscription = null;
    });
    return null;
  }

  void _onLogs(List<pb.LogMessage> events) {
    if (events.isEmpty) return;

    // logController emits the full rolling buffer each time. Core log
    // timestamps are not reliable on every platform, so keep an object cursor
    // into that rolling buffer instead of comparing protobuf time values.
    final start = _nextLogStartIndex(events);
    String? url;
    var done = false;
    var failed = false;
    for (var i = start; i < events.length; i++) {
      final msg = events[i];
      _lastProcessedLog = msg;
      final candidate = _classify(msg.message);
      if (candidate == null) continue;
      loggy.info(
        'captcha candidate: done=${candidate.done} failed=${candidate.failed} '
        'hasUrl=${candidate.url != null}',
      );
      if (!_armed) {
        if (candidate.done) {
          _deferredEvent = null;
        } else if (candidate.url != null) {
          _deferredEvent = CaptchaEvent(url: candidate.url!, createdAt: DateTime.now());
          loggy.info('captcha request deferred until watcher is armed');
        }
        continue;
      }
      if (candidate.done) {
        done = true;
        failed = candidate.failed;
        url = null;
      } else if (candidate.url != null) {
        url = candidate.url;
        done = false;
        failed = false;
      }
    }
    if (done) {
      loggy.info(
        'captcha terminal event=${failed ? 'failed' : 'resolved'} '
        'pending=${state != null}',
      );
      if (state != null) {
        loggy.info('captcha terminal; dismissing pending event');
        state = null;
      }
      return;
    }
    if (url != null && url != state?.url) {
      loggy.info('captcha terminal event=request stateChanged=true');
      state = CaptchaEvent(url: url, createdAt: DateTime.now());
    }
  }

  int _nextLogStartIndex(List<pb.LogMessage> events) {
    final previous = _lastProcessedLog;
    if (previous == null) return 0;
    for (var i = events.length - 1; i >= 0; i--) {
      if (identical(events[i], previous)) return i + 1;
    }
    return 0;
  }

  /// Examines a single log line and classifies it as either a captcha request
  /// (with a URL), a captcha-done sentinel, or unrelated. Several detection
  /// paths are tried in order from strictest to most permissive so that minor
  /// log-format changes downstream don't silently break the UI.
  _CaptchaCandidate? _classify(String text) {
    if (text.contains(_captchaFailedMarker)) {
      return const _CaptchaCandidate(done: true, failed: true);
    }
    if (text.contains(_captchaDoneMarker)) {
      return const _CaptchaCandidate(done: true);
    }
    // Strict marker we emit on purpose.
    final idx = text.indexOf(_captchaMarker);
    if (idx >= 0) {
      final extracted = _extractUrl(text.substring(idx));
      if (extracted != null) return _CaptchaCandidate(url: extracted);
    }
    // Permissive fallback: dialer logs the captcha URL on the local proxy
    // origin. If we see one in any log line, treat it as a request — we never
    // get those URLs in any other context.
    final loc = text.indexOf(_captchaLocalOrigin);
    if (loc >= 0) {
      final tail = text.substring(loc);
      // Skip the bare "local=http://localhost:8765" announcement — the
      // associated request line carries a path, not just the origin.
      if (tail.length > _captchaLocalOrigin.length && tail[_captchaLocalOrigin.length] == '/') {
        final end = _findUrlEnd(tail);
        return _CaptchaCandidate(url: end < 0 ? tail : tail.substring(0, end));
      }
    }
    return null;
  }

  /// Pulls the URL out of the `MARTEN_TURNCOAT_CAPTCHA url=<u>` marker, or
  /// any other log line that happens to carry the local captcha origin as
  /// the permissive fallback below relies on the same shape.
  String? _extractUrl(String text) {
    const key = 'url=';
    final idx = text.indexOf(key);
    if (idx < 0) return null;
    final tail = text.substring(idx + key.length);
    final end = _findUrlEnd(tail);
    final raw = end < 0 ? tail : tail.substring(0, end);
    if (raw.isEmpty) return null;
    return raw;
  }

  int _findUrlEnd(String s) {
    // URLs in our markers terminate at whitespace.
    for (var i = 0; i < s.length; i++) {
      final code = s.codeUnitAt(i);
      // ASCII whitespace: space, tab, CR, LF.
      if (code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D) {
        return i;
      }
    }
    return -1;
  }

  /// Acknowledge the active captcha request (e.g. user closed the WebView).
  /// Does not signal anything to the dialer — it tracks its own timeout.
  void dismiss() {
    if (state != null) state = null;
  }

  void arm({required bool enabled}) {
    _armed = enabled;
    if (!enabled) {
      _deferredEvent = null;
      _lastProcessedLog = ref.read(martenCoreServiceProvider).runtimeLogBuffer.lastOrNull;
      if (state != null) state = null;
      loggy.info('captcha watcher armed=false');
      return;
    }

    final deferred = _deferredEvent;
    _deferredEvent = null;
    if (deferred != null) {
      final age = DateTime.now().difference(deferred.createdAt);
      if (age <= _deferredCaptchaMaxAge) {
        loggy.info('replaying CAPTCHA request received while watcher was arming');
        state = deferred;
      } else {
        loggy.warning('discarding stale deferred CAPTCHA request age=${age.inSeconds}s');
      }
    }
    loggy.info('captcha watcher armed=$enabled');
  }

  void reset() {
    arm(enabled: false);
  }
}

class _CaptchaCandidate {
  const _CaptchaCandidate({this.url, this.done = false, this.failed = false});
  final String? url;
  final bool done;
  final bool failed;
}
