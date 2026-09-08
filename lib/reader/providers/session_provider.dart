import 'dart:async';
import 'package:flutter/foundation.dart';
import '../services/session_monitor_service.dart';

/// Owns the [SessionMonitorService] and exposes its state to the UI.
///
/// Wire this provider into MultiProvider, then call [init] after ServerProvider
/// is ready so it can discover which servers to watch.
class SessionProvider extends ChangeNotifier {
  SessionMonitorService? _monitor;
  SessionMonitorService get monitor => _monitor!;

  StreamSubscription<SessionChange>? _changeSub;
  final List<SessionChange> _recentChanges = [];
  bool _initialized = false;

  List<SessionChange> get recentChanges => List.unmodifiable(_recentChanges);
  bool get isInitialized => _initialized;
  bool get isMonitoring => _monitor?.isRunning ?? false;

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
    _monitor?.dispose();
    super.dispose();
  }
}
