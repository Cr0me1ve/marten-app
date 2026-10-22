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
const String _captchaLifecycleMarker = 'MARTEN_CAPTCHA_LIFECYCLE';

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

    // The controller may emit either an incremental immutable batch or a full
    // rolling buffer (including values injected by tests). Core timestamps are
    // not reliable on every platform, so keep an object cursor instead.
    final start = _nextLogStartIndex(events);
    for (var i = start; i < events.length; i++) {
      final msg = events[i];
      _lastProcessedLog = msg;
      final candidate = _classify(msg.message);
      if (candidate == null) continue;
      loggy.info(
        'captcha candidate: done=${candidate.done} failed=${candidate.failed} '
        'hasUrl=${candidate.url != null}',
      );
      loggy.info(
        '$_captchaLifecycleMarker event=notifier revision=${candidate.revision} '
        'outcome=${candidate.failed
            ? 'failed'
            : candidate.done
            ? 'resolved'
            : 'required'} armed=$_armed',
      );
      if (!_armed) {
        if (candidate.done) {
          if (_terminalMatches(candidate.revision, _deferredEvent?.revision)) {
            _deferredEvent = null;
          }
        } else if (candidate.url != null) {
          _deferredEvent = CaptchaEvent(url: candidate.url!, createdAt: DateTime.now(), revision: candidate.revision);
          loggy.info('captcha request deferred until watcher is armed');
          loggy.info('$_captchaLifecycleMarker event=notifier revision=${candidate.revision} outcome=deferred');
        }
        continue;
      }
      if (candidate.done) {
        final current = state;
        final matches = _terminalMatches(candidate.revision, current?.revision);
        loggy.info(
          'captcha terminal event=${candidate.failed ? 'failed' : 'resolved'} '
          'pending=${current != null} matches=$matches',
        );
        loggy.info(
          '$_captchaLifecycleMarker event=notifier revision=${candidate.revision} '
          'outcome=${candidate.failed ? 'failed' : 'resolved'} active_revision=${current?.revision ?? 0} '
          'matches=$matches',
        );
        if (current != null && matches) {
          loggy.info('captcha terminal; dismissing matching pending event');
          state = null;
        } else if (current != null) {
          loggy.warning('ignoring stale captcha terminal revision=${candidate.revision}');
        }
        continue;
      }
      final url = candidate.url;
      if (url == null) continue;
      final current = state;
      if (url != current?.url || candidate.revision != current?.revision) {
        loggy.info('captcha terminal event=request stateChanged=true revision=${candidate.revision}');
        loggy.info(
          '$_captchaLifecycleMarker event=notifier revision=${candidate.revision} outcome=published '
          'previous_revision=${current?.revision ?? 0}',
        );
        if (candidate.revision == 0) {
          // Keep legacy construction explicit for compatibility with older
          // cores and source-level embedding contracts.
          state = CaptchaEvent(url: url, createdAt: DateTime.now());
        } else {
          state = CaptchaEvent(url: url, createdAt: DateTime.now(), revision: candidate.revision);
        }
      }
    }
  }

  bool _terminalMatches(int terminalRevision, int? activeRevision) {
    if (activeRevision == null) return false;
    // Legacy cores publish zero for both REQUIRED and terminal markers. Once a
    // versioned REQUIRED is active, even an unversioned terminal is stale: it
    // must not close the replacement challenge.
    return terminalRevision == activeRevision;
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
    final revision = _extractRevision(text);
    if (text.contains(_captchaFailedMarker)) {
      return _CaptchaCandidate(done: true, failed: true, revision: revision);
    }
    if (text.contains(_captchaDoneMarker)) {
      return _CaptchaCandidate(done: true, revision: revision);
    }
    // Strict marker we emit on purpose.
    final idx = text.indexOf(_captchaMarker);
    if (idx >= 0) {
      final extracted = _extractUrl(text.substring(idx));
      if (extracted != null) return _CaptchaCandidate(url: extracted, revision: revision);
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
        return _CaptchaCandidate(url: end < 0 ? tail : tail.substring(0, end), revision: revision);
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

  int _extractRevision(String text) {
    // Core appends the revision after the URL. Use the final, whitespace-bound
    // field so a provider URL containing its own `revision=` query parameter
    // cannot impersonate the control-plane challenge identity.
    const key = ' revision=';
    final idx = text.lastIndexOf(key);
    if (idx < 0) return 0;
    final tail = text.substring(idx + key.length);
    var end = 0;
    while (end < tail.length) {
      final code = tail.codeUnitAt(end);
      if (code < 0x30 || code > 0x39) break;
      end++;
    }
    if (end == 0) return 0;
    final parsed = int.tryParse(tail.substring(0, end));
    return parsed != null && parsed > 0 ? parsed : 0;
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
    final revision = state?.revision ?? 0;
    if (state != null) state = null;
    loggy.info('$_captchaLifecycleMarker event=notifier revision=$revision outcome=dismissed');
  }

  void arm({required bool enabled}) {
    _armed = enabled;
    if (!enabled) {
      _deferredEvent = null;
      _lastProcessedLog = ref.read(martenCoreServiceProvider).runtimeLogBuffer.lastOrNull;
      if (state != null) state = null;
      loggy.info('captcha watcher armed=false');
      loggy.info('$_captchaLifecycleMarker event=notifier revision=0 outcome=disarmed');
      return;
    }

    final deferred = _deferredEvent;
    _deferredEvent = null;
    if (deferred != null) {
      final age = DateTime.now().difference(deferred.createdAt);
      if (age <= _deferredCaptchaMaxAge) {
        loggy.info('replaying CAPTCHA request received while watcher was arming');
        loggy.info('$_captchaLifecycleMarker event=notifier revision=${deferred.revision} outcome=replayed');
        state = deferred;
      } else {
        loggy.warning('discarding stale deferred CAPTCHA request age=${age.inSeconds}s');
        loggy.warning(
          '$_captchaLifecycleMarker event=notifier revision=${deferred.revision} outcome=deferred_expired '
          'age_seconds=${age.inSeconds}',
        );
      }
    }
    loggy.info('captcha watcher armed=$enabled');
    loggy.info('$_captchaLifecycleMarker event=notifier revision=${state?.revision ?? 0} outcome=armed');
  }

  void reset() {
    arm(enabled: false);
  }
}

class _CaptchaCandidate {
  const _CaptchaCandidate({this.url, this.done = false, this.failed = false, this.revision = 0});
  final String? url;
  final bool done;
  final bool failed;
  final int revision;
}
