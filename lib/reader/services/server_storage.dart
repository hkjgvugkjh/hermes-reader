import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/hive_models.dart';

/// Persistent storage for server configurations
class ServerStorage {
  static const String _keyServers = 'hermes_hive_servers';
  static const String _keyActiveServer = 'hermes_hive_active_server';

  /// Load all saved server configs
  static Future<List<ServerConfig>> loadServers() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_keyServers);
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((s) => ServerConfig.fromJson(s as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// Save all server configs
  static Future<bool> saveServers(List<ServerConfig> servers) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(servers.map((s) => s.toJson()).toList());
    return prefs.setString(_keyServers, jsonStr);
  }

  /// Get active server ID
  static Future<String?> getActiveServerId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyActiveServer);
  }

  /// Set active server ID
  static Future<bool> setActiveServerId(String? serverId) async {
    final prefs = await SharedPreferences.getInstance();
    if (serverId == null) {
      return prefs.remove(_keyActiveServer);
    }
    return prefs.setString(_keyActiveServer, serverId);
  }
}
