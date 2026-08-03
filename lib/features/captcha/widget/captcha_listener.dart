import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/router/go_router/go_router_notifier.dart';
import 'package:marten/features/captcha/data/captcha_event.dart';
import 'package:marten/features/captcha/data/captcha_notifier.dart';
import 'package:marten/features/captcha/widget/captcha_page.dart';
import 'package:marten/utils/custom_loggers.dart';

const _captchaAutoRevealDelay = Duration(seconds: 4);

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
  CaptchaEvent? _backgroundEvent;
  ProviderSubscription<CaptchaEvent?>? _sub;

  @override
  void initState() {
    super.initState();
    loggy.info('captcha listener initState');

    // Subscribe through listenManual so the subscription is alive immediately
    // and survives even if build() is delayed. ref.listen inside build only
    // arms after the first build pass; on this app shell that build may be
    // gated behind theme / locale init and could miss an early captcha event.
    _sub = ref.listenManual<CaptchaEvent?>(captchaNotifierProvider, (previous, next) {
      loggy.info('captcha listener: state changed previous=${previous != null} next=${next != null}');
      if (next == null) {
        _activeUrl = null;
        if (_backgroundEvent != null && mounted) {
          setState(() => _backgroundEvent = null);
        }
        return;
      }
      if (_shouldRunInBackground(next.url)) {
        if (_backgroundEvent?.url == next.url) {
          loggy.info('captcha listener: background captcha already running, skipping re-open');
          return;
        }
        loggy.info('captcha listener: running captcha in background');
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
    if (_activeUrl == url) {
      loggy.info('captcha listener: challenge already visible, skipping re-open');
      return;
    }
    _activeUrl = url;
    // CaptchaListener sits in MaterialApp.router's builder — it wraps the
    // Navigator, not the other way round. Navigator.maybeOf(rootNavigator:
    // true) walks UP from our context and finds nothing. Reach for the
    // GoRouter's NavigatorState through the global key instead.
    final navigator = rootNavKey.currentState;
    if (navigator == null) {
      loggy.warning('captcha listener: rootNavKey not attached when trying to show challenge');
      _activeUrl = null;
      return;
    }
    loggy.info('captcha listener: pushing CaptchaPage');
    navigator
        .push(
          PageRouteBuilder<void>(
            fullscreenDialog: true,
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => CaptchaPage(url: url, revealDelay: _captchaAutoRevealDelay),
          ),
        )
        .whenComplete(() {
          if (_activeUrl == url) _activeUrl = null;
        });
  }

  bool _shouldRunInBackground(String url) => Uri.tryParse(url)?.queryParameters['blank'] == '1';

  @override
  Widget build(BuildContext context) {
    final backgroundEvent = _backgroundEvent;
    if (backgroundEvent == null) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: CaptchaPage(
            key: ValueKey(backgroundEvent.url),
            url: backgroundEvent.url,
            revealDelay: _captchaAutoRevealDelay,
            background: true,
          ),
        ),
      ],
    );
  }
}
