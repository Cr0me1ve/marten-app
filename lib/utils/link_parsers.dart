import 'dart:convert';

import 'package:marten/utils/validators.dart';

typedef ProfileLink = ({String url, String name, String? pushEndpoint});

/// Normalizes subscription links shared by Marten and other proxy clients.
///
/// Client-specific links are only transport wrappers. Their payload must still
/// resolve to a remote HTTP(S) subscription or to configuration content that
/// the core already understands. This keeps custom URL schemes from becoming
/// a way to import arbitrary local files or executable URI schemes.
abstract class LinkParser {
  static const _wrapperProtocols = <String>{
    'marten',
    'v2ray',
    'v2rayn',
    'v2rayng',
    'clash',
    'clashmeta',
    'sing-box',
    'singbox',
    'happ',
    'hiddify',
    'incy',
    'icny',
    'streisand',
    'v2box',
    'v2raytun',
    'shadowrocket',
    'sub',
    'stash',
    'surge',
    'loon',
    'quantumult',
    'quantumult-x',
    'karing',
    'mihomo',
    'clashx',
    'clash-verge',
    'flclashx',
    'koala-clash',
    'prizrak-box',
    'nekobox',
    'nekoray',
    'surfboard',
  };

  /// Single-server share links accepted by the bundled configuration parser.
  /// They are registered with the OS so a tapped share link can be imported as
  /// local profile content instead of being mistaken for a download URL.
  static const _shareProtocols = <String>{
    'turncoat',
    'vless',
    'svless',
    'vmess',
    'svmess',
    'trojan',
    'strojan',
    'ss',
    'tuic',
    'hysteria',
    'hysteria2',
    'hy2',
    'ssh',
    'wg',
    'wireguard',
    'ssconf',
    'ssconf+http',
    'warp',
    'socks',
    'phttp',
    'phttps',
    'xvmess',
    'xvless',
    'xtrojan',
  };

  /// URL schemes registered by the platform runners and by Windows at runtime.
  static const protocols = <String>[..._wrapperProtocols, ..._shareProtocols];

  static const _payloadQueryKeys = <String>[
    'url',
    'subscription',
    'subscribe',
    'sub',
    'nodelist',
    'config',
    'link',
    'target',
    'remote-resource',
    'content',
  ];

  static const _nameQueryKeys = <String>['name', 'remark', 'title', 'tag'];

  static const _wrapperActions = <String>{
    'add',
    'import',
    'install-config',
    'install-sub',
    'install-proxy',
    'import-remote-profile',
    'add-resource',
    'update-configuration',
  };

  static String generateSubShareLink(String url, [String? name]) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    final modifiedUri = Uri(
      scheme: uri.scheme,
      host: uri.host,
      path: uri.path,
      query: uri.query,
      fragment: name ?? uri.fragment,
    );
    return '$modifiedUri';
  }

  static ProfileLink? parse(String link) => simple(link) ?? deep(link);

  static ProfileLink? simple(String link) {
    if (!isUrl(link)) return null;
    final uri = Uri.parse(link.trim());
    return (url: uri.toString(), name: uri.queryParameters['name'] ?? '', pushEndpoint: null);
  }

  /// Whether [value] is a URL that should be downloaded as a remote profile.
  static bool isRemoteProfileUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return false;
    return const {'http', 'https', 'ftp'}.contains(uri.scheme.toLowerCase());
  }

  static ProfileLink? deep(String link) {
    try {
      final raw = link.trim();
      final uri = Uri.tryParse(raw);
      if (uri == null || !uri.hasScheme) return null;

      final scheme = uri.scheme.toLowerCase();
      if (!_wrapperProtocols.contains(scheme)) return null;
      if (scheme == 'happ' && _isEncryptedHappLink(uri)) return null;

      final name = _profileName(uri);
      final pushEndpoint = _pushEndpoint(uri, scheme);
      if (uri.queryParameters.containsKey('push') && scheme == 'marten' && pushEndpoint == null) return null;
      for (final key in _payloadQueryKeys) {
        final candidate = uri.queryParameters[key];
        if (candidate == null || candidate.trim().isEmpty) continue;
        final normalized = _normalizePayload(candidate);
        if (normalized != null) return (url: normalized, name: name, pushEndpoint: pushEndpoint);
      }

      final pathPayload = _pathPayload(raw, uri, scheme);
      final normalized = pathPayload == null ? null : _normalizePayload(pathPayload);
      return normalized == null ? null : (url: normalized, name: name, pushEndpoint: pushEndpoint);
    } on FormatException {
      return null;
    }
  }

  static bool _isEncryptedHappLink(Uri uri) {
    final pathAction = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
    final action = (uri.host.isNotEmpty ? uri.host : pathAction).toLowerCase();
    return action == 'crypto' || action.startsWith('crypt');
  }

  static String _profileName(Uri uri) {
    for (final key in _nameQueryKeys) {
      final value = uri.queryParameters[key]?.trim();
      if (value != null && value.isNotEmpty) return _decodePercent(value);
    }
    return uri.hasFragment ? _decodePercent(uri.fragment.trim()) : '';
  }

  static String? _pushEndpoint(Uri uri, String scheme) {
    if (scheme != 'marten') return null;
    final raw = uri.queryParameters['push']?.trim();
    if (raw == null || raw.isEmpty) return null;
    final endpoint = Uri.tryParse(raw);
    if (endpoint == null || endpoint.scheme.toLowerCase() != 'https' || endpoint.host.isEmpty) return null;
    if (endpoint.userInfo.isNotEmpty || endpoint.hasQuery || endpoint.hasFragment) return null;
    return endpoint.toString();
  }

  static String? _pathPayload(String raw, Uri uri, String scheme) {
    if (scheme == 'sub') {
      var payload = raw.substring(raw.indexOf(':') + 1);
      while (payload.startsWith('/')) {
        payload = payload.substring(1);
      }
      final end = [
        payload.indexOf('?'),
        payload.indexOf('#'),
      ].where((index) => index >= 0).fold<int>(payload.length, (current, index) => index < current ? index : current);
      return payload.substring(0, end);
    }

    var payload = uri.path;
    while (payload.startsWith('/')) {
      payload = payload.substring(1);
    }

    if (!uri.hasAuthority && payload.isNotEmpty) {
      final slash = payload.indexOf('/');
      final action = (slash < 0 ? payload : payload.substring(0, slash)).toLowerCase();
      if (_wrapperActions.contains(action)) {
        payload = slash < 0 ? '' : payload.substring(slash + 1);
      }
    }

    if (payload.isEmpty && uri.host.isNotEmpty && !_wrapperActions.contains(uri.host.toLowerCase())) {
      payload = uri.host;
    }
    if (payload.isEmpty) return null;

    final hasPayloadQuery = _payloadQueryKeys.any(uri.queryParameters.containsKey);
    final pathOwnsQuery = !hasPayloadQuery && scheme != 'shadowrocket';
    if (pathOwnsQuery && uri.hasQuery) payload = '$payload?${uri.query}';
    return payload;
  }

  static String? _normalizePayload(String raw, [int depth = 0]) {
    if (depth > 4) return null;
    var value = raw.trim();
    if (value.isEmpty) return null;

    while (value.startsWith('/')) {
      value = value.substring(1);
    }

    if (_isSafeRemoteUrl(value) || _looksLikeSupportedLocalContent(value)) return value;

    if (value.toLowerCase().startsWith('sub://')) {
      return _normalizePayload(value.substring('sub://'.length), depth + 1);
    }

    final structuredUrl = _subscriptionUrlFromStructuredPayload(value);
    if (structuredUrl != null) return structuredUrl;

    final percentDecoded = _decodePercent(value);
    if (percentDecoded != value) {
      final normalized = _normalizePayload(percentDecoded, depth + 1);
      if (normalized != null) return normalized;
    }

    final base64Decoded = _tryDecodeBase64(value);
    if (base64Decoded != null && base64Decoded != value) {
      return _normalizePayload(base64Decoded, depth + 1);
    }
    return null;
  }

  static bool _isSafeRemoteUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.hasAuthority &&
        uri.host.isNotEmpty &&
        const {'http', 'https'}.contains(uri.scheme.toLowerCase());
  }

  static bool _looksLikeSupportedLocalContent(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('[Interface]')) return true;
    if (RegExp(r'(^|\n)\s*proxies\s*:', caseSensitive: false).hasMatch(trimmed)) return true;

    for (final line in trimmed.split(RegExp(r'[\r\n]+'))) {
      final candidate = line.trim();
      if (candidate.isEmpty || candidate.startsWith('#') || candidate.startsWith('//')) continue;
      final uri = Uri.tryParse(candidate);
      if (uri != null && _shareProtocols.contains(uri.scheme.toLowerCase())) return true;
    }

    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) return decoded.isNotEmpty;
        if (decoded is Map) {
          return decoded.containsKey('outbounds') || decoded.containsKey('type') || decoded.containsKey('proxies');
        }
      } on FormatException {
        return false;
      }
    }
    return false;
  }

  static String? _subscriptionUrlFromStructuredPayload(String value) {
    if (!value.trimLeft().startsWith('{') && !value.trimLeft().startsWith('[')) return null;
    try {
      final decoded = jsonDecode(value);
      return _findSubscriptionUrl(decoded);
    } on FormatException {
      return null;
    }
  }

  static String? _findSubscriptionUrl(dynamic value) {
    if (value is String) {
      final candidate = value.split(RegExp(r',\s*[A-Za-z_-]+\s*=')).first.trim();
      return _isSafeRemoteUrl(candidate) ? candidate : null;
    }
    if (value is List) {
      for (final item in value) {
        final found = _findSubscriptionUrl(item);
        if (found != null) return found;
      }
      return null;
    }
    if (value is Map) {
      for (final key in const ['server_remote', 'url', 'subscription', 'subscribe', 'sub']) {
        if (!value.containsKey(key)) continue;
        final found = _findSubscriptionUrl(value[key]);
        if (found != null) return found;
      }
    }
    return null;
  }
}

String _decodePercent(String value) {
  var decoded = value;
  for (var i = 0; i < 3; i++) {
    try {
      final next = Uri.decodeComponent(decoded);
      if (next == decoded) break;
      decoded = next;
    } on FormatException {
      break;
    }
  }
  return decoded;
}

String? _tryDecodeBase64(String value) {
  final compact = value.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty || !RegExp(r'^[A-Za-z0-9+/_-]+={0,2}$').hasMatch(compact)) return null;

  var normalized = compact.replaceAll('-', '+').replaceAll('_', '/');
  switch (normalized.length % 4) {
    case 0:
      break;
    case 2:
      normalized = '$normalized==';
    case 3:
      normalized = '$normalized=';
    default:
      return null;
  }
  try {
    return utf8.decode(base64Decode(normalized));
  } on FormatException {
    return null;
  }
}

String safeDecodeBase64(String str) => _tryDecodeBase64(str) ?? str;
