import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';

import 'package:marten/martencore/marten_core_service.dart';
import 'package:marten/singbox/model/core_status.dart';

void main() {
  const localShutdownErrors = [
    GrpcError.unavailable("background core is unavailable"),
    GrpcError.cancelled("request cancelled"),
    GrpcError.unknown('HTTP/2 stream forcefully terminated'),
  ];

  const unrelatedUnknownError = GrpcError.unknown('unrelated unknown failure unrelated to transport shutdown');
  final otherError = StateError('not a grpc error');

  group('classifyBackgroundObservationStreamError', () {
    test('returns finish for local shutdown while current state is terminal', () {
      for (final error in localShutdownErrors) {
        expect(
          classifyBackgroundObservationStreamError(
            error: error,
            observationClientRetired: false,
            currentState: const CoreStatus.stopping(),
            platformStatus: const CoreStatus.started(),
            disposed: false,
          ),
          BackgroundObservationStreamErrorAction.finish,
          reason: 'error: ${error.runtimeType}',
        );

        expect(
          classifyBackgroundObservationStreamError(
            error: error,
            observationClientRetired: false,
            currentState: const CoreStatus.stopped(),
            platformStatus: const CoreStatus.started(),
            disposed: false,
          ),
          BackgroundObservationStreamErrorAction.finish,
          reason: 'error: ${error.runtimeType}',
        );
      }
    });

    test('returns finish when lifecycle is terminal even if client is retired', () {
      for (final error in localShutdownErrors) {
        expect(
          classifyBackgroundObservationStreamError(
            error: error,
            observationClientRetired: true,
            currentState: const CoreStatus.stopping(),
            platformStatus: const CoreStatus.started(),
            disposed: false,
          ),
          BackgroundObservationStreamErrorAction.finish,
          reason: 'error: ${error.runtimeType}',
        );

        expect(
          classifyBackgroundObservationStreamError(
            error: error,
            observationClientRetired: true,
            currentState: const CoreStatus.stopped(),
            platformStatus: const CoreStatus.stopped(),
            disposed: false,
          ),
          BackgroundObservationStreamErrorAction.finish,
          reason: 'error: ${error.runtimeType}',
        );
      }
    });

    test(
      'does not finish for terminal platform snapshot when current lifecycle is active and client is not retired',
      () {
        for (final error in localShutdownErrors) {
          expect(
            classifyBackgroundObservationStreamError(
              error: error,
              observationClientRetired: false,
              currentState: const CoreStatus.started(),
              platformStatus: const CoreStatus.stopped(),
              disposed: false,
            ),
            BackgroundObservationStreamErrorAction.propagate,
            reason: 'error: ${error.runtimeType}',
          );
        }
      },
    );

    test('reattaches retired observation stream on active state with terminal platform snapshot', () {
      for (final error in localShutdownErrors) {
        expect(
          classifyBackgroundObservationStreamError(
            error: error,
            observationClientRetired: true,
            currentState: const CoreStatus.started(),
            platformStatus: const CoreStatus.stopped(),
            disposed: false,
          ),
          BackgroundObservationStreamErrorAction.reattach,
          reason: 'error: ${error.runtimeType}',
        );
      }
    });

    test('returns finish when disposed before classification even for active state', () {
      for (final error in localShutdownErrors) {
        expect(
          classifyBackgroundObservationStreamError(
            error: error,
            observationClientRetired: false,
            currentState: const CoreStatus.started(),
            platformStatus: const CoreStatus.started(),
            disposed: true,
          ),
          BackgroundObservationStreamErrorAction.finish,
          reason: 'error: ${error.runtimeType}',
        );
      }
    });

    test('returns reattach for local shutdown on retired observation client during active lifecycle', () {
      for (final error in localShutdownErrors) {
        for (final currentState in [const CoreStatus.started(), const CoreStatus.starting()]) {
          expect(
            classifyBackgroundObservationStreamError(
              error: error,
              observationClientRetired: true,
              currentState: currentState,
              platformStatus: const CoreStatus.started(),
              disposed: false,
            ),
            BackgroundObservationStreamErrorAction.reattach,
            reason: '$currentState / ${error.runtimeType}',
          );
        }
      }
    });

    test('returns propagate for local shutdown on current client while active', () {
      for (final error in localShutdownErrors) {
        for (final currentState in [const CoreStatus.started(), const CoreStatus.starting()]) {
          expect(
            classifyBackgroundObservationStreamError(
              error: error,
              observationClientRetired: false,
              currentState: currentState,
              platformStatus: const CoreStatus.started(),
              disposed: false,
            ),
            BackgroundObservationStreamErrorAction.propagate,
            reason: '$currentState / ${error.runtimeType}',
          );
        }
      }
    });

    test('returns propagate for unrelated UNKNOWN and non-gRPC errors even in terminal lifecycle', () {
      expect(
        classifyBackgroundObservationStreamError(
          error: unrelatedUnknownError,
          observationClientRetired: true,
          currentState: const CoreStatus.stopped(),
          platformStatus: const CoreStatus.stopping(),
          disposed: false,
        ),
        BackgroundObservationStreamErrorAction.propagate,
      );

      expect(
        classifyBackgroundObservationStreamError(
          error: otherError,
          observationClientRetired: true,
          currentState: const CoreStatus.stopped(),
          platformStatus: const CoreStatus.stopping(),
          disposed: false,
        ),
        BackgroundObservationStreamErrorAction.propagate,
      );
    });
  });
}
