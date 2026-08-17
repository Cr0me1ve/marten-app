import 'dart:convert';

/// Converts client-specific subscription documents into the canonical Marten
/// profile shape without depending on the activity-bound native parser. This
/// makes the same conversion available to foreground and headless refreshes.
abstract final class SubscriptionContentAdapter {
  static String normalize(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty || (!trimmed.startsWith('{') && !trimmed.startsWith('['))) {
      return content;
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return content;
    }

    final List<Map<String, dynamic>> profiles;
    if (decoded case final Map<dynamic, dynamic> value when _isXrayConfig(value)) {
      profiles = [Map<String, dynamic>.from(value)];
    } else if (decoded case final List<dynamic> values when values.isNotEmpty) {
      final containsXray = values.any((item) => item is Map && _isXrayConfig(item));
      if (!containsXray) return content;
      profiles = <Map<String, dynamic>>[];
      for (var index = 0; index < values.length; index++) {
        final item = values[index];
        if (item is! Map || !_isXrayConfig(item)) {
          throw FormatException('Xray subscription item $index is invalid');
        }
        profiles.add(Map<String, dynamic>.from(item));
      }
    } else {
      return content;
    }

    final usedTags = <String, int>{};
    final outbounds = <Map<String, dynamic>>[];
    for (var index = 0; index < profiles.length; index++) {
      final profile = _normalizeXrayProfile(profiles[index]);
      var remarks = profile.remove('remarks')?.toString().trim() ?? '';
      if (remarks.isEmpty) remarks = _firstProxyTag(profile);
      if (remarks.isEmpty) remarks = 'XRay ${index + 1}';
      final count = usedTags.update(remarks, (value) => value + 1, ifAbsent: () => 1);
      final tag = count == 1 ? remarks : '$remarks ($count)';
      outbounds.add({'type': 'xray', 'tag': tag, 'xconfig': profile});
    }
    return jsonEncode({'outbounds': outbounds});
  }

  static bool _isXrayConfig(Map<dynamic, dynamic> value) {
    final outbounds = value['outbounds'];
    return outbounds is List &&
        outbounds.isNotEmpty &&
        outbounds.any((item) => item is Map && (item['protocol']?.toString().trim().isNotEmpty ?? false));
  }

  static Map<String, dynamic> _normalizeXrayProfile(Map<String, dynamic> source) {
    final profile = Map<String, dynamic>.from(jsonDecode(jsonEncode(source)) as Map);
    final removedInboundTags = <String>{
      for (final item in _maps(profile['inbounds']))
        if (item['tag']?.toString().trim() case final String tag when tag.isNotEmpty) tag,
    };
    profile.remove('inbounds');

    final removedOutboundTags = <String>{};
    final proxyTags = <String>[];
    final retainedOutbounds = <Map<String, dynamic>>[];
    for (final outbound in _maps(profile['outbounds'])) {
      final protocol = outbound['protocol']?.toString().trim().toLowerCase() ?? '';
      final tag = outbound['tag']?.toString().trim() ?? '';
      if (protocol == 'loopback') {
        if (tag.isNotEmpty) removedOutboundTags.add(tag);
        continue;
      }
      retainedOutbounds.add(outbound);
      if (tag.isNotEmpty && _isProxyProtocol(protocol)) proxyTags.add(tag);
    }
    if (proxyTags.isEmpty) {
      throw const FormatException('embedded Xray config has no proxy outbound');
    }
    profile['outbounds'] = retainedOutbounds;

    if (profile['routing'] case final Map<dynamic, dynamic> rawRouting) {
      final routing = Map<String, dynamic>.from(rawRouting);
      if (routing['rules'] case final List<dynamic> rawRules) {
        routing['rules'] = <dynamic>[
          for (final rawRule in rawRules)
            if (rawRule is! Map ||
                (!_referencesAny(rawRule['inboundTag'], removedInboundTags) &&
                    !_referencesAny(rawRule['outboundTag'], removedOutboundTags)))
              rawRule,
        ];
      }
      if (routing['balancers'] case final List<dynamic> rawBalancers) {
        final proxyTagSet = proxyTags.toSet();
        routing['balancers'] = <dynamic>[
          for (final rawBalancer in rawBalancers)
            if (rawBalancer is! Map)
              rawBalancer
            else
              _normalizeBalancer(Map<String, dynamic>.from(rawBalancer), proxyTags, proxyTagSet),
        ];
      }
      profile['routing'] = routing;
    }
    return profile;
  }

  static Map<String, dynamic> _normalizeBalancer(
    Map<String, dynamic> balancer,
    List<String> proxyTags,
    Set<String> proxyTagSet,
  ) {
    final fallback = balancer['fallbackTag']?.toString().trim() ?? '';
    if (!proxyTagSet.contains(fallback)) {
      balancer['fallbackTag'] = _fallbackForSelectors(balancer['selector'], proxyTags);
    }
    return balancer;
  }

  static String _fallbackForSelectors(dynamic rawSelectors, List<String> proxyTags) {
    if (rawSelectors is List) {
      for (final rawSelector in rawSelectors) {
        final selector = rawSelector?.toString().trim() ?? '';
        if (selector.isEmpty) continue;
        for (final tag in proxyTags) {
          if (tag == selector || tag.startsWith(selector)) return tag;
        }
      }
    }
    return proxyTags.first;
  }

  static bool _referencesAny(dynamic raw, Set<String> tags) {
    if (tags.isEmpty) return false;
    if (raw is String) return tags.contains(raw.trim());
    if (raw is List) return raw.any((item) => tags.contains(item?.toString().trim()));
    return false;
  }

  static bool _isProxyProtocol(String protocol) =>
      protocol.isNotEmpty && !const {'freedom', 'blackhole', 'dns', 'loopback'}.contains(protocol);

  static Iterable<Map<String, dynamic>> _maps(dynamic raw) sync* {
    if (raw is! List) return;
    for (final item in raw) {
      if (item is Map) yield Map<String, dynamic>.from(item);
    }
  }

  static String _firstProxyTag(Map<String, dynamic> profile) {
    for (final outbound in _maps(profile['outbounds'])) {
      final protocol = outbound['protocol']?.toString().trim().toLowerCase() ?? '';
      if (!_isProxyProtocol(protocol)) continue;
      final tag = outbound['tag']?.toString().trim() ?? '';
      if (tag.isNotEmpty) return tag;
    }
    return '';
  }
}
