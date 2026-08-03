import 'dart:async';

import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart' as pb;
import 'package:marten/martencore/marten_core_service_provider.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'turncoat_liveness_notifier.g.dart';

/// Whether runtime traffic has reached the TURNcoat transport, and whether at
/// least one of its sessions has been verified bidirectional ("promoted to
/// active TX pool" in dialer terms — a TCPR probe got a TCPA ack, or real RX
/// traffic was observed).
///
/// sing-box reports `Connected` as soon as the box is up, but for TURNcoat the
/// box being up doesn't mean the selected route is usable yet. UI uses this to
/// hold "Connecting" from the moment a TURNcoat-backed route is armed until a
/// stream is verified live.
class TurncoatLivenessState {
  const TurncoatLivenessState({
    this.inUse = false,
    this.live = false,
    this.routeActive = false,
    this.routeActivityCount = 0,
    this.timedOut = false,
  });

  /// True while the selected route uses TURNcoat for the current connection
  /// cycle. Set during arming so the UI cannot show `Connected` before the
  /// lazy outbound has solved captcha and produced a live stream.
  final bool inUse;

  /// True once at least one packet-conn session in the TURNcoat pool has been
  /// promoted to "active" (RX-verified). Survives transient session churn —
  /// only reset when the user disconnects.
  final bool live;

  /// True once the selected backend outbound itself has emitted runtime
  /// traffic. This is separate from [live]: a TURNcoat carrier can be healthy
  /// while the selected Hysteria/VLESS/WireGuard route is still warming up.
  final bool routeActive;

  /// Monotonic count of selected backend outbound traffic markers. Health
  /// checks use this to distinguish a fresh active probe from a stale startup
  /// marker when sing-box `urlTest` reports a timeout despite opening the
  /// selected TURNcoat-backed outbound.
  final int routeActivityCount;

  /// True when the selected TURNcoat route stayed in the pre-live state past
  /// the connection grace window.
  final bool timedOut;

  bool get isWaitingForLive => inUse && !live && !timedOut;

  TurncoatLivenessState copyWith({
    bool? inUse,
    bool? live,
    bool? routeActive,
    int? routeActivityCount,
    bool? timedOut,
  }) => TurncoatLivenessState(
    inUse: inUse ?? this.inUse,
    live: live ?? this.live,
    routeActive: routeActive ?? this.routeActive,
    routeActivityCount: routeActivityCount ?? this.routeActivityCount,
    timedOut: timedOut ?? this.timedOut,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TurncoatLivenessState &&
          other.inUse == inUse &&
          other.live == live &&
          other.routeActive == routeActive &&
          other.routeActivityCount == routeActivityCount &&
          other.timedOut == timedOut;

  @override
  int get hashCode => Object.hash(inUse, live, routeActive, routeActivityCount, timedOut);
}

/// Tracks whether the selected route uses the TURNcoat transport and scans the
/// marten-core log stream for activity markers emitted by the dialer
/// (`log.Printf` lines from `TURNcoat/dialer/session_health.go` and the
/// sing-box turncoat outbound).
///
/// The notifier is armed explicitly from the prepared selected route, not from
/// the raw config dump. Subscriptions may contain hidden TURNcoat helpers for
/// servers the user did not select, so merely seeing `"type":"turncoat"` in the
/// config is not enough.
///
/// Two runtime log shapes are matched:
///
///   - `turncoat: opening (stream|packet conn|packet association) ...`
///     and `turncoat: dialer ready` — marten-sing-box `outbound/turncoat.go`
///     logs these once traffic actually reaches the outbound.
///   - `[session N] promoted to active TX pool ...` — emitted from
///     `dialer/session_health.go` via `markRx` / `markProbeAck` when a
///     session is verified bidirectional. First match flips [live] true.
///
/// Both reach Flutter via `installCaptchaBridge` in marten-core
/// (`stdlog.SetOutput` for the dialer's stdlib `log.Printf`) and via the
/// sing-box `LogInterface.WriteMessage` → `logObserver` chain for the rest.
/// If the promotion string changes downstream, TURNcoat connections may stay
/// in "Connecting" until this detector is updated.
@Riverpod(keepAlive: true)
class TurncoatLivenessNotifier extends _$TurncoatLivenessNotifier with InfraLogger {
  static const connectTimeout = Duration(seconds: 75);

  StreamSubscription<List<pb.LogMessage>>? _logSub;
  pb.LogMessage? _lastProcessedLog;
  bool _armedForTurncoat = false;
  String? _selectedTag;
  Timer? _connectTimer;
  Completer<TurncoatLivenessState>? _startupWaiter;
  Completer<TurncoatLivenessState>? _startupRouteEvidenceWaiter;

  @override
  TurncoatLivenessState build() {
    final core = ref.watch(martenCoreServiceProvider);
    _lastProcessedLog = core.runtimeLogBuffer.lastOrNull;
    _logSub = core.runtimeLogController.stream.listen(_onLogs);

    ref.onDispose(() {
      _logSub?.cancel();
      _logSub = null;
      _connectTimer?.cancel();
      _connectTimer = null;
      _completeStartupWaiter(const TurncoatLivenessState());
      _completeStartupRouteEvidenceWaiter(const TurncoatLivenessState());
    });
    return const TurncoatLivenessState();
  }

  void arm({required bool inUse, String? selectedTag}) {
    // A reconnect starts a new liveness generation. Release waiters owned by
    // the previous generation before replacing its state so an old startup
    // operation cannot share the new generation's completion signal.
    _completeStartupWaiter(state);
    _completeStartupRouteEvidenceWaiter(state);
    _connectTimer?.cancel();
    _connectTimer = null;
    _armedForTurncoat = inUse;
    _selectedTag = inUse ? selectedTag : null;
    _lastProcessedLog = ref.read(martenCoreServiceProvider).runtimeLogBuffer.lastOrNull;
    final next = TurncoatLivenessState(inUse: inUse);
    loggy.info('turncoat liveness: armed inUse=$inUse selectedTag=$_selectedTag');
    if (state != next) state = next;
    _completeStartupWaiterIfTerminal();
    if (inUse) {
      _connectTimer = Timer(connectTimeout, _markTimedOut);
    }
  }

  void reset() {
    _reset();
  }

  Future<TurncoatLivenessState> waitForLiveOrTerminal() {
    final current = state;
    if (isTerminalTurncoatStartupWaitState(current, armedForTurncoat: _armedForTurncoat)) {
      return Future.value(current);
    }
    final waiter = _startupWaiter ??= Completer<TurncoatLivenessState>();
    return waiter.future;
  }

  /// Current state of the armed generation. Startup verification uses this
  /// after an active probe finishes so it does not wait again for an event
  /// that was already observed while the probe was running.
  TurncoatLivenessState get currentState => state;

  /// Waits for the stronger startup signal used when the active URL probe is
  /// inconclusive: both a live TURNcoat carrier and traffic emitted by the
  /// selected backend in the current armed generation.
  Future<TurncoatLivenessState> waitForLiveSelectedRouteOrTerminal() {
    final current = state;
    if (isTerminalTurncoatStartupRouteWaitState(current, armedForTurncoat: _armedForTurncoat)) {
      return Future.value(current);
    }
    final waiter = _startupRouteEvidenceWaiter ??= Completer<TurncoatLivenessState>();
    return waiter.future;
  }

  void cancelStartupRouteEvidenceWait() {
    _completeStartupRouteEvidenceWaiter(state);
  }

  Future<TurncoatLivenessState> waitForFreshRouteActivity(
    int previousRouteActivityCount, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final current = state;
      if (current.routeActivityCount > previousRouteActivityCount || current.timedOut || !current.inUse) {
        return current;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return current;
      final nextDelay = remaining < const Duration(milliseconds: 100) ? remaining : const Duration(milliseconds: 100);
      await Future<void>.delayed(nextDelay);
    }
  }

  void _onLogs(List<pb.LogMessage> events) {
    if (events.isEmpty) return;
    // logController emits the full rolling buffer each time. Core log
    // timestamps are not reliable on every platform, so keep an object cursor
    // into that rolling buffer instead of comparing protobuf time values.
    final start = _nextLogStartIndex(events);
    var nextInUse = state.inUse;
    var nextLive = state.live;
    var nextRouteActive = state.routeActive;
    var nextRouteActivityCount = state.routeActivityCount;
    final selectedTag = _selectedTag;
    for (var i = start; i < events.length; i++) {
      final msg = events[i];
      _lastProcessedLog = msg;
      if (!_armedForTurncoat && !nextInUse) continue;
      final line = msg.message;
      if (!nextInUse && isTurncoatInUseLogLine(line)) {
        nextInUse = true;
        loggy.info('turncoat liveness: in-use detected ($line)');
      }
      final backendRx = selectedTag != null && isTurncoatBackendRxLogLine(line);
      if (!nextLive && isTurncoatPromotedLogLine(line)) {
        nextLive = true;
        nextInUse = true;
        loggy.info('turncoat liveness: stream promoted to active ($line)');
      }
      if (backendRx || (selectedTag != null && isSelectedOutboundActivityLogLine(line, selectedTag))) {
        nextRouteActivityCount++;
        if (!nextRouteActive) {
          loggy.info('turncoat liveness: selected route active ($line)');
        }
        nextRouteActive = true;
        nextInUse = true;
      }
    }
    if (nextInUse != state.inUse ||
        nextLive != state.live ||
        nextRouteActive != state.routeActive ||
        nextRouteActivityCount != state.routeActivityCount) {
      state = state.copyWith(
        inUse: nextInUse,
        live: nextLive,
        routeActive: nextRouteActive,
        routeActivityCount: nextRouteActivityCount,
        timedOut: state.timedOut && !nextLive,
      );
      _completeStartupWaiterIfTerminal();
      _completeStartupRouteEvidenceWaiterIfTerminal();
    }
    if (state.live) {
      _connectTimer?.cancel();
      _connectTimer = null;
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

  void _reset() {
    _connectTimer?.cancel();
    _connectTimer = null;
    _armedForTurncoat = false;
    _selectedTag = null;
    if (state.inUse || state.live || state.routeActive || state.timedOut) {
      loggy.info('turncoat liveness: resetting on disconnect');
      state = const TurncoatLivenessState();
    }
    _completeStartupWaiterIfTerminal();
    _completeStartupRouteEvidenceWaiterIfTerminal();
    // Skip log history accumulated before the next connect attempt so a stale
    // "promoted to active" line from the previous session can't satisfy the
    // gate of the next one.
    _lastProcessedLog = ref.read(martenCoreServiceProvider).runtimeLogBuffer.lastOrNull;
  }

  void _markTimedOut() {
    _connectTimer = null;
    if (!_armedForTurncoat || state.live || state.timedOut) return;
    loggy.warning('turncoat liveness: timed out after ${connectTimeout.inSeconds}s');
    state = state.copyWith(timedOut: true);
    _completeStartupWaiterIfTerminal();
    _completeStartupRouteEvidenceWaiterIfTerminal();
  }

  void _completeStartupWaiterIfTerminal() {
    if (!isTerminalTurncoatStartupWaitState(state, armedForTurncoat: _armedForTurncoat)) return;
    _completeStartupWaiter(state);
  }

  void _completeStartupWaiter(TurncoatLivenessState value) {
    final waiter = _startupWaiter;
    if (waiter == null) return;
    _startupWaiter = null;
    if (!waiter.isCompleted) waiter.complete(value);
  }

  void _completeStartupRouteEvidenceWaiterIfTerminal() {
    if (!isTerminalTurncoatStartupRouteWaitState(state, armedForTurncoat: _armedForTurncoat)) return;
    _completeStartupRouteEvidenceWaiter(state);
  }

  void _completeStartupRouteEvidenceWaiter(TurncoatLivenessState value) {
    final waiter = _startupRouteEvidenceWaiter;
    if (waiter == null) return;
    _startupRouteEvidenceWaiter = null;
    if (!waiter.isCompleted) waiter.complete(value);
  }
}

bool isTerminalTurncoatLivenessState(TurncoatLivenessState state) => !state.inUse || state.live || state.timedOut;

bool isTerminalTurncoatStartupWaitState(TurncoatLivenessState state, {required bool armedForTurncoat}) {
  if (state.live || state.timedOut) return true;
  if (armedForTurncoat) return false;
  return !state.inUse;
}

bool isTerminalTurncoatStartupRouteWaitState(TurncoatLivenessState state, {required bool armedForTurncoat}) {
  if (state.timedOut || (state.live && state.routeActive)) return true;
  if (armedForTurncoat) return false;
  return !state.inUse;
}

bool isTurncoatInUseLogLine(String line) {
  // marten-sing-box outbound/turncoat.go logs these on each real
  // DialContext/ListenPacket call. Do not infer usage from the config dump:
  // subscriptions may contain hidden TURNcoat helpers for other servers.
  return line.contains('turncoat: opening stream') ||
      line.contains('turncoat: opening packet conn') ||
      line.contains('turncoat: opening packet association') ||
      line.contains('turncoat: dialer ready') ||
      line.contains('[turncoat] live streams') ||
      line.contains('[Captcha]') ||
      line.contains('MARTEN_TURNCOAT_CAPTCHA') ||
      line.contains('[packet session') ||
      line.contains('[Call Auth]');
}

final _turncoatLiveStreamsReadyPattern = RegExp(r'\[turncoat\] live streams .*\b(?:active|ready)=([1-9]\d*)\b');

bool isTurncoatPromotedLogLine(String line) {
  // TURNcoat/dialer/session_health.go logs this verbatim on first transition
  // probing -> active. We don't care which session, just that at least one in
  // the pool is verified.
  return line.contains('promoted to active TX pool') || _turncoatLiveStreamsReadyPattern.hasMatch(line);
}

/// A real packet returned by the configured UDP backend through TURNcoat.
/// This is stronger than a TCPA probe ack: the dialer emits this exact marker
/// only after excluding keepalives and probe acknowledgements and immediately
/// before forwarding the packet to the selected backend client (Hysteria2,
/// WireGuard, etc.). It is therefore valid fresh selected-route evidence for
/// the currently armed TURNcoat generation.
bool isTurncoatBackendRxLogLine(String line) => line.contains('promoted to active TX pool (RX proof received)');

bool isSelectedOutboundActivityLogLine(String line, String selectedTag) {
  if (selectedTag.isEmpty) return false;
  return line.contains('outbound/') &&
      line.contains('[$selectedTag]') &&
      (line.contains('outbound connection to') || line.contains('outbound packet connection to'));
}
