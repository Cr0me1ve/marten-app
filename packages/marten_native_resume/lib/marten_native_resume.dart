import 'package:flutter/services.dart';

class MartenNativeResume {
  MartenNativeResume._();

  static const _channel = MethodChannel('app.marten.client/native_resume');

  static Future<bool> store({required String path, required String name}) async {
    return await _channel.invokeMethod<bool>('store', {'path': path, 'name': name}) ?? false;
  }

  static Future<bool> clear() async {
    return await _channel.invokeMethod<bool>('clear') ?? false;
  }

  /// Canonicalizes a remote subscription with the exact native schema bundled
  /// into the APK. The operation is pure and is available in foreground and
  /// headless Flutter engines without starting the VPN service.
  static Future<String> canonicalizeSubscription({required String content, required String settingsJson}) async {
    final canonical = await _channel.invokeMethod<String>('canonicalizeSubscription', {
      'content': content,
      'settingsJson': settingsJson,
    });
    if (canonical == null) {
      throw PlatformException(
        code: 'subscription_canonicalization_failed',
        message: 'subscription candidate is not usable',
      );
    }
    return canonical;
  }

  /// Runs the TURNcoat CAPTCHA in a detached native Android WebView. Unlike a
  /// platform view attached to Flutter's Activity window, this renderer keeps
  /// making progress while another application is in the foreground.
  static Future<bool> loadHeadlessCaptcha({
    required String url,
    required String automationScript,
    required int revision,
  }) async {
    return await _channel.invokeMethod<bool>('loadHeadlessCaptcha', {
          'url': url,
          'automationScript': automationScript,
          'revision': revision,
        }) ??
        false;
  }

  static Future<bool> clearHeadlessCaptcha({required int revision}) async {
    return await _channel.invokeMethod<bool>('clearHeadlessCaptcha', {'revision': revision}) ?? false;
  }
}
