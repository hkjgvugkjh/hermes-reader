import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/reader_config.dart';

/// Resolves the app's user-visible `hermes-reader` folder on the device.
///
/// The folder intentionally lives OUTSIDE the app sandbox (on the phone's
/// primary shared storage) so the books and config it holds survive an app
/// uninstall — exactly what was asked for. The local library keeps its files
/// under `<hermes-reader>/library/`, downloaded books are cached under
/// `<hermes-reader>/books/`, and a portable `config.json` sits at the root.
class ExternalLibraryDir {
  ExternalLibraryDir._(this.root);

  /// The resolved `hermes-reader` directory.
  final Directory root;

  /// Where the local-library source files live.
  Future<Directory> get library async => _sub('library');

  /// Where downloaded / cached books live.
  Future<Directory> get books async => _sub('books');

  /// The portable config file at the root of the folder.
  File get configFile => File(p.join(root.path, 'config.json'));

  Future<Directory> _sub(String name) async {
    final dir = Directory(p.join(root.path, name));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Computes the `hermes-reader` path without touching permissions or the disk.
  ///
  /// On Android this is the primary external storage root, e.g.
  /// `/storage/emulated/0/hermes-reader` (outside `Android/data`, so it is not
  /// removed on uninstall). On iOS / desktop it falls back to the documents
  /// directory, where it cannot outlive an uninstall but is still user-visible.
  static Future<Directory> rootDirectory() async {
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      if (ext == null) {
        throw const FileSystemException('外部存储不可用，无法创建文库目录');
      }
      // ext.path -> /storage/emulated/0/Android/data/<pkg>/files
      // Walk up past .../Android/data/<pkg> to the shared storage root.
      final parts = ext.path.split('/');
      final androidIdx = parts.indexOf('Android');
      final base =
          androidIdx > 0 ? parts.sublist(0, androidIdx).join('/') : ext.path;
      return Directory('$base/hermes-reader');
    }
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'hermes-reader'));
  }

  /// Ensures the `hermes-reader` folder exists and we may write to it.
  static Future<ExternalLibraryDir> ensure() async {
    await ensurePermission();
    final root = await rootDirectory();
    await root.create(recursive: true);
    return ExternalLibraryDir._(root);
  }

  /// The downloaded-books folder, created if necessary.
  static Future<Directory> booksDirectory() async {
    final root = await rootDirectory();
    final dir = Directory(p.join(root.path, 'books'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Requests the storage permission required to write outside the app sandbox.
  ///
  /// On Android 11+ this is all-files access ([Permission.manageExternalStorage]);
  /// on older releases the legacy storage permission is used as a fallback.
  /// Returns false only when the user has permanently denied access (in which
  /// case they must enable it from system settings).
  static Future<bool> ensurePermission() async {
    if (!Platform.isAndroid) return true;

    var manage = await Permission.manageExternalStorage.status;
    if (!manage.isGranted) {
      manage = await Permission.manageExternalStorage.request();
    }
    if (manage.isGranted) return true;

    var storage = await Permission.storage.status;
    if (!storage.isGranted) {
      storage = await Permission.storage.request();
    }

    if (manage.isPermanentlyDenied || storage.isPermanentlyDenied) {
      await openAppSettings();
      return false;
    }
    return storage.isGranted;
  }
}

/// Reads and writes the portable `config.json` that lives at the root of the
/// `hermes-reader` folder, so reader settings travel with the books and survive
/// an uninstall.
class LocalLibraryConfig {
  LocalLibraryConfig(this.root);

  final Directory root;

  File get file => File(p.join(root.path, 'config.json'));

  Future<void> writeReaderConfig(ReaderConfig config) async {
    final data = {
      'version': 1,
      'updated': DateTime.now().toIso8601String(),
      'reader': config.toJson(),
    };
    await file.writeAsString(jsonEncode(data), flush: true);
  }

  Future<ReaderConfig?> readReaderConfig() async {
    if (!await file.exists()) return null;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map<String, dynamic> && raw['reader'] is Map) {
        return ReaderConfig.fromJson(raw['reader'] as Map<String, dynamic>);
      }
    } catch (_) {
      // Corrupt config — ignore and fall back to prefs / defaults.
    }
    return null;
  }
}
