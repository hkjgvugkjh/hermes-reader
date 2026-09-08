import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/global_config.dart';

/// Persistent storage for global configuration
class GlobalConfigStorage {
  static const String _keyGlobalConfig = 'hermes_hive_global_config';

  /// Load global config from storage
  static Future<GlobalConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_keyGlobalConfig);
    if (jsonStr == null || jsonStr.isEmpty) return GlobalConfig();

    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      return GlobalConfig.fromJson(data);
    } catch (e) {
      return GlobalConfig();
    }
  }

  /// Save global config to storage
  static Future<bool> save(GlobalConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(config.toJson());
    return prefs.setString(_keyGlobalConfig, jsonStr);
  }
}
