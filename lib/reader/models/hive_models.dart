import 'package:uuid/uuid.dart';

/// Proxy configuration for connecting through hermes-proxy or other proxy types.
enum ProxyType {
  none('None'),
  hermesProxy('Hermes Proxy (WebSocket)'),
  httpProxy('HTTP Proxy'),
  httpsProxy('HTTPS Proxy'),
  socks5Proxy('SOCKS5 Proxy');

  const ProxyType(this.label);
  final String label;
}

class ProxyConfig {
  ProxyType type;
  String host;
  int port;
  String? username;
  String? password;

  // Hermes-proxy specific
  String? authToken;
  String? wsPath;
  bool useEncryption;

  ProxyConfig({
    this.type = ProxyType.none,
    this.host = '',
    this.port = 0,
    this.username,
    this.password,
    this.authToken,
    this.wsPath = '/ws',
    this.useEncryption = true,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'authToken': authToken,
        'wsPath': wsPath,
        'useEncryption': useEncryption,
      };

  factory ProxyConfig.fromJson(Map<String, dynamic> json) => ProxyConfig(
        type: ProxyType.values.firstWhere(
          (e) => e.name == json['type'],
          orElse: () => ProxyType.none,
        ),
        host: json['host'] as String? ?? '',
        port: json['port'] as int? ?? 0,
        username: json['username'] as String?,
        password: json['password'] as String?,
        authToken: json['authToken'] as String?,
        wsPath: json['wsPath'] as String? ?? '/ws',
        useEncryption: json['useEncryption'] as bool? ?? true,
      );

  ProxyConfig copyWith({
    ProxyType? type,
    String? host,
    int? port,
    String? username,
    String? password,
    String? authToken,
    String? wsPath,
    bool? useEncryption,
  }) =>
      ProxyConfig(
        type: type ?? this.type,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
        authToken: authToken ?? this.authToken,
        wsPath: wsPath ?? this.wsPath,
        useEncryption: useEncryption ?? this.useEncryption,
      );

  bool get hasAuth => username != null && username!.isNotEmpty;

  String get displayAddress => '$host:$port';

  /// Returns true if this is a hermes-proxy connection
  bool get isHermesProxy => type == ProxyType.hermesProxy;

  /// Build WebSocket URL for hermes-proxy
  String get wsUrl {
    if (!isHermesProxy) return '';
    final scheme = useEncryption ? 'wss' : 'ws';
    return '$scheme://$host:$port$wsPath';
  }
}

/// Configuration for a single Hermes Web UI server
class ServerConfig {
  final String id;
  String name;
  String url;
  String? authToken;
  String? username;
  String? password;
  String profile;
  bool useAuth;
  DateTime createdAt;
  DateTime? lastConnected;
  bool isOnline;
  ProxyConfig proxy;

  ServerConfig({
    String? id,
    required this.name,
    required this.url,
    this.authToken,
    this.username,
    this.password,
    this.profile = 'default',
    this.useAuth = false,
    DateTime? createdAt,
    this.lastConnected,
    this.isOnline = false,
    ProxyConfig? proxy,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        proxy = proxy ?? ProxyConfig();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'authToken': authToken,
        'username': username,
        'password': password,
        'profile': profile,
        'useAuth': useAuth,
        'createdAt': createdAt.toIso8601String(),
        'lastConnected': lastConnected?.toIso8601String(),
        'isOnline': isOnline,
        'proxy': proxy.toJson(),
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        authToken: json['authToken'] as String?,
        username: json['username'] as String?,
        password: json['password'] as String?,
        profile: json['profile'] as String? ?? 'default',
        useAuth: json['useAuth'] as bool? ?? false,
        createdAt: DateTime.parse(json['createdAt'] as String),
        lastConnected: json['lastConnected'] != null
            ? DateTime.parse(json['lastConnected'] as String)
            : null,
        isOnline: json['isOnline'] as bool? ?? false,
        proxy: json['proxy'] != null
            ? ProxyConfig.fromJson(json['proxy'] as Map<String, dynamic>)
            : ProxyConfig(),
      );

  ServerConfig copyWith({
    String? name,
    String? url,
    String? authToken,
    String? username,
    String? password,
    String? profile,
    bool? useAuth,
    DateTime? lastConnected,
    bool? isOnline,
    ProxyConfig? proxy,
  }) =>
      ServerConfig(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        authToken: authToken ?? this.authToken,
        username: username ?? this.username,
        password: password ?? this.password,
        profile: profile ?? this.profile,
        useAuth: useAuth ?? this.useAuth,
        createdAt: createdAt,
        lastConnected: lastConnected ?? this.lastConnected,
        isOnline: isOnline ?? this.isOnline,
        proxy: proxy ?? this.proxy,
      );

  /// Returns the base URL without trailing slash
  String get baseUrl => url.replaceAll(RegExp(r'/+$'), '');
}

/// Chat message model
class ChatMessage {
  final String id;
  final String role; // 'user' or 'assistant'
  final String content;
  final DateTime timestamp;
  final bool isError;

  ChatMessage({
    String? id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.isError = false,
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'isOnline': isError,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        role: json['role'] as String,
        content: json['content'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        isError: json['isError'] as bool? ?? false,
      );
}

/// Session info from Hermes Studio
class HermesSession {
  final String id;
  final String title;
  final String? profile;
  final String? model;
  final String? provider;
  final DateTime? updatedAt;
  final int? messageCount;
  final String? serverId;
  final String? serverName;
  final SessionStatus status;

  HermesSession({
    required this.id,
    required this.title,
    this.profile,
    this.model,
    this.provider,
    this.updatedAt,
    this.messageCount,
    this.serverId,
    this.serverName,
    this.status = SessionStatus.unknown,
  });

  factory HermesSession.fromJson(Map<String, dynamic> json) => HermesSession(
        id: json['id'] as String? ?? json['session_id'] as String? ?? '',
        title: json['title'] as String? ?? json['name'] as String? ?? 'Untitled',
        profile: json['profile'] as String?,
        model: json['model'] as String?,
        provider: json['provider'] as String?,
        updatedAt: json['last_active'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                (json['last_active'] as num).toInt() * 1000)
            : json['updated_at'] != null
                ? DateTime.tryParse(json['updated_at'] as String)
                : null,
        messageCount: json['message_count'] as int?,
      );

  HermesSession copyWith({
    String? serverId,
    String? serverName,
    SessionStatus? status,
  }) =>
      HermesSession(
        id: id,
        title: title,
        profile: profile,
        model: model,
        provider: provider,
        updatedAt: updatedAt,
        messageCount: messageCount,
        serverId: serverId ?? this.serverId,
        serverName: serverName ?? this.serverName,
        status: status ?? this.status,
      );
}

enum SessionStatus {
  inProgress,
  completed,
  unknown,
}

/// Health status response
class HealthStatus {
  final bool healthy;
  final String? version;
  final Map<String, dynamic>? details;

  HealthStatus({
    required this.healthy,
    this.version,
    this.details,
  });

  factory HealthStatus.fromJson(Map<String, dynamic> json) => HealthStatus(
        healthy: json['status'] == 'ok' || json['healthy'] == true,
        version: json['version'] as String?,
        details: json,
      );
}

/// Model info for dropdown
class ModelInfo {
  final String id;
  final String label;
  final String description;
  final int priority;

  ModelInfo({
    required this.id,
    required this.label,
    this.description = '',
    this.priority = 1000,
  });
}

/// Group of models by provider
class ModelGroup {
  final String provider;
  final String providerKey;
  final List<ModelInfo> models;

  ModelGroup({
    required this.provider,
    required this.providerKey,
    required this.models,
  });
}
