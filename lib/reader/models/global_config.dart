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
  String proxyUrl;       // e.g. https://proxy.example.com:8080
  String proxyAuthToken; // Admin token for proxy
  int proxyWsPort;       // WebSocket port (default 8649)
  int proxyAdminPort;    // Admin API port (default 8650)
  
  GlobalConfig({
    this.mode = ConnectionMode.standalone,
    this.proxyUrl = '',
    this.proxyAuthToken = '',
    this.proxyWsPort = 8649,
    this.proxyAdminPort = 8650,
  });

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'proxyUrl': proxyUrl,
        'proxyAuthToken': proxyAuthToken,
        'proxyWsPort': proxyWsPort,
        'proxyAdminPort': proxyAdminPort,
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
      );

  GlobalConfig copyWith({
    ConnectionMode? mode,
    String? proxyUrl,
    String? proxyAuthToken,
    int? proxyWsPort,
    int? proxyAdminPort,
  }) => GlobalConfig(
        mode: mode ?? this.mode,
        proxyUrl: proxyUrl ?? this.proxyUrl,
        proxyAuthToken: proxyAuthToken ?? this.proxyAuthToken,
        proxyWsPort: proxyWsPort ?? this.proxyWsPort,
        proxyAdminPort: proxyAdminPort ?? this.proxyAdminPort,
      );

  /// Build WebSocket URL with token for Nginx auth
  /// Derives from proxyUrl: https://host → wss://host/ws?token=xxx (default 443, no port needed)
  /// Only include port when explicitly specified and non-standard (e.g. :8443)
  String get proxyWsUrl {
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
    final scheme = uri.scheme;
    final host = uri.host;
    final port = proxyAdminPort;
    return '$scheme://$host:$port';
  }
}
