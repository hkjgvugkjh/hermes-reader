import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/global_config.dart';
import 'server_storage.dart';

/// Persistent storage for global configuration using a JSON file.
/// Stores in app documents directory so it survives when the app is backgrounded.
class GlobalConfigStorage {
  static String? _cachePath;

  static Future<String> _filePath() async {
    if (_cachePath != null) return _cachePath!;
    // Use the same directory as ServerStorage for consistency
    final dir = await getApplicationDocumentsDirectory();
    _cachePath = '${dir.path}/hermes_reader_config.json';
    return _cachePath!;
  }

  /// Load global config from file
  static Future<GlobalConfig> load() async {
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

  /// Save global config to file
  static Future<bool> save(GlobalConfig config) async {
    try {
      final path = await _filePath();
      final file = File(path);
      final jsonStr = jsonEncode(config.toJson());
      await file.writeAsString(jsonStr);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Debug: get the config file path
  static Future<String> debugPath() => _filePath();
}
