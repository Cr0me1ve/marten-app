import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/martencore/single_stream_subscription_registry.dart';

void main() {
  test('late error from a replaced listener does not remove or cancel its replacement', () async {
    final registry = SingleStreamSubscriptionRegistry();
    addTearDown(() => registry.stop('core-status'));
    final oldStream = _LateSignalStream<int>();
    final newStream = _LateSignalStream<int>();
    var oldErrorCalls = 0;
    var newErrorCalls = 0;

    final oldSubscription = await registry.listen('core-status', () => oldStream, onError: (_) => oldErrorCalls++);
    final newSubscription = await registry.listen('core-status', () => newStream, onError: (_) => newErrorCalls++);
    final oldListener = await oldStream.subscription;
    final newListener = await newStream.subscription;

    expect(oldSubscription, same(oldListener));
    expect(oldListener.cancelCalls, 1);
    expect(newSubscription, same(newListener));

    oldListener.emitError(StateError('late old listener error'));
    await Future<void>.delayed(Duration.zero);

    expect(oldErrorCalls, 0);
    expect(newErrorCalls, 0);
    expect(registry.subscriptions['core-status'], same(newSubscription));
    expect(newListener.cancelCalls, 0);
  });

  test('late completion from an old listener cannot stop the replacement slot', () async {
    final registry = SingleStreamSubscriptionRegistry();
    addTearDown(() => registry.stop('core-status'));
    final oldStream = _LateSignalStream<int>();
    final newStream = _LateSignalStream<int>();
    var oldDoneCalls = 0;
    var newDoneCalls = 0;

    await registry.listen('core-status', () => oldStream, onDone: () => oldDoneCalls++);
    final newSubscription = await registry.listen('core-status', () => newStream, onDone: () => newDoneCalls++);
    final oldListener = await oldStream.subscription;
    final newListener = await newStream.subscription;

    oldListener.emitDone();
    await Future<void>.delayed(Duration.zero);

    expect(oldDoneCalls, 0);
    expect(newDoneCalls, 0);
    expect(registry.subscriptions['core-status'], same(newSubscription));
    expect(newListener.cancelCalls, 0);
  });

  test('waitUntilRemoved lets a lifecycle owner cancel its wait without tearing down the live listener', () async {
    final registry = SingleStreamSubscriptionRegistry();
    addTearDown(() => registry.stop('recovery-log'));
    final stream = _LateSignalStream<int>();
    final subscription = await registry.listen('recovery-log', () => stream);
    final listener = await stream.subscription;
    final cancellation = Completer<void>();

    final wait = registry.waitUntilRemoved('recovery-log', cancelSignal: cancellation.future);
    await _expectPending(wait);
    expect(listener.cancelCalls, 0);
    cancellation.complete();
    await wait;

    expect(
      registry.subscriptions['recovery-log'],
      same(subscription),
      reason: 'cancelling the waiter must not implicitly cancel the live stream',
    );
    expect(listener.cancelCalls, 0);
  });

  test('waitUntilRemoved completes when the registry removes the exact listener on stop', () async {
    final registry = SingleStreamSubscriptionRegistry();
    addTearDown(() => registry.stop('recovery-log'));
    final stream = _LateSignalStream<int>();
    await registry.listen('recovery-log', () => stream);
    final listener = await stream.subscription;

    final removalWait = registry.waitUntilRemoved('recovery-log', cancelSignal: Completer<void>().future);
    await _expectPending(removalWait);
    expect(listener.cancelCalls, 0);
    await registry.stop('recovery-log');
    await removalWait;

    expect(listener.cancelCalls, 1);
    expect(registry.subscriptions, isNot(contains('recovery-log')));
  });

  test('waitUntilRemoved completes for the exact replaced listener, not its replacement', () async {
    final registry = SingleStreamSubscriptionRegistry();
    addTearDown(() => registry.stop('recovery-log'));
    final oldStream = _LateSignalStream<int>();
    final newStream = _LateSignalStream<int>();
    await registry.listen('recovery-log', () => oldStream);
    final oldListener = await oldStream.subscription;
    final replacementWait = registry.waitUntilRemoved('recovery-log', cancelSignal: Completer<void>().future);
    await _expectPending(replacementWait);

    final newSubscription = await registry.listen('recovery-log', () => newStream);
    await replacementWait;

    expect(oldListener.cancelCalls, 1);
    expect(registry.subscriptions['recovery-log'], same(newSubscription));
    expect((await newStream.subscription).cancelCalls, 0);
  });
}

Future<void> _expectPending(Future<void> future) async {
  var completed = false;
  unawaited(future.then<void>((_) => completed = true));
  await Future<void>.delayed(Duration.zero);
  expect(completed, isFalse, reason: 'the waiter must remain pending until its signal wins');
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
