import 'dart:async';
import 'package:flutter/foundation.dart';
import '../services/session_monitor_service.dart';
import '../services/proxy_client.dart' as reader_proxy;

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

  @override
  void dispose() {
    _changeSub?.cancel();
    _diSub?.cancel();
    _monitor?.dispose();
    super.dispose();
  }
}
