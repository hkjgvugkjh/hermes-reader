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

  /// Supplies the JWT obtained during login, if the server required one.
  void setToken(String? token) => _token = token;

  /// Refreshes the token using the same flow as HermesApiClient.
  Future<bool> ensureLoggedIn() async {
    final statusUri = Uri.parse('${server.baseUrl}/api/auth/status');
    try {
      final statusResp =
          await _client.get(statusUri).timeout(const Duration(seconds: 10));
      if (statusResp.statusCode != 200) return _token != null;

      final status = _decode(statusResp.body);
      final authEnabled = (status['hasPasswordLogin'] == true) ||
          (status['hasUsers'] == true);
      if (!authEnabled) return true;

      if (_token != null) {
        final meResp = await _client
            .get(
              Uri.parse('${server.baseUrl}/api/auth/me'),
              headers: {'Authorization': 'Bearer $_token'},
            )
            .timeout(const Duration(seconds: 10));
        if (meResp.statusCode == 200) return true;
      }

      if (server.username == null || server.username!.isEmpty) return false;

      final loginResp = await _client
          .post(
            Uri.parse('${server.baseUrl}/api/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: _encode({
              'username': server.username,
              'password': server.password ?? '',
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (loginResp.statusCode != 200) return false;
      final data = _decode(loginResp.body);
      _token = data['token'] as String?;
      return _token != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<TransportResponse> get(
    String path, {
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse('${server.baseUrl}$path');
    final merged = <String, String>{
      'X-Hermes-Profile': server.profile,
      if (_token != null) 'Authorization': 'Bearer $_token',
      ...?headers,
    };

    final response =
        await _client.get(uri, headers: merged).timeout(const Duration(minutes: 2));

    return TransportResponse(
      statusCode: response.statusCode,
      body: Uint8List.fromList(response.bodyBytes),
      headers: response.headers,
    );
  }

  void dispose() => _client.close();

  static Map<String, dynamic> _decode(String body) {
    // ignore: avoid_dynamic_calls
    return (jsonDecode(body) as Map?)?.cast<String, dynamic>() ?? {};
  }

  static String _encode(Map<String, dynamic> value) => jsonEncode(value);
}
