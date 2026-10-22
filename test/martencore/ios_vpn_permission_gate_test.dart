import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/martencore/core_interface/core_interface_mobile.dart';

void main() {
  group('IosVpnPermissionGate', () {
    test('waits beyond the old 30 second startup window for permission success', () {
      fakeAsync((async) {
        final gate = IosVpnPermissionGate();
        final permission = Completer<bool?>();
        bool? allowed;
        gate.prepare(() => permission.future).then((value) => allowed = value);

        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();
        expect(allowed, isNull);

        permission.complete(true);
        async.flushMicrotasks();
        expect(allowed, isTrue);
      });
    });

    test('resolves denial and a missing permission answer as false', () {
      fakeAsync((async) {
        final gate = IosVpnPermissionGate();
        final denied = Completer<bool?>();
        final unanswered = Completer<bool?>();
        bool? deniedResult;
        bool? unansweredResult;

        gate.prepare(() => denied.future).then((value) => deniedResult = value);
        denied.complete(false);
        async.flushMicrotasks();
        expect(deniedResult, isFalse);

        gate.prepare(() => unanswered.future).then((value) => unansweredResult = value);
        unanswered.complete(null);
        async.flushMicrotasks();
        expect(unansweredResult, isFalse);
      });
    });

    test('propagates a permission request error to its caller', () {
      fakeAsync((async) {
        final gate = IosVpnPermissionGate();
        final permission = Completer<bool?>();
        final failure = StateError('permission request failed');
        Object? resultError;

        gate
            .prepare(() => permission.future)
            .then<void>((_) {}, onError: (Object error, StackTrace stack) => resultError = error);
        permission.completeError(failure);
        async.flushMicrotasks();

        expect(resultError, same(failure));
      });
    });

    test('propagates a synchronous permission request throw to its caller', () {
      fakeAsync((async) {
        final gate = IosVpnPermissionGate();
        final failure = StateError('permission request threw synchronously');
        Object? resultError;

        gate
            .prepare(() => throw failure)
            .then<void>((_) {}, onError: (Object error, StackTrace stack) => resultError = error);
        async.flushMicrotasks();

        expect(resultError, same(failure));
      });
    });

    test('cancellation completes the pending caller immediately with false', () {
      fakeAsync((async) {
        final gate = IosVpnPermissionGate();
        final permission = Completer<bool?>();
        bool? result;

        gate.prepare(() => permission.future).then((value) => result = value);
        gate.cancel();
        async.flushMicrotasks();

        expect(result, isFalse);
        expect(permission.isCompleted, isFalse);
      });
    });

    test('late permission success after cancellation cannot change the result', () {
      fakeAsync((async) {
        final gate = IosVpnPermissionGate();
        final permission = Completer<bool?>();
        bool? result;

        gate.prepare(() => permission.future).then((value) => result = value);
        gate.cancel();
        async.flushMicrotasks();
        expect(result, isFalse);

        permission.complete(true);
        async.flushMicrotasks();
        expect(result, isFalse);
      });
    });

    test('late permission error after cancellation is consumed and cannot replace false', () {
      fakeAsync((async) {
        final gate = IosVpnPermissionGate();
        final permission = Completer<bool?>();
        bool? result;

        gate.prepare(() => permission.future).then((value) => result = value);
        gate.cancel();
        async.flushMicrotasks();
        expect(result, isFalse);

        permission.completeError(StateError('late permission error'));
        async.flushMicrotasks();
        expect(result, isFalse);
      });
    });

    test('replacing a waiter cancels it and late success cannot affect the new gate', () {
      fakeAsync((async) {
        final gate = IosVpnPermissionGate();
        final firstPermission = Completer<bool?>();
        final nextPermission = Completer<bool?>();
        bool? firstResult;
        bool? nextResult;

        gate.prepare(() => firstPermission.future).then((value) => firstResult = value);
        gate.prepare(() => nextPermission.future).then((value) => nextResult = value);
        async.flushMicrotasks();
        expect(firstResult, isFalse);
        expect(nextResult, isNull);

        firstPermission.complete(true);
        async.flushMicrotasks();
        expect(firstResult, isFalse);
        expect(nextResult, isNull);

        nextPermission.complete(true);
        async.flushMicrotasks();
        expect(nextResult, isTrue);
      });
    });
  });
}
