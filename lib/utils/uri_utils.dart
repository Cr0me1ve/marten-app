import 'dart:io';

import 'package:loggy/loggy.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

abstract class UriUtils {
  static final loggy = Loggy<InfraLogger>("UriUtils");

  static Future<bool> tryShareOrLaunchFile(Uri uri, {Uri? fileOrDir, String? mimeType}) {
    if (Platform.isWindows || Platform.isLinux) {
      return tryLaunch(fileOrDir ?? uri);
    }
    return tryShareFile(uri, mimeType: mimeType);
  }

  static Future<bool> tryLaunch(Uri uri) async {
    try {
      loggy.debug('launching external URI scheme [${uri.scheme}]');
      if (!await canLaunchUrl(uri)) {
        loggy.warning('cannot launch external URI scheme [${uri.scheme}]');
        return false;
      }
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (error) {
      loggy.warning('error launching external URI (${error.runtimeType})');
      return false;
    }
  }

  static Future<bool> tryShareFile(Uri uri, {String? mimeType}) async {
    try {
      loggy.debug('sharing local file');
      final file = XFile(uri.path, mimeType: mimeType);
      final result = await Share.shareXFiles([file]);
      loggy.debug('share result status: ${result.status.name}');
      return result.status == ShareResultStatus.success;
    } catch (error) {
      loggy.warning('error sharing local file (${error.runtimeType})');
      return false;
    }
  }
}
