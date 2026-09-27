import 'dart:convert';
import 'dart:io';

import 'external_library_dir.dart';

/// A small JSON side-car that records per-download metadata for books in the
/// `books/` cache.
///
/// Two problems it solves:
///   * The on-disk cache name is flattened by [LibrarySandbox.localFileName]
///     and strips every non-ASCII character, so a remote book named
///     `天龙八部.txt` is stored as `serverId___.txt` and would otherwise show
///     up under a sanitised, unreadable name. We keep the *real* server file
///     name and relative path here so the local library can display it exactly
///     as the remote shelf does.
///   * When automatic charset detection fails, the user can pick an encoding
///     (e.g. GBK) to fix mojibake. We persist that choice so it survives app
///     restarts and is not re-guessed (and re-broken) on every open.
///
/// All I/O is best-effort: a missing or unreadable index never breaks reading
/// a book.
class LibraryCacheIndex {
  const LibraryCacheIndex();

  static const String _fileName = '.hermes-index.json';

  Future<File> _file() async {
    final dir = await ExternalLibraryDir.booksDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<Map<String, dynamic>> _readAll() async {
    try {
      final file = await _file();
      if (!await file.exists()) return <String, dynamic>{};
      final text = await file.readAsString();
      if (text.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeAll(Map<String, dynamic> all) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(all), flush: true);
    } catch (_) {
      // Best effort — a missing index never breaks reading a book.
    }
  }

  Map<String, dynamic> _entriesOf(Map<String, dynamic> all) {
    final e = all['entries'];
    return e is Map<String, dynamic> ? e : <String, dynamic>{};
  }

  /// The full record for a cache file name, or null when the index has none.
  Future<Map<String, dynamic>?> entry(String cacheFileName) async {
    final all = await _readAll();
    final e = _entriesOf(all)[cacheFileName];
    return e is Map<String, dynamic> ? e : null;
  }

  /// The original server-side title, or null when the index has no record.
  Future<String?> titleOf(String cacheFileName) async {
    final e = await entry(cacheFileName);
    final t = e?['title'];
    return t is String ? t : null;
  }

  /// The original server-side relative path, or null when unknown.
  Future<String?> relativePathOf(String cacheFileName) async {
    final e = await entry(cacheFileName);
    final r = e?['relativePath'];
    return r is String ? r : null;
  }

  /// The user-chosen encoding, defaulting to `'auto'`.
  Future<String> encodingOf(String cacheFileName) async {
    final e = await entry(cacheFileName);
    final enc = e?['encoding'];
    return enc is String && enc.isNotEmpty ? enc : 'auto';
  }

  /// Records (or refreshes) metadata for a freshly downloaded book.
  Future<void> recordDownload({
    required String cacheFileName,
    required String serverId,
    required String relativePath,
    required String title,
    required int sizeBytes,
  }) async {
    final all = await _readAll();
    final entries = _entriesOf(all);
    final previous = entries[cacheFileName];
    entries[cacheFileName] = <String, dynamic>{
      'serverId': serverId,
      'relativePath': relativePath,
      'title': title,
      'size': sizeBytes,
      // Keep a previously chosen encoding so a re-download does not reset it.
      'encoding': previous is Map && previous['encoding'] is String
          ? previous['encoding']
          : 'auto',
      'cachedAt': DateTime.now().toIso8601String(),
    };
    all['entries'] = entries;
    await _writeAll(all);
  }

  /// Persists the encoding a user picked to fix mojibake.
  Future<void> setEncoding(String cacheFileName, String encoding) async {
    final all = await _readAll();
    final entries = _entriesOf(all);
    final previous = entries[cacheFileName];
    final record = previous is Map<String, dynamic>
        ? Map<String, dynamic>.from(previous)
        : <String, dynamic>{};
    record['encoding'] = encoding;
    entries[cacheFileName] = record;
    all['entries'] = entries;
    await _writeAll(all);
  }
}
