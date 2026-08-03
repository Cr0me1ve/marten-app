import 'dart:convert';
import 'dart:io';

import 'package:dartx/dartx.dart';
import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/crypto/subscription_envelope.dart';
import 'package:marten/core/db/db.dart';
import 'package:marten/core/device/device_identity.dart';
import 'package:marten/core/http_client/dio_http_client.dart';
import 'package:marten/features/profile/data/profile_data_mapper.dart';
import 'package:marten/features/profile/data/profile_refresh_diagnostics.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/model/profile_failure.dart';
import 'package:marten/features/settings/data/config_option_repository.dart';
import 'package:marten/singbox/model/singbox_proxy_type.dart';
import 'package:marten/utils/utils.dart';
import 'package:meta/meta.dart';

/// parse profile subscription url and headers for data
///
/// ***name parser hierarchy:***
/// - UserOverride.name
/// - `profile-title` header
/// - `content-disposition` header
/// - url fragment (example: `https://example.com/config#user`) -> name=`user`
/// - url filename extension (example: `https://example.com/config.json`) -> name=`config`
/// - if none of these methods return a non-blank string, switch(profileType)
/// - remote:  fallback to `Remote Profile`
/// - local: fallback to protocol, extracted from content by protocol()

class _ProfileDownloadResult {
  const _ProfileDownloadResult({required this.headers, required this.endpoints, required this.currentEndpoint});

  final Map<String, dynamic> headers;
  final List<String> endpoints;
  final String? currentEndpoint;
}

class ProfileParser with InfraLogger {
  static const defaultUpdateInterval = Duration(hours: 1);
  static const infiniteTrafficThreshold = 920_233_720_368;
  static const infiniteTimeThreshold = 92_233_720_368;
  static const maxRemoteIncludes = 64;
  static const maxExpandedProfileBytes = DioHttpClient.maxResponseBytes;

  static const _retryableStatusCodes = {502, 503, 504};
  static const _supportedOutboundTypes = {
    'direct',
    'block',
    'dns',
    'socks',
    'http',
    'shadowsocks',
    'vmess',
    'trojan',
    'wireguard',
    'amneziawg',
    'hysteria',
    'tor',
    'ssh',
    'shadowtls',
    'shadowsocksr',
    'vless',
    'tuic',
    'hysteria2',
    'selector',
    'urltest',
    'custom',
    'xray',
    'turncoat',
    'icmp',
  };
  static const _supportedTopLevelConfigKeys = {
    r'$schema',
    'log',
    'dns',
    'ntp',
    'inbounds',
    'outbounds',
    'route',
    'experimental',
    'custom',
    'providers',
    'split_tunnel',
    'split_tunneling',
    'servers',
    'subscription',
  };
  static const allowedOverrideConfigs = [
    'connection-test-url',
    'direct-dns-address',
    'remote-dns-address',
    'exclude-package',
    'tls-tricks',
  ];
  static const allowedProfileHeaders = [
    'profile-title',
    'content-disposition',
    'subscription-userinfo',
    'profile-update-interval',
    'support-url',
    'profile-web-page-url',
    'direct-dns-address',
    'remote-dns-address',
    'enable-fragment',
  ];

  final Ref _ref;
  final DioHttpClient _httpClient;

  ProfileParser({required Ref ref, required DioHttpClient httpClient}) : _ref = ref, _httpClient = httpClient;
  TaskEither<ProfileFailure, ProfileEntriesCompanion> addLocal({
    required String id,
    required String content,
    required String tempFilePath,
    required UserOverride? userOverride,
    bool active = true,
  }) {
    return TaskEither.tryCatch(() async {
          await expandRemoteLinesInParallel(
            tempFilePath: tempFilePath,
            httpClient: _httpClient,
            cancelToken: CancelToken(),
            ref: _ref,
          );
        }, (error, stackTrace) => error is ProfileFailure ? error : ProfileFailure.unexpected(error, stackTrace))
        .flatMap((_) => TaskEither.fromEither(populateHeaders(content: content)))
        .flatMap(
          (populatedHeaders) => TaskEither.fromEither(
            parse(
              tempFilePath: tempFilePath,
              profile: ProfileEntity.local(
                id: id,
                active: active,
                name: '',
                lastUpdate: DateTime.now(),
                userOverride: userOverride,
                populatedHeaders: populatedHeaders,
              ),
            ).flatMap((profEntity) => Either.tryCatch(() => profEntity.toInsertEntry(), ProfileFailure.unexpected)),
          ),
        );
  }

  TaskEither<ProfileFailure, ProfileEntriesCompanion> addRemote({
    required String id,
    required String url,
    required String tempFilePath,
    required UserOverride? userOverride,
    bool active = true,
    CancelToken? cancelToken,
  }) => _downloadProfile(url, tempFilePath, cancelToken).flatMap(
    (download) =>
        TaskEither.fromEither(
          populateHeaders(content: File(tempFilePath).readAsStringSync(), remoteHeaders: download.headers),
        ).flatMap(
          (populatedHeaders) => TaskEither.fromEither(
            parse(
              tempFilePath: tempFilePath,
              profile: ProfileEntity.remote(
                id: id,
                active: active,
                name: '',
                url: url,
                lastUpdate: DateTime.now(),
                userOverride: userOverride,
                subscriptionEndpoints: download.endpoints,
                currentSubscriptionEndpoint: download.currentEndpoint,
                populatedHeaders: populatedHeaders,
              ),
            ).flatMap((profEntity) => Either.tryCatch(() => profEntity.toInsertEntry(), ProfileFailure.unexpected)),
          ),
        ),
  );

  TaskEither<ProfileFailure, ProfileEntriesCompanion> updateRemote({
    required RemoteProfileEntity rp,
    required String tempFilePath,
    CancelToken? cancelToken,
  }) => _downloadProfile(rp.url, tempFilePath, cancelToken, refresh: true, profile: rp).flatMap(
    (download) =>
        TaskEither.fromEither(
          populateHeaders(content: File(tempFilePath).readAsStringSync(), remoteHeaders: download.headers),
        ).flatMap(
          (populatedHeaders) => TaskEither.fromEither(
            parse(
              tempFilePath: tempFilePath,
              profile: rp.copyWith(
                populatedHeaders: populatedHeaders,
                subscriptionEndpoints: download.endpoints,
                currentSubscriptionEndpoint: download.currentEndpoint,
              ),
            ).flatMap((profEntity) => Either.tryCatch(() => profEntity.toUpdateEntry(), ProfileFailure.unexpected)),
          ),
        ),
  );

  Either<ProfileFailure, ProfileEntriesCompanion> offlineUpdate({
    required ProfileEntity profile,
    required String tempFilePath,
  }) => profile
      .map(
        remote: (rp) => parse(profile: rp, tempFilePath: tempFilePath),
        local: (lp) => parse(tempFilePath: tempFilePath, profile: lp),
      )
      .flatMap((profEntity) => Either.tryCatch(() => profEntity.toUpdateEntry(), ProfileFailure.unexpected));

  TaskEither<ProfileFailure, _ProfileDownloadResult> _downloadProfile(
    String url,
    String tempFilePath,
    CancelToken? cancelToken, {
    bool refresh = false,
    RemoteProfileEntity? profile,
  }) => TaskEither.tryCatch(() async {
    final deviceIdentity = await _ref.read(deviceIdentityProvider.future);
    final requestUrl = url.trim();
    final userAgent = _ref.read(ConfigOptions.useXrayCoreWhenPossible)
        ? _httpClient.userAgent.replaceAll("Marten", "MartenX")
        : null;
    final extraHeaders = {
      'X-Device-ID': deviceIdentity.deviceId,
      'X-Client-Secret': deviceIdentity.clientSecret,
      'X-Marten-Capabilities': 'icmp-v1',
    };

    Future<Response> download(String targetUrl, {String method = 'GET'}) {
      return _httpClient.download(
        targetUrl,
        tempFilePath,
        method: method,
        cancelToken: cancelToken,
        userAgent: userAgent,
        extraHeaders: extraHeaders,
      );
    }

    final candidates = refresh ? subscriptionCandidateUrls(requestUrl, profile: profile) : [requestUrl];
    loggy.debug('subscription_download phase=start refresh=$refresh candidate_count=${candidates.length}');
    Object? lastError;
    Response? rs;
    String successfulUrl = requestUrl;

    for (var candidateIndex = 0; candidateIndex < candidates.length; candidateIndex++) {
      final candidate = candidates[candidateIndex];
      final attemptIndex = candidateIndex + 1;
      final refreshUrl = refreshUrlFor(candidate);
      final useRefreshEndpoint = refresh && refreshUrl != null;
      final primaryMethod = useRefreshEndpoint ? 'refresh_post' : 'canonical_get';
      _logDownloadAttempt(
        phase: 'attempt',
        candidateIndex: attemptIndex,
        candidateCount: candidates.length,
        method: primaryMethod,
      );
      try {
        rs = await download(
          useRefreshEndpoint ? refreshUrl.toString() : candidate,
          method: useRefreshEndpoint ? 'POST' : 'GET',
        );
        successfulUrl = candidate;
        _logDownloadAttempt(
          phase: 'success',
          candidateIndex: attemptIndex,
          candidateCount: candidates.length,
          method: primaryMethod,
        );
        break;
      } catch (err) {
        _logDownloadFailure(
          phase: 'failure',
          candidateIndex: attemptIndex,
          candidateCount: candidates.length,
          method: primaryMethod,
          error: err,
        );
        final martenRedirectTarget = martenImportRedirectTargetFromError(err) ?? martenImportDownloadTarget(candidate);
        if (martenRedirectTarget != null) {
          _logDownloadFallback(
            candidateIndex: attemptIndex,
            candidateCount: candidates.length,
            fallback: 'import_redirect_get',
          );
          try {
            rs = await download(martenRedirectTarget);
            successfulUrl = martenRedirectTarget;
            _logDownloadAttempt(
              phase: 'success',
              candidateIndex: attemptIndex,
              candidateCount: candidates.length,
              method: 'import_redirect_get',
            );
            break;
          } catch (redirectErr) {
            _logDownloadFailure(
              phase: 'fallback_failure',
              candidateIndex: attemptIndex,
              candidateCount: candidates.length,
              method: 'import_redirect_get',
              error: redirectErr,
            );
            lastError = redirectErr;
          }
        } else if (useRefreshEndpoint && _shouldFallbackFromRefresh(err)) {
          _logDownloadFallback(
            candidateIndex: attemptIndex,
            candidateCount: candidates.length,
            fallback: 'canonical_get',
          );
          try {
            rs = await download(candidate);
            successfulUrl = candidate;
            _logDownloadAttempt(
              phase: 'success',
              candidateIndex: attemptIndex,
              candidateCount: candidates.length,
              method: 'canonical_get',
            );
            break;
          } catch (fallbackErr) {
            _logDownloadFailure(
              phase: 'fallback_failure',
              candidateIndex: attemptIndex,
              candidateCount: candidates.length,
              method: 'canonical_get',
              error: fallbackErr,
            );
            lastError = fallbackErr;
          }
        } else {
          lastError = err;
        }
        final errToThrow = lastError;
        if (!_isRetryableEndpointFailure(errToThrow)) {
          _throwDownloadFailure(errToThrow);
        }
        loggy.debug(
          'subscription_download phase=rotate candidate_index=$attemptIndex '
          'candidate_count=${candidates.length} has_next=${attemptIndex < candidates.length}',
        );
      }
    }
    if (rs == null) {
      loggy.debug('subscription_download phase=exhausted candidate_count=${candidates.length}');
      _throwDownloadFailure(lastError ?? StateError('subscription download failed'));
    }

    // decrypt envelope if the server sent one
    final rawContent = await File(tempFilePath).readAsString();
    if (SubscriptionEnvelope.isEnvelope(rawContent)) {
      final serverDeviceSecret = rs.headers.value('x-device-secret') ?? '';
      final plaintext = await SubscriptionEnvelope.decrypt(rawContent, serverDeviceSecret, deviceIdentity.clientSecret);
      await File(tempFilePath).writeAsString(plaintext);
    }

    await expandRemoteLinesInParallel(
      tempFilePath: tempFilePath,
      httpClient: _httpClient,
      cancelToken: cancelToken ?? CancelToken(),
      ref: _ref,
    );
    final parsedEndpoints = subscriptionEndpointsFromContent(await File(tempFilePath).readAsString());
    final fallbackEndpoint = subscriptionEndpointFor(successfulUrl);
    final endpoints = parsedEndpoints.isNotEmpty ? parsedEndpoints : [if (fallbackEndpoint != null) fallbackEndpoint];
    final currentEndpoint = fallbackEndpoint != null && endpoints.contains(fallbackEndpoint)
        ? fallbackEndpoint
        : (endpoints.isNotEmpty ? endpoints.first : fallbackEndpoint);
    final headers = rs.headers.map.map((key, value) {
      if (value.length == 1) return MapEntry(key, value.first);
      return MapEntry(key, value);
    });
    return _ProfileDownloadResult(headers: headers, endpoints: endpoints, currentEndpoint: currentEndpoint);
  }, (err, st) => err is ProfileFailure ? err : ProfileFailure.unexpected(err, st));

  void _logDownloadAttempt({
    required String phase,
    required int candidateIndex,
    required int candidateCount,
    required String method,
  }) {
    loggy.debug(
      'subscription_download phase=$phase candidate_index=$candidateIndex '
      'candidate_count=$candidateCount method=$method',
    );
  }

  void _logDownloadFallback({required int candidateIndex, required int candidateCount, required String fallback}) {
    loggy.debug(
      'subscription_download phase=fallback candidate_index=$candidateIndex '
      'candidate_count=$candidateCount fallback=$fallback',
    );
  }

  void _logDownloadFailure({
    required String phase,
    required int candidateIndex,
    required int candidateCount,
    required String method,
    required Object error,
  }) {
    final diagnostic = _downloadFailureDiagnostic(error);
    loggy.debug(
      'subscription_download phase=$phase candidate_index=$candidateIndex '
      'candidate_count=$candidateCount method=$method category=${diagnostic.category} '
      'error_type=${diagnostic.errorType} http_status_class=${diagnostic.httpStatusClass}',
    );
  }

  static ProfileRefreshFailureDiagnostic _downloadFailureDiagnostic(Object? error) {
    if (error is ProfileFailure) return profileRefreshFailureDiagnostic(error);
    return profileRefreshUnexpectedErrorDiagnostic(error);
  }

  @visibleForTesting
  static Uri? refreshUrlFor(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (segments.length == 2 && segments.first == 'sub' && segments.last != 'refresh') {
      return uri.replace(pathSegments: [...segments, 'refresh']);
    }
    return null;
  }

  @visibleForTesting
  static String? martenImportRedirectTargetFromError(Object err) {
    if (err is! DioException) return null;
    return martenImportRedirectTarget(err.response?.headers.value('location'));
  }

  @visibleForTesting
  static String? martenImportRedirectTarget(String? location) {
    if (location == null || location.trim().isEmpty) return null;
    final parsed = LinkParser.deep(location.trim());
    if (parsed == null) return null;
    final uri = Uri.tryParse(parsed.url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return null;
    return uri.toString();
  }

  @visibleForTesting
  static String? martenImportDownloadTarget(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return null;
    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (segments.length != 3 || segments.first != 'sub' || segments.last != 'import') return null;
    return uri.replace(pathSegments: segments.take(2)).toString();
  }

  static List<String> subscriptionCandidateUrls(String url, {RemoteProfileEntity? profile}) {
    final trimmedUrl = url.trim();
    final endpoint = subscriptionEndpointFor(trimmedUrl);
    if (endpoint == null || profile == null) return [trimmedUrl];

    final endpoints = _normalizeEndpoints([
      if (profile.currentSubscriptionEndpoint != null) profile.currentSubscriptionEndpoint!,
      ...profile.subscriptionEndpoints,
      endpoint,
    ]);
    if (endpoints.isEmpty) return [trimmedUrl];

    final unavailable = profile.unavailableSubscriptionEndpoints.toSet();
    final active = <String>[
      for (final candidate in endpoints)
        if (!unavailable.contains(candidate) || candidate == profile.currentSubscriptionEndpoint) candidate,
    ];
    final ordered = active.isEmpty ? endpoints : active;
    return [for (final candidateEndpoint in ordered) replaceSubscriptionEndpoint(trimmedUrl, candidateEndpoint)];
  }

  @visibleForTesting
  static String? subscriptionEndpointFor(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (segments.length < 2 || segments.first != 'sub' || segments[1].isEmpty) return null;
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString().replaceFirst(RegExp(r'/$'), '');
  }

  @visibleForTesting
  static String replaceSubscriptionEndpoint(String url, String endpoint) {
    final uri = Uri.parse(url.trim());
    final endpointUri = Uri.parse(endpoint.trim());
    return uri
        .replace(
          scheme: endpointUri.scheme,
          userInfo: endpointUri.userInfo,
          host: endpointUri.host,
          port: endpointUri.hasPort ? endpointUri.port : null,
        )
        .toString();
  }

  @visibleForTesting
  static List<String> subscriptionEndpointsFromContent(String content) {
    try {
      final decoded = decodeJsonContent(content);
      if (decoded is! Map) return const [];
      final metadata = decoded['subscription'];
      if (metadata is! Map) return const [];
      final rawEndpoints = metadata['endpoints'];
      if (rawEndpoints is! List) return const [];
      return _normalizeEndpoints(rawEndpoints.map((item) => item.toString()));
    } catch (_) {
      return const [];
    }
  }

  @visibleForTesting
  static String? subscriptionNameFromContent(String content) {
    try {
      final decoded = decodeJsonContent(content);
      if (decoded is! Map) return null;
      final metadata = decoded['subscription'];
      if (metadata is! Map || metadata['name'] is! String) return null;
      final name = (metadata['name'] as String).trim();
      return name.isEmpty ? null : name;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static DateTime? subscriptionExpiresAtFromContent(String content) {
    try {
      final decoded = decodeJsonContent(content);
      if (decoded is! Map) return null;
      final metadata = decoded['subscription'];
      if (metadata is! Map || metadata['expires_at'] is! String) return null;
      return DateTime.tryParse((metadata['expires_at'] as String).trim())?.toLocal();
    } catch (_) {
      return null;
    }
  }

  static List<String> _normalizeEndpoints(Iterable<String> values) {
    final seen = <String>{};
    final endpoints = <String>[];
    for (final value in values) {
      final uri = Uri.tryParse(value.trim());
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) continue;
      if (uri.scheme != 'http' && uri.scheme != 'https') continue;
      final endpoint = Uri(
        scheme: uri.scheme,
        userInfo: uri.userInfo,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      ).toString().replaceFirst(RegExp(r'/$'), '');
      if (seen.add(endpoint)) endpoints.add(endpoint);
    }
    return endpoints;
  }

  static bool _shouldFallbackFromRefresh(Object err) {
    if (err is! DioException) return false;
    final statusCode = err.response?.statusCode;
    return statusCode == 404 ||
        statusCode == 405 ||
        statusCode == 501 ||
        (statusCode == null && err.type == DioExceptionType.connectionError);
  }

  static bool _isRetryableEndpointFailure(Object? err) {
    if (err is! DioException) return false;
    final statusCode = err.response?.statusCode;
    if (statusCode == null) return true;
    return _retryableStatusCodes.contains(statusCode);
  }

  Never _throwDownloadFailure(Object err) {
    if (err is DioException) {
      if (CancelToken.isCancel(err)) {
        throw const ProfileFailure.cancelByUser('HTTP request for getting profile content canceled by user.');
      }
      if (err.response?.statusCode == 403) {
        throw const ProfileFailure.deviceMismatch();
      }
    }
    throw err;
  }

  Future<void> expandRemoteLinesInParallel({
    required String tempFilePath,
    required DioHttpClient httpClient,
    required CancelToken cancelToken,
    required Ref ref,
    int parallelism = 4,
  }) async {
    final content = await File(tempFilePath).readAsString();
    final lines = content.split('\n');
    final remoteIncludeCount = lines.where((line) => line.startsWith('http://') || line.startsWith('https://')).length;
    if (remoteIncludeCount > maxRemoteIncludes) {
      throw const ProfileFailure.invalidConfig('too many remote subscription includes');
    }

    final results = List<String?>.filled(lines.length, null);
    var expandedBytes = 0;

    void storeResult(int resultIndex, String value) {
      expandedBytes += utf8.encode(value).length + 1;
      if (expandedBytes > maxExpandedProfileBytes) {
        throw const ProfileFailure.invalidConfig('expanded subscription is too large');
      }
      results[resultIndex] = value;
    }

    int index = 0;

    Future<void> worker() async {
      while (true) {
        if (cancelToken.isCancelled) return;

        final currentIndex = index++;
        if (currentIndex >= lines.length) return;

        final line = lines[currentIndex];

        // Non-URL
        if (!line.startsWith('http://') && !line.startsWith('https://')) {
          storeResult(currentIndex, line.trim());
          continue;
        }

        try {
          final includeFile = File('$tempFilePath.$currentIndex');
          final include = await readRemoteIncludeWithCleanup(
            includeFile,
            () => httpClient.download(
              line,
              includeFile.path,
              cancelToken: cancelToken,
              userAgent: ref.read(ConfigOptions.useXrayCoreWhenPossible)
                  ? httpClient.userAgent.replaceAll('Marten', 'MartenX')
                  : null,
            ),
          );
          storeResult(currentIndex, include);
        } catch (err) {
          if (err is ProfileFailure) rethrow;
          if (err is DioException && CancelToken.isCancel(err)) {
            return;
          }
          results[currentIndex] = '';
        }
      }
    }

    // Start workers
    await Future.wait(List.generate(parallelism, (_) => worker()));
    if (cancelToken.isCancelled) {
      throw const ProfileFailure.cancelByUser('remote subscription include expansion canceled');
    }

    if (results.any((e) => e != null)) {
      final newContent = results.join("\n");
      await File(tempFilePath).writeAsString(newContent);
    }
  }

  @visibleForTesting
  static Future<String> readRemoteIncludeWithCleanup(File includeFile, Future<void> Function() download) async {
    try {
      await download();
      return (await includeFile.readAsString()).trim();
    } finally {
      if (await includeFile.exists()) await includeFile.delete();
    }
  }

  static Either<ProfileFailure, Map<String, dynamic>> populateHeaders({
    required String content,
    Map<String, dynamic>? remoteHeaders,
  }) => Either.tryCatch(() {
    final contentHeaders = _parseHeadersFromContent(content);
    return _mergeAndValidateHeaders(contentHeaders, remoteHeaders ?? {});
  }, ProfileFailure.unexpected);

  static Map<String, dynamic> _mergeAndValidateHeaders(
    Map<String, dynamic> contentHeaders,
    Map<String, dynamic> remoteHeaders,
  ) {
    final normalizedRemoteHeaders = {for (final entry in remoteHeaders.entries) entry.key.toLowerCase(): entry.value};
    for (final entry in contentHeaders.entries) {
      if (!normalizedRemoteHeaders.keys.contains(entry.key)) {
        normalizedRemoteHeaders[entry.key] = entry.value;
      }
    }
    final headers = <String, dynamic>{};
    for (final entry in normalizedRemoteHeaders.entries) {
      if (allowedProfileHeaders.contains(entry.key) && entry.value != null && entry.value.toString().isNotEmpty) {
        headers[entry.key] = entry.value;
      }
    }
    return headers;
  }

  static Map<String, dynamic> _parseHeadersFromContent(String content) {
    final headers = <String, dynamic>{};
    final content_ = safeDecodeBase64(content);
    final lines = content_.split("\n");
    final linesToProcess = lines.length < 10 ? lines.length : 10;
    for (int i = 0; i < linesToProcess; i++) {
      final line = lines[i];
      if (line.startsWith("#") || line.startsWith("//")) {
        final index = line.indexOf(':');
        if (index == -1) continue;
        final key = line.substring(0, index).replaceFirst(RegExp("^#|//"), "").trim().toLowerCase();
        final value = line.substring(index + 1).trim();
        headers[key] = value;
      }
    }
    return headers;
  }

  static SubscriptionInfo? _parseSubscriptionInfo(String subInfoStr) {
    final values = subInfoStr.split(';');
    final map = {for (final v in values) v.split('=').first.trim(): num.tryParse(v.split('=').second.trim())?.toInt()};
    if (map case {"upload": final upload?, "download": final download?, "total": final total, "expire": var expire}) {
      final total1 = (total == null || total == 0) ? infiniteTrafficThreshold + 1 : total;
      expire = (expire == null || expire == 0) ? infiniteTimeThreshold : expire;
      return SubscriptionInfo(
        upload: upload,
        download: download,
        total: total1,
        expire: DateTime.fromMillisecondsSinceEpoch(expire * 1000),
      );
    }
    return null;
  }

  @visibleForTesting
  static Either<ProfileFailure, ProfileEntity> parse({required String tempFilePath, required ProfileEntity profile}) =>
      Either.tryCatch(() {
        final headers = Map<String, dynamic>.from(profile.populatedHeaders ?? {});
        final rawContent = tempFilePath.isNotEmpty && File(tempFilePath).existsSync()
            ? File(tempFilePath).readAsStringSync()
            : '';
        var name = '';
        if (subscriptionNameFromContent(rawContent) case final String subscriptionName) {
          name = subscriptionName;
        }

        if (profile.userOverride?.name case final String oName when oName.isNotEmpty && name.isEmpty) {
          name = oName;
        }

        if (headers['profile-title'] case final String titleHeader when name.isEmpty) {
          if (titleHeader.startsWith("base64:")) {
            name = utf8.decode(base64.decode(titleHeader.replaceFirst("base64:", "")));
          } else {
            name = titleHeader.trim();
          }
        }
        if (headers['content-disposition'] case final String contentDispositionHeader when name.isEmpty) {
          final regExp = RegExp('filename="([^"]*)"');
          final match = regExp.firstMatch(contentDispositionHeader);
          if (match != null && match.groupCount >= 1) {
            name = match.group(1) ?? '';
          }
        }
        if (profile case RemoteProfileEntity(:final url)) {
          if (Uri.parse(url).fragment case final fragment when name.isEmpty) {
            name = fragment;
          }
          if (url.split("/").lastOrNull case final part? when name.isEmpty) {
            final pattern = RegExp(r"\.(json|yaml|yml|txt)[\s\S]*");
            name = part.replaceFirst(pattern, "");
          }
        }
        if (name.isBlank) {
          switch (profile) {
            case RemoteProfileEntity():
              name = "Remote Profile";

            case LocalProfileEntity():
              name = protocol(File(tempFilePath).readAsStringSync());
          }
        }

        if (headers['enable-fragment'].toString() == 'true' || profile.userOverride?.enableFragment == true) {
          headers['tls-tricks'] = {'enable-fragment': true};
        }

        final bypassApps = splitTunnelBypassApps(rawContent);
        if (bypassApps.isNotEmpty) {
          headers['exclude-package'] = bypassApps;
        }

        final isAutoUpdateDisable = profile.userOverride?.isAutoUpdateDisable ?? false;
        Duration? updateInterval;
        if (profile.userOverride?.updateInterval case final int overrideHours
            when overrideHours > 0 && !isAutoUpdateDisable) {
          updateInterval = Duration(hours: overrideHours);
        }
        if (headers['profile-update-interval'] case final String updateIntervalStr
            when updateInterval == null && !isAutoUpdateDisable) {
          final hours = int.tryParse(updateIntervalStr);
          if (hours != null && hours > 0) {
            updateInterval = Duration(hours: hours);
          }
        }
        if (profile case RemoteProfileEntity() when updateInterval == null && !isAutoUpdateDisable) {
          updateInterval = defaultUpdateInterval;
        }
        final options = updateInterval != null ? ProfileOptions(updateInterval: updateInterval) : null;

        SubscriptionInfo? subInfo;
        if (headers['subscription-userinfo'] case final String subInfoStr) {
          subInfo = _parseSubscriptionInfo(subInfoStr);
        }

        if (subInfo != null) {
          if (headers['profile-web-page-url'] case final String profileWebPageUrl when isUrl(profileWebPageUrl)) {
            subInfo = subInfo.copyWith(webPageUrl: profileWebPageUrl);
          }
          if (headers['support-url'] case final String profileSupportUrl when isUrl(profileSupportUrl)) {
            subInfo = subInfo.copyWith(supportUrl: profileSupportUrl);
          }
        }

        final metadataExpiresAt = subscriptionExpiresAtFromContent(rawContent);

        headers.removeWhere(
          (key, value) => !allowedOverrideConfigs.contains(key) || value == null || value.toString().isEmpty,
        );

        final profileOverrideStr = jsonEncode({for (final key in headers.keys) key: headers[key]});

        return profile.map(
          remote: (rp) => rp.copyWith(
            name: name,
            lastUpdate: DateTime.now(),
            options: options,
            subInfo: subInfo,
            expiresAt: metadataExpiresAt ?? subInfo?.expire ?? rp.expiresAt,
            populatedHeaders: profile.populatedHeaders,
            profileOverride: profileOverrideStr,
          ),
          local: (lp) => lp.copyWith(
            name: name,
            lastUpdate: DateTime.now(),
            populatedHeaders: profile.populatedHeaders,
            profileOverride: profileOverrideStr,
          ),
        );
      }, ProfileFailure.unexpected);

  static String protocol(String content) {
    if (content.contains("[Interface]")) {
      return ProxyType.wireguard.label;
    }
    final lines = content.split('\n');
    String? name;
    for (final line in lines) {
      final uri = Uri.tryParse(line);
      if (uri == null) continue;
      final fragment = uri.hasFragment ? Uri.decodeComponent(uri.fragment.split(" -> ")[0]) : null;
      name ??= switch (uri.scheme) {
        'ss' => fragment ?? ProxyType.shadowsocks.label,
        'ssconf' => fragment ?? ProxyType.shadowsocks.label,
        'vmess' => ProxyType.vmess.label,
        'vless' => fragment ?? ProxyType.vless.label,
        'trojan' => fragment ?? ProxyType.trojan.label,
        'tuic' => fragment ?? ProxyType.tuic.label,
        'hy2' || 'hysteria2' => fragment ?? ProxyType.hysteria2.label,
        'hy' || 'hysteria' => fragment ?? ProxyType.hysteria.label,
        'ssh' => fragment ?? ProxyType.ssh.label,
        'wg' => fragment ?? ProxyType.wireguard.label,
        'awg' || 'amneziawg' => fragment ?? ProxyType.awg.label,
        'shadowtls' => fragment ?? ProxyType.shadowtls.label,
        'mieru' => fragment ?? ProxyType.mieru.label,
        'turncoat' => fragment ?? ProxyType.turncoat.label,
        _ => null,
      };
    }
    return name ?? ProxyType.unknown.label;
  }

  static Map<String, dynamic> applyProfileOverride(Map<String, dynamic> main, String? profileOverride) {
    if (profileOverride == null) return main;
    if (profileOverride.contains("{")) {
      final profileOverrideMap = jsonDecode(profileOverride) as Map<String, dynamic>;
      return _mergeJson(main, profileOverrideMap);
    } else {
      return main;
    }
  }

  static Map<String, dynamic> _mergeJson(Map<String, dynamic> main, Map<String, dynamic> override) {
    override.forEach((key, value) {
      if (main.containsKey(key)) {
        if (main[key] is Map<String, dynamic> && value is Map<String, dynamic>) {
          main[key] = _mergeJson(main[key] as Map<String, dynamic>, value);
        } else {
          main[key] = value;
        }
      } else {
        main[key] = value;
      }
    });
    return main;
  }

  @visibleForTesting
  static List<String> splitTunnelBypassApps(String content) {
    try {
      final decoded = decodeJsonContent(content);
      if (decoded is! Map) return [];
      final splitTunnel = decoded['split_tunnel'] ?? decoded['split_tunneling'];
      if (splitTunnel is! Map) return [];
      return _normalizePackageNames(splitTunnel['bypass_apps']);
    } catch (_) {
      return [];
    }
  }

  static String stripMartenSubscriptionMetadata(String content) {
    try {
      final decoded = decodeJsonContent(content);
      if (decoded is! Map) return content;
      final config = _sanitizeUnsupportedOutbounds(Map<String, dynamic>.from(decoded));

      // These keys are Marten app metadata. sing-box strict-decodes the
      // top-level config and rejects them if they reach the native core.
      for (final key in const ['split_tunnel', 'split_tunneling', 'servers', 'subscription']) {
        config.remove(key);
      }
      return jsonEncode(config);
    } catch (_) {
      return content;
    }
  }

  static String normalizeMartenSubscriptionContent(String content) {
    try {
      final canonical = canonicalJsonContent(content);
      final decoded = jsonDecode(canonical);
      if (decoded is! Map) return canonical;
      return jsonEncode(_sanitizeUnsupportedOutbounds(Map<String, dynamic>.from(decoded)));
    } catch (_) {
      return content;
    }
  }

  static Map<String, dynamic> _sanitizeUnsupportedOutbounds(Map<String, dynamic> config) {
    config.removeWhere((key, _) => !_supportedTopLevelConfigKeys.contains(key));
    final rawOutbounds = config['outbounds'];
    if (rawOutbounds is! List) return config;

    final removedTags = <String>{};
    var outbounds = <Map<String, dynamic>>[];
    for (final rawOutbound in rawOutbounds) {
      if (rawOutbound is! Map) continue;
      final outbound = Map<String, dynamic>.from(rawOutbound);
      final type = outbound['type'];
      if (type is String && _supportedOutboundTypes.contains(type.toLowerCase())) {
        outbounds.add(outbound);
        continue;
      }
      if (outbound['tag'] case final String tag when tag.isNotEmpty) {
        removedTags.add(tag);
      }
    }

    var removedDependency = true;
    while (removedDependency) {
      removedDependency = false;
      final retained = <Map<String, dynamic>>[];
      for (var outbound in outbounds) {
        final detour = outbound['detour'];
        if (detour is String && removedTags.contains(detour)) {
          if (outbound['tag'] case final String tag when tag.isNotEmpty) {
            removedTags.add(tag);
          }
          removedDependency = true;
          continue;
        }

        final type = outbound['type']?.toString().toLowerCase();
        final references = outbound['outbounds'];
        if ((type == 'selector' || type == 'urltest') && references is List) {
          final filtered = [
            for (final reference in references)
              if (reference is! String || !removedTags.contains(reference)) reference,
          ];
          if (references.isNotEmpty && filtered.isEmpty) {
            if (outbound['tag'] case final String tag when tag.isNotEmpty) {
              removedTags.add(tag);
            }
            removedDependency = true;
            continue;
          }
          if (filtered.length != references.length) {
            outbound = Map<String, dynamic>.from(outbound)..['outbounds'] = filtered;
          }
        }
        retained.add(outbound);
      }
      outbounds = retained;
    }
    config['outbounds'] = outbounds;

    if (!outbounds.any((outbound) => outbound['type']?.toString().toLowerCase() == 'turncoat')) {
      config.remove('providers');
    }
    if (config['servers'] case final List servers) {
      config['servers'] = [
        for (final server in servers)
          if (server is! Map || server['tag'] is! String || !removedTags.contains(server['tag'])) server,
      ];
    }
    if (config['route'] case final Map route) {
      final sanitizedRoute = Map<String, dynamic>.from(route);
      if (sanitizedRoute['final'] case final String finalTag when removedTags.contains(finalTag)) {
        sanitizedRoute.remove('final');
      }
      if (sanitizedRoute['rules'] case final List rules) {
        sanitizedRoute['rules'] = [
          for (final rule in rules)
            if (_sanitizeRouteRule(rule, removedTags) case final sanitizedRule?) sanitizedRule,
        ];
      }
      config['route'] = sanitizedRoute;
    }
    if (config['dns'] case final Map dns) {
      final sanitizedDNS = Map<String, dynamic>.from(dns);
      if (sanitizedDNS['servers'] case final List servers) {
        sanitizedDNS['servers'] = [
          for (final server in servers)
            if (server is! Map || server['detour'] is! String || !removedTags.contains(server['detour'])) server,
        ];
      }
      config['dns'] = sanitizedDNS;
    }
    return config;
  }

  static dynamic _sanitizeRouteRule(dynamic rawRule, Set<String> removedTags) {
    if (rawRule is! Map) return rawRule;
    final rule = Map<String, dynamic>.from(rawRule);
    if (rule['outbound'] case final String outbound when removedTags.contains(outbound)) {
      return null;
    }
    if (rule['rules'] case final List nestedRules) {
      final sanitizedRules = [
        for (final nestedRule in nestedRules)
          if (_sanitizeRouteRule(nestedRule, removedTags) case final sanitizedRule?) sanitizedRule,
      ];
      if (nestedRules.isNotEmpty && sanitizedRules.isEmpty) return null;
      rule['rules'] = sanitizedRules;
    }
    return rule;
  }

  /// Background isolates cannot ask the activity-bound native core to parse a
  /// candidate. Reject obvious error pages, empty/truncated JSON and unknown
  /// payloads before they can replace the last-known-good encrypted profile.
  static Either<ProfileFailure, String> validateBackgroundCandidate(String content) {
    return Either.tryCatch(
      () {
        final normalizedInput = normalizeJsonContentInput(normalizeMartenSubscriptionContent(content)).trim();
        if (normalizedInput.isEmpty) {
          throw const ProfileFailure.invalidConfig('empty background subscription update');
        }

        if (normalizedInput.startsWith('{') || normalizedInput.startsWith('[')) {
          final decoded = jsonDecode(normalizedInput);
          if (decoded is! Map || decoded['outbounds'] is! List || (decoded['outbounds'] as List).isEmpty) {
            throw const ProfileFailure.invalidConfig('background subscription update has no outbounds');
          }
          return jsonEncode(decoded);
        }

        final decodedLinks = safeDecodeBase64(content).trim();
        if (protocol(decodedLinks) != ProxyType.unknown.label) {
          return decodedLinks;
        }
        throw const ProfileFailure.invalidConfig('unsupported background subscription update');
      },
      (error, stackTrace) {
        if (error is ProfileFailure) return error;
        return ProfileFailure.invalidConfig('invalid background subscription update: $error');
      },
    );
  }

  static List<String> _normalizePackageNames(dynamic value) {
    final rawItems = switch (value) {
      List() => value.map((e) => e.toString()),
      String() => value.split(RegExp(r'[\r\n,;]+')),
      _ => const Iterable<String>.empty(),
    };
    final seen = <String>{};
    final packagePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$');
    final packageNames = <String>[];
    for (final raw in rawItems) {
      final packageName = raw.trim();
      if (!packagePattern.hasMatch(packageName) || !seen.add(packageName)) continue;
      packageNames.add(packageName);
    }
    return packageNames;
  }
}
