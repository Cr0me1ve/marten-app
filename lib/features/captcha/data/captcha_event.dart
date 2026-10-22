/// Event surfaced from the marten-core log stream when a TURNcoat outbound
/// needs the user to solve a captcha to fetch TURN credentials.
///
/// The [url] points at the dialer's local proxy server (typically
/// `http://127.0.0.1:8765/...`). The Marten Flutter app should load that URL
/// in an in-app WebView; the dialer's reverse proxy handles the rest of the
/// captcha flow (cookie domain rewriting, token detection, etc).
class CaptchaEvent {
  const CaptchaEvent({required this.url, required this.createdAt, this.revision = 0});

  final String url;
  final DateTime createdAt;

  /// Process-local monotonic challenge identity published by marten-core.
  /// Legacy cores omit it and use zero. The local proxy URL may be reused, so
  /// URL equality alone cannot distinguish a replacement CAPTCHA session.
  final int revision;
}
