import 'package:flutter/foundation.dart';
import '../models/global_config.dart';
import '../services/global_config_storage.dart';
import '../services/proxy_client.dart';

/// Global configuration state provider
class GlobalConfigProvider extends ChangeNotifier {
  GlobalConfig _config = GlobalConfig();
  bool _isLoading = false;
  String? _error;
  List<Map<String, dynamic>> _proxyServers = [];
  bool _isFetchingServers = false;

  GlobalConfig get config => _config;
  bool get isLoading => _isLoading;
  String? get error => _error;
  List<Map<String, dynamic>> get proxyServers => _proxyServers;
  bool get isFetchingServers => _isFetchingServers;

  bool get isProxyMode => _config.mode == ConnectionMode.hermesProxy;
  bool get isStandaloneMode => _config.mode == ConnectionMode.standalone;

  /// Load global config from storage
  Future<void> load() async {
    _isLoading = true;
    notifyListeners();

    _config = await GlobalConfigStorage.load();

    _isLoading = false;
    notifyListeners();
  }

  /// Update and save global config
  Future<void> updateConfig(GlobalConfig newConfig) async {
    _config = newConfig;
    await GlobalConfigStorage.save(_config);
    // Clear cached server list when config changes
    _proxyServers = [];
    notifyListeners();
  }

  /// Set connection mode
  Future<void> setMode(ConnectionMode mode) async {
    _config = _config.copyWith(mode: mode);
    await GlobalConfigStorage.save(_config);
    _proxyServers = [];
    notifyListeners();
  }

  /// Set proxy URL
  Future<void> setProxyUrl(String url) async {
    _config = _config.copyWith(proxyUrl: url);
    await GlobalConfigStorage.save(_config);
    notifyListeners();
  }

  /// Set proxy auth token
  Future<void> setProxyAuthToken(String token) async {
    _config = _config.copyWith(proxyAuthToken: token);
    await GlobalConfigStorage.save(_config);
    notifyListeners();
  }

  /// Fetch server list from hermes-proxy admin API
  Future<List<Map<String, dynamic>>> fetchServersFromProxy() async {
    if (!isProxyMode || _config.proxyUrl.isEmpty) return [];

    _isFetchingServers = true;
    _error = null;
    notifyListeners();

    try {
      final client = ProxyClient(
        proxyUrl: _config.proxyWsUrl,
        authToken: _config.proxyAuthToken,
      );

      final servers = await client.fetchServers();
      _proxyServers = servers;
      _isFetchingServers = false;
      notifyListeners();
      return servers;
    } catch (e) {
      _error = 'Failed to fetch servers: $e';
      _isFetchingServers = false;
      notifyListeners();
      return [];
    }
  }

  /// Test proxy connection
  Future<bool> testProxyConnection() async {
    if (!isProxyMode || _config.proxyUrl.isEmpty) return false;

    _error = null;
    notifyListeners();

    try {
      final client = ProxyClient(
        proxyUrl: _config.proxyWsUrl,
        authToken: _config.proxyAuthToken,
      );

      await client.fetchServers();
      return true;
    } catch (e) {
      _error = 'Proxy connection failed: $e';
      notifyListeners();
      return false;
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void clearProxyServers() {
    _proxyServers = [];
    notifyListeners();
  }
}
