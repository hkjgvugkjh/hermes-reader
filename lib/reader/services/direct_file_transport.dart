import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/hive_models.dart';
import 'library_service.dart';

/// Adapter that lets [LibraryService] talk to a server directly over HTTP,
/// used when hermes-hive is in standalone (non-proxy) mode.
class DirectFileTransport implements FileTransport {
  DirectFileTransport({
    required this.server,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final ServerConfig server;
  final http.Client _client;

  String? _token;

  void setToken(String? token) => _token = token;

  Future<bool> ensureLoggedIn() async {
    try {
      final uri = Uri.parse('${server.baseUrl}/api/auth/status');
      final resp = await _client.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return _token != null;
      final body = _decode(resp.body);
      final authEnabled = body['hasPasswordLogin'] == true || body['hasUsers'] == true;
      if (!authEnabled) return true;
      if (_token != null) {
        final me = await _client
            .get(Uri.parse('${server.baseUrl}/api/auth/me'),
                headers: {'Authorization': 'Bearer $_token'})
            .timeout(const Duration(seconds: 10));
        if (me.statusCode == 200) return true;
      }
      if (server.username == null || server.username!.isEmpty) return false;
      final login = await _client
          .post(Uri.parse('${server.baseUrl}/api/auth/login'),
              headers: {'Content-Type': 'application/json'},
              body: _encode({
                'username': server.username,
                'password': server.password ?? '',
              }))
          .timeout(const Duration(seconds: 15));
      if (login.statusCode != 200) return false;
      final data = _decode(login.body);
      _token = data['token'] as String?;
      return _token != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<TransportResponse> get(String path,
      {Map<String, String>? headers, int? expectedBytes}) async {
    final uri = Uri.parse('${server.baseUrl}$path');
    final merged = <String, String>{
      'X-Hermes-Profile': server.profile,
      if (_token != null) 'Authorization': 'Bearer $_token',
      ...?headers,
    };
    final resp = await _client.get(uri, headers: merged).timeout(const Duration(minutes: 2));
    return TransportResponse(
      statusCode: resp.statusCode,
      body: Uint8List.fromList(resp.bodyBytes),
      headers: resp.headers,
    );
  }

  /// The Studio API has no Range support, so ranges are emulated by fetching
  /// the file once and slicing it. Progress therefore still works (the UI sees
  /// per-chunk advances), but the whole body is transferred on the first call.
  @override
  bool get supportsRange => true;

  @override
  Future<TransportResponse> getRange(
    String path, {
    required int offset,
    required int length,
    Map<String, String>? headers,
    int? expectedBytes,
  }) async {
    final uri = Uri.parse(path);
    final basePath = Uri(
      path: uri.path,
      queryParameters: {'path': uri.queryParameters['path'] ?? ''},
    ).toString();
    final full = await get(basePath, headers: headers, expectedBytes: expectedBytes);
    final total = full.body.length;
    final start = offset.clamp(0, total);
    var end = start + length;
    if (end > total) end = total;
    return TransportResponse(
      statusCode: full.statusCode,
      body: Uint8List.sublistView(full.body, start, end),
      headers: {
        ...full.headers,
        'X-Hermes-Total': '$total',
        'X-Hermes-Offset': '$start',
      },
    );
  }

  void dispose() => _client.close();

  static Map<String, dynamic> _decode(String body) =>
      (jsonDecode(body) as Map?)?.cast<String, dynamic>() ?? {};
  static String _encode(Map<String, dynamic> v) => jsonEncode(v);
}
