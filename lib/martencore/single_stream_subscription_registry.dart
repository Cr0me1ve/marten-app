import 'dart:async';

final class SingleStreamSubscriptionRegistry {
  final Map<String, _SubscriptionSlot> _slots = {};
  final Map<String, int> _generations = {};

  Map<String, StreamSubscription<dynamic>?> get subscriptions => {
    for (final entry in _slots.entries) entry.key: entry.value.subscription,
  };

  /// Completes when the exact subscription currently stored under [key] is
  /// removed, or when [cancelSignal] wins. This lets lifecycle owners wait for
  /// stream termination without polling the registry.
  Future<void> waitUntilRemoved(String key, {required Future<void> cancelSignal}) {
    final slot = _slots[key];
    if (slot == null) return Future<void>.value();
    return slot.waitUntilRemoved(cancelSignal);
  }

  Future<StreamSubscription<T>?> listen<T>(
    String key,
    Stream<T> Function() createStream, {
    void Function(T event)? onData,
    void Function(dynamic error)? onError,
    void Function()? onDone,
    bool cancelOnError = true,
  }) async {
    final generation = _nextGeneration(key);
    final previous = _slots.remove(key);
    previous?.markRemoved();
    await previous?.subscription?.cancel();
    if (_generations[key] != generation) return null;

    final slot = _SubscriptionSlot(generation);
    _slots[key] = slot;
    late final StreamSubscription<T> subscription;
    try {
      subscription = createStream().listen(
        onData,
        cancelOnError: cancelOnError,
        onError: (dynamic error) {
          if (!_owns(key, slot)) return;
          _slots.remove(key);
          slot.markRemoved();
          onError?.call(error);
          unawaited(slot.subscription?.cancel());
        },
        onDone: () {
          if (!_owns(key, slot)) return;
          _slots.remove(key);
          slot.markRemoved();
          onDone?.call();
        },
      );
    } catch (_) {
      if (_owns(key, slot)) {
        _slots.remove(key);
        slot.markRemoved();
      }
      rethrow;
    }
    slot.subscription = subscription;

    if (!_owns(key, slot)) {
      slot.markRemoved();
      await subscription.cancel();
      return null;
    }
    return subscription;
  }

  Future<void> stop(String keyPrefix) async {
    final keys = <String>{
      ..._slots.keys.where((key) => key.startsWith(keyPrefix)),
      ..._generations.keys.where((key) => key.startsWith(keyPrefix)),
    };
    for (final key in keys) {
      _nextGeneration(key);
      final slot = _slots.remove(key);
      slot?.markRemoved();
      await slot?.subscription?.cancel();
    }
  }

  int _nextGeneration(String key) {
    final generation = (_generations[key] ?? 0) + 1;
    _generations[key] = generation;
    return generation;
  }

  bool _owns(String key, _SubscriptionSlot slot) =>
      _generations[key] == slot.generation && identical(_slots[key], slot);
}

final class _SubscriptionSlot {
  _SubscriptionSlot(this.generation);

  final int generation;
  StreamSubscription<dynamic>? subscription;
  bool _removed = false;
  final Set<Completer<void>> _removalWaiters = {};

  Future<void> waitUntilRemoved(Future<void> cancelSignal) {
    if (_removed) return Future<void>.value();
    final waiter = Completer<void>();
    _removalWaiters.add(waiter);
    unawaited(
      cancelSignal.then((_) {
        _completeWaiter(waiter);
      }),
    );
    if (_removed) _completeWaiter(waiter);
    return waiter.future;
  }

  void markRemoved() {
    if (_removed) return;
    _removed = true;
    final waiters = _removalWaiters.toList(growable: false);
    _removalWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  void _completeWaiter(Completer<void> waiter) {
    _removalWaiters.remove(waiter);
    if (!waiter.isCompleted) waiter.complete();
  }
}
