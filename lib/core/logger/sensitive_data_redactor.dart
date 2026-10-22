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
  static final _outboundTagPattern = RegExp(r'(\boutbound/[A-Za-z0-9_-]+)\[', caseSensitive: false);
  static final _peerIdentifierPattern = RegExp(r'\bpeer\([^\)\r\n]*\)', caseSensitive: false);
  static final _selectedRouteTagPattern = RegExp(
    r'(\b(?:verifying startup route|selected route(?: watchdog failed)?)\s*)\[',
    caseSensitive: false,
  );
  static final _legacyDiagnosticTagPattern = RegExp(
    r'(\b(?:startup route (?:timed out|verified|failed|url test command failed)|selected route probe returned|failed to stop/close startup route|stopping failed startup route|route watchdog verified(?: by endpoint fallback)?|manual connected-route ping verified|verifying startup endpoint|startup endpoint(?: verified| probe failed)?|falling back to startup endpoint probe|changing proxy, group:|testing group:|failed to read (?:selected )?url test snapshot for|active profile config file (?:is )?(?:missing|disappeared(?: during encrypted read)?)|registered push token for profile|push token (?:registered|registration failed|unregistered|unregister failed) for profile)\s*)\[[^\r\n]*\]',
    caseSensitive: false,
  );
  static final _legacyLogIdentifierPattern = RegExp(
    r'(\b(?:selectedTag\s*=\s*|deleting profile:\s*|selected route watchdog url test failed:\s*|select outbound:\s*))[^\r\n]*',
    caseSensitive: false,
  );
  static final _legacyLivenessPayloadPattern = RegExp(
    r'(\bturncoat liveness:\s*selected route active)\s*\([^\r\n]*\)',
    caseSensitive: false,
  );
  static final _selectorFailureDetailsPattern = RegExp(
    r'(\boutbound not found in selector\b)[^\r\n]*',
    caseSensitive: false,
  );
  static final _xrayRouteTagPattern = RegExp(
    r'(\b(?:tags|taking(?:\s+platform\s+initialized)?\s+detour)\s*)\[',
    caseSensitive: false,
  );
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
    // Profiling histories can contain hundreds of MiB of numeric records. A
    // required-character check avoids expensive regex scans of impossible
    // matches while retaining the same sanitizer for every possible match.
    var redacted = value.contains('://')
        ? value.replaceAllMapped(_uriPattern, (match) => _redactUri(match.group(0)!))
        : value;
    if (redacted.contains('=') || redacted.contains(':')) {
      final lower = redacted.toLowerCase();
      if (const ['authorization', 'secret', 'device', 'token', 'key', 'password', 'uuid', 'call'].any(lower.contains)) {
        redacted = redacted.replaceAllMapped(_namedSecretPattern, (match) => '${match.group(1)}[redacted]');
      }
    }
    if (redacted.contains('/')) {
      redacted = redacted.replaceAllMapped(_subscriptionTokenPattern, (match) => '${match.group(1)}[redacted]');
    }
    redacted = _redactBracketedValue(redacted, _outboundTagPattern);
    redacted = redacted.replaceAll(_peerIdentifierPattern, 'peer([redacted])');
    redacted = _redactBracketedValue(redacted, _selectedRouteTagPattern);
    redacted = redacted.replaceAllMapped(_legacyDiagnosticTagPattern, (match) => '${match.group(1)}[redacted]');
    redacted = redacted.replaceAllMapped(_legacyLogIdentifierPattern, (match) => '${match.group(1)}[redacted]');
    redacted = redacted.replaceAllMapped(_legacyLivenessPayloadPattern, (match) => '${match.group(1)} ([redacted])');
    redacted = redacted.replaceAllMapped(_selectorFailureDetailsPattern, (match) => '${match.group(1)} [redacted]');
    redacted = _redactBracketedValue(redacted, _xrayRouteTagPattern);
    redacted = redacted.replaceAllMapped(_packagePattern, (match) => '${match.group(1)}[redacted]');
    if (redacted.contains('-')) redacted = redacted.replaceAll(_uuidPattern, '[redacted-uuid]');
    if (redacted.contains('@')) redacted = redacted.replaceAll(_emailPattern, '[redacted-email]');
    redacted = redacted.replaceAll(_opaqueTokenPattern, '[redacted-token]');
    if (redacted.contains('/')) redacted = redacted.replaceAll(_unixHomePattern, '/Users/[redacted]/');
    if (redacted.contains('\\')) {
      redacted = redacted.replaceAllMapped(_windowsHomePattern, (match) => '${match.group(1)}[redacted]\\');
    }
    if (redacted.contains(':')) {
      redacted = redacted.replaceAll(_bracketedIpv6Pattern, '[redacted-ip]');
      redacted = redacted.replaceAllMapped(_ipv6Pattern, (match) => '${match.group(1)}[redacted-ip]');
    }
    if (redacted.contains('.')) {
      redacted = redacted.replaceAllMapped(_hostnamePattern, (match) => '${match.group(1)}[redacted-host]');
      redacted = redacted.replaceAllMapped(_ipv4Pattern, (match) => '${match.group(1)}[redacted-ip]');
    }
    return redacted.replaceAll(_localhostPattern, '[redacted-host]');
  }

  // A display label can itself contain brackets. Keep later diagnostic fields
  // while consuming the complete nested label, including malformed open labels.
  static String _redactBracketedValue(String value, RegExp prefix) {
    final result = StringBuffer();
    var offset = 0;
    for (final match in prefix.allMatches(value)) {
      if (match.start < offset) continue;
      result.write(value.substring(offset, match.start));
      result.write('${match.group(1)}[redacted]');
      var depth = 1;
      var end = match.end;
      while (end < value.length && depth > 0) {
        final char = value[end];
        if (char == '\n' || char == '\r') break;
        if (char == '[') depth++;
        if (char == ']') depth--;
        end++;
      }
      offset = end;
    }
    result.write(value.substring(offset));
    return result.toString();
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
