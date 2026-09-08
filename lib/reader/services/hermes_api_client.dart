import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/hive_models.dart';
import '../providers/debug_logger.dart';

/// HTTP client for communicating with Hermes Web UI servers
class HermesApiClient {
  final ServerConfig server;
  String? _token;  // JWT token from login
  bool _serverAuthEnabled = false;  // auto-detected

  HermesApiClient(this.server);

  Map<String, String> get _headers {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (_token != null) {
      headers['Authorization'] = 'Bearer $_token';
    }
    return headers;
  }

  /// Get the stored token (for persistence)
  String? get token => _token;

  /// Set token (e.g., from storage)
  void setToken(String? token) {
    _token = token;
  }

  /// Check if server has password login enabled (auto-detect from /api/auth/status)
  Future<bool> checkServerAuthEnabled() async {
    try {
      final response = await http
          .get(Uri.parse('${server.baseUrl}/api/auth/status'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Hermes returns hasUsers or hasPasswordLogin
        _serverAuthEnabled = data['hasPasswordLogin'] == true || data['hasUsers'] == true;
        DebugLogger.instance.info('checkServerAuthEnabled: enabled=$_serverAuthEnabled');
        return _serverAuthEnabled;
      }
    } catch (e) {
      DebugLogger.instance.warn('checkServerAuthEnabled: failed $e');
    }
    return false;
  }

  /// Login to the server and store JWT token
  Future<bool> login() async {
    DebugLogger.instance.info('login: ${server.username}');
    try {
      final response = await http
          .post(
            Uri.parse('${server.baseUrl}/api/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'username': server.username ?? '',
              'password': server.password ?? '',
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _token = data['token'] as String?;
        DebugLogger.instance.success('login: token received, userId=${data['userId']}');
        return _token != null;
      }
      DebugLogger.instance.error('login: failed status=${response.statusCode} body=${response.body.substring(0, response.body.length.clamp(0, 200))}');
      return false;
    } catch (e) {
      DebugLogger.instance.error('login: exception $e');
      return false;
    }
  }

  /// Check auth status - returns true if authenticated
  Future<bool> checkAuthStatus() async {
    if (_token == null) return false;
    try {
      final response = await http
          .get(Uri.parse('${server.baseUrl}/api/auth/me'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Ensure logged in - auto-detect auth requirement and auto-login if needed
  /// Returns: true (logged in/no auth needed), false (login required - show form)
  Future<bool> ensureLoggedIn() async {
    // Step 1: Auto-detect if server requires auth
    final authEnabled = await checkServerAuthEnabled();
    if (!authEnabled) {
      DebugLogger.instance.info('ensureLoggedIn: server has no auth, skipping');
      return true;  // No auth needed
    }

    // Step 2: If we have a token, verify it's still valid
    if (_token != null) {
      final valid = await checkAuthStatus();
      if (valid) {
        DebugLogger.instance.info('ensureLoggedIn: token still valid');
        return true;
      }
      DebugLogger.instance.warn('ensureLoggedIn: token expired, re-login');
    }

    // Step 3: Auto-login with stored credentials
    if (server.username != null && server.username!.isNotEmpty &&
        server.password != null && server.password!.isNotEmpty) {
      return await login();
    }

    // Step 4: Auth required but no credentials stored - need user input
    DebugLogger.instance.warn('ensureLoggedIn: auth required but no credentials stored');
    return false;
  }

  /// Health check
  Future<HealthStatus> checkHealth() async {
    try {
      final response = await http
          .get(Uri.parse('${server.baseUrl}/health'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return HealthStatus.fromJson(jsonDecode(response.body));
      }
      return HealthStatus(healthy: false);
    } catch (e) {
      return HealthStatus(healthy: false);
    }
  }

  /// Get server config
  Future<Map<String, dynamic>?> getConfig() async {
    try {
      final response = await http
          .get(Uri.parse('${server.baseUrl}/api/hermes/config'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// List sessions
  Future<List<HermesSession>> listSessions({int limit = 50}) async {
    final url = '${server.baseUrl}/api/hermes/sessions?limit=$limit';
    DebugLogger.instance.info('listSessions: GET $url');
    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));

      DebugLogger.instance.info('listSessions: response status=${response.statusCode} body_len=${response.body.length}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final sessions = (data['sessions'] as List? ?? data as List? ?? [])
            .map((s) => HermesSession.fromJson(s as Map<String, dynamic>))
            .toList();
        DebugLogger.instance.success('listSessions: parsed ${sessions.length} sessions');
        return sessions;
      }
      DebugLogger.instance.warn('listSessions: non-200 response', response.body.substring(0, response.body.length.clamp(0, 200)));
      return [];
    } catch (e) {
      DebugLogger.instance.error('listSessions: exception', e.toString());
      return [];
    }
  }

  /// Get session messages
  Future<List<ChatMessage>> getSessionMessages(String sessionId) async {
    DebugLogger.instance.info('getSessionMessages: sessionId=$sessionId url=${server.baseUrl}/api/hermes/sessions/$sessionId/context');
    try {
      final response = await http
          .get(
            Uri.parse('${server.baseUrl}/api/hermes/sessions/$sessionId/context'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));

      DebugLogger.instance.info('getSessionMessages: status=${response.statusCode}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final messages = <ChatMessage>[];
        final msgs = data['messages'] as List? ?? [];
        for (final m in msgs) {
          messages.add(ChatMessage(
            role: m['role'] as String? ?? 'unknown',
            content: m['content'] as String? ?? '',
            timestamp: m['timestamp'] != null
                ? DateTime.fromMillisecondsSinceEpoch((m['timestamp'] as num).toInt() * 1000)
                : DateTime.now(),
          ));
        }
        DebugLogger.instance.success('getSessionMessages: parsed ${messages.length} messages');
        return messages;
      }
      DebugLogger.instance.warn('getSessionMessages: non-200 status=${response.statusCode}');
      return [];
    } catch (e) {
      DebugLogger.instance.error('getSessionMessages: exception $e');
      return [];
    }
  }

  /// Run chat (send message and get response)
  Future<ChatResult> runChat({
    required String input,
    String? sessionId,
    String? model,
    String? provider,
  }) async {
    try {
      final body = <String, dynamic>{
        'input': input,
        'profile': server.profile,
      };
      if (sessionId != null) body['session_id'] = sessionId;
      if (model != null) body['model'] = model;
      if (provider != null) body['provider'] = provider;

      final response = await http
          .post(
            Uri.parse('${server.baseUrl}/api/studio/chat-run/runs'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return ChatResult(
          success: true,
          content: data['output'] as String? ?? data['content'] as String? ?? '',
          sessionId: data['session_id'] as String? ?? sessionId,
          events: data['events'] as List?,
        );
      } else {
        return ChatResult(
          success: false,
          content: 'Error: HTTP ${response.statusCode}',
          error: response.body,
        );
      }
    } catch (e) {
      return ChatResult(
        success: false,
        content: 'Connection error: $e',
        error: e.toString(),
      );
    }
  }

  /// Get available model groups for the active profile
  Future<List<ModelGroup>> fetchModelGroups() async {
    try {
      final response = await http
          .get(
            Uri.parse('${server.baseUrl}/api/hermes/config/model-groups'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final groups = (data['groups'] as List? ?? []).map((g) {
          return ModelGroup(
            provider: g['provider'] as String? ?? '',
            providerKey: g['provider_key'] as String? ?? '',
            models: (g['models'] as List? ?? [])
                .map((m) => ModelInfo(
                      id: m['id'] as String? ?? '',
                      label: m['label'] as String? ?? m['id'] as String? ?? '',
                      description: m['description'] as String? ?? '',
                      priority: m['priority'] as int? ?? 1000,
                    ))
                .toList(),
          );
        }).toList();
        return groups;
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Delete a session
  Future<bool> deleteSession(String sessionId) async {
    try {
      final response = await http
          .delete(
            Uri.parse('${server.baseUrl}/api/hermes/sessions/$sessionId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Rename a session
  Future<bool> renameSession(String sessionId, String title) async {
    try {
      final response = await http
          .post(
            Uri.parse('${server.baseUrl}/api/hermes/sessions/$sessionId/rename'),
            headers: _headers,
            body: jsonEncode({'title': title}),
          )
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// List files in a directory
  Future<List<FileNode>> listFiles(String path) async {
    try {
      final response = await http
          .get(
            Uri.parse('${server.baseUrl}/api/studio/files/list?path=${Uri.encodeComponent(path)}'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final files = (data['files'] as List? ?? data as List? ?? [])
            .map((f) => FileNode.fromJson(f as Map<String, dynamic>))
            .toList();
        return files;
      }
      return [];
    } catch (e) {
      DebugLogger.instance.error('listFiles failed', e.toString());
      return [];
    }
  }

  /// Read file content
  Future<String> readFile(String path) async {
    try {
      final response = await http
          .get(
            Uri.parse('${server.baseUrl}/api/studio/files/read?path=${Uri.encodeComponent(path)}'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['content'] as String? ?? '';
      }
      return '';
    } catch (e) {
      DebugLogger.instance.error('readFile failed', e.toString());
      return '';
    }
  }

  /// Write file content
  Future<bool> writeFile(String path, String content) async {
    try {
      final response = await http
          .put(
            Uri.parse('${server.baseUrl}/api/studio/files/write'),
            headers: _headers,
            body: jsonEncode({'path': path, 'content': content}),
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode == 200;
    } catch (e) {
      DebugLogger.instance.error('writeFile failed', e.toString());
      return false;
    }
  }

  /// Create directory
  Future<bool> createDirectory(String path) async {
    try {
      final response = await http
          .post(
            Uri.parse('${server.baseUrl}/api/studio/files/mkdir'),
            headers: _headers,
            body: jsonEncode({'path': path}),
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode == 200;
    } catch (e) {
      DebugLogger.instance.error('createDirectory failed', e.toString());
      return false;
    }
  }

  /// Delete file or directory
  Future<bool> deleteFile(String path) async {
    try {
      final response = await http
          .delete(
            Uri.parse('${server.baseUrl}/api/studio/files/delete?path=${Uri.encodeComponent(path)}'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode == 200;
    } catch (e) {
      DebugLogger.instance.error('deleteFile failed', e.toString());
      return false;
    }
  }

  /// Rename file or directory
  Future<bool> renameFile(String oldPath, String newPath) async {
    try {
      final response = await http
          .post(
            Uri.parse('${server.baseUrl}/api/studio/files/rename'),
            headers: _headers,
            body: jsonEncode({'old_path': oldPath, 'new_path': newPath}),
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode == 200;
    } catch (e) {
      DebugLogger.instance.error('renameFile failed', e.toString());
      return false;
    }
  }
}

/// File node for directory listing
class FileNode {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime modifiedAt;

  FileNode({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
    DateTime? modifiedAt,
  }) : modifiedAt = modifiedAt ?? DateTime.now();

  factory FileNode.fromJson(Map<String, dynamic> json) => FileNode(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        isDirectory: json['is_directory'] as bool? ?? json['type'] == 'directory',
        size: json['size'] as int? ?? 0,
        modifiedAt: json['modified_at'] != null
            ? DateTime.tryParse(json['modified_at']) ?? DateTime.now()
            : DateTime.now(),
      );
}

/// Result from a chat run
class ChatResult {
  final bool success;
  final String content;
  final String? sessionId;
  final String? error;
  final List? events;

  ChatResult({
    required this.success,
    required this.content,
    this.sessionId,
    this.error,
    this.events,
  });
}
