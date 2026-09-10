import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../services/proxy_client.dart' as reader_proxy;

/// Snapshot of one Hermes session's state at a point in time.
class SessionSnapshot {
  final String id;
  final String title;
  final SessionState state;
  final DateTime lastActivity;
  final String? pendingAction;
  final Map<String, dynamic>? raw;

  const SessionSnapshot({
    required this.id,
    required this.title,
    required this.state,
    required this.lastActivity,
    this.pendingAction,
    this.raw,
  });

  factory SessionSnapshot.fromJson(Map<String, dynamic> json) {
    return SessionSnapshot(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? json['name']?.toString() ?? 'untitled',
      state: _inferState(json),
      lastActivity: _parseTime(json),
      raw: json,
    );
  }

  /// Accepts ISO8601 strings or unix epoch (seconds or milliseconds).
  static DateTime _parseTime(Map<String, dynamic> json) {
    final raw = json['updated_at'] ??
        json['updatedAt'] ??
        json['last_activity'] ??
        json['lastActive'] ??
        json['last_active'];
    if (raw == null) return DateTime.now();
    if (raw is num) {
      final v = raw.toInt();
      // Heuristic: values above 1e12 are milliseconds.
      return DateTime.fromMillisecondsSinceEpoch(
        v > 1000000000000 ? v : v * 1000,
      );
    }
    final s = raw.toString();
    final asNum = int.tryParse(s);
    if (asNum != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        asNum > 1000000000000 ? asNum : asNum * 1000,
      );
    }
    return DateTime.tryParse(s) ?? DateTime.now();
  }

  /// Seconds of inactivity after which a session is considered stopped.
  static const int activityTtlSeconds = 180;

  static SessionState _inferState(Map<String, dynamic> json) {
    final rawStatus = (json['status'] ?? json['state'])?.toString().toLowerCase();
    if (rawStatus != null && rawStatus.isNotEmpty) {
      switch (rawStatus) {
        case 'error':
        case 'failed':
          return SessionState.error;
        case 'pending':
        case 'waiting':
        case 'needs_input':
          return SessionState.pending;
        case 'completed':
        case 'stopped':
        case 'finished':
        case 'done':
          return SessionState.stopped;
        case 'running':
        case 'active':
        case 'busy':
          return SessionState.running;
      }
    }
    if (json['error'] == true) return SessionState.error;
    if (json['pending'] == true || json['needs_input'] == true) {
      return SessionState.pending;
    }
    if (json['completed'] == true) return SessionState.stopped;

    // Hermes DI only reports `last_active`; infer from recency.
    final last = _parseTime(json);
    final idle = DateTime.now().difference(last).inSeconds;
    if (idle < 0 || idle > activityTtlSeconds) return SessionState.stopped;
    return SessionState.running;
  }
}

enum SessionState {
  running,
  stopped,
  pending,
  error,
}

/// What kind of change was detected between two polling cycles.
enum SessionChangeKind {
  sessionStarted,
  sessionStopped,
  sessionNeedsInput,
  sessionResumed,
  authRequired,
  serverError,
}

/// Detected change between two polling cycles.
class SessionChange {
  final SessionChangeKind kind;
  final SessionSnapshot? before;
  final SessionSnapshot? after;
  final String serverId;
  final DateTime detectedAt;

  SessionChange({
    required this.kind,
    this.before,
    this.after,
    required this.serverId,
    DateTime? detectedAt,
  }) : detectedAt = detectedAt ?? DateTime.now();

  @override
  String toString() =>
      'SessionChange($kind, server=$serverId, session=${after?.id ?? before?.id})';
}

/// Configuration for a single server to monitor.
class MonitorTarget {
  final String serverId;
  final String baseUrl;
  final String? authToken;

  /// Credentials forwarded to the proxy on DI connect. Required whenever the
  /// proxy has no stored credentials for this server, otherwise mcu-login
  /// fails and the connect just times out.
  final String? username;
  final String? password;

  /// hermes_studio profile to bind to.
  final String? profile;

  final Duration pollInterval;
  final Duration stoppedThreshold;

  const MonitorTarget({
    required this.serverId,
    required this.baseUrl,
    this.authToken,
    this.username,
    this.password,
    this.profile,
    this.pollInterval = const Duration(seconds: 60),
    this.stoppedThreshold = const Duration(seconds: 90),
  });
}

/// Polls one or more Hermes servers for session state, emits changes.
///
/// Usage:
///   final monitor = SessionMonitorService();
///   monitor.addTarget(MonitorTarget(serverId: 'srv-1', baseUrl: 'http://...'));
///   monitor.changes.listen((change) { /* notify user */ });
///   await monitor.start();
class SessionMonitorService {
  final http.Client _client;
  reader_proxy.ProxyClient? _proxyClient;

  final List<MonitorTarget> _targets = [];
  final Map<String, List<SessionSnapshot>> _lastSnapshots = {};
  final Map<String, DateTime> _lastActivity = {};
  final Map<String, Timer> _timers = {};
  final Map<String, String?> _serverTokens = {};

  final _changeController = StreamController<SessionChange>.broadcast();
  Stream<SessionChange> get changes => _changeController.stream;

  final Map<String, bool> _stoppedNotified = {};
  bool _running = false;
  bool get isRunning => _running;

  /// Build a service with an optional custom http client (for tests)
  /// and an optional proxy client (when connecting via hermes-proxy).
  SessionMonitorService({http.Client? client, reader_proxy.ProxyClient? proxyClient})
      : _client = client ?? http.Client(),
        _proxyClient = proxyClient;

  /// Add a server to monitor. If already monitoring, updates its target.
  void addTarget(MonitorTarget target) {
    removeTarget(target.serverId);
    _targets.add(target);
    if (_running) {
      _startTimerFor(target);
    }
  }

  void removeTarget(String serverId) {
    _timers[serverId]?.cancel();
    _timers.remove(serverId);
    _lastSnapshots.remove(serverId);
    _lastActivity.remove(serverId);
    _serverTokens.remove(serverId);
    _stoppedNotified.remove(serverId);
    _targets.removeWhere((t) => t.serverId == serverId);
  }

  void clearTargets() {
    for (final t in [..._targets]) {
      removeTarget(t.serverId);
    }
  }

  List<MonitorTarget> get targets => List.unmodifiable(_targets);

  /// Set (or clear) the auth token for a server (e.g., after login).
  void setToken(String serverId, String? token) {
    _serverTokens[serverId] = token;
  }

  /// Set the proxy client to use for polling (via DI protocol).
  void setProxyClient(reader_proxy.ProxyClient client) {
    _proxyClient = client;
  }

  /// Begin polling all targets.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    for (final target in _targets) {
      await _pollOnce(target);
      _startTimerFor(target);
    }
  }

  void _startTimerFor(MonitorTarget target) {
    _timers[target.serverId]?.cancel();
    _timers[target.serverId] = Timer.periodic(target.pollInterval, (_) async {
      await _pollOnce(target);
    });
  }

  /// Stop all polling.
  Future<void> stop() async {
    _running = false;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  /// Immediately poll one target and emit changes (useful for manual refresh).
  Future<void> pollNow(String serverId) async {
    for (final t in _targets) {
      if (t.serverId == serverId) {
        await _pollOnce(t);
        return;
      }
    }
  }

  Future<void> _pollOnce(MonitorTarget target) async {
    try {
      final token = _serverTokens[target.serverId] ?? target.authToken;
      
      // Use proxy client if available (DI protocol), otherwise direct HTTP
      if (_proxyClient != null && _proxyClient!.isConnected) {
        final fetched = await _fetchSessionsDI(target.serverId, token);
        if (fetched == null) {
          _emitChange(SessionChange(
            kind: SessionChangeKind.serverError,
            serverId: target.serverId,
          ));
          return;
        }
        final snapshots = fetched.$1;
        final authRequired = fetched.$2;

        if (authRequired) {
          _emitChange(SessionChange(
            kind: SessionChangeKind.authRequired,
            serverId: target.serverId,
          ));
          return;
        }

        final previous = _lastSnapshots[target.serverId] ?? [];
        _lastSnapshots[target.serverId] = snapshots;
        _detectChanges(target, previous, snapshots);
      } else {
        // Direct HTTP (fallback)
        final fetched = await _fetchSessions(target.baseUrl, token);
        if (fetched == null) {
          _emitChange(SessionChange(
            kind: SessionChangeKind.serverError,
            serverId: target.serverId,
          ));
          return;
        }
        final snapshots = fetched.$1;
        final authRequired = fetched.$2;

        if (authRequired) {
          _emitChange(SessionChange(
            kind: SessionChangeKind.authRequired,
            serverId: target.serverId,
          ));
          return;
        }

        final previous = _lastSnapshots[target.serverId] ?? [];
        _lastSnapshots[target.serverId] = snapshots;
        _detectChanges(target, previous, snapshots);
      }
    } catch (_) {
      _emitChange(SessionChange(
        kind: SessionChangeKind.serverError,
        serverId: target.serverId,
      ));
    }
  }

  /// Fetch sessions via DI protocol (through proxy).
  Future<(List<SessionSnapshot>, bool)?> _fetchSessionsDI(String serverId, String? token) async {
    if (_proxyClient == null) return null;
    
    try {
      final update = await _proxyClient!.requestSessions(serverId,
          timeout: const Duration(seconds: 15));
      final sessions = update['sessions'] as List? ?? [];
      final snapshots = sessions
          .map((e) => SessionSnapshot.fromJson(e as Map<String, dynamic>))
          .toList();
      return (snapshots, false);
    } catch (e) {
      return null;
    }
  }

  /// Returns (snapshots, authRequired). null on network failure.
  Future<(List<SessionSnapshot>, bool)?> _fetchSessions(
      String baseUrl, String? token) async {
    final headers = <String, String>{
      'Accept': 'application/json',
    };
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    final uri = Uri.parse('$baseUrl/api/hermes/sessions');
    final resp = await _client.get(uri, headers: headers).timeout(
      const Duration(seconds: 15),
    );

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      return (<SessionSnapshot>[], true);
    }
    if (resp.statusCode != 200) return null;

    final body = jsonDecode(resp.body);
    final rawList = body is List
        ? body
        : (body['sessions'] as List? ?? body['data'] as List? ?? []);

    final snapshots = rawList
        .map((e) => SessionSnapshot.fromJson(e as Map<String, dynamic>))
        .toList();
    return (snapshots, false);
  }

  void _detectChanges(MonitorTarget target,
      List<SessionSnapshot> previous, List<SessionSnapshot> current) {
    final prevMap = {for (final s in previous) s.id: s};
    final currMap = {for (final s in current) s.id: s};

    // New sessions
    for (final snap in current) {
      if (!prevMap.containsKey(snap.id)) {
        _emitChange(SessionChange(
          kind: SessionChangeKind.sessionStarted,
          after: snap,
          serverId: target.serverId,
        ));
      }
    }

    // Removed sessions (treat as stopped)
    for (final snap in previous) {
      if (!currMap.containsKey(snap.id)) {
        _emitChange(SessionChange(
          kind: SessionChangeKind.sessionStopped,
          before: snap,
          serverId: target.serverId,
        ));
      }
    }

    // State changes for existing sessions
    for (final snap in current) {
      final prev = prevMap[snap.id];
      if (prev == null) continue;

      if (prev.state != snap.state) {
        if (snap.state == SessionState.stopped) {
          final key = '${target.serverId}:${snap.id}';
          final already = _stoppedNotified[key] ?? false;
          if (!already) {
            _stoppedNotified[key] = true;
            _emitChange(SessionChange(
              kind: SessionChangeKind.sessionStopped,
              before: prev,
              after: snap,
              serverId: target.serverId,
            ));
          }
        } else if (snap.state == SessionState.pending) {
          _emitChange(SessionChange(
            kind: SessionChangeKind.sessionNeedsInput,
            before: prev,
            after: snap,
            serverId: target.serverId,
          ));
        } else if (snap.state == SessionState.running) {
          _emitChange(SessionChange(
            kind: SessionChangeKind.sessionResumed,
            before: prev,
            after: snap,
            serverId: target.serverId,
          ));
        }
      } else {
        _lastActivity['${target.serverId}:${snap.id}'] = snap.lastActivity;
      }
    }
  }

  void _emitChange(SessionChange change) {
    if (!_changeController.isClosed) {
      _changeController.add(change);
    }
  }

  /// Dispose all resources.
  Future<void> dispose() async {
    await stop();
    await _changeController.close();
    _client.close();
  }
}
