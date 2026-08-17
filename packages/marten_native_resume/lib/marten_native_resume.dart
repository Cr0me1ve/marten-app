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

  /// Runs the TURNcoat CAPTCHA in a detached native Android WebView. Unlike a
  /// platform view attached to Flutter's Activity window, this renderer keeps
  /// making progress while another application is in the foreground.
  static Future<bool> loadHeadlessCaptcha({required String url, required String automationScript}) async {
    return await _channel.invokeMethod<bool>('loadHeadlessCaptcha', {
          'url': url,
          'automationScript': automationScript,
        }) ??
        false;
  }

  static Future<bool> clearHeadlessCaptcha() async {
    return await _channel.invokeMethod<bool>('clearHeadlessCaptcha') ?? false;
  }
}
