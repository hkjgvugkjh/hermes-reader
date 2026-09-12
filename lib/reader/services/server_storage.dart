import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/hive_models.dart';
import 'app_config_service.dart';

/// Persistent storage for server configurations using JSON files.
/// All configs are stored in app documents directory as JSON files.
/// 
/// @deprecated Use [AppConfigService] instead. This class is kept for
/// backward compatibility and delegates to [AppConfigService].
class ServerStorage {
  static String? _cachePath;

  static Future<String> _dirPath() async {
    if (_cachePath != null) return _cachePath!;
    final dir = await getApplicationDocumentsDirectory();
    _cachePath = '${dir.path}/hermes_reader';
    return _cachePath!;
  }

  static Future<File> _serversFile() async {
    final dir = await _dirPath();
    return Directory(dir).create(recursive: true).then((_) => File('$dir/servers.json'));
  }

  /// Load all saved server configs.
  /// 
  /// Delegates to [AppConfigService] for unified config loading.
  static Future<List<ServerConfig>> loadServers() async {
    try {
      // Try unified config first
      final bundle = await AppConfigService.load();
      if (bundle.servers.isNotEmpty) {
        return bundle.servers;
      }
    } catch (_) {
      // Fall through to legacy file
    }
    
    // Legacy fallback
    try {
      final file = await _serversFile();
      if (!await file.exists()) return [];
      final jsonStr = await file.readAsString();
      if (jsonStr.isEmpty) return [];
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((s) => ServerConfig.fromJson(s as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// Save all server configs.
  /// 
  /// Delegates to [AppConfigService] for unified config saving.
  static Future<bool> saveServers(List<ServerConfig> servers) async {
    try {
      final bundle = await AppConfigService.load();
      bundle.servers = servers;
      return await AppConfigService.save(bundle);
    } catch (e) {
      return false;
    }
  }

  static Future<File> _activeServerFile() async {
    final dir = await _dirPath();
    return Directory(dir).create(recursive: true).then((_) => File('$dir/active_server.txt'));
  }

  /// Get active server ID.
  static Future<String?> getActiveServerId() async {
    try {
      final bundle = await AppConfigService.load();
      if (bundle.activeServerId != null) {
        return bundle.activeServerId;
      }
    } catch (_) {
      // Fall through
    }
    try {
      final file = await _activeServerFile();
      if (!await file.exists()) return null;
      final id = await file.readAsString();
      return id.isEmpty ? null : id;
    } catch (e) {
      return null;
    }
  }

  /// Set active server ID.
  static Future<bool> setActiveServerId(String? serverId) async {
    try {
      final bundle = await AppConfigService.load();
      bundle.activeServerId = serverId;
      return await AppConfigService.save(bundle);
    } catch (e) {
      return false;
    }
  }
}
