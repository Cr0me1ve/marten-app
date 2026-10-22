import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:marten/martencore/core_interface/core_interface.dart';
import 'package:marten/martencore/generated/v2/hcommon/common.pb.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:marten/martencore/marten_core_service.dart';
import 'package:marten/singbox/model/core_status.dart';

class _ObservationRpcService extends CoreServiceBase {
  final groupEvents = StreamController<OutboundGroupList>.broadcast();
  final groupCallsEvents = StreamController<int>.broadcast();
  final activeGroupEvents = StreamController<OutboundGroupList>.broadcast();
  final groupOpened = Completer<void>();
  final activeGroupsOpened = Completer<void>();
  final activeGroupsCancelled = Completer<void>();
  int activeGroupsCalls = 0;
  int groupCalls = 0;

  _ObservationRpcService() {
    activeGroupEvents.onCancel = () {
      if (!activeGroupsCancelled.isCompleted) activeGroupsCancelled.complete();
    };
  }

  @override
  Stream<OutboundGroupList> outboundsInfo(ServiceCall call, Empty request) {
    groupCalls++;
    groupCallsEvents.add(groupCalls);
    if (!groupOpened.isCompleted) groupOpened.complete();
    return groupEvents.stream;
  }

  @override
  Stream<OutboundGroupList> mainOutboundsInfo(ServiceCall call, Empty request) {
    activeGroupsCalls++;
    if (!activeGroupsOpened.isCompleted) activeGroupsOpened.complete();
    return activeGroupEvents.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Future<void> close() async {
    await groupEvents.close();
    await groupCallsEvents.close();
    await activeGroupEvents.close();
  }
}

class _ObservationEndpoint {
  _ObservationEndpoint._(this.service, this.server, this.channel, this.client);

  final _ObservationRpcService service;
  final Server server;
  final ClientChannel channel;
  final CoreClient client;

  static Future<_ObservationEndpoint> start() async {
    final service = _ObservationRpcService();
    final server = Server.create(services: [service]);
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    final channel = ClientChannel(
      '127.0.0.1',
      port: server.port!,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    return _ObservationEndpoint._(service, server, channel, CoreClient(channel));
  }

  Future<void> close() async {
    await channel.terminate();
    await server.shutdown();
    unawaited(service.close());
  }
}

class _ObservationCore extends CoreInterface {
  _ObservationCore(CoreClient client) {
    fgClient = client;
    bgClient = client;
  }

  @override
  bool isInitialized() => true;

  int platformStatusReadCalls = 0;
  Future<CoreStatus?> Function()? readPlatformStatus;
  final statusEvents = StreamController<CoreStatus>.broadcast();
  int statusWatchCalls = 0;
  void Function()? onStatusWatch;

  @override
  Future<CoreStatus?> readPlatformServiceStatus() async {
    platformStatusReadCalls++;
    return readPlatformStatus?.call();
  }

  @override
  Stream<CoreStatus> watchServiceStatus() {
    statusWatchCalls++;
    onStatusWatch?.call();
    return statusEvents.stream;
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 10));

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

  group('background observation streams', () {
    late ProviderContainer container;
    late _ObservationEndpoint first;
    late _ObservationEndpoint replacement;
    late _ObservationCore core;
    late MartenCoreService service;
    late List<StreamSubscription<dynamic>> subscriptions;

    setUp(() async {
      first = await _ObservationEndpoint.start();
      replacement = await _ObservationEndpoint.start();
      core = _ObservationCore(first.client);
      final provider = Provider<MartenCoreService>((ref) => MartenCoreService(ref, core: core));
      container = ProviderContainer();
      service = container.read(provider);
      service.currentState = const CoreStatus.started();
      subscriptions = [];
    });

    tearDown(() async {
      unawaited(first.service.close());
      unawaited(replacement.service.close());
      await Future.wait(subscriptions.map((subscription) => subscription.cancel())).timeout(const Duration(seconds: 2));
      await service.dispose();
      container.dispose();
      await core.statusEvents.close();
      await first.close();
      await replacement.close();
    });

    test('watchActiveGroups reattaches a retired active client after its local stream shutdown', () async {
      final values = <List<OutboundGroup>>[];
      final errors = <Object>[];
      final replacementValue = Completer<void>();
      final subscription = service.watchActiveGroups().listen((value) {
        values.add(value);
        if (value.any((group) => group.tag == 'replacement') && !replacementValue.isCompleted) {
          replacementValue.complete();
        }
      }, onError: errors.add);
      subscriptions.add(subscription);

      await first.service.activeGroupsOpened.future.timeout(const Duration(seconds: 2));
      core.bgClient = replacement.client;
      first.service.activeGroupEvents.addError(const GrpcError.cancelled('retired observation client'));

      await replacement.service.activeGroupsOpened.future.timeout(const Duration(seconds: 2));
      replacement.service.activeGroupEvents.add(OutboundGroupList(items: [OutboundGroup(tag: 'replacement')]));
      await replacementValue.future.timeout(const Duration(seconds: 2));

      expect(errors, isEmpty);
      expect(values.last.single.tag, 'replacement');
    });

    test('watchGroup finishes without an error when a local shutdown arrives during terminal lifecycle', () async {
      final done = Completer<void>();
      final errors = <Object>[];
      final subscription = service.watchGroup().listen((_) {}, onError: errors.add, onDone: done.complete);
      subscriptions.add(subscription);

      await first.service.groupOpened.future.timeout(const Duration(seconds: 2));
      service.currentState = const CoreStatus.stopped();
      first.service.groupEvents.addError(const GrpcError.cancelled('terminal observation shutdown'));

      await done.future.timeout(const Duration(seconds: 2));
      expect(errors, isEmpty);
    });

    test('waits for a delayed fresh native Starting snapshot before finishing transport error', () async {
      final freshStatus = Completer<CoreStatus?>();
      final queryStarted = Completer<void>();
      core.readPlatformStatus = () {
        if (!queryStarted.isCompleted) queryStarted.complete();
        return freshStatus.future;
      };
      final done = Completer<void>();
      final errors = <Object>[];
      final subscription = service.watchGroup().listen((_) {}, onError: errors.add, onDone: done.complete);
      subscriptions.add(subscription);

      await first.service.groupOpened.future.timeout(const Duration(seconds: 2));
      first.service.groupEvents.addError(const GrpcError.unknown('HTTP/2 stream forcefully terminated'));
      await queryStarted.future.timeout(const Duration(seconds: 2));
      expect(errors, isEmpty, reason: 'the original transport error stays pending during reconciliation');
      expect(done.isCompleted, isFalse);

      freshStatus.complete(const CoreStatus.starting());
      await done.future.timeout(const Duration(seconds: 2));

      expect(errors, isEmpty);
      expect(core.platformStatusReadCalls, 1);
    });

    test('finishes when fresh native status is Starting, Stopping, or Stopped', () async {
      final confirmedStatuses = <CoreStatus>[
        const CoreStatus.starting(),
        const CoreStatus.stopping(),
        const CoreStatus.stopped(),
      ];

      for (var index = 0; index < confirmedStatuses.length; index++) {
        final done = Completer<void>();
        final errors = <Object>[];
        final expectedGroupCall = index + 1;
        final opened = first.service.groupCallsEvents.stream.firstWhere((calls) => calls >= expectedGroupCall);
        final subscription = service.watchGroup().listen((_) {}, onError: errors.add, onDone: done.complete);
        subscriptions.add(subscription);
        await opened.timeout(const Duration(seconds: 2));
        core.readPlatformStatus = () async => confirmedStatuses[index];
        first.service.groupEvents.addError(const GrpcError.unknown('HTTP/2 stream forcefully terminated'));
        await done.future.timeout(const Duration(seconds: 2));

        expect(errors, isEmpty, reason: 'confirmed $confirmedStatuses[index] is a native lifecycle transition');
      }

      expect(core.platformStatusReadCalls, 3);
    });

    test('waits for Starting event and a second authoritative Starting snapshot', () async {
      final statusWatchStarted = Completer<void>();
      var reads = 0;
      core.readPlatformStatus = () async {
        reads++;
        return reads == 1 ? const CoreStatus.started() : const CoreStatus.starting();
      };
      core.onStatusWatch = () {
        if (!statusWatchStarted.isCompleted) statusWatchStarted.complete();
      };
      final done = Completer<void>();
      final errors = <Object>[];
      final subscription = service.watchGroup().listen((_) {}, onError: errors.add, onDone: done.complete);
      subscriptions.add(subscription);

      await first.service.groupOpened.future.timeout(const Duration(seconds: 2));
      first.service.groupEvents.addError(const GrpcError.unknown('HTTP/2 stream forcefully terminated'));
      await statusWatchStarted.future.timeout(const Duration(seconds: 2));
      expect(core.platformStatusReadCalls, 1);
      expect(core.statusEvents.hasListener, isTrue);

      core.statusEvents.add(const CoreStatus.starting());
      await done.future.timeout(const Duration(seconds: 2));

      expect(errors, isEmpty);
      expect(core.platformStatusReadCalls, 2);
      expect(core.statusEvents.hasListener, isFalse);
    });

    test('preserves error when Starting event is followed by authoritative Started snapshot', () async {
      final statusWatchStarted = Completer<void>();
      core.readPlatformStatus = () async => const CoreStatus.started();
      core.onStatusWatch = () {
        if (!statusWatchStarted.isCompleted) statusWatchStarted.complete();
      };
      final failure = Completer<Object>();
      final subscription = service.watchGroup().listen((_) {}, onError: failure.complete);
      subscriptions.add(subscription);

      await first.service.groupOpened.future.timeout(const Duration(seconds: 2));
      first.service.groupEvents.addError(const GrpcError.unknown('HTTP/2 stream forcefully terminated'));
      await statusWatchStarted.future.timeout(const Duration(seconds: 2));
      core.statusEvents.add(const CoreStatus.starting());

      expect(await failure.future.timeout(const Duration(seconds: 2)), isA<GrpcError>());
      expect(core.platformStatusReadCalls, 2);
      expect(core.statusEvents.hasListener, isFalse);
    });

    test('active native status with no lifecycle event times out promptly and removes its observer', () async {
      core.readPlatformStatus = () async => const CoreStatus.started();
      final failure = Completer<Object>();
      final subscription = service.watchGroup().listen((_) {}, onError: failure.complete);
      subscriptions.add(subscription);

      await first.service.groupOpened.future.timeout(const Duration(seconds: 2));
      final timer = Stopwatch()..start();
      first.service.groupEvents.addError(const GrpcError.unknown('HTTP/2 stream forcefully terminated'));
      expect(await failure.future.timeout(const Duration(seconds: 2)), isA<GrpcError>());

      expect(timer.elapsed, lessThan(const Duration(seconds: 1)));
      expect(core.statusEvents.hasListener, isFalse);
      expect(core.statusWatchCalls, 1);
    });

    test('event stream error preserves the original transport failure and removes observer', () async {
      final statusWatchStarted = Completer<void>();
      core.readPlatformStatus = () async => const CoreStatus.started();
      core.onStatusWatch = () {
        if (!statusWatchStarted.isCompleted) statusWatchStarted.complete();
      };
      final failure = Completer<Object>();
      final subscription = service.watchGroup().listen((_) {}, onError: failure.complete);
      subscriptions.add(subscription);

      await first.service.groupOpened.future.timeout(const Duration(seconds: 2));
      first.service.groupEvents.addError(const GrpcError.unknown('HTTP/2 stream forcefully terminated'));
      await statusWatchStarted.future.timeout(const Duration(seconds: 2));
      core.statusEvents.addError(StateError('native event stream failed'));

      expect(await failure.future.timeout(const Duration(seconds: 2)), isA<GrpcError>());
      expect(core.platformStatusReadCalls, 1);
      expect(core.statusEvents.hasListener, isFalse);
    });

    test('a lifecycle change during event wait prevents suppressing the old transport error', () async {
      final statusWatchStarted = Completer<void>();
      var reads = 0;
      core.readPlatformStatus = () async {
        reads++;
        return reads == 1 ? const CoreStatus.started() : const CoreStatus.starting();
      };
      core.onStatusWatch = () {
        if (!statusWatchStarted.isCompleted) statusWatchStarted.complete();
      };
      final failure = Completer<Object>();
      final subscription = service.watchGroup().listen((_) {}, onError: failure.complete);
      subscriptions.add(subscription);

      await first.service.groupOpened.future.timeout(const Duration(seconds: 2));
      first.service.groupEvents.addError(const GrpcError.unknown('HTTP/2 stream forcefully terminated'));
      await statusWatchStarted.future.timeout(const Duration(seconds: 2));
      service.beginManualBackgroundLifecycle();
      core.statusEvents.add(const CoreStatus.starting());

      expect(await failure.future.timeout(const Duration(seconds: 2)), isA<GrpcError>());
      expect(core.platformStatusReadCalls, 2);
      expect(core.statusEvents.hasListener, isFalse);
    });

    test('propagates an expected transport error when a fresh native snapshot is unavailable or active', () async {
      final replies = <Future<CoreStatus?> Function()>[
        () async => null,
        () async => const CoreStatus.started(),
        () => Completer<CoreStatus?>().future,
      ];
      final errors = <Object>[];

      for (var index = 0; index < replies.length; index++) {
        final failure = Completer<Object>();
        final expectedGroupCall = index + 1;
        final opened = first.service.groupCallsEvents.stream.firstWhere((calls) => calls >= expectedGroupCall);
        core.readPlatformStatus = replies[index];
        final subscription = service.watchGroup().listen((_) {}, onError: failure.complete);
        subscriptions.add(subscription);
        await opened.timeout(const Duration(seconds: 2));
        first.service.groupEvents.addError(const GrpcError.unknown('HTTP/2 stream forcefully terminated'));
        errors.add(await failure.future.timeout(const Duration(seconds: 2)));
      }

      expect(errors, everyElement(isA<GrpcError>()));
      expect(core.platformStatusReadCalls, 3);
    });

    test('does not query native status for unrelated stream errors', () async {
      final failure = Completer<Object>();
      final subscription = service.watchGroup().listen((_) {}, onError: failure.complete);
      subscriptions.add(subscription);

      await first.service.groupOpened.future.timeout(const Duration(seconds: 2));
      first.service.groupEvents.addError(const GrpcError.unknown('application stream failure'));

      expect(await failure.future.timeout(const Duration(seconds: 2)), isA<GrpcError>());
      expect(core.platformStatusReadCalls, 0);
    });

    test('propagates transport error when a newer lifecycle supersedes the queried snapshot', () async {
      final freshStatus = Completer<CoreStatus?>();
      final queryStarted = Completer<void>();
      core.readPlatformStatus = () {
        if (!queryStarted.isCompleted) queryStarted.complete();
        return freshStatus.future;
      };
      final failure = Completer<Object>();
      final subscription = service.watchGroup().listen((_) {}, onError: failure.complete);
      subscriptions.add(subscription);

      await first.service.groupOpened.future.timeout(const Duration(seconds: 2));
      first.service.groupEvents.addError(const GrpcError.unknown('HTTP/2 stream forcefully terminated'));
      await queryStarted.future.timeout(const Duration(seconds: 2));
      service.beginManualBackgroundLifecycle();
      freshStatus.complete(const CoreStatus.stopping());

      expect(await failure.future.timeout(const Duration(seconds: 2)), isA<GrpcError>());
      expect(core.platformStatusReadCalls, 1);
    });

    test('finishes transport error if disposal occurs during platform reconciliation', () async {
      final freshStatus = Completer<CoreStatus?>();
      final queryStarted = Completer<void>();
      core.readPlatformStatus = () {
        if (!queryStarted.isCompleted) queryStarted.complete();
        return freshStatus.future;
      };
      final done = Completer<void>();
      final errors = <Object>[];
      final subscription = service.watchGroup().listen((_) {}, onError: errors.add, onDone: done.complete);
      subscriptions.add(subscription);

      await first.service.groupOpened.future.timeout(const Duration(seconds: 2));
      first.service.groupEvents.addError(const GrpcError.unknown('HTTP/2 stream forcefully terminated'));
      await queryStarted.future.timeout(const Duration(seconds: 2));
      await service.dispose();
      freshStatus.complete(const CoreStatus.started());

      await done.future.timeout(const Duration(seconds: 2));
      expect(errors, isEmpty);
    });

    test('a pending reconciliation propagates while subscribed but is suppressed after cancellation', () async {
      var platformReads = 0;
      final eventWaitStarted = Completer<void>();
      core.readPlatformStatus = () {
        platformReads++;
        return Future.value(const CoreStatus.started());
      };

      final subscribedFailure = Completer<Object>();
      final subscribed = service.watchGroup().listen((_) {}, onError: subscribedFailure.complete);
      subscriptions.add(subscribed);
      await first.service.groupCallsEvents.stream.firstWhere((calls) => calls >= 1).timeout(const Duration(seconds: 2));
      first.service.groupEvents.addError(const GrpcError.unknown('HTTP/2 stream forcefully terminated'));
      expect(await subscribedFailure.future.timeout(const Duration(seconds: 2)), isA<GrpcError>());
      await subscribed.cancel();

      final zoneErrors = <Object>[];
      core.onStatusWatch = () {
        if (!eventWaitStarted.isCompleted) eventWaitStarted.complete();
      };
      final cancellationRun = runZonedGuarded<Future<void>>(
        () async {
          const expectedGroupCall = 2;
          final opened = first.service.groupCallsEvents.stream.firstWhere((calls) => calls >= expectedGroupCall);
          final cancelled = service.watchGroup().listen((_) {}, onError: zoneErrors.add);
          subscriptions.add(cancelled);
          await opened.timeout(const Duration(seconds: 2));
          first.service.groupEvents.addError(const GrpcError.unknown('HTTP/2 stream forcefully terminated'));
          await eventWaitStarted.future.timeout(const Duration(seconds: 2));
          expect(core.statusEvents.hasListener, isTrue);
          await cancelled.cancel().timeout(const Duration(seconds: 2));
          expect(
            core.statusEvents.hasListener,
            isFalse,
            reason: 'cancelling must remove the temporary native observer',
          );
          core.statusEvents.add(const CoreStatus.starting());
          await _settle();
        },
        (error, _) {
          zoneErrors.add(error);
        },
      );
      await cancellationRun;

      expect(zoneErrors, isEmpty);
      expect(platformReads, 2);
    });

    test('watchGroup propagates local shutdown from the current active client and nontransport errors', () async {
      final currentClientError = Completer<Object>();
      final firstSubscription = service.watchGroup().listen((_) {}, onError: currentClientError.complete);
      subscriptions.add(firstSubscription);

      await first.service.groupOpened.future.timeout(const Duration(seconds: 2));
      first.service.groupEvents.addError(const GrpcError.cancelled('current active observation client'));
      expect(await currentClientError.future.timeout(const Duration(seconds: 2)), isA<GrpcError>());

      await firstSubscription.cancel();
      final secondEndpoint = await _ObservationEndpoint.start();
      addTearDown(secondEndpoint.close);
      core.bgClient = secondEndpoint.client;
      final nontransportError = Completer<Object>();
      final secondSubscription = service.watchGroup().listen((_) {}, onError: nontransportError.complete);
      subscriptions.add(secondSubscription);
      await secondEndpoint.service.groupOpened.future.timeout(const Duration(seconds: 2));
      secondEndpoint.service.groupEvents.addError(const GrpcError.unknown('application stream failure'));

      expect(await nontransportError.future.timeout(const Duration(seconds: 2)), isA<GrpcError>());
    });

    test('cancelling watchActiveGroups closes the source and never opens a replacement stream', () async {
      final subscription = service.watchActiveGroups().listen((_) {});
      subscriptions.add(subscription);
      await first.service.activeGroupsOpened.future.timeout(const Duration(seconds: 2));

      await subscription.cancel().timeout(const Duration(seconds: 2));
      await first.service.activeGroupsCancelled.future.timeout(const Duration(seconds: 2));
      core.bgClient = replacement.client;
      first.service.activeGroupEvents.addError(const GrpcError.cancelled('retired after cancellation'));
      await _settle();

      expect(replacement.service.activeGroupsCalls, 0);
    });
  });
}
