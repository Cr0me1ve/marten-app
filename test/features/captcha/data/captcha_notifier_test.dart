import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/features/captcha/data/captcha_notifier.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart' as pb;
import 'package:marten/martencore/marten_core_service.dart';
import 'package:marten/martencore/marten_core_service_provider.dart';

void main() {
  group('CaptchaNotifier deferred CAPTCHA events', () {
    late ProviderContainer container;
    late MartenCoreService core;
    late List<pb.LogMessage> logs;

    setUp(() {
      container = ProviderContainer();
      core = container.read(martenCoreServiceProvider);
      logs = [];
      // Build the notifier before publishing a log batch, exactly as the
      // connection flow does before it arms CAPTCHA handling.
      container.read(captchaNotifierProvider);
    });

    tearDown(() {
      container.dispose();
    });

    Future<void> emit(String message) async {
      logs.add(pb.LogMessage(message: message));
      core.runtimeLogBuffer = List.of(logs);
      core.runtimeLogController.add(List.unmodifiable(logs));
      await Future<void>.delayed(Duration.zero);
    }

    test('replays a REQUIRED received while disarmed when armed', () async {
      const url = 'http://localhost:8765/captcha?deferred=1';

      await emit('MARTEN_TURNCOAT_CAPTCHA url=$url');
      expect(container.read(captchaNotifierProvider), isNull);

      container.read(captchaNotifierProvider.notifier).arm(enabled: true);
      expect(container.read(captchaNotifierProvider)?.url, url);
    });

    test('DONE or FAILED while disarmed cancels a deferred request', () async {
      for (final terminal in ['MARTEN_TURNCOAT_CAPTCHA_DONE', 'MARTEN_TURNCOAT_CAPTCHA_FAILED']) {
        logs = [];
        core.runtimeLogBuffer = [];
        container.read(captchaNotifierProvider.notifier).arm(enabled: false);

        await emit('MARTEN_TURNCOAT_CAPTCHA url=http://localhost:8765/captcha?terminal=$terminal');
        await emit(terminal);
        container.read(captchaNotifierProvider.notifier).arm(enabled: true);

        expect(container.read(captchaNotifierProvider), isNull, reason: terminal);
        container.read(captchaNotifierProvider.notifier).arm(enabled: false);
      }
    });

    test('armed watcher preserves FAILED then next REQUIRED ordering', () async {
      final notifier = container.read(captchaNotifierProvider.notifier)..arm(enabled: true);

      await emit('MARTEN_TURNCOAT_CAPTCHA url=http://localhost:8765/captcha?attempt=1');
      expect(container.read(captchaNotifierProvider)?.url, contains('attempt=1'));

      await emit('MARTEN_TURNCOAT_CAPTCHA_FAILED');
      expect(container.read(captchaNotifierProvider), isNull);

      await emit('MARTEN_TURNCOAT_CAPTCHA url=http://localhost:8765/captcha?attempt=2');
      expect(container.read(captchaNotifierProvider)?.url, contains('attempt=2'));
      // Keep the notifier alive through the final assertion so the test also
      // verifies its public state after the ordered sequence.
      expect(notifier, isNotNull);
    });

    test('same loopback URL with a newer revision replaces the active challenge', () async {
      const url = 'http://127.0.0.1:8765/captcha?blank=1&fake=revision';
      final notifier = container.read(captchaNotifierProvider.notifier)..arm(enabled: true);

      await emit('MARTEN_TURNCOAT_CAPTCHA url=$url revision=41');
      final first = container.read(captchaNotifierProvider);
      expect(first?.url, url);
      expect(first?.revision, 41);

      // The local proxy keeps one stable entry URL. A new provider challenge
      // must nevertheless be observable to the detached runner as a reload.
      await emit('MARTEN_TURNCOAT_CAPTCHA url=$url revision=42');
      final second = container.read(captchaNotifierProvider);
      expect(second?.url, url);
      expect(second?.revision, 42);
      expect(identical(second, first), isFalse);
      expect(notifier, isNotNull);
    });

    test('stale terminal only clears its matching CAPTCHA revision', () async {
      const url = 'http://127.0.0.1:8765/captcha?blank=1&fake=stale-terminal';
      container.read(captchaNotifierProvider.notifier).arm(enabled: true);

      await emit('MARTEN_TURNCOAT_CAPTCHA url=$url revision=7');
      await emit('MARTEN_TURNCOAT_CAPTCHA url=$url revision=8');
      expect(container.read(captchaNotifierProvider)?.revision, 8);

      await emit('MARTEN_TURNCOAT_CAPTCHA_FAILED revision=7');
      expect(container.read(captchaNotifierProvider)?.revision, 8);

      await emit('MARTEN_TURNCOAT_CAPTCHA_DONE revision=8');
      expect(container.read(captchaNotifierProvider), isNull);
    });

    test('unversioned terminal does not clear a versioned active CAPTCHA', () async {
      const url = 'http://127.0.0.1:8765/captcha?blank=1&fake=unversioned-terminal';
      container.read(captchaNotifierProvider.notifier).arm(enabled: true);

      await emit('MARTEN_TURNCOAT_CAPTCHA url=$url revision=9');
      expect(container.read(captchaNotifierProvider)?.revision, 9);

      await emit('MARTEN_TURNCOAT_CAPTCHA_FAILED');
      expect(container.read(captchaNotifierProvider)?.revision, 9);

      await emit('MARTEN_TURNCOAT_CAPTCHA_DONE revision=9');
      expect(container.read(captchaNotifierProvider), isNull);
    });

    test('manual lifecycle reset discards an old log generation but accepts the new generation', () async {
      final notifier = container.read(captchaNotifierProvider.notifier)..arm(enabled: true);

      await emit('MARTEN_TURNCOAT_CAPTCHA url=http://localhost:8765/captcha?generation=old');
      expect(container.read(captchaNotifierProvider)?.url, contains('generation=old'));

      // The exact old rolling buffer can be replayed while the previous gRPC
      // stream is retiring. Reset must move the cursor past it, rather than
      // letting a stale route re-open CAPTCHA on the replacement lifecycle.
      notifier.reset();
      core.runtimeLogController.add(List.unmodifiable(logs));
      await Future<void>.delayed(Duration.zero);
      notifier.arm(enabled: true);
      expect(container.read(captchaNotifierProvider), isNull);

      await emit('MARTEN_TURNCOAT_CAPTCHA url=http://localhost:8765/captcha?generation=current');
      expect(container.read(captchaNotifierProvider)?.url, contains('generation=current'));
    });
  });
}
