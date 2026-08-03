import 'dart:async';

final class SingleStreamSubscriptionRegistry {
  final Map<String, _SubscriptionSlot> _slots = {};
  final Map<String, int> _generations = {};

  Map<String, StreamSubscription<dynamic>?> get subscriptions => {
    for (final entry in _slots.entries) entry.key: entry.value.subscription,
  };

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
    await previous?.subscription?.cancel();
    if (_generations[key] != generation) return null;

    final slot = _SubscriptionSlot(generation);
    _slots[key] = slot;
    final subscription = createStream().listen(
      onData,
      cancelOnError: cancelOnError,
      onError: (dynamic error) {
        if (!_owns(key, slot)) return;
        onError?.call(error);
        _slots.remove(key);
        unawaited(slot.subscription?.cancel());
      },
      onDone: () {
        if (!_owns(key, slot)) return;
        onDone?.call();
        _slots.remove(key);
      },
    );
    slot.subscription = subscription;

    if (!_owns(key, slot)) {
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
}
