import 'package:app_links/app_links.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/logger/logger.dart';
import 'package:marten/core/router/deep_linking/url_protocol/api.dart';
import 'package:marten/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'my_app_links.g.dart';

@riverpod
Stream<String> myAppLinks(Ref ref) async* {
  if (PlatformUtils.isWindows) {
    for (final protocol in LinkParser.protocols) {
      registerProtocolHandler(protocol);
    }
  }
  final appLinks = AppLinks();
  try {
    final initialLink = await appLinks.getInitialLinkString();
    if (initialLink != null && initialLink.isNotEmpty) yield initialLink;
  } catch (error, stackTrace) {
    Logger.app.warning("error reading initial app link", error, stackTrace);
  }
  yield* appLinks.stringLinkStream.handleError((Object error, StackTrace stackTrace) {
    Logger.app.warning("error reading app link stream", error, stackTrace);
  });
}
