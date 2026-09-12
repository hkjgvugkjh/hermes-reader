import 'dart:convert';
import 'dart:typed_data';

import 'package:hermes_shared/hermes_shared.dart';

import 'library_service.dart';

/// A [FileTransport] that serves the proxy-hosted local library.
///
/// It reuses the existing [LibraryService] machinery (sandbox validation,
/// extraction, on-device caching) by translating the studio file API paths the
/// service emits (`/api/studio/files/*`) into the local library paths
/// (`/api/library/*`). Requests go through [LocalLibraryClient], which addresses
/// the proxy with the reserved [kLocalLibraryServerID] server id so the proxy
/// serves them from its own file store instead of forwarding.
class LocalLibraryFileTransport implements FileTransport {
  LocalLibraryFileTransport({required this.client});

  final LocalLibraryClient client;

  @override
  Future<TransportResponse> get(String path, {Map<String, String>? headers}) async {
    final translated = _translate(path);
    final res = await client.raw('GET', translated);
    final status = _code(res);
    final body = _decodeBytes(res['body']);
    return TransportResponse(statusCode: status, body: body);
  }

  static String _translate(String path) {
    if (path.contains('/api/studio/files/list')) {
      final q = Uri.parse(path).queryParameters;
      return LocalLibraryClient.listPath(q['path'] ?? '');
    }
    if (path.contains('/api/studio/files/read')) {
      final q = Uri.parse(path).queryParameters;
      return LocalLibraryClient.readPath(
        q['path'] ?? '',
        encoding: q['encoding'] ?? 'base64',
      );
    }
    return path;
  }

  static int _code(Map<String, dynamic> res) =>
      (res['statusCode'] ?? res['status_code']) as int? ?? 200;

  static Uint8List _decodeBytes(dynamic body) {
    if (body is Uint8List) return body;
    if (body is List<int>) return Uint8List.fromList(body);
    if (body is String) {
      try {
        return base64Decode(body);
      } catch (_) {
        return Uint8List.fromList(utf8.encode(body));
      }
    }
    return Uint8List(0);
  }
}
