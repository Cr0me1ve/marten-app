import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _strictVpnNativeMethodChannel = MethodChannel('app.marten.client/method');

typedef StrictVpnEgressRetirer = FutureOr<void> Function();

/// A passive admission boundary for work that is safe to defer across an
/// Android VPN transition. It never opens the gate itself; only the exact
/// native route/terminal owner can complete the wait.
abstract interface class StrictVpnEgressAdmission {
  Future<T> runWhenAdmitted<T>(String operation, Future<T> Function() action);
}

/// Expected rejection when an ordinary operation races a strict VPN
/// transition. Callers that expose optional diagnostics may treat this as
/// cancellation; real network failures from an admitted operation still
/// propagate normally.
final class StrictVpnEgressSealedException implements Exception {
  const StrictVpnEgressSealedException(this.operation);

  final String operation;

  @override
  String toString() => 'ordinary network operation rejected during strict VPN transition: $operation';
}

final class _ActiveEgressOperation {
  _ActiveEgressOperation(this.retire);

  final StrictVpnEgressRetirer? retire;
  final completion = Completer<void>();
}

/// Process-local barrier for ordinary Dart networking around Android VPN
/// admission and teardown.
///
/// Android's process network binding only affects sockets created after the
/// bind. Before the native service installs its full-route blocker, this gate
/// first rejects new ordinary requests, force-retires registered connection
/// pools, and waits for every already admitted operation to settle. Native
/// transport/control sockets are outside this gate: the platform binds and
/// protects those descriptors explicitly.
final strictVpnEgressGate = StrictVpnEgressGate._();

final class StrictVpnEgressGate implements StrictVpnEgressAdmission {
  StrictVpnEgressGate._();

  final Map<Object, StrictVpnEgressRetirer> _retirers = <Object, StrictVpnEgressRetirer>{};
  final Set<_ActiveEgressOperation> _activeOperations = <_ActiveEgressOperation>{};

  bool _sealed = false;
  Completer<void>? _admissionWaiter;
  Future<void>? _sealOperation;
  Future<void> _transitionOperation = Future<void>.value();
  int _transitionEpoch = 0;
  int? _nativeBlockEpoch;

  bool get _applies => !kIsWeb && Platform.isAndroid;
  bool get isSealed => _applies && _sealed;

  void registerRetirer(Object owner, StrictVpnEgressRetirer retire) {
    _retirers[owner] = retire;
  }

  void unregisterRetirer(Object owner) {
    _retirers.remove(owner);
  }

  Future<T> run<T>(String operation, Future<T> Function() action, {StrictVpnEgressRetirer? retire}) async {
    if (!_applies) return action();
    if (_sealed) {
      throw StrictVpnEgressSealedException(operation);
    }

    return await _runAdmitted(action, retire: retire);
  }

  /// Queues coalescible work behind the current exact transition instead of
  /// turning an expected fail-closed window into a product error. The check
  /// and operation registration are synchronous within one Dart-isolate turn,
  /// so a new seal either precedes this lease or drains it as an active owner.
  @override
  Future<T> runWhenAdmitted<T>(String operation, Future<T> Function() action) async {
    if (!_applies) return action();
    while (_sealed) {
      final waiter = _admissionWaiter ??= Completer<void>();
      await waiter.future;
    }
    return _runAdmitted(action);
  }

  Future<T> _runAdmitted<T>(Future<T> Function() action, {StrictVpnEgressRetirer? retire}) async {
    final activeOperation = _ActiveEgressOperation(retire);
    _activeOperations.add(activeOperation);
    try {
      // The Dart isolate cannot interleave sealForVpnTransition() between the
      // check above and registration in _activeOperations. Once registered,
      // sealing waits for this exact operation before native admission.
      return await action();
    } finally {
      _activeOperations.remove(activeOperation);
      if (!activeOperation.completion.isCompleted) activeOperation.completion.complete();
    }
  }

  Future<void> sealForVpnTransition() {
    if (!_applies) return Future<void>.value();
    _transitionEpoch += 1;
    if (!_sealed) _admissionWaiter = Completer<void>();
    _sealed = true;
    final activeSeal = _sealOperation;
    if (activeSeal != null) return activeSeal;

    final operation = _serializeTransition(_retireAndDrain);
    _sealOperation = operation;
    return operation.whenComplete(() {
      if (identical(_sealOperation, operation)) _sealOperation = null;
    });
  }

  Future<void> _retireAndDrain() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      // Flutter engines have isolate-local registries, while native TLS/ICMP
      // probes are process-wide. Always close and drain that native admission
      // first so a detached engine's physical socket cannot outlive Connect.
      // This runs only on a transition; it creates no timer or background work.
      await _strictVpnNativeMethodChannel.invokeMethod<int>('cancel_local_probes', <String, Object?>{
        'keepBlocked': true,
      });
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    for (final retire in List<StrictVpnEgressRetirer>.of(_retirers.values)) {
      try {
        await Future<void>.sync(retire);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    // Operations with process-external resources (raw sockets, native probes,
    // queued work) must be actively retired before the physical VPN blocker is
    // admitted. Merely awaiting their normal timeout would permit direct
    // traffic and prolong CPU/radio activity after the user pressed Connect.
    for (final operation in List<_ActiveEgressOperation>.of(_activeOperations)) {
      final retire = operation.retire;
      if (retire == null) continue;
      try {
        await Future<void>.sync(retire);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    while (_activeOperations.isNotEmpty) {
      final snapshot = List<Future<void>>.of(_activeOperations.map((operation) => operation.completion.future));
      await Future.wait(snapshot);
    }
    try {
      // Retirers may themselves strengthen the process-wide native seal. Take
      // one final exact epoch after every drain so an older Flutter engine can
      // never reopen TLS/ICMP admission after a newer transition started.
      final nativeBlockEpoch = await _strictVpnNativeMethodChannel.invokeMethod<int>(
        'cancel_local_probes',
        <String, Object?>{'keepBlocked': true},
      );
      if (nativeBlockEpoch == null) {
        throw StateError('native local-probe seal did not return an ownership epoch');
      }
      _nativeBlockEpoch = nativeBlockEpoch;
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace ?? StackTrace.current);
    }
  }

  /// Opens ordinary Dart networking only after Android has acknowledged a
  /// current-generation VPN data-plane proof and bound the process to it.
  Future<bool> admitVerifiedVpnRoute() {
    // A late Flutter engine can join an already admitted native Started route
    // before it ever creates a Dart-side seal. Admission is idempotent in that
    // state; the native preflight in bootstrap supplied the exact proof.
    if (_applies && !_sealed) return Future<bool>.value(true);
    return _openForCurrentTransition(refreshNativeBlockEpoch: false);
  }

  /// A completed terminal Disconnect may release the Dart-side barrier. The
  /// native release predicate independently proves that the service, TUN and
  /// platform Network ownership are terminal before physical networking is
  /// admitted again. Reacquire the process-wide native block epoch here: a
  /// detached Flutter engine or native lifecycle transition may have
  /// strengthened the seal after this isolate cached its previous epoch.
  Future<bool> releaseAfterTerminalDisconnect() => _openForCurrentTransition(refreshNativeBlockEpoch: true);

  Future<bool> _openForCurrentTransition({required bool refreshNativeBlockEpoch}) {
    if (!_applies) return Future<bool>.value(true);
    final expectedEpoch = _transitionEpoch;
    return _serializeTransition(() async {
      if (expectedEpoch != _transitionEpoch) return false;
      var nativeBlockEpoch = _nativeBlockEpoch;
      if (refreshNativeBlockEpoch) {
        nativeBlockEpoch = await _strictVpnNativeMethodChannel.invokeMethod<int>(
          'cancel_local_probes',
          <String, Object?>{'keepBlocked': true},
        );
        if (nativeBlockEpoch == null || expectedEpoch != _transitionEpoch) return false;
        _nativeBlockEpoch = nativeBlockEpoch;
      }
      if (nativeBlockEpoch == null) return false;
      final allowed = await _strictVpnNativeMethodChannel.invokeMethod<bool>('allow_local_probes', <String, Object?>{
        'blockEpoch': nativeBlockEpoch,
      });
      if (allowed != true) return false;
      if (expectedEpoch != _transitionEpoch) {
        _nativeBlockEpoch = await _strictVpnNativeMethodChannel.invokeMethod<int>(
          'cancel_local_probes',
          <String, Object?>{'keepBlocked': true},
        );
        return false;
      }
      _sealed = false;
      _nativeBlockEpoch = null;
      final waiter = _admissionWaiter;
      _admissionWaiter = null;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
      return true;
    });
  }

  Future<T> _serializeTransition<T>(Future<T> Function() operation) {
    final run = _transitionOperation.then<T>((_) => operation());
    _transitionOperation = run.then<void>((_) {}, onError: (_, _) {});
    return run;
  }
}
