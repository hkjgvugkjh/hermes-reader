import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/global_config.dart';
import 'app_config_service.dart';

/// Persistent storage for global configuration using a JSON file.
/// Stores in app documents directory so it survives when the app is backgrounded.
/// 
/// @deprecated Use [AppConfigService] instead. This class is kept for
/// backward compatibility and delegates to [AppConfigService].
class GlobalConfigStorage {
  static String? _cachePath;

  static Future<String> _filePath() async {
    if (_cachePath != null) return _cachePath!;
    // Use the same directory as ServerStorage for consistency
    final dir = await getApplicationDocumentsDirectory();
    _cachePath = '${dir.path}/hermes_reader_config.json';
    return _cachePath!;
  }

  /// Load global config from file.
  /// 
  /// Delegates to [AppConfigService] for unified config loading.
  static Future<GlobalConfig> load() async {
    try {
      // Try unified config first
      final bundle = await AppConfigService.load();
      return bundle.globalConfig;
    } catch (_) {
      // Fall through to legacy
    }
    
    // Legacy fallback
    try {
      final path = await _filePath();
      final file = File(path);
      if (!await file.exists()) return GlobalConfig();
      final jsonStr = await file.readAsString();
      if (jsonStr.isEmpty) return GlobalConfig();
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      return GlobalConfig.fromJson(data);
    } catch (e) {
      return GlobalConfig();
    }
  }

  /// Save global config to file.
  /// 
  /// Delegates to [AppConfigService] for unified config saving.
  static Future<bool> save(GlobalConfig config) async {
    try {
      final bundle = await AppConfigService.load();
      bundle.globalConfig = config;
      return await AppConfigService.save(bundle);
    } catch (e) {
      return false;
    }
  }

  /// Debug: get the config file path
  static Future<String> debugPath() => AppConfigService.debugPath();
}
