import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/connection/data/turncoat_liveness_notifier.dart';

void main() {
  group('turncoat liveness log detection', () {
    test('timed out state stops holding the UI in connecting', () {
      const state = TurncoatLivenessState(inUse: true, timedOut: true);

      expect(state.isWaitingForLive, isFalse);
      expect(state.copyWith(live: true, timedOut: false).isWaitingForLive, isFalse);
    });

    test('route activity count participates in state identity', () {
      expect(
        const TurncoatLivenessState(inUse: true, live: true, routeActive: true, routeActivityCount: 1),
        isNot(const TurncoatLivenessState(inUse: true, live: true, routeActive: true, routeActivityCount: 2)),
      );
    });

    test('terminal states can release startup waiters', () {
      expect(isTerminalTurncoatLivenessState(const TurncoatLivenessState(inUse: true)), isFalse);
      expect(isTerminalTurncoatLivenessState(const TurncoatLivenessState(inUse: true, live: true)), isTrue);
      expect(isTerminalTurncoatLivenessState(const TurncoatLivenessState(inUse: true, timedOut: true)), isTrue);
      expect(isTerminalTurncoatLivenessState(const TurncoatLivenessState()), isTrue);
    });

    test('armed TURNcoat startup wait does not finish before first runtime marker', () {
      expect(isTerminalTurncoatStartupWaitState(const TurncoatLivenessState(), armedForTurncoat: true), isFalse);
      expect(
        isTerminalTurncoatStartupWaitState(const TurncoatLivenessState(inUse: true), armedForTurncoat: true),
        isFalse,
      );
    });

    test('startup wait still finishes for non-TURNcoat, live, and timeout states', () {
      expect(isTerminalTurncoatStartupWaitState(const TurncoatLivenessState(), armedForTurncoat: false), isTrue);
      expect(
        isTerminalTurncoatStartupWaitState(
          const TurncoatLivenessState(inUse: true, live: true),
          armedForTurncoat: true,
        ),
        isTrue,
      );
      expect(
        isTerminalTurncoatStartupWaitState(
          const TurncoatLivenessState(inUse: true, timedOut: true),
          armedForTurncoat: true,
        ),
        isTrue,
      );
    });

    test('selected-route waiter requires live carrier and backend traffic from the same generation', () {
      expect(
        isTerminalTurncoatStartupRouteWaitState(
          const TurncoatLivenessState(inUse: true, live: true),
          armedForTurncoat: true,
        ),
        isFalse,
      );
      expect(
        isTerminalTurncoatStartupRouteWaitState(
          const TurncoatLivenessState(inUse: true, routeActive: true),
          armedForTurncoat: true,
        ),
        isFalse,
      );
      expect(
        isTerminalTurncoatStartupRouteWaitState(
          const TurncoatLivenessState(inUse: true, live: true, routeActive: true),
          armedForTurncoat: true,
        ),
        isTrue,
      );
      expect(
        isTerminalTurncoatStartupRouteWaitState(
          const TurncoatLivenessState(inUse: true, timedOut: true),
          armedForTurncoat: true,
        ),
        isTrue,
      );
    });

    test('does not treat config dumps as active TURNcoat usage', () {
      const configDump = 'Current Config is: {"outbounds":[{"type":"turncoat","tag":"hidden-turncoat"}]}';

      expect(isTurncoatInUseLogLine(configDump), isFalse);
    });

    test('detects real TURNcoat outbound activity', () {
      expect(isTurncoatInUseLogLine('turncoat: opening stream for example.com:443'), isTrue);
      expect(isTurncoatInUseLogLine('turncoat: opening packet conn for 1.1.1.1:53'), isTrue);
      expect(isTurncoatInUseLogLine('turncoat: opening packet association for backend:443'), isTrue);
      expect(isTurncoatInUseLogLine('turncoat: dialer ready, peer=127.0.0.1:56000'), isTrue);
      expect(isTurncoatInUseLogLine('[turncoat] live streams active=0 ready=0 total=12'), isTrue);
      expect(isTurncoatInUseLogLine('[Captcha] manual captcha triggered'), isTrue);
    });

    test('detects active session promotion', () {
      expect(isTurncoatPromotedLogLine('[session 0] promoted to active TX pool'), isTrue);
      expect(isTurncoatPromotedLogLine('[turncoat] live streams active=1 ready=0 total=12'), isTrue);
      expect(isTurncoatPromotedLogLine('[turncoat] live streams active=0 ready=2 total=12'), isTrue);
      expect(isTurncoatPromotedLogLine('[turncoat] live streams active=0 ready=0 total=12'), isFalse);
    });

    test('distinguishes real backend RX from carrier-only probe acknowledgements', () {
      expect(isTurncoatBackendRxLogLine('[session 1] promoted to active TX pool (RX proof received)'), isTrue);
      expect(
        isTurncoatBackendRxLogLine('[session 1] promoted to active TX pool (probe burst acked in 164ms)'),
        isFalse,
      );
      expect(isTurncoatBackendRxLogLine('[turncoat] live streams active=10 ready=10 total=10'), isFalse);
    });

    test('detects runtime traffic on the selected backend outbound only', () {
      const selected = 'США 2 | ОБХОД БЕЛЫХ СПИСКОВ';

      expect(
        isSelectedOutboundActivityLogLine(
          'INFO[0015] outbound/hysteria2[США 2 | ОБХОД БЕЛЫХ СПИСКОВ]: outbound connection to www.gstatic.com:443',
          selected,
        ),
        isTrue,
      );
      expect(
        isSelectedOutboundActivityLogLine(
          'INFO[0016] outbound/hysteria2[США 2 | ОБХОД БЕЛЫХ СПИСКОВ]: outbound packet connection to 8.8.4.4:443',
          selected,
        ),
        isTrue,
      );
      expect(
        isSelectedOutboundActivityLogLine(
          'INFO outbound/turncoat[США 2 | ОБХОД БЕЛЫХ СПИСКОВ turncoat]: turncoat: opening packet conn',
          selected,
        ),
        isFalse,
      );
      expect(
        isSelectedOutboundActivityLogLine(
          'INFO[0015] outbound/hysteria2[ГЕРМАНИЯ 1]: outbound connection to www.gstatic.com:443',
          selected,
        ),
        isFalse,
      );
    });
  });
}
