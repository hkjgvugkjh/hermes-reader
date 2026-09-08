import 'dart:convert';
import 'dart:typed_data';

import 'proxy_client.dart';
import 'library_service.dart';

/// Adapter that lets [LibraryService] reach a server through hermes-proxy.
///
/// The proxy forwards HTTP inside the encrypted X25519/ChaCha20 session, so
/// this looks like any other transport to the caller.
class ProxyFileTransport implements FileTransport {
  ProxyFileTransport({
    required this.proxyClient,
    required this.serverId,
  });

  final ProxyClient proxyClient;

  /// The proxy's own id for the target server, e.g. 'local'.
  ///
  /// This is NOT the proxy URL: hermes-proxy resolves requests with
  /// `config.GetServer(id)` which matches on `ServerConfig.ID`. Passing
  /// anything else (the proxy URL, say) yields 404 "server not found".
  final String serverId;

  @override
  Future<TransportResponse> get(
    String path, {
    Map<String, String>? headers,
  }) async {
    if (!proxyClient.isConnected) {
      await proxyClient.connect();
    }

    final result = await proxyClient.sendRequest(
      serverId: serverId,
      method: 'GET',
      path: path,
      headers: headers,
    );

    final status = result['status_code'] as int? ?? 0;

    // The proxy hands back the body already decoded when it is JSON, and
    // base64 when it is binary. Normalise both to raw bytes.
    final body = result['body'];
    Uint8List bytes;
    if (body is Uint8List) {
      bytes = body;
    } else if (body is List<int>) {
      bytes = Uint8List.fromList(body);
    } else if (body is String) {
      bytes = _decodeBody(body, result);
    } else if (body is Map) {
      bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    } else {
      bytes = Uint8List(0);
    }

    final rawHeaders = result['headers'];
    return TransportResponse(
      statusCode: status,
      body: bytes,
      headers: rawHeaders is Map
          ? rawHeaders.map((k, v) => MapEntry(k.toString(), v.toString()))
          : const {},
    );
  }

  Uint8List _decodeBody(String body, Map<String, dynamic> result) {
    // Binary payloads arrive base64-encoded; JSON arrives as-is.
    final isBase64 = result['body_encoding'] == 'base64' ||
        result['encoding'] == 'base64';
    if (isBase64) {
      try {
        return base64Decode(body);
      } catch (_) {
        // Fall through and treat it as text.
      }
    }
    return Uint8List.fromList(utf8.encode(body));
  }
}
