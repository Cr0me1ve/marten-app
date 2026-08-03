import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/martencore/single_stream_subscription_registry.dart';

void main() {
  test('late error from a replaced listener does not remove or cancel its replacement', () async {
    final registry = SingleStreamSubscriptionRegistry();
    final oldStream = _LateSignalStream<int>();
    final newStream = _LateSignalStream<int>();

    final oldSubscription = await registry.listen('core-status', () => oldStream);
    final newSubscription = await registry.listen('core-status', () => newStream);
    final oldListener = await oldStream.subscription;
    final newListener = await newStream.subscription;

    expect(oldSubscription, same(oldListener));
    expect(oldListener.cancelCalls, 1);
    expect(newSubscription, same(newListener));

    oldListener.emitError(StateError('late old listener error'));
    await Future<void>.delayed(Duration.zero);

    expect(registry.subscriptions['core-status'], same(newSubscription));
    expect(newListener.cancelCalls, 0);
    await newListener.cancel();
    await oldListener.cancel();
  });

  test('late completion from an old listener cannot stop the replacement slot', () async {
    final registry = SingleStreamSubscriptionRegistry();
    final oldStream = _LateSignalStream<int>();
    final newStream = _LateSignalStream<int>();

    await registry.listen('core-status', () => oldStream);
    final newSubscription = await registry.listen('core-status', () => newStream);
    final oldListener = await oldStream.subscription;
    final newListener = await newStream.subscription;

    oldListener.emitDone();
    await Future<void>.delayed(Duration.zero);

    expect(registry.subscriptions['core-status'], same(newSubscription));
    expect(newListener.cancelCalls, 0);
    await newListener.cancel();
    await oldListener.cancel();
  });
}

final class _LateSignalStream<T> extends Stream<T> {
  final Completer<_LateSignalSubscription<T>> _subscription = Completer<_LateSignalSubscription<T>>();

  Future<_LateSignalSubscription<T>> get subscription => _subscription.future;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final listener = _LateSignalSubscription<T>(onError: onError, onDone: onDone);
    _subscription.complete(listener);
    return listener;
  }
}

final class _LateSignalSubscription<T> implements StreamSubscription<T> {
  _LateSignalSubscription({Function? onError, void Function()? onDone})
    : _onError = _errorHandler(onError),
      _onDone = onDone;

  void Function(Object error)? _onError;
  void Function()? _onDone;
  int cancelCalls = 0;

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  void emitError(Object error) {
    final onError = _onError;
    if (onError != null) onError(error);
  }

  void emitDone() => _onDone?.call();

  @override
  Future<E> asFuture<E>([E? futureValue]) => futureValue == null ? Completer<E>().future : Future<E>.value(futureValue);

  @override
  bool get isPaused => false;

  @override
  void onData(void Function(T data)? handleData) {}

  @override
  void onDone(void Function()? handleDone) {
    _onDone = handleDone;
  }

  @override
  void onError(Function? handleError) {
    _onError = _errorHandler(handleError);
  }

  @override
  void pause([Future<void>? resumeSignal]) {}

  @override
  void resume() {}

  static void Function(Object error)? _errorHandler(Function? handler) {
    if (handler == null) return null;
    return (Object error) => Function.apply(handler, [error]);
  }
}
