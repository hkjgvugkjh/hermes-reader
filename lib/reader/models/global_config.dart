/// Global connection mode for hermes-hive
enum ConnectionMode {
  /// Connect through hermes-proxy (server list from proxy admin API)
  hermesProxy('Hermes Proxy'),
  
  /// Connect directly to Hermes Studio servers (manual configuration)
  standalone('Standalone');

  const ConnectionMode(this.label);
  final String label;
}

/// Global configuration for the application
class GlobalConfig {
  ConnectionMode mode;

  // Hermes-proxy mode settings
  String proxyUrl; // Admin base URL (http/https), e.g. http://111.228.38.128:8649
  String proxyAuthToken; // Admin token for proxy
  int proxyWsPort; // WebSocket port (default 8649)
  int proxyAdminPort; // Admin API port (default 8650)

  // Full WebSocket connection URL (source of truth for the connection).
  // Preserves the exact scheme (ws/wss), host, port, path and ?token query
  // from the scanned / configured external host. Empty means "derive legacy".
  final String _wsUrl;

  GlobalConfig({
    this.mode = ConnectionMode.standalone,
    this.proxyUrl = 'https://hermes-proxy.willam.eu.org',
    this.proxyAuthToken = '',
    this.proxyWsPort = 8649,
    this.proxyAdminPort = 8650,
    String? proxyWsUrl,
  }) : _wsUrl = proxyWsUrl ?? '';

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'proxyUrl': proxyUrl,
        'proxyAuthToken': proxyAuthToken,
        'proxyWsPort': proxyWsPort,
        'proxyAdminPort': proxyAdminPort,
        'proxyWsUrl': _wsUrl,
      };

  factory GlobalConfig.fromJson(Map<String, dynamic> json) => GlobalConfig(
        mode: ConnectionMode.values.firstWhere(
          (e) => e.name == json['mode'],
          orElse: () => ConnectionMode.standalone,
        ),
        proxyUrl: json['proxyUrl'] as String? ?? '',
        proxyAuthToken: json['proxyAuthToken'] as String? ?? '',
        proxyWsPort: json['proxyWsPort'] as int? ?? 8649,
        proxyAdminPort: json['proxyAdminPort'] as int? ?? 8650,
        proxyWsUrl: json['proxyWsUrl'] as String? ?? '',
      );

  GlobalConfig copyWith({
    ConnectionMode? mode,
    String? proxyUrl,
    String? proxyAuthToken,
    int? proxyWsPort,
    int? proxyAdminPort,
    String? proxyWsUrl,
  }) =>
      GlobalConfig(
        mode: mode ?? this.mode,
        proxyUrl: proxyUrl ?? this.proxyUrl,
        proxyAuthToken: proxyAuthToken ?? this.proxyAuthToken,
        proxyWsPort: proxyWsPort ?? this.proxyWsPort,
        proxyAdminPort: proxyAdminPort ?? this.proxyAdminPort,
        proxyWsUrl: proxyWsUrl ?? _wsUrl,
      );

  /// Full WebSocket connection URL (scheme/path/token preserved).
  /// Falls back to legacy https→wss derivation when not explicitly stored.
  String get proxyWsUrl {
    if (_wsUrl.isNotEmpty) return _wsUrl;
    if (mode != ConnectionMode.hermesProxy) return '';
    final uri = Uri.parse(proxyUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final host = uri.host;
    final port = uri.port;
    final defaultPort = scheme == 'wss' ? 443 : 80;
    final portPart = (port > 0 && port != defaultPort) ? ':$port' : '';
    final tokenPart = proxyAuthToken.isNotEmpty ? '?token=$proxyAuthToken' : '';
    return '$scheme://$host$portPart/ws$tokenPart';
  }

  /// Get admin HTTP URL from proxy URL
  String get proxyAdminUrl {
    if (mode != ConnectionMode.hermesProxy) return '';
    final uri = Uri.parse(proxyUrl);
    final scheme = uri.scheme.isNotEmpty ? uri.scheme : 'https';
    final host = uri.host;
    final port = uri.hasPort ? uri.port : proxyAdminPort;
    return '$scheme://$host:$port';
  }
}
