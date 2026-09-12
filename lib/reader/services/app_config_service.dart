import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/global_config.dart';
import '../models/hive_models.dart';
import '../models/reader_config.dart';

/// Unified application configuration service.
/// 
/// All configuration is stored in the `hermes_reader/` subdirectory of the
/// app documents directory as a single JSON file (`config.json`), with
/// automatic migration from the legacy split-file layout.
class AppConfigService {
  static String? _cachePath;
  static const String _configFileName = 'config.json';

  /// Get the unified storage directory (documents/hermes_reader/).
  static Future<String> _dirPath() async {
    if (_cachePath != null) return _cachePath!;
    final dir = await getApplicationDocumentsDirectory();
    _cachePath = '${dir.path}/hermes_reader';
    return _cachePath!;
  }

  /// Get the full path to the unified config file (hermes_reader/config.json).
  static Future<String> _configFilePath() async {
    final dir = await _dirPath();
    return '$dir/$_configFileName';
  }

  /// Debug: get the config file path.
  static Future<String> debugPath() => _configFilePath();

  /// Load all configuration from the unified store.
  /// 
  /// Automatically migrates from legacy layout if the unified file does
  /// not yet exist.
  static Future<AppConfigBundle> load() async {
    final filePath = await _configFilePath();
    final file = File(filePath);

    // If unified config exists, load it directly.
    if (await file.exists()) {
      try {
        final jsonStr = await file.readAsString();
        if (jsonStr.isEmpty) return AppConfigBundle();
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        return AppConfigBundle.fromJson(data);
      } catch (e) {
        // Corrupted file — start fresh but keep backup.
        await _backupCorrupted(filePath);
        return AppConfigBundle();
      }
    }

    // No unified config yet — try legacy migration.
    final bundle = await _migrateFromLegacy();
    if (bundle != null) {
      // Save migrated bundle to unified file.
      await _saveBundle(bundle);
      return bundle;
    }

    // Fresh start.
    return AppConfigBundle();
  }

  /// Save all configuration to the unified store.
  static Future<bool> save(AppConfigBundle bundle) async {
    try {
      final filePath = await _configFilePath();
      final dir = await _dirPath();
      await Directory(dir).create(recursive: true);
      final file = File(filePath);
      final jsonStr = jsonEncode(bundle.toJson());
      await file.writeAsString(jsonStr);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Migrate from the legacy split-file layout to the unified store.
  /// 
  /// Legacy layout:
  /// - `<documents>/hermes_reader_config.json` (GlobalConfig)
  /// - `<documents>/hermes_reader/servers.json` (ServerConfig[])
  /// - `<documents>/hermes_reader/active_server.txt` (String)
  static Future<AppConfigBundle?> _migrateFromLegacy() async {
    try {
      final dir = await _dirPath();
      final docsDir = await getApplicationDocumentsDirectory();

      GlobalConfig? globalConfig;
      List<ServerConfig>? servers;
      String? activeServerId;

      // 1. Load GlobalConfig from legacy location.
      final legacyGlobalFile = File('${docsDir.path}/hermes_reader_config.json');
      if (await legacyGlobalFile.exists()) {
        try {
          final jsonStr = await legacyGlobalFile.readAsString();
          if (jsonStr.isNotEmpty) {
            final data = jsonDecode(jsonStr) as Map<String, dynamic>;
            globalConfig = GlobalConfig.fromJson(data);
          }
        } catch (_) {
          // ignore parse errors — will use defaults
        }
      }

      // 2. Load ServerConfig[] from legacy location.
      final legacyServersFile = File('$dir/servers.json');
      if (await legacyServersFile.exists()) {
        try {
          final jsonStr = await legacyServersFile.readAsString();
          if (jsonStr.isNotEmpty) {
            final list = jsonDecode(jsonStr) as List;
            servers = list
                .map((s) => ServerConfig.fromJson(s as Map<String, dynamic>))
                .toList();
          }
        } catch (_) {
          // ignore parse errors — will use defaults
        }
      }

      // 3. Load active server ID from legacy location.
      final legacyActiveFile = File('$dir/active_server.txt');
      if (await legacyActiveFile.exists()) {
        try {
          final id = await legacyActiveFile.readAsString();
          if (id.isNotEmpty) activeServerId = id;
        } catch (_) {
          // ignore
        }
      }

      // Only return a bundle if we found at least one legacy file.
      if (globalConfig != null || servers != null || activeServerId != null) {
        return AppConfigBundle(
          globalConfig: globalConfig ?? GlobalConfig(),
          servers: servers ?? [],
          activeServerId: activeServerId,
          readerConfig: const ReaderConfig(),
          configVersion: 1,
        );
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// Internal save helper used during migration.
  static Future<bool> _saveBundle(AppConfigBundle bundle) async {
    try {
      final filePath = await _configFilePath();
      final dir = await _dirPath();
      await Directory(dir).create(recursive: true);
      final file = File(filePath);
      final jsonStr = jsonEncode(bundle.toJson());
      await file.writeAsString(jsonStr);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Back up a corrupted config file so the user can inspect it.
  static Future<void> _backupCorrupted(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        final backupPath = '$filePath.bak.${DateTime.now().millisecondsSinceEpoch}';
        await file.copy(backupPath);
      }
    } catch (_) {
      // best-effort
    }
  }

  /// Clean up legacy files after successful migration.
  /// Call this after `load()` if you want to remove the old files.
  static Future<void> cleanupLegacyFiles() async {
    try {
      final dir = await _dirPath();
      final docsDir = await getApplicationDocumentsDirectory();

      final legacyGlobalFile = File('${docsDir.path}/hermes_reader_config.json');
      if (await legacyGlobalFile.exists()) {
        await legacyGlobalFile.delete();
      }

      final legacyServersFile = File('$dir/servers.json');
      if (await legacyServersFile.exists()) {
        await legacyServersFile.delete();
      }

      final legacyActiveFile = File('$dir/active_server.txt');
      if (await legacyActiveFile.exists()) {
        await legacyActiveFile.delete();
      }
    } catch (_) {
      // best-effort cleanup
    }
  }
}

/// Bundle containing all application configuration.
/// 
/// This is the single object that gets serialized to the unified config file.
class AppConfigBundle {
  GlobalConfig globalConfig;
  List<ServerConfig> servers;
  String? activeServerId;
  ReaderConfig readerConfig;
  int configVersion;

  AppConfigBundle({
    GlobalConfig? globalConfig,
    List<ServerConfig>? servers,
    this.activeServerId,
    ReaderConfig? readerConfig,
    this.configVersion = 1,
  })  : globalConfig = globalConfig ?? GlobalConfig(),
        servers = servers ?? const [],
        readerConfig = readerConfig ?? const ReaderConfig();

  /// Convenience accessor: connection mode from global config.
  ConnectionMode get connectionMode => globalConfig.mode;

  /// Convenience accessor: proxy URL from global config.
  String get proxyUrl => globalConfig.proxyUrl;

  /// Convenience accessor: proxy auth token from global config.
  String get proxyAuthToken => globalConfig.proxyAuthToken;

  /// Get the active server, or null if none is set.
  ServerConfig? get activeServer {
    if (activeServerId == null) return null;
    try {
      return servers.firstWhere((s) => s.id == activeServerId);
    } catch (_) {
      return servers.isNotEmpty ? servers.first : null;
    }
  }

  /// Get a specific server by ID.
  ServerConfig? getServer(String id) {
    try {
      return servers.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Add a new server. Returns the added server.
  ServerConfig addServer(ServerConfig server) {
    servers = [...servers, server];
    if (activeServer == null) {
      activeServerId = server.id;
    }
    return server;
  }

  /// Update an existing server. Returns true if found and updated.
  bool updateServer(ServerConfig server) {
    final index = servers.indexWhere((s) => s.id == server.id);
    if (index < 0) return false;
    servers = List<ServerConfig>.from(servers);
    servers[index] = server;
    return true;
  }

  /// Remove a server by ID. Returns true if found and removed.
  bool removeServer(String id) {
    final exists = servers.any((s) => s.id == id);
    if (!exists) return false;
    servers = servers.where((s) => s.id != id).toList();
    if (activeServerId == id) {
      activeServerId = servers.isNotEmpty ? servers.first.id : null;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
        'configVersion': configVersion,
        'globalConfig': globalConfig.toJson(),
        'servers': servers.map((s) => s.toJson()).toList(),
        'activeServerId': activeServerId,
        'readerConfig': readerConfig.toJson(),
      };

  factory AppConfigBundle.fromJson(Map<String, dynamic> json) {
    final version = json['configVersion'] as int? ?? 1;

    GlobalConfig gc;
    try {
      final gcJson = json['globalConfig'] as Map<String, dynamic>?;
      gc = gcJson != null ? GlobalConfig.fromJson(gcJson) : GlobalConfig();
    } catch (_) {
      gc = GlobalConfig();
    }

    List<ServerConfig> srvs;
    try {
      final srvsJson = json['servers'] as List?;
      srvs = (srvsJson ?? [])
          .map((s) => ServerConfig.fromJson(s as Map<String, dynamic>))
          .toList();
    } catch (_) {
      srvs = [];
    }

    ReaderConfig rc;
    try {
      final rcJson = json['readerConfig'] as Map<String, dynamic>?;
      rc = rcJson != null ? ReaderConfig.fromJson(rcJson) : const ReaderConfig();
    } catch (_) {
      rc = const ReaderConfig();
    }

    return AppConfigBundle(
      globalConfig: gc,
      servers: srvs,
      activeServerId: json['activeServerId'] as String?,
      readerConfig: rc,
      configVersion: version,
    );
  }

  AppConfigBundle copyWith({
    GlobalConfig? globalConfig,
    List<ServerConfig>? servers,
    String? activeServerId,
    ReaderConfig? readerConfig,
    int? configVersion,
  }) {
    return AppConfigBundle(
      globalConfig: globalConfig ?? this.globalConfig,
      servers: servers ?? this.servers,
      activeServerId: activeServerId ?? this.activeServerId,
      readerConfig: readerConfig ?? this.readerConfig,
      configVersion: configVersion ?? this.configVersion,
    );
  }
}
