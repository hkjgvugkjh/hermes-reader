import 'package:flutter/foundation.dart';
import '../models/hive_models.dart';
import '../services/hermes_api_client.dart';
import '../services/proxy_client.dart';
import '../services/server_storage.dart';
import 'global_config_provider.dart';
import 'debug_logger.dart';

/// Main state provider for the application
class ServerProvider extends ChangeNotifier {
  final GlobalConfigProvider? _globalConfigProvider;
  List<ServerConfig> _servers = [];
  ServerConfig? _activeServer;
  bool _isLoading = false;
  String? _error;
  final Map<String, HermesApiClient> _clients = {};
  final Map<String, ProxyClient> _proxyClients = {};

  ServerProvider([this._globalConfigProvider]);

  List<ServerConfig> get servers => _servers;
  ServerConfig? get activeServer => _activeServer;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Load servers from storage
  Future<void> load() async {
    _isLoading = true;
    notifyListeners();

    _servers = await ServerStorage.loadServers();
    final activeId = await ServerStorage.getActiveServerId();
    if (activeId != null) {
      _activeServer = _servers.where((s) => s.id == activeId).firstOrNull;
    }
    // If no active server but we have servers, pick the first
    if (_activeServer == null && _servers.isNotEmpty) {
      _activeServer = _servers.first;
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Set servers from proxy API response
  void setServers(List<dynamic> servers) {
    _servers = servers.map((s) {
      final map = s as Map<String, dynamic>;
      return ServerConfig(
        id: map['id']?.toString() ?? '',
        name: map['name']?.toString() ?? '',
        url: map['url']?.toString() ?? '',
        username: map['username']?.toString(),
        password: map['password']?.toString(),
        profile: map['profile']?.toString() ?? 'default',
      );
    }).toList();
    
    if (_servers.isNotEmpty && _activeServer == null) {
      _activeServer = _servers.first;
    }
    notifyListeners();
  }

  /// Clear all servers
  void clearServers() {
    _servers.clear();
    _activeServer = null;
    notifyListeners();
  }

  /// Add a new server
  Future<void> addServer(ServerConfig server) async {
    _servers.add(server);
    await ServerStorage.saveServers(_servers);
    if (_activeServer == null) {
      _activeServer = server;
      await ServerStorage.setActiveServerId(server.id);
    }
    notifyListeners();
  }

  /// Update an existing server
  Future<void> updateServer(ServerConfig server) async {
    final index = _servers.indexWhere((s) => s.id == server.id);
    if (index >= 0) {
      _servers[index] = server;
      if (_activeServer?.id == server.id) {
        _activeServer = server;
      }
      await ServerStorage.saveServers(_servers);
      // Remove cached clients so they get recreated with new config
      _clients.remove(server.id);
      _proxyClients.remove(server.id)?.disconnect();
      notifyListeners();
    }
  }

  /// Remove a server
  Future<void> removeServer(String id) async {
    _servers.removeWhere((s) => s.id == id);
    _clients.remove(id);
    _proxyClients.remove(id)?.disconnect();
    if (_activeServer?.id == id) {
      _activeServer = _servers.isNotEmpty ? _servers.first : null;
      await ServerStorage.setActiveServerId(_activeServer?.id);
    }
    await ServerStorage.saveServers(_servers);
    notifyListeners();
  }

  /// Set the active server
  Future<void> setActiveServer(ServerConfig server) async {
    DebugLogger.instance.info('setActiveServer', 'name=${server.name} id=${server.id}');
    _activeServer = server;
    await ServerStorage.setActiveServerId(server.id);
    notifyListeners();
  }

  /// Get online servers
  List<ServerConfig> get onlineServers =>
      _servers.where((s) => s.isOnline).toList();

  /// Get online servers
  HermesApiClient getClient(ServerConfig server) {
    return _clients.putIfAbsent(server.id, () => HermesApiClient(server));
  }

  /// Get or create proxy client for a server (via hermes-proxy)
  ProxyClient? getProxyClient(ServerConfig server) {
    if (_globalConfigProvider == null) return null;
    if (!_globalConfigProvider.isProxyMode) return null;
    return _proxyClients.putIfAbsent(
      server.id,
      () => ProxyClient(
        proxyUrl: _globalConfigProvider.config.proxyWsUrl,
        authToken: _globalConfigProvider.config.proxyAuthToken,
      ),
    );
  }

  /// Check health of all servers
  Future<void> checkAllServers() async {
    for (final server in _servers) {
      try {
        HealthStatus health;
        if (_globalConfigProvider?.isProxyMode == true) {
          final proxyClient = getProxyClient(server);
          if (proxyClient != null) {
            await proxyClient.connect();
            final result = await proxyClient.sendRequest(
              serverId: _globalConfigProvider!.config.proxyUrl,
              method: 'GET',
              path: '/health',
            );
            health = HealthStatus(
              healthy: result['status_code'] == 200,
              details: result,
            );
          } else {
            health = HealthStatus(healthy: false);
          }
        } else {
          final client = getClient(server);
          health = await client.checkHealth();
        }
        final index = _servers.indexWhere((s) => s.id == server.id);
        if (index >= 0) {
          _servers[index] = server.copyWith(
            isOnline: health.healthy,
            lastConnected: health.healthy ? DateTime.now() : server.lastConnected,
          );
        }
      } catch (e) {
        final index = _servers.indexWhere((s) => s.id == server.id);
        if (index >= 0) {
          _servers[index] = server.copyWith(isOnline: false);
        }
      }
    }
    // Update active server reference
    if (_activeServer != null) {
      _activeServer = _servers.where((s) => s.id == _activeServer!.id).firstOrNull;
    }
    await ServerStorage.saveServers(_servers);
    notifyListeners();
  }

  /// Check health of a single server
  Future<HealthStatus> checkServerHealth(ServerConfig server) async {
    if (_globalConfigProvider?.isProxyMode == true) {
      final proxyClient = getProxyClient(server);
      if (proxyClient != null) {
        await proxyClient.connect();
        final result = await proxyClient.sendRequest(
          serverId: _globalConfigProvider!.config.proxyUrl,
          method: 'GET',
          path: '/health',
        );
        return HealthStatus(
          healthy: result['status_code'] == 200,
          details: result,
        );
      }
      return HealthStatus(healthy: false);
    }
    final client = getClient(server);
    return client.checkHealth();
  }

  /// Login to a server
  Future<bool> loginServer(ServerConfig server) async {
    if (_globalConfigProvider?.isProxyMode == true) {
      final proxyClient = getProxyClient(server);
      if (proxyClient != null) {
        try {
          await proxyClient.connect();
          return true;
        } catch (e) {
          return false;
        }
      }
      return false;
    }
    final client = getClient(server);
    _setError(null);
    final result = await client.ensureLoggedIn();
    if (!result) {
      _setError('Login failed for ${server.name}');
    }
    return result;
  }

  void _setError(String? err) {
    _error = err;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    // Disconnect all proxy clients
    for (final client in _proxyClients.values) {
      client.disconnect();
    }
    super.dispose();
  }
}

/// Extension for firstOrNull on Iterable
extension IterableExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
