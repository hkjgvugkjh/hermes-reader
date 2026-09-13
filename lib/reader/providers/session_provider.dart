import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../services/session_monitor_service.dart';
import '../services/proxy_client.dart' as reader_proxy;
import '../services/socket_io_client.dart';
import '../services/hermes_api_client.dart';
import '../services/voice_command_service.dart';
import '../models/hive_models.dart';

/// Owns the [SessionMonitorService] and exposes its state to the UI.
/// Also listens to DI session updates from the proxy client.
class SessionProvider extends ChangeNotifier {
  SessionMonitorService? _monitor;
  SessionMonitorService get monitor => _monitor!;

  StreamSubscription<SessionChange>? _changeSub;
  StreamSubscription<Map<String, dynamic>>? _diSub;
  final List<SessionChange> _recentChanges = [];
  bool _initialized = false;
  reader_proxy.ProxyClient? _proxyClient;

  List<SessionChange> get recentChanges => List.unmodifiable(_recentChanges);
  bool get isInitialized => _initialized;
  bool get isMonitoring => _monitor?.isRunning ?? false;

  /// Current snapshot of every known session (latest poll per server).
  List<SessionSnapshot> get currentSessions =>
      _monitor?.currentSessions.values.toList() ?? const [];

  /// The server a session is monitored under.
  String? serverIdForSession(String sessionId) =>
      _monitor?.serverIdForSession(sessionId);

  /// The monitoring target (base url, credentials) for a server, or null.
  MonitorTarget? targetForServer(String serverId) {
    _ensureInit();
    if (_monitor == null) return null;
    for (final t in _monitor!.targets) {
      if (t.serverId == serverId) return t;
    }
    return null;
  }

  /// Build an API client bound to the server hosting [sessionId].
  HermesApiClient? clientForSession(String sessionId) {
    final serverId = serverIdForSession(sessionId);
    if (serverId == null) return null;
    final target = targetForServer(serverId);
    if (target == null) return null;
    final client = HermesApiClient(ServerConfig(
      id: target.serverId,
      name: target.serverId,
      url: target.baseUrl,
      authToken: target.authToken,
      username: target.username,
      password: target.password,
      profile: target.profile ?? 'default',
    ));
    client.setToken(target.authToken);
    return client;
  }

  /// Send [input] as a chat command to a session, mirroring hermes-web-ui's
  /// chat-run interface (POST /api/studio/chat-run/runs with session_id).
  ///
  /// Routes through the proxy (DI) protocol when a proxy client is connected
  /// for the session's server, otherwise falls back to a direct HTTP client.
  Future<ChatResult> sendCommandToSession(String sessionId, String input) async {
    final serverId = serverIdForSession(sessionId);
    if (serverId == null) {
      return ChatResult(
        success: false,
        content: '',
        error: '未找到会话所属服务器',
      );
    }
    if (_proxyClient != null && _proxyClient!.isConnected) {
      return _runChatViaProxy(serverId, input, sessionId);
    }
    final client = clientForSession(serverId);
    if (client == null) {
      return ChatResult(
        success: false,
        content: '',
        error: '未找到会话所属服务器',
      );
    }
    return client.runChat(input: input, sessionId: sessionId);
  }

  /// Send [input] as a chat command to [sessionId] through the proxy.
  ///
  /// The Studio REST endpoint this used to hit (`POST /api/studio/chat-run/runs`)
  /// is a dead stub on current builds; the live path is the Studio Socket.IO
  /// `/chat-run` namespace (Engine.IO over WebSocket). We open a raw WebSocket
  /// tunnel through the proxy, run a tiny Socket.IO client inside it, then
  /// `resume` the session and emit `run` with the user input — collecting the
  /// streamed `message.delta` / `run.completed` events back into the reply.
  Future<ChatResult> _runChatViaProxy(
    String serverId,
    String input,
    String sessionId,
  ) async {
    final target = targetForServer(serverId);
    final token = target?.authToken;
    final profile = target?.profile ?? 'default';

    final headers = <String, String>{};
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    final profileEnc = Uri.encodeQueryComponent(profile);
    var socketPath = '/socket.io/?EIO=4&transport=websocket&profile=$profileEnc';
    if (token != null && token.isNotEmpty) {
      socketPath += '&token=${Uri.encodeQueryComponent(token)}';
    }

    try {
      final tunnel = await _proxyClient!.openTunnel(
        serverId: serverId,
        path: socketPath,
        headers: headers.isNotEmpty ? headers : null,
      );
      final socket = SocketIoClient(
        input: tunnel.data,
        send: (s) {
          tunnel.send(s);
        },
        namespace: '/chat-run',
      );
      await socket.opened.timeout(const Duration(seconds: 15));

      // Connect to the /chat-run namespace with the Studio auth token.
      socket.connectNamespace({'token': token ?? ''});
      // Subscribe to the session's event stream.
      socket.emit('resume', {'session_id': sessionId, 'profile': profile});
      // Submit the user input as a run.
      socket.emit('run', {
        'session_id': sessionId,
        'input': input,
        'profile': profile,
      });

      final buffer = StringBuffer();
      String? finalSessionId = sessionId;
      String? finalError;
      var completed = false;

      try {
        await for (final ev in socket.events.timeout(const Duration(minutes: 5))) {
          switch (ev.name) {
            case 'run.started':
              break;
            case 'message.delta':
              final delta = _extractDelta(ev.data);
              if (delta != null && delta.isNotEmpty) buffer.write(delta);
              break;
            case 'run.completed':
              final d = ev.data as Map?;
              finalSessionId = d?['session_id'] as String? ?? finalSessionId;
              final out = d?['output'] as String? ?? d?['content'] as String?;
              if (out != null && out.isNotEmpty) {
                // Final assembled output takes precedence over streamed deltas.
                buffer.clear();
                buffer.write(out);
              }
              completed = true;
              break;
            case 'run.failed':
              final d = ev.data as Map?;
              finalError = d?['error'] as String? ??
                  d?['message'] as String? ??
                  'run failed';
              break;
            default:
              final lower = ev.name.toLowerCase();
              if (lower.contains('error') || lower.contains('fail')) {
                final d = ev.data as Map?;
                finalError = d?['error'] as String? ??
                    d?['message'] as String? ??
                    ev.name;
              }
          }
          if (completed || finalError != null) break;
        }
      } on TimeoutException {
        // Ran past the cap; return whatever streamed so far.
      }

      await tunnel.close();

      if (finalError != null) {
        return ChatResult(
          success: false,
          content: buffer.toString(),
          error: finalError,
          sessionId: finalSessionId,
        );
      }
      final content = buffer.toString();
      if (content.isEmpty) {
        return ChatResult(
          success: false,
          content: '',
          error: '未收到回复（事件流为空）',
          sessionId: finalSessionId,
        );
      }
      return ChatResult(
        success: true,
        content: content,
        sessionId: finalSessionId,
      );
    } catch (e) {
      return ChatResult(
        success: false,
        content: '',
        error: e.toString(),
      );
    }
  }

  /// Pull a text delta out of a Socket.IO `message.delta` payload. Studio may
  /// shape it as `{delta}`, `{text}`, `{content}`, or `{message:{content}}`.
  String? _extractDelta(dynamic data) {
    if (data is! Map) return null;
    final direct = data['delta'] as String? ??
        data['text'] as String? ??
        data['content'] as String?;
    if (direct != null) return direct;
    final msg = data['message'];
    if (msg is Map) {
      return msg['content'] as String? ?? msg['text'] as String?;
    }
    return null;
  }

  /// Send recorded audio to the server's voice-turn endpoint through the proxy
  /// (DI) protocol. Used by the voice command button when a proxy is connected.
  Future<VoiceTurnResult> sendVoiceTurnViaProxy(
    String serverId,
    String filePath,
    String? authToken,
  ) async {
    if (_proxyClient == null || !_proxyClient!.isConnected) {
      return const VoiceTurnResult(
        success: false,
        transcript: '',
        error: 'proxy 未连接',
      );
    }
    final bytes = await File(filePath).readAsBytes();
    final headers = <String, String>{
      'Content-Type': 'audio/wav',
      'Accept': 'application/json',
    };
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }
    try {
      final resp = await _proxyClient!.sendRequest(
        serverId: serverId,
        method: 'POST',
        path: '/api/hermes/mcu/voice-turn',
        headers: headers,
        body: bytes,
      ).timeout(const Duration(seconds: 30));
      final status = resp['status_code'] as int? ?? 0;
      if (status == 401 || status == 403) {
        return const VoiceTurnResult(
          success: false,
          transcript: '',
          error: 'authorization required',
        );
      }
      if (status != 200) {
        return VoiceTurnResult(
          success: false,
          transcript: '',
          error: 'server error $status',
        );
      }
      final body = _decodeJsonBody(resp);
      return VoiceTurnResult(
        success: true,
        transcript: body?['transcript']?.toString() ?? '',
      );
    } catch (e) {
      return VoiceTurnResult(
        success: false,
        transcript: '',
        error: e.toString(),
      );
    }
  }

  /// Normalise a proxy HTTP response body (base64 bytes or raw JSON string)
  /// into a JSON map.
  Map<String, dynamic>? _decodeJsonBody(Map<String, dynamic> resp) {
    final body = resp['body'];
    if (body == null) return null;
    String text;
    if (body is List<int>) {
      text = utf8.decode(body);
    } else if (body is String) {
      try {
        text = utf8.decode(base64Decode(body));
      } catch (_) {
        text = body;
      }
    } else {
      return null;
    }
    if (text.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(text));
    } catch (_) {
      return null;
    }
  }

  /// Maximum changes to retain for the UI list.
  int maxHistory = 50;

  /// The proxy client for DI protocol communication.
  reader_proxy.ProxyClient? get proxyClient => _proxyClient;

  /// Initialize with optional pre-built monitor (e.g., from tests).
  void init({SessionMonitorService? monitor}) {
    if (_initialized) return;
    _monitor = monitor ?? SessionMonitorService();
    _changeSub = _monitor!.changes.listen(_onChange);
    _initialized = true;
    notifyListeners();
  }

  /// Set the proxy client to receive DI session updates.
  void setProxyClient(reader_proxy.ProxyClient client) {
    _proxyClient = client;
    _diSub = client.sessionUpdates.listen(_onDIUpdate);
    // Also pass to monitor service for DI polling
    _monitor?.setProxyClient(client);
    notifyListeners();
  }

  void _onDIUpdate(Map<String, dynamic> update) {
    final serverId = update['server_id'] as String? ?? '';
    final full = update['full'] as bool? ?? false;
    final sessions = update['sessions'] as List? ?? [];

    for (final s in sessions) {
      final map = s as Map<String, dynamic>;
      final snap = SessionSnapshot.fromJson(map);
      final change = SessionChange(
        kind: SessionChangeKind.sessionResumed,
        after: snap,
        serverId: serverId,
      );
      _onChange(change);
    }
  }

  void _onChange(SessionChange change) {
    _recentChanges.insert(0, change);
    if (_recentChanges.length > maxHistory) {
      _recentChanges.removeLast();
    }
    notifyListeners();
  }

  /// Add a server and start monitoring if not already.
  Future<void> addServer(MonitorTarget target) async {
    _ensureInit();
    _monitor!.addTarget(target);
    // Connect to the server via DI protocol first, then start monitoring
    if (_proxyClient != null && _proxyClient!.isConnected) {
      await _proxyClient!.connectServer(
        target.serverId,
        username: target.username,
        password: target.password,
        profile: target.profile,
      );
    }
    if (!_monitor!.isRunning) {
      await _monitor!.start();
    }
    notifyListeners();
  }

  void removeServer(String serverId) {
    _ensureInit();
    _monitor!.removeTarget(serverId);
    notifyListeners();
  }

  void setToken(String serverId, String? token) {
    _ensureInit();
    _monitor!.setToken(serverId, token);
  }

  Future<void> pollNow(String serverId) async {
    _ensureInit();
    await _monitor!.pollNow(serverId);
  }

  Future<void> start() async {
    _ensureInit();
    await _monitor!.start();
    notifyListeners();
  }

  Future<void> stop() async {
    _ensureInit();
    await _monitor!.stop();
    notifyListeners();
  }

  void clearHistory() {
    _recentChanges.clear();
    notifyListeners();
  }

  void _ensureInit() {
    if (!_initialized) init();
  }

  void clearProxyClient() {
    _diSub?.cancel();
    _diSub = null;
    _proxyClient = null;
    _monitor?.clearProxyClient();
    notifyListeners();
  }

  @override
  void dispose() {
    _changeSub?.cancel();
    _diSub?.cancel();
    _monitor?.dispose();
    super.dispose();
  }
}
