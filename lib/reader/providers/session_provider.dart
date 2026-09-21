import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../services/session_monitor_service.dart';
import '../services/proxy_client.dart' as reader_proxy;
import '../services/socket_io_client.dart';
import '../services/hermes_api_client.dart';
import '../services/voice_command_service.dart';
import '../providers/task_provider.dart';
import '../models/hive_models.dart';

/// Owns the [SessionMonitorService] and exposes its state to the UI.
/// Also listens to DI session updates from the proxy client.
class SessionProvider extends ChangeNotifier {
  SessionMonitorService? _monitor;
  SessionMonitorService get monitor => _monitor!;

  StreamSubscription<SessionChange>? _changeSub;
  StreamSubscription<Map<String, dynamic>>? _diSub;
  StreamSubscription<Map<String, dynamic>>? _authSub;
  StreamSubscription<Map<String, dynamic>>? _diEventSub;
  final List<SessionChange> _recentChanges = [];
  bool _initialized = false;
  reader_proxy.ProxyClient? _proxyClient;
  TaskProvider? _taskProvider;

  List<SessionChange> get recentChanges => List.unmodifiable(_recentChanges);
  bool get isInitialized => _initialized;
  bool get isMonitoring => _monitor?.isRunning ?? false;

  /// The proxy client used for DI/WebSocket tunneling. Exposed so the TTS
  /// service can forward /api/hermes/tts/synthesize through the same proxy
  /// connection (and reuse the backend JWT the proxy obtained on mcu-login).
  reader_proxy.ProxyClient? get proxyClient => _proxyClient;

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
    // Use the backend JWT the proxy obtained during mcu-login (returned in the
    // ConnectAck) — NOT the reader's proxy auth token, which the backend
    // rejects for /chat-run. Fall back to the target auth token only if the
    // proxy didn't supply one.
    final token = _proxyClient?.backendJWT(serverId) ?? target?.authToken;
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

      // Connect to the /chat-run namespace with the Studio auth token, and
      // wait for the Engine.IO `40` CONNECT ack before emitting anything.
      // Emitting before the ack is a protocol violation the server rejects
      // with "Authentication failed".
      await socket.connectNamespace({'token': token ?? ''})
          .timeout(const Duration(seconds: 15));
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
      String? preFailure;
      var completed = false;
      var started = false;

      try {
        await for (final ev in socket.events.timeout(const Duration(minutes: 5))) {
          switch (ev.name) {
            case 'run.started':
              started = true;
              break;
            case 'message.delta':
              final delta = _extractDelta(ev.data);
              if (delta != null && delta.isNotEmpty) buffer.write(delta);
              break;
            case 'run.completed':
              final d = ev.data as Map?;
              finalSessionId = d?['session_id'] as String? ?? finalSessionId;
              final out = (d?['output'] as String?) ??
                  (d?['final_response'] as String?) ??
                  (d?['content'] as String?) ??
                  ((d?['result'] is Map)
                      ? (d?['result'] as Map)['final_response'] as String?
                      : null);
              if (out != null && out.isNotEmpty) {
                // Final assembled output takes precedence over streamed deltas.
                buffer.clear();
                buffer.write(out);
              }
              completed = true;
              break;
            case 'run.failed':
              final d = ev.data as Map?;
              final msg = d?['error'] as String? ??
                  d?['message'] as String? ??
                  'run failed';
              if (started) {
                // The run started and then failed — a real failure.
                finalError = msg;
              } else {
                // A failure arriving before run.started (e.g. a spurious
                // "Session not found" emitted in response to `resume`) is not
                // necessarily fatal — keep listening in case run.started /
                // run.completed follow (observed with probe-session).
                preFailure = msg;
              }
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

      // A failure emitted before the run ever started is only fatal if no
      // run.started / run.completed superseded it.
      if (!completed && finalError == null && !started && preFailure != null) {
        finalError = preFailure;
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
    // Subscribe to backend authorization requests (DI 0x39) and surface them
    // as pending tasks in 待处理事项.
    _authSub = client.authRequests.listen(_onDIAuthRequest);
    // Subscribe to opaque DI events (DI 0x3B) and surface clarify.requested
    // as pending tasks with selectable choices.
    _diEventSub = client.diEvents.listen(_onDIEvent);
    // Also pass to monitor service for DI polling
    _monitor?.setProxyClient(client);
    notifyListeners();
  }

  /// Bind the TaskProvider so DI auth requests can be surfaced as tasks.
  void setTaskProvider(TaskProvider provider) {
    _taskProvider = provider;
  }

  /// Handle a DI authorization request (0x39) pushed by the proxy and turn it
  /// into a pending task in 待处理事项.
  void _onDIAuthRequest(Map<String, dynamic> req) {
    final taskProvider = _taskProvider;
    if (taskProvider == null) return;

    final reqId = (req['req_id'] ?? req['id'] ?? '').toString();
    final serverId = (req['server_id'] ?? req['source'] ?? '').toString();
    if (reqId.isEmpty) return;

    final prompt = (req['prompt'] ?? req['message'] ?? req['desc'] ?? '需要您确认')
        .toString();
    final title = (req['title'] ??
            req['name'] ??
            (prompt.length > 20 ? prompt.substring(0, 20) : prompt))
        .toString();
    final choicesRaw = req['choices'];
    final List<String> choices = choicesRaw is List
        ? choicesRaw.map((e) => e.toString()).toList()
        : <String>[];
    final timeoutMs = req['timeout_ms'];
    final DateTime? timeoutAt = timeoutMs is int
        ? DateTime.now().add(Duration(milliseconds: timeoutMs))
        : null;

    final task = TaskItem(
      id: reqId,
      title: title,
      description: prompt,
      serverId: serverId,
      createdAt: DateTime.now(),
      timeoutAt: timeoutAt,
      priority: TaskPriority.high,
      resolved: false,
    );
    taskProvider.addTask(task);
  }

  /// Handle an opaque DI event (0x3B) pushed by the proxy. Currently used to
  /// surface `clarify.requested` dialogs as pending tasks in 待处理事项.
  void _onDIEvent(Map<String, dynamic> event) {
    final taskProvider = _taskProvider;
    if (taskProvider == null) return;

    final eventName = (event['event'] ?? '').toString();
    if (eventName != 'clarify.requested') return;

    final data = event['data'];
    if (data is! Map) return;

    final sessionId = (data['session_id'] ?? '').toString();
    final clarifyId = (data['clarify_id'] ?? '').toString();
    final question = (data['question'] ?? '').toString();
    final choicesRaw = data['choices'];
    final List<String> choices = choicesRaw is List
        ? choicesRaw.map((e) => e.toString()).toList()
        : <String>[];
    final timeoutMs = data['timeout_ms'];
    final DateTime? timeoutAt = timeoutMs is int
        ? DateTime.now().add(Duration(milliseconds: timeoutMs))
        : null;

    if (clarifyId.isEmpty) return;

    final task = TaskItem(
      id: clarifyId,
      title: question.isNotEmpty ? question : '需要您确认',
      description: '来自会话 $sessionId 的确认请求',
      serverId: '',
      createdAt: DateTime.now(),
      timeoutAt: timeoutAt,
      priority: TaskPriority.high,
      choices: choices,
      resolved: false,
    );
    taskProvider.addTask(task);
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
  // 检查是否是停止事件，只保留最新的一个停止会话
  if (change.kind == SessionChangeKind.sessionStopped) {
    // 检查是否已经记录过这个会话的停止
    bool isDuplicate = _recentChanges.any((c) => 
      c.kind == SessionChangeKind.sessionStopped && 
      c.after?.id == change.after?.id
    );
    if (!isDuplicate) {
      _recentChanges.insert(0, change);
      if (_recentChanges.length > maxHistory) {
        _recentChanges.removeLast();
      }
    }
  } else {
    _recentChanges.insert(0, change);
    if (_recentChanges.length > maxHistory) {
      _recentChanges.removeLast();
    }
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
    _authSub?.cancel();
    _authSub = null;
    _proxyClient = null;
    _monitor?.clearProxyClient();
    notifyListeners();
  }

  @override
  void dispose() {
    _changeSub?.cancel();
    _diSub?.cancel();
    _authSub?.cancel();
    _monitor?.dispose();
    super.dispose();
  }
}
