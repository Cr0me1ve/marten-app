import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/features/profile/data/profile_data_providers.dart';
import 'package:marten/features/profile/notifier/active_profile_notifier.dart';
import 'package:marten/utils/custom_loggers.dart';
import 'package:marten/utils/json_content.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalOutbound {
  const LocalOutbound({
    required this.tag,
    required this.type,
    required this.server,
    required this.serverPort,
    this.countryCode,
    this.tlsServerName,
    this.tunnelPingUrl,
    this.callUrls = const [],
    this.usesTurncoat = false,
  });

  final String tag;
  final String type;
  final String server;
  final int serverPort;
  final String? countryCode;
  final String? tlsServerName;

  String get displayName => stripTagMetadata(tag);

  /// HTTP URL the marten-agent on the corresponding node serves under
  /// /tunnel/ping. A 200 response with `{"ok":true}` proves the full data
  /// path (entry -> cascade -> exit -> internet on cascade entry nodes;
  /// default route on single nodes) is alive — without the client
  /// establishing the VPN itself.
  final String? tunnelPingUrl;

  /// TURNcoat call-invite URLs, copied from this outbound or one of its
  /// hidden TURNcoat dependencies.
  final List<String> callUrls;

  /// True when this visible outbound itself is TURNcoat or routes through a
  /// hidden TURNcoat helper via `detour`.
  final bool usesTurncoat;
}

const _excludedTypes = {'selector', 'urltest', 'dns', 'block', 'direct'};
const _excludedTags = {'direct', 'bypass', 'direct-fragment', 'dns-out', 'block'};
const _coreSelectableExcludedTypes = {'selector', 'urltest', 'dns', 'block', 'direct', 'custom', 'turncoat'};
const _tunnelPingPort = 9443;

final localOutboundsProvider = FutureProvider<List<LocalOutbound>>((ref) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return const [];

  final repo = await ref.watch(profileRepositoryProvider.future);
  final raw = await repo.getRawConfig(profile.id).run().then((e) => e.getOrElse((_) => ''));
  return parseLocalOutboundsResponsively(raw);
});

const localOutboundsBackgroundParseThreshold = 64 * 1024;

Future<List<LocalOutbound>> parseLocalOutboundsResponsively(String raw) {
  if (raw.length < localOutboundsBackgroundParseThreshold) {
    return Future.value(parseLocalOutbounds(raw));
  }
  return compute(parseLocalOutbounds, raw, debugLabel: 'parse local outbounds');
}

List<LocalOutbound> parseLocalOutbounds(String raw) {
  if (raw.isEmpty) return const [];
  try {
    final parsed = decodeJsonContent(raw);
    if (parsed is! Map) return const [];
    final out = parsed['outbounds'];
    if (out is! List) return const [];

    // Per-outbound metadata block emitted by master in the same JSON. Used
    // for pre-connect tunnel ping. Stripped by marten-core before the
    // sing-box load; we read it from the raw config directly.
    final serverInfo = <String, _ServerInfo>{};
    final servers = parsed['servers'];
    if (servers is List) {
      for (final s in servers) {
        if (s is! Map<String, dynamic>) continue;
        final tag = s['tag']?.toString() ?? '';
        if (tag.isEmpty) continue;
        final pingUrl = s['tunnel_ping_url']?.toString();
        final callRaw = s['call_urls'];
        final calls = <String>[];
        if (callRaw is List) {
          for (final c in callRaw) {
            final v = c?.toString();
            if (v != null && v.isNotEmpty) calls.add(v);
          }
        }
        final server = s['server']?.toString() ?? '';
        final serverPort = (s['server_port'] is int)
            ? s['server_port'] as int
            : int.tryParse(s['server_port']?.toString() ?? '') ?? 0;
        final tlsServerName = firstNonEmptyString([s['server_name'], s['tls_server_name'], s['sni']]);
        serverInfo[tag] = _ServerInfo(
          server: server.isNotEmpty ? server : null,
          serverPort: serverPort > 0 ? serverPort : null,
          tlsServerName: tlsServerName,
          tunnelPingUrl: pingUrl?.isNotEmpty == true ? pingUrl : null,
          callUrls: calls,
        );
      }
    }

    final byTag = _outboundsByTag(out);
    final result = <LocalOutbound>[];
    for (final ob in out) {
      if (ob is! Map<String, dynamic>) continue;
      final tag = ob['tag']?.toString() ?? '';
      final rawType = (ob['type']?.toString() ?? '').toLowerCase();
      final type = displayTypeForOutbound(ob);
      if (tag.isEmpty || type.isEmpty) continue;
      if (_excludedTypes.contains(rawType)) continue;
      if (_excludedTags.contains(tag)) continue;
      final info = serverInfo[tag];
      final serverFromMetadata = info?.server?.trim() ?? '';
      final serverFromOutbound = ob['server']?.toString().trim() ?? '';
      final portFromOutbound = (ob['server_port'] is int)
          ? ob['server_port'] as int
          : int.tryParse(ob['server_port']?.toString() ?? '') ?? 0;
      final port = (info?.serverPort ?? 0) > 0 ? info!.serverPort! : portFromOutbound;
      final tlsServerName = firstNonEmptyString([info?.tlsServerName, tlsServerNameForOutbound(ob)]);
      final server = serverFromMetadata.isNotEmpty ? serverFromMetadata : serverFromOutbound;
      if (hasTagMetadata(tag) && info == null) continue;
      result.add(
        LocalOutbound(
          tag: tag,
          type: type,
          server: server,
          serverPort: port,
          tlsServerName: tlsServerName,
          countryCode: countryCodeFromTag(tag),
          tunnelPingUrl: info?.tunnelPingUrl ?? tunnelPingUrlForServer(server),
          callUrls: _callUrlsForOutbound(tag, byTag, serverInfo),
          usesTurncoat: _outboundUsesTurncoat(tag, byTag),
        ),
      );
    }
    return result;
  } catch (_) {
    return const [];
  }
}

String displayTypeForOutbound(Map<String, dynamic> outbound) {
  final type = (outbound['type']?.toString() ?? '').toLowerCase();
  if (displayTypeForProxyLabel(type) == 'vless' || (type == 'xray' && _xrayOutboundCarriesVless(outbound))) {
    return 'vless';
  }
  return type;
}

String displayTypeForProxyLabel(String type) {
  final normalized = type.trim().toLowerCase();
  return _isVlessLikeType(normalized) ? 'vless' : type;
}

bool _isVlessLikeType(String type) {
  return type == 'vless' || type == 'xvless' || type == 'x-vless' || type == 'x_vless';
}

bool _xrayOutboundCarriesVless(Map<String, dynamic> outbound) {
  final xconfig = outbound['xconfig'];
  if (xconfig is Map) {
    final nested = xconfig['outbounds'];
    if (nested is List) {
      for (final item in nested) {
        if (item is Map && (item['protocol']?.toString().toLowerCase() == 'vless')) {
          return true;
        }
      }
    }
    if (xconfig['protocol']?.toString().toLowerCase() == 'vless') {
      return true;
    }
  }
  final raw = outbound['xray_outbound_raw'];
  if (raw is Map && raw['protocol']?.toString().toLowerCase() == 'vless') {
    return true;
  }
  return false;
}

String? tlsServerNameForOutbound(Map<String, dynamic> outbound) {
  final tls = outbound['tls'];
  if (tls is Map) {
    final value = firstNonEmptyString([tls['server_name'], tls['serverName']]);
    if (value != null) return value;
  }

  final xconfig = outbound['xconfig'];
  final fromXconfig = _xrayTLSServerName(xconfig);
  if (fromXconfig != null) return fromXconfig;

  final raw = outbound['xray_outbound_raw'];
  return _xrayTLSServerName(raw);
}

String? _xrayTLSServerName(Object? value) {
  if (value is Map) {
    final tlsSettings = value['tlsSettings'];
    if (tlsSettings is Map) {
      final name = firstNonEmptyString([tlsSettings['serverName'], tlsSettings['server_name']]);
      if (name != null) return name;
    }

    final realitySettings = value['realitySettings'];
    if (realitySettings is Map) {
      final name = firstNonEmptyString([realitySettings['serverName'], realitySettings['server_name']]);
      if (name != null) return name;
    }

    final xhttpSettings = value['xhttpSettings'];
    if (xhttpSettings is Map) {
      final host = firstNonEmptyString([xhttpSettings['host']]);
      if (host != null) return host;
    }

    for (final child in value.values) {
      final name = _xrayTLSServerName(child);
      if (name != null) return name;
    }
  } else if (value is List) {
    for (final child in value) {
      final name = _xrayTLSServerName(child);
      if (name != null) return name;
    }
  }
  return null;
}

List<String> selectableOutboundTagsFromConfig(String raw) {
  if (raw.isEmpty) return const [];
  try {
    final parsed = decodeJsonContent(raw);
    if (parsed is! Map) return const [];
    final outbounds = parsed['outbounds'];
    if (outbounds is! List) return const [];
    final tags = <String>[];
    for (final item in outbounds) {
      if (item is! Map) continue;
      final outbound = Map<String, dynamic>.from(item);
      if (!_isCoreSelectableOutbound(outbound)) continue;
      tags.add(outbound['tag'].toString());
    }
    return tags;
  } catch (_) {
    return const [];
  }
}

String? resolveSelectedOutboundTag(Iterable<String> tags, {String? pending, String? remembered}) {
  final available = tags.where((tag) => tag.isNotEmpty).toList(growable: false);
  if (available.isEmpty) return null;
  final availableSet = available.toSet();
  if (pending != null && pending.isNotEmpty && availableSet.contains(pending)) {
    return pending;
  }
  if (remembered != null && remembered.isNotEmpty && availableSet.contains(remembered)) {
    return remembered;
  }
  return available.first;
}

String prepareConfigForSelectedOutbound(String raw, String selectedTag) {
  if (raw.isEmpty || selectedTag.isEmpty) return raw;
  try {
    final parsed = decodeJsonContent(raw);
    if (parsed is! Map) return raw;
    final config = Map<String, dynamic>.from(parsed);
    final outbounds = config['outbounds'];
    if (outbounds is! List) return raw;

    final prunedOutbounds = _outboundsForSelectedRoute(outbounds, selectedTag);
    if (prunedOutbounds == null) return raw;

    final selectableSlots = <int>[];
    final selectableOutbounds = <Map<String, dynamic>>[];
    for (var i = 0; i < prunedOutbounds.length; i++) {
      final item = prunedOutbounds[i];
      if (item is! Map) continue;
      final outbound = Map<String, dynamic>.from(item);
      if (!_isCoreSelectableOutbound(outbound)) continue;
      selectableSlots.add(i);
      selectableOutbounds.add(outbound);
    }

    if (selectableOutbounds.isNotEmpty) {
      final selectedIndex = selectableOutbounds.indexWhere((outbound) => outbound['tag'] == selectedTag);
      if (selectedIndex > 0) {
        final selected = selectableOutbounds.removeAt(selectedIndex);
        selectableOutbounds.insert(0, selected);
      }

      final nextOutbounds = List<dynamic>.from(prunedOutbounds);
      for (var i = 0; i < selectableSlots.length; i++) {
        nextOutbounds[selectableSlots[i]] = selectableOutbounds[i];
      }
      config['outbounds'] = nextOutbounds;
      _patchSelectorDefaults(nextOutbounds, selectedTag);
    } else {
      config['outbounds'] = prunedOutbounds;
      _patchSelectorDefaults(prunedOutbounds, selectedTag);
    }

    _pruneServerMetadata(config, selectedTag);
    _stripCoreUnsafeMartenMetadata(config);
    return '${const JsonEncoder.withIndent('  ').convert(config)}\n';
  } catch (_) {
    return raw;
  }
}

bool selectedOutboundUsesTurncoat(String raw, String selectedTag) {
  if (raw.isEmpty || selectedTag.isEmpty) return false;
  try {
    final parsed = decodeJsonContent(raw);
    if (parsed is! Map) return false;
    final outbounds = parsed['outbounds'];
    if (outbounds is! List) return false;
    final byTag = _outboundsByTag(outbounds);
    final dependencyTags = _outboundDependencyTags(byTag, selectedTag);
    for (final tag in dependencyTags) {
      final type = byTag[tag]?['type']?.toString().toLowerCase();
      if (type == 'turncoat') return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

bool _outboundUsesTurncoat(String tag, Map<String, Map<String, dynamic>> byTag) {
  final dependencyTags = _outboundDependencyTags(byTag, tag);
  for (final dependencyTag in dependencyTags) {
    final type = byTag[dependencyTag]?['type']?.toString().toLowerCase();
    if (type == 'turncoat') return true;
  }
  return false;
}

List<String> _callUrlsForOutbound(
  String tag,
  Map<String, Map<String, dynamic>> byTag,
  Map<String, _ServerInfo> serverInfo,
) {
  final dependencyTags = _outboundDependencyTags(byTag, tag);
  final seen = <String>{};
  final calls = <String>[];

  void add(String? value) {
    final callUrl = value?.trim();
    if (callUrl == null || callUrl.isEmpty || !seen.add(callUrl)) return;
    calls.add(callUrl);
  }

  void addAll(Iterable<String> values) {
    for (final value in values) {
      add(value);
    }
  }

  for (final dependencyTag in dependencyTags) {
    addAll(serverInfo[dependencyTag]?.callUrls ?? const []);
    final outbound = byTag[dependencyTag];
    if (outbound == null) continue;
    addAll(_stringList(outbound['call_urls']));
    add(outbound['call_invite']?.toString());
  }

  return calls;
}

List<String> _stringList(Object? value) {
  if (value is List) {
    return value.map((item) => item?.toString() ?? '').where((item) => item.trim().isNotEmpty).toList();
  }
  if (value is String && value.trim().isNotEmpty) return [value];
  return const [];
}

bool _isCoreSelectableOutbound(Map<String, dynamic> outbound) {
  final tag = outbound['tag']?.toString() ?? '';
  final type = (outbound['type']?.toString() ?? '').toLowerCase();
  if (tag.isEmpty || type.isEmpty) return false;
  if (_coreSelectableExcludedTypes.contains(type)) return false;
  if (_excludedTags.contains(tag) || _excludedTags.contains(stripTagMetadata(tag))) return false;
  if (tag.contains('§hide§')) return false;
  return true;
}

List<dynamic>? _outboundsForSelectedRoute(List<dynamic> outbounds, String selectedTag) {
  final byTag = _outboundsByTag(outbounds);
  if (!byTag.containsKey(selectedTag)) return null;

  final routeTags = _outboundDependencyTags(byTag, selectedTag);
  final kept = <dynamic>[];
  for (final item in outbounds) {
    if (item is! Map) continue;
    final outbound = Map<String, dynamic>.from(item);
    final tag = outbound['tag']?.toString() ?? '';
    final type = (outbound['type']?.toString() ?? '').toLowerCase();
    if (routeTags.contains(tag) || _isAlwaysKeptCoreOutbound(type)) {
      kept.add(outbound);
    }
  }
  return kept;
}

Map<String, Map<String, dynamic>> _outboundsByTag(List<dynamic> outbounds) {
  final byTag = <String, Map<String, dynamic>>{};
  for (final item in outbounds) {
    if (item is! Map) continue;
    final outbound = Map<String, dynamic>.from(item);
    final tag = outbound['tag']?.toString() ?? '';
    if (tag.isEmpty) continue;
    byTag[tag] = outbound;
  }
  return byTag;
}

Set<String> _outboundDependencyTags(Map<String, Map<String, dynamic>> byTag, String selectedTag) {
  final seen = <String>{};
  final pending = <String>[selectedTag];
  while (pending.isNotEmpty) {
    final tag = pending.removeLast();
    if (!seen.add(tag)) continue;
    final outbound = byTag[tag];
    if (outbound == null) continue;
    for (final detour in _outboundDetourTags(outbound)) {
      if (!byTag.containsKey(detour)) continue;
      pending.add(detour);
    }
  }
  return seen;
}

Set<String> _outboundDetourTags(Map<String, dynamic> outbound) {
  final tags = <String>{};

  void walk(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key?.toString();
        final child = entry.value;
        if (key == 'detour') {
          final tag = child?.toString() ?? '';
          if (tag.isNotEmpty) tags.add(tag);
          continue;
        }
        walk(child);
      }
    } else if (value is List) {
      for (final item in value) {
        walk(item);
      }
    }
  }

  walk(outbound);
  return tags;
}

bool _isAlwaysKeptCoreOutbound(String type) {
  return type == 'selector' ||
      type == 'urltest' ||
      type == 'dns' ||
      type == 'block' ||
      type == 'direct' ||
      type == 'custom';
}

void _patchSelectorDefaults(List<dynamic> outbounds, String selectedTag) {
  final availableTags = outbounds.whereType<Map>().map((item) => item['tag']?.toString() ?? '').toSet();
  for (final item in outbounds) {
    if (item is! Map) continue;
    final outbound = Map<String, dynamic>.from(item);
    final type = (outbound['type']?.toString() ?? '').toLowerCase();
    if (type != 'selector' && type != 'urltest') continue;
    final selectorItems = outbound['outbounds'];
    if (selectorItems is List) {
      final filteredItems = selectorItems
          .map((item) => item?.toString() ?? '')
          .where((tag) => tag.isNotEmpty && availableTags.contains(tag))
          .toSet()
          .toList();
      if (filteredItems.contains(selectedTag)) {
        item['outbounds'] = [selectedTag];
      } else {
        item['outbounds'] = filteredItems;
      }
    }
    if (type == 'selector' && availableTags.contains(selectedTag)) {
      item['default'] = selectedTag;
    }
  }
}

void _pruneServerMetadata(Map<String, dynamic> config, String selectedTag) {
  final servers = config['servers'];
  if (servers is! List) return;
  config['servers'] = servers.where((item) {
    if (item is! Map) return false;
    return item['tag']?.toString() == selectedTag;
  }).toList();
}

void _stripCoreUnsafeMartenMetadata(Map<String, dynamic> config) {
  for (final key in const ['split_tunnel', 'split_tunneling', 'servers', 'subscription']) {
    config.remove(key);
  }
}

class _ServerInfo {
  const _ServerInfo({this.server, this.serverPort, this.tlsServerName, this.tunnelPingUrl, this.callUrls = const []});
  final String? server;
  final int? serverPort;
  final String? tlsServerName;
  final String? tunnelPingUrl;
  final List<String> callUrls;
}

String? firstNonEmptyString(Iterable<Object?> values) {
  for (final value in values) {
    final stringValue = value?.toString().trim();
    if (stringValue != null && stringValue.isNotEmpty) return stringValue;
  }
  return null;
}

/// Strip marten-server metadata markers like ` §id:abc123§` from a raw tag,
/// returning a clean display name.
String stripTagMetadata(String tag) {
  final idx = tag.indexOf('§');
  if (idx < 0) return tag;
  return tag.substring(0, idx).trimRight();
}

bool hasTagMetadata(String tag) => tag.contains('§');

String? tunnelPingUrlForServer(String server) {
  final host = server.trim();
  if (host.isEmpty) return null;
  return 'http://$host:$_tunnelPingPort/tunnel/ping';
}

bool localOutboundUsesServerPortPing(LocalOutbound outbound) {
  final type = outbound.type.trim().toLowerCase();
  return (type == 'vless' || type == 'xray') && outbound.server.trim().isNotEmpty && outbound.serverPort > 0;
}

bool localOutboundUsesICMPEchoPing(LocalOutbound outbound) {
  return outbound.type.trim().toLowerCase() == 'icmp' && outbound.server.trim().isNotEmpty;
}

bool localOutboundUsesConnectedRoutePing(LocalOutbound outbound) {
  if (!outbound.usesTurncoat) return false;
  return (outbound.tunnelPingUrl?.trim().isNotEmpty ?? false) ||
      (outbound.server.trim().isNotEmpty && outbound.serverPort > 0) ||
      outbound.callUrls.isNotEmpty;
}

List<LocalOutbound> connectedRoutePingOutbounds(Iterable<LocalOutbound> outbounds, Iterable<String> activeTags) {
  final tags = activeTags.where((tag) => tag.trim().isNotEmpty).toSet();
  if (tags.isEmpty) return const [];
  return outbounds
      .where((outbound) => tags.contains(outbound.tag) && localOutboundUsesConnectedRoutePing(outbound))
      .toList(growable: false);
}

int displayDelayWithLocalPing({required int coreDelay, required int? localPing}) {
  return switch (localPing) {
    null => coreDelay,
    0 => 0,
    -1 => 999999,
    _ => localPing,
  };
}

/// Extract a 2-letter ISO country code from a tag string.
/// Tries (in order): regional-indicator emoji, name regex.
String? countryCodeFromTag(String tag) {
  final fromEmoji = _flagEmojiToCode(tag);
  if (fromEmoji != null) return fromEmoji;
  for (final entry in _countryAliases.entries) {
    if (entry.key.hasMatch(tag)) return entry.value;
  }
  return null;
}

String? _flagEmojiToCode(String s) {
  // Iterate UTF-16 surrogate pairs to find regional indicator code points.
  final runes = s.runes.toList();
  for (var i = 0; i < runes.length - 1; i++) {
    final a = runes[i];
    final b = runes[i + 1];
    if (a >= 0x1F1E6 && a <= 0x1F1FF && b >= 0x1F1E6 && b <= 0x1F1FF) {
      final c1 = String.fromCharCode(a - 0x1F1E6 + 0x41);
      final c2 = String.fromCharCode(b - 0x1F1E6 + 0x41);
      return '$c1$c2'.toLowerCase();
    }
  }
  return null;
}

final _countryAliases = <RegExp, String>{
  RegExp('(US|USA|United States|Америк[аи]|США)', caseSensitive: false): 'us',
  RegExp('(UK|United Kingdom|Britain|Англи[яи]|Великобритани[яи])', caseSensitive: false): 'gb',
  RegExp('(Германи[яи]|Germany|Frankfurt|\\bDE\\b)', caseSensitive: false): 'de',
  RegExp('(Нидерланд[ыов]|Netherlands|Amsterdam|\\bNL\\b)', caseSensitive: false): 'nl',
  RegExp('(Финлянди[яи]|Finland|Helsinki|\\bFI\\b)', caseSensitive: false): 'fi',
  RegExp('(Швеци[яи]|Sweden|Stockholm|\\bSE\\b)', caseSensitive: false): 'se',
  RegExp('(Франци[яи]|France|Paris|\\bFR\\b)', caseSensitive: false): 'fr',
  RegExp('(Польш[аи]|Poland|Warsaw|\\bPL\\b)', caseSensitive: false): 'pl',
  RegExp('(Латви[яи]|Latvia|Riga|\\bLV\\b)', caseSensitive: false): 'lv',
  RegExp('(Литв[аы]|Lithuania|\\bLT\\b)', caseSensitive: false): 'lt',
  RegExp('(Эстони[яи]|Estonia|Tallinn|\\bEE\\b)', caseSensitive: false): 'ee',
  RegExp('(Швейцари[яи]|Switzerland|\\bCH\\b)', caseSensitive: false): 'ch',
  RegExp('(Австри[яи]|Austria|Vienna|\\bAT\\b)', caseSensitive: false): 'at',
  RegExp('(Канад[аы]|Canada|\\bCA\\b)', caseSensitive: false): 'ca',
  RegExp('(Япони[яи]|Japan|Tokyo|\\bJP\\b)', caseSensitive: false): 'jp',
  RegExp('(Сингапур|Singapore|\\bSG\\b)', caseSensitive: false): 'sg',
  RegExp('(Гонконг|Hong Kong|\\bHK\\b)', caseSensitive: false): 'hk',
  RegExp('(Турци[яи]|Turkey|Istanbul|\\bTR\\b)', caseSensitive: false): 'tr',
  RegExp('(Россия|Russia|\\bRU\\b)', caseSensitive: false): 'ru',
  RegExp('(Чехи[яи]|Czech|\\bCZ\\b)', caseSensitive: false): 'cz',
  RegExp('(Норвеги[яи]|Norway|\\bNO\\b)', caseSensitive: false): 'no',
  RegExp('(Дани[яи]|Denmark|\\bDK\\b)', caseSensitive: false): 'dk',
  RegExp('(Италия|Italy|\\bIT\\b)', caseSensitive: false): 'it',
  RegExp('(Испани[яи]|Spain|\\bES\\b)', caseSensitive: false): 'es',
  RegExp('(Австрали[яи]|Australia|\\bAU\\b)', caseSensitive: false): 'au',
  RegExp('(Бразили[яи]|Brazil|\\bBR\\b)', caseSensitive: false): 'br',
  RegExp('(Молдав[аи]|Moldova|\\bMD\\b)', caseSensitive: false): 'md',
  RegExp('(Украин[аы]|Ukraine|\\bUA\\b)', caseSensitive: false): 'ua',
  RegExp('(Беларус[ьи]|Belarus|\\bBY\\b)', caseSensitive: false): 'by',
};

class PendingProxySelectionNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  String? get selected => state;
  set selected(String? tag) => state = tag;
}

final pendingProxySelectionProvider = NotifierProvider<PendingProxySelectionNotifier, String?>(
  PendingProxySelectionNotifier.new,
);

const _selectedProxyByProfilePrefKey = 'selected_proxy_by_profile';

class SelectedProxyByProfileNotifier extends StateNotifier<Map<String, String>> {
  SelectedProxyByProfileNotifier(SharedPreferences preferences) : this._(preferences, _readEntries(preferences));

  SelectedProxyByProfileNotifier._(this._preferences, this._entries) : super(_stateFromEntries(_entries));

  final SharedPreferences _preferences;
  Map<String, _RememberedProxySelection> _entries;

  static Map<String, _RememberedProxySelection> _readEntries(SharedPreferences preferences) {
    final raw = preferences.getString(_selectedProxyByProfilePrefKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map) return const {};
      final entries = <String, _RememberedProxySelection>{};
      for (final entry in parsed.entries) {
        final profileId = entry.key.toString();
        final value = entry.value;
        if (value is Map) {
          final tag = value['tag']?.toString() ?? '';
          if (tag.isEmpty) continue;
          entries[profileId] = _RememberedProxySelection(tag: tag, fingerprint: value['fingerprint']?.toString());
        } else {
          final tag = value?.toString() ?? '';
          if (tag.isEmpty) continue;
          entries[profileId] = _RememberedProxySelection(tag: tag);
        }
      }
      return entries;
    } catch (_) {
      return const {};
    }
  }

  static Map<String, String> _stateFromEntries(Map<String, _RememberedProxySelection> entries) {
    return {
      for (final entry in entries.entries)
        if (entry.value.fingerprint != null) entry.key: entry.value.tag,
    };
  }

  String? rememberedTagFor(String profileId, Iterable<String> availableTags) {
    final entry = _entries[profileId];
    if (entry == null || entry.fingerprint == null) return null;
    final tags = _normalizeOutboundTags(availableTags);
    if (tags.isEmpty || !tags.contains(entry.tag)) return null;
    if (entry.fingerprint != _outboundListFingerprint(tags)) return null;
    return entry.tag;
  }

  Future<void> select(String profileId, String tag, {Iterable<String> availableTags = const []}) async {
    if (profileId.isEmpty || tag.isEmpty) return;
    final tags = _normalizeOutboundTags(availableTags);
    final fingerprintTags = tags.contains(tag) ? tags : <String>[...tags, tag];
    final nextEntries = {
      ..._entries,
      profileId: _RememberedProxySelection(tag: tag, fingerprint: _outboundListFingerprint(fingerprintTags)),
    };
    _entries = nextEntries;
    state = _stateFromEntries(nextEntries);
    await _preferences.setString(_selectedProxyByProfilePrefKey, jsonEncode(_entriesToJson(nextEntries)));
  }
}

final selectedProxyByProfileProvider = StateNotifierProvider<SelectedProxyByProfileNotifier, Map<String, String>>((
  ref,
) {
  return SelectedProxyByProfileNotifier(ref.watch(sharedPreferencesProvider).requireValue);
});

class _RememberedProxySelection {
  const _RememberedProxySelection({required this.tag, this.fingerprint});

  final String tag;
  final String? fingerprint;
}

Map<String, dynamic> _entriesToJson(Map<String, _RememberedProxySelection> entries) {
  return {
    for (final entry in entries.entries) entry.key: {'tag': entry.value.tag, 'fingerprint': entry.value.fingerprint},
  };
}

List<String> _normalizeOutboundTags(Iterable<String> tags) {
  return tags.where((tag) => tag.trim().isNotEmpty).toList(growable: false);
}

String _outboundListFingerprint(Iterable<String> tags) => jsonEncode(_normalizeOutboundTags(tags));

const _pingTimeout = Duration(seconds: 4);
const _maxConcurrentPings = 20;
const _martenMethodChannel = MethodChannel('app.marten.client/method');

Future<int> nativeICMPEchoProbe(String host, {MethodChannel channel = _martenMethodChannel, bool? isAndroid}) async {
  if (!(isAndroid ?? Platform.isAndroid) || host.trim().isEmpty) return -1;
  try {
    final delay = await channel
        .invokeMethod<int>('icmp_ping', {'host': host.trim(), 'timeoutMs': _pingTimeout.inMilliseconds})
        .timeout(_pingTimeout + const Duration(milliseconds: 500));
    return delay != null && delay > 0 ? delay : -1;
  } catch (_) {
    return -1;
  }
}

enum LocalPingMode { preConnect, connectedRoute }

/// Maps tag → measured latency in ms (-1 = timeout/error, 0 = not yet measured).
///
/// Probe strategy is chosen per outbound type so that "ping" reflects the
/// actual data path, not just whether the entry's L4 port is open:
///
///   * **TURNcoat / TURNcoat-backed** — probe the host of the hidden helper's
///     call invite URL, since that is the public WebRTC path TURNcoat uses
///     before it obtains relay credentials, then multiply it by 4 + random(0, 1)
///     to approximate TURNcoat setup/relay cost.
///   * **VLESS** — probe the configured server domain/IP on server_port with a
///     TCP connect. Do not promote IP endpoints to SNI domains for ping, because
///     that can hide the real node latency behind a fronting host.
///   * **Cascade entry / single nodes** (everything else) — when the
///     subscription provides a `tunnel_ping_url`, we GET it. The marten-agent
///     on the entry node serves it by SO_BINDTODEVICE-ing the cascade WG
///     interface and TCP-dialing a public target, so a 2xx response proves
///     entry → cascade → exit → internet works end to end. Falls back to
///     plain TCP-connect on (server, server_port) when the agent endpoint is
///     missing or unhealthy (e.g. legacy single-node subscriptions).
class LocalPingNotifier extends Notifier<Map<String, int>> with InfraLogger {
  @override
  Map<String, int> build() => const {};

  bool _running = false;

  void clear() => state = const {};

  void markPending(Iterable<LocalOutbound> outbounds) {
    state = {for (final outbound in outbounds) outbound.tag: 0};
  }

  void record(String tag, int delay) {
    state = {...state, tag: delay};
  }

  Future<void> pingAll(List<LocalOutbound> outbounds, {LocalPingMode mode = LocalPingMode.preConnect}) async {
    if (_running) return;
    _running = true;
    try {
      state = {for (final o in outbounds) o.tag: 0};
      for (var start = 0; start < outbounds.length; start += _maxConcurrentPings) {
        final next = start + _maxConcurrentPings;
        final end = next > outbounds.length ? outbounds.length : next;
        await Future.wait(outbounds.sublist(start, end).map((outbound) => _pingOne(outbound, mode)));
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _pingOne(LocalOutbound o, LocalPingMode mode) async {
    final delay = await _measure(o, mode);
    state = {...state, o.tag: delay};
  }

  Future<int> _measure(LocalOutbound o, LocalPingMode mode) async {
    if (mode == LocalPingMode.connectedRoute) {
      return _measureConnectedRoute(o);
    }
    if (localOutboundUsesICMPEchoPing(o)) {
      return nativeICMPEchoProbe(o.server);
    }
    if (o.usesTurncoat) {
      return scaledTurncoatPingDelay(await _tcpProbeTurncoat(o));
    }
    if (localOutboundUsesServerPortPing(o)) {
      return _tcpProbe(o.server, o.serverPort);
    }
    if (o.tunnelPingUrl != null && o.tunnelPingUrl!.isNotEmpty) {
      final delay = await _httpTunnelPing(o.tunnelPingUrl!);
      if (delay >= 0) return delay;
    }
    return _tcpProbe(o.server, o.serverPort);
  }

  Future<int> _measureConnectedRoute(LocalOutbound o) async {
    if (o.tunnelPingUrl != null && o.tunnelPingUrl!.isNotEmpty) {
      final delay = await _httpTunnelPing(o.tunnelPingUrl!);
      if (delay >= 0) return delay;
    }
    if (o.server.trim().isNotEmpty && o.serverPort > 0) {
      final delay = await _tcpProbe(o.server, o.serverPort);
      if (delay >= 0 || !o.usesTurncoat) return delay;
    }
    if (o.usesTurncoat) {
      return scaledTurncoatPingDelay(await _tcpProbeTurncoat(o));
    }
    return -1;
  }

  Future<int> _tcpProbe(String host, int port) async {
    if (host.isEmpty || port <= 0) return -1;
    final sw = Stopwatch()..start();
    try {
      final socket = await Socket.connect(host, port, timeout: _pingTimeout);
      sw.stop();
      socket.destroy();
      return sw.elapsedMilliseconds;
    } catch (err, st) {
      loggy.debug('tcp ping failed [$host:$port]', err, st);
      return -1;
    }
  }

  Future<int> _tcpProbeTurncoat(LocalOutbound o) async {
    var hasCallUrl = false;
    for (final raw in o.callUrls) {
      final endpoint = turncoatPingEndpointFromUrl(raw);
      if (endpoint == null) continue;
      hasCallUrl = true;
      final delay = await _tcpProbe(endpoint.host, endpoint.port);
      if (delay >= 0) return delay;
    }
    if (hasCallUrl) return -1;
    return _tcpProbe(o.server, o.serverPort);
  }

  Future<int> _httpTunnelPing(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return -1;
    HttpClient? client;
    final sw = Stopwatch()..start();
    try {
      client = HttpClient()
        ..connectionTimeout = _pingTimeout
        ..idleTimeout = const Duration(seconds: 1);
      final req = await client.getUrl(uri).timeout(_pingTimeout);
      final resp = await req.close().timeout(_pingTimeout);
      final body = await utf8.decoder.bind(resp).join().timeout(_pingTimeout);
      sw.stop();
      if (resp.statusCode < 200 || resp.statusCode >= 300) return -1;
      final parsed = jsonDecode(body);
      if (parsed is Map<String, dynamic> && parsed['ok'] == true) {
        return sw.elapsedMilliseconds;
      }
      if (parsed is Map && parsed['ok'] == true) {
        return sw.elapsedMilliseconds;
      }
      return -1;
    } catch (error) {
      loggy.debug('http tunnel ping failed (${error.runtimeType})');
      return -1;
    } finally {
      client?.close(force: true);
    }
  }
}

final localPingProvider = NotifierProvider<LocalPingNotifier, Map<String, int>>(LocalPingNotifier.new);

int scaledTurncoatPingDelay(int delay, {double? randomFraction}) {
  if (delay < 0) return delay;
  final jitter = (randomFraction ?? _turncoatPingRandom.nextDouble()).clamp(0.0, 1.0);
  return (delay * (_turncoatPingBaseMultiplier + jitter)).round();
}

final _turncoatPingRandom = math.Random();
const _turncoatPingBaseMultiplier = 4.0;

({String host, int port})? turncoatPingEndpointFromUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return null;
  final port = uri.hasPort
      ? uri.port
      : switch (uri.scheme) {
          'http' => 80,
          _ => 443,
        };
  if (port <= 0) return null;
  return (host: uri.host, port: port);
}
