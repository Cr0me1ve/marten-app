class SensitiveDataRedactor {
  const SensitiveDataRedactor._();

  static const _ipv6AddressExpression =
      '(?:'
      '(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|'
      '(?:[0-9A-Fa-f]{1,4}:){1,7}:|'
      '(?:[0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|'
      '(?:[0-9A-Fa-f]{1,4}:){1,5}(?::[0-9A-Fa-f]{1,4}){1,2}|'
      '(?:[0-9A-Fa-f]{1,4}:){1,4}(?::[0-9A-Fa-f]{1,4}){1,3}|'
      '(?:[0-9A-Fa-f]{1,4}:){1,3}(?::[0-9A-Fa-f]{1,4}){1,4}|'
      '(?:[0-9A-Fa-f]{1,4}:){1,2}(?::[0-9A-Fa-f]{1,4}){1,5}|'
      '[0-9A-Fa-f]{1,4}:(?:(?::[0-9A-Fa-f]{1,4}){1,6})|'
      ':(?:(?::[0-9A-Fa-f]{1,4}){1,7}|:)'
      ')';

  static final _uriPattern = RegExp(
    r'''\b[a-z][a-z0-9+.-]*://(?:\[[0-9a-f:.]+(?:%[a-z0-9_.-]+)?\](?::[0-9]{1,5})?[^\s<>'"\])]*|[^\s<>'"\]\[)]+)''',
    caseSensitive: false,
  );
  static final _namedSecretPattern = RegExp(
    r'''("?(?:authorization|x-client-secret|x-device-id|client[_-]?secret|device[_-]?id|push[_-]?token|access[_-]?token|refresh[_-]?token|session[_-]?token|private[_-]?key|password|uuid|call[_-]?urls?)"?\s*[:=]\s*)(\[[^\]]*\]|"[^"]*"|'[^']*'|[^,&\s}\]]+)''',
    caseSensitive: false,
  );
  static final _subscriptionTokenPattern = RegExp(r'(/(?:sub|subscriptions)/)[^/?#\s]+', caseSensitive: false);
  static final _packagePattern = RegExp(
    r'((?:package|packageName)\s*[:=]\s*)[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+',
    caseSensitive: false,
  );
  static final _uuidPattern = RegExp(
    r'\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b',
    caseSensitive: false,
  );
  static final _emailPattern = RegExp(r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,63}\b', caseSensitive: false);
  static final _opaqueTokenPattern = RegExp('(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])');
  static final _unixHomePattern = RegExp(r'/(?:Users|home)/[^/\s]+/');
  static final _windowsHomePattern = RegExp(r'([A-Za-z]:\\Users\\)[^\\\s]+\\', caseSensitive: false);
  static final _bracketedIpv6Pattern = RegExp('\\[$_ipv6AddressExpression(?:%[A-Za-z0-9_.-]+)?\\](?::[0-9]{1,5})?');
  static final _ipv6Pattern = RegExp(
    '(^|[^0-9A-Fa-f:.])($_ipv6AddressExpression(?:%[A-Za-z0-9_.-]+)?)(?![0-9A-Fa-f:.])',
    multiLine: true,
  );
  static final _hostnamePattern = RegExp(
    r'(^|[^A-Za-z0-9_@\u00C0-\uFFFF])((?:(?:xn--[a-z0-9-]+|[a-z0-9\u00C0-\uFFFF](?:[a-z0-9\u00C0-\uFFFF-]{0,61}[a-z0-9\u00C0-\uFFFF])?)\.)+(?:xn--[a-z0-9-]+|[a-z\u00C0-\uFFFF]{2,63})\.?(?::[0-9]{1,5})?)',
    caseSensitive: false,
    multiLine: true,
    unicode: true,
  );
  static final _ipv4Pattern = RegExp(r'(^|[^0-9])((?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]{1,5})?)', multiLine: true);
  static final _localhostPattern = RegExp(r'\blocalhost(?::[0-9]{1,5})?\b', caseSensitive: false);
  static const _opaqueProxySchemes = {
    'turncoat',
    'vless',
    'vmess',
    'trojan',
    'ss',
    'ssconf',
    'tuic',
    'hy2',
    'hysteria',
    'hysteria2',
    'ssh',
    'wg',
    'awg',
    'amneziawg',
    'shadowtls',
    'mieru',
  };

  static String redact(String value) {
    if (value.isEmpty) return value;
    var redacted = value.replaceAllMapped(_uriPattern, (match) => _redactUri(match.group(0)!));
    redacted = redacted.replaceAllMapped(_namedSecretPattern, (match) => '${match.group(1)}[redacted]');
    redacted = redacted.replaceAllMapped(_subscriptionTokenPattern, (match) => '${match.group(1)}[redacted]');
    redacted = redacted.replaceAllMapped(_packagePattern, (match) => '${match.group(1)}[redacted]');
    redacted = redacted.replaceAll(_uuidPattern, '[redacted-uuid]');
    redacted = redacted.replaceAll(_emailPattern, '[redacted-email]');
    redacted = redacted.replaceAll(_opaqueTokenPattern, '[redacted-token]');
    redacted = redacted.replaceAll(_unixHomePattern, '/Users/[redacted]/');
    redacted = redacted.replaceAllMapped(_windowsHomePattern, (match) => '${match.group(1)}[redacted]\\');
    redacted = redacted.replaceAll(_bracketedIpv6Pattern, '[redacted-ip]');
    redacted = redacted.replaceAllMapped(_ipv6Pattern, (match) => '${match.group(1)}[redacted-ip]');
    redacted = redacted.replaceAllMapped(_hostnamePattern, (match) => '${match.group(1)}[redacted-host]');
    redacted = redacted.replaceAllMapped(_ipv4Pattern, (match) => '${match.group(1)}[redacted-ip]');
    return redacted.replaceAll(_localhostPattern, '[redacted-host]');
  }

  static String redactObject(Object? value) => value == null ? '' : redact(value.toString());

  static String _redactUri(String raw) {
    final trailing = RegExp(r'[.,;:!?}]+$').firstMatch(raw)?.group(0) ?? '';
    final candidate = trailing.isEmpty ? raw : raw.substring(0, raw.length - trailing.length);
    final uri = Uri.tryParse(candidate);
    if (uri == null) return '[redacted-url]$trailing';
    final scheme = uri.scheme.toLowerCase();
    if (_opaqueProxySchemes.contains(scheme)) return '$scheme://[redacted]$trailing';

    if (uri.host.isEmpty) return '${uri.scheme}://[redacted]$trailing';
    return '${uri.scheme}://[redacted-host]/[redacted]$trailing';
  }
}
