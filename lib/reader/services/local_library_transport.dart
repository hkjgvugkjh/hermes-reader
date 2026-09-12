import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'library_service.dart';

/// A [FileTransport] that serves the local library straight from the device
/// filesystem — no proxy, no network.
///
/// It reuses the existing [LibraryService] machinery (sandbox validation,
/// extraction, on-device caching) by answering the studio file API paths the
/// service emits (`/api/studio/files/*`). The files live under [rootDir] (the
/// app-private `library` folder); the request `path` parameter is normalised
/// through [_localRel] so the `list` convention (`library`) and the `read`
/// convention (`library/<file>`) both resolve inside that folder.
class LocalFileSystemTransport implements FileTransport {
  LocalFileSystemTransport(this.rootDir);

  final Directory rootDir;

  @override
  Future<TransportResponse> get(String path,
      {Map<String, String>? headers}) async {
    final uri = Uri.parse(path);
    if (uri.path.contains('/api/studio/files/list')) {
      return _list(uri.queryParameters['path'] ?? '');
    }
    if (uri.path.contains('/api/studio/files/read')) {
      return _read(uri.queryParameters['path'] ?? '');
    }
    return TransportResponse(statusCode: 404, body: Uint8List(0));
  }

  Future<TransportResponse> _list(String subdir) async {
    final dir = Directory(_join(rootDir.path, _localRel(subdir)));
    if (!await dir.exists()) await dir.create(recursive: true);
    final entries = <Map<String, dynamic>>[];
    await for (final entity in dir.list()) {
      final stat = await entity.stat();
      final isDir = entity is Directory;
      entries.add({
        'name': _basename(entity.path),
        'is_dir': isDir,
        'size': stat.size,
        'modified': stat.modified.toUtc().toIso8601String(),
      });
    }
    entries.sort((a, b) {
      if (a['is_dir'] != b['is_dir']) {
        return (a['is_dir'] ? 1 : 0) - (b['is_dir'] ? 1 : 0);
      }
      return (a['name'] as String).compareTo(b['name'] as String);
    });
    return TransportResponse(
      statusCode: 200,
      body: utf8.encode(jsonEncode({'entries': entries})),
    );
  }

  Future<TransportResponse> _read(String relPath) async {
    final file = File(_join(rootDir.path, _localRel(relPath)));
    if (!await file.exists()) {
      return TransportResponse(statusCode: 404, body: Uint8List(0));
    }
    return TransportResponse(statusCode: 200, body: await file.readAsBytes());
  }

  /// Strips the sandbox `library/` prefix so both the `list` request (`library`)
  /// and the `read` request (`library/<file>`) resolve under [rootDir].
  static String _localRel(String p) {
    if (p.isEmpty || p == 'library' || p == '/') return '';
    if (p.startsWith('library/')) return p.substring(8);
    return p;
  }

  static String _join(String base, String rel) => rel.isEmpty ? base : '$base/$rel';

  static String _basename(String p) {
    final clean = p.endsWith('/') ? p.substring(0, p.length - 1) : p;
    final i = clean.lastIndexOf('/');
    return i < 0 ? clean : clean.substring(i + 1);
  }
}
