/// Event surfaced from the marten-core log stream when a TURNcoat outbound
/// needs the user to solve a captcha to fetch TURN credentials.
///
/// The [url] points at the dialer's local proxy server (typically
/// `http://127.0.0.1:8765/...`). The Marten Flutter app should load that URL
/// in an in-app WebView; the dialer's reverse proxy handles the rest of the
/// captcha flow (cookie domain rewriting, token detection, etc).
class CaptchaEvent {
  const CaptchaEvent({required this.url, required this.createdAt});

  final String url;
  final DateTime createdAt;
}
