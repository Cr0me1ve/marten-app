import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/router/go_router/go_router_notifier.dart';
import 'package:marten/features/captcha/data/captcha_event.dart';
import 'package:marten/features/captcha/data/captcha_notifier.dart';
import 'package:marten/features/captcha/widget/captcha_page.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:marten/utils/platform_utils.dart';

const _captchaAutoRevealDelay = Duration(seconds: 4);
const _captchaLifecycleMarker = 'MARTEN_CAPTCHA_LIFECYCLE';

/// Top-of-tree widget that reacts to TURNcoat captcha events by pushing the
/// captcha WebView page. Designed to wrap the router so it can use the root
/// Navigator regardless of which screen the user is currently on.
///
/// Render this once near the app shell. Multiple instances would race to push
/// duplicate pages.
class CaptchaListener extends ConsumerStatefulWidget {
  const CaptchaListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<CaptchaListener> createState() => _CaptchaListenerState();
}

class _CaptchaListenerState extends ConsumerState<CaptchaListener> with InfraLogger {
  // Tracks the URL of the captcha page currently on the navigator stack so we
  // don't double-push if the notifier emits the same event twice.
  String? _activeUrl;
  int? _activeRevision;
  CaptchaEvent? _backgroundEvent;
  ProviderSubscription<CaptchaEvent?>? _sub;

  @override
  void initState() {
    super.initState();
    loggy.info('captcha listener initState');
    loggy.info('$_captchaLifecycleMarker event=listener revision=0 outcome=initialized');

    // Subscribe through listenManual so the subscription is alive immediately
    // and survives even if build() is delayed. ref.listen inside build only
    // arms after the first build pass; on this app shell that build may be
    // gated behind theme / locale init and could miss an early captcha event.
    _sub = ref.listenManual<CaptchaEvent?>(captchaNotifierProvider, (previous, next) {
      loggy.info('captcha listener: state changed previous=${previous != null} next=${next != null}');
      loggy.info(
        '$_captchaLifecycleMarker event=listener '
        'revision=${next?.revision ?? previous?.revision ?? 0} outcome=state_changed '
        'previous_revision=${previous?.revision ?? 0} next_revision=${next?.revision ?? 0}',
      );
      if (next == null) {
        loggy.info('$_captchaLifecycleMarker event=clear revision=${previous?.revision ?? 0} outcome=observed');
        _activeUrl = null;
        _activeRevision = null;
        if (_backgroundEvent != null && mounted) {
          setState(() => _backgroundEvent = null);
        }
        return;
      }
      if (_shouldRunInBackground(next.url)) {
        if (PlatformUtils.isAndroid) {
          loggy.info('captcha listener: persistent Android runner owns background challenge');
          loggy.info('$_captchaLifecycleMarker event=listener revision=${next.revision} outcome=native_owner');
          return;
        }
        if (_backgroundEvent?.url == next.url && _backgroundEvent?.revision == next.revision) {
          loggy.info('captcha listener: background captcha already running, skipping re-open');
          loggy.info('$_captchaLifecycleMarker event=listener revision=${next.revision} outcome=deduplicated');
          return;
        }
        loggy.info('captcha listener: running captcha in background');
        loggy.info('$_captchaLifecycleMarker event=listener revision=${next.revision} outcome=background_started');
        if (mounted) setState(() => _backgroundEvent = next);
        return;
      }
      // Riverpod fires this listener synchronously from a stream callback
      // (CaptchaNotifier._onLogs) — we are not inside a build pass, so we
      // can push the navigator route directly. The previous addPostFrameCallback
      // detour relied on a frame being pumped, which doesn't always happen
      // immediately when the state change originates outside the widget tree.
      if (mounted) _open(next);
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _sub?.close();
    super.dispose();
  }

  void _open(CaptchaEvent event) {
    final url = event.url;
    if (_activeUrl == url && _activeRevision == event.revision) {
      loggy.info('captcha listener: challenge already visible, skipping re-open');
      loggy.info('$_captchaLifecycleMarker event=listener revision=${event.revision} outcome=deduplicated');
      return;
    }
    _activeUrl = url;
    _activeRevision = event.revision;
    // CaptchaListener sits in MaterialApp.router's builder — it wraps the
    // Navigator, not the other way round. Navigator.maybeOf(rootNavigator:
    // true) walks UP from our context and finds nothing. Reach for the
    // GoRouter's NavigatorState through the global key instead.
    final navigator = rootNavKey.currentState;
    if (navigator == null) {
      loggy.warning('captcha listener: rootNavKey not attached when trying to show challenge');
      loggy.warning('$_captchaLifecycleMarker event=listener revision=${event.revision} outcome=navigator_unavailable');
      _activeUrl = null;
      _activeRevision = null;
      return;
    }
    loggy.info('captcha listener: pushing CaptchaPage');
    loggy.info('$_captchaLifecycleMarker event=listener revision=${event.revision} outcome=navigation_started');
    navigator
        .push(
          PageRouteBuilder<void>(
            fullscreenDialog: true,
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) =>
                CaptchaPage(url: url, revision: event.revision, revealDelay: _captchaAutoRevealDelay),
          ),
        )
        .whenComplete(() {
          if (_activeUrl == url && _activeRevision == event.revision) {
            _activeUrl = null;
            _activeRevision = null;
          }
        });
  }

  bool _shouldRunInBackground(String url) => Uri.tryParse(url)?.queryParameters['blank'] == '1';

  @override
  Widget build(BuildContext context) {
    final backgroundEvent = _backgroundEvent;
    if (backgroundEvent == null) return widget.child;
    final captcha = CaptchaPage(
      key: ValueKey(backgroundEvent.url),
      url: backgroundEvent.url,
      revision: backgroundEvent.revision,
      revealDelay: _captchaAutoRevealDelay,
      background: true,
    );
    if (PlatformUtils.isIOS) {
      return IosCaptchaBackgroundLayer(captcha: captcha, child: widget.child);
    }
    return Stack(
      children: [
        widget.child,
        Positioned.fill(child: captcha),
      ],
    );
  }
}

/// Keep WKWebView painted while the opaque app surface covers its contents.
/// Opacity(0)/Offstage can suspend timers in the underlying web process.
class IosCaptchaBackgroundLayer extends StatelessWidget {
  const IosCaptchaBackgroundLayer({super.key, required this.captcha, required this.child});

  final Widget captcha;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(
        child: IgnorePointer(child: ExcludeSemantics(child: captcha)),
      ),
      Positioned.fill(
        child: ColoredBox(color: Theme.of(context).colorScheme.surface.withValues(alpha: 1), child: child),
      ),
    ],
  );
}
