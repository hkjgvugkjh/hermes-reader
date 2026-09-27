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
    this.username,
    this.password,
    this.profile = 'default',
    this.fallbackToken,
  });

  final ProxyClient proxyClient;

  /// Used as `Authorization: Bearer <token>` when the proxy has no backend JWT
  /// cached for this server (mirrors SessionProvider / SessionDetailDialog).
  final String? fallbackToken;

  /// The proxy's own id for the target server, e.g. 'local'.
  ///
  /// This is NOT the proxy URL: hermes-proxy resolves requests with
  /// `config.GetServer(id)` which matches on `ServerConfig.ID`. Passing
  /// anything else (the proxy URL, say) yields 404 "server not found".
  final String serverId;

  String? username;
  String? password;
  String profile;

  bool _attached = false;

  @override
  Future<TransportResponse> get(
    String path, {
    Map<String, String>? headers,
    int? expectedBytes,
  }) async {
    try {
      return await _get(path, headers, expectedBytes);
    } catch (e) {
      // A socket that died since the last request fails here rather than at
      // the caller. One reconnect keeps a dropped Wi-Fi handover from looking
      // like a broken shelf.
      if (!_looksLikeConnectionFailure(e)) rethrow;
      print('[TRANS] retrying after connection failure: $e');

      _attached = false;
      proxyClient.disconnect();
      await proxyClient.connect();
      return _get(path, headers, expectedBytes);
    }
  }

  /// The proxy serves byte ranges for studio file reads, so the library can
  /// stream a book in chunks and report progress.
  @override
  bool get supportsRange => true;

  /// Per-chunk timeout for a ranged read. A slice is at most 1 MiB, so even a
  /// slow link finishes well within this; a stall here is a real failure worth
  /// reporting rather than waiting out the (much longer) whole-file cap.
  static const Duration _chunkTimeout = Duration(seconds: 90);

  /// Fetches a byte range by adding `offset`/`limit` to the read path. The
  /// proxy reads the whole file once (buffering it), then serves each slice
  /// from memory with `X-Hermes-Total` telling us the full size.
  ///
  /// The first slice may take longer than the rest because the proxy has to
  /// fetch the whole file upstream to seed its buffer, so it gets a larger
  /// allowance than the follow-up slices.
  @override
  Future<TransportResponse> getRange(
    String path, {
    required int offset,
    required int length,
    Map<String, String>? headers,
    int? expectedBytes,
  }) async {
    final uri = Uri.parse(path);
    final query = Map<String, String>.from(uri.queryParameters)
      ..['offset'] = '$offset'
      ..['limit'] = '$length';
    final ranged = Uri(
      path: uri.path,
      queryParameters: query,
    ).toString();
    // First slice seeds the proxy buffer from upstream (whole file), so scale
    // its cap like a full download; later slices are cheap buffer reads.
    final timeout = offset == 0 ? _requestTimeout(expectedBytes) : _chunkTimeout;
    try {
      return await _get(ranged, headers, expectedBytes, timeout: timeout);
    } catch (e) {
      if (!_looksLikeConnectionFailure(e)) rethrow;
      _attached = false;
      proxyClient.disconnect();
      await proxyClient.connect();
      return _get(ranged, headers, expectedBytes, timeout: timeout);
    }
  }

  /// Adds `Authorization: Bearer <backend_jwt>` unless the caller already set
  /// one. The Studio file API rejects unauthenticated requests with 401; the
  /// proxy issues the backend JWT during connectServer (mcu-login).
  Map<String, String> _withAuth(Map<String, String>? headers) {
    final out = <String, String>{...?headers};
    if (out.keys.any((k) => k.toLowerCase() == 'authorization')) {
      return out;
    }
    final jwt = proxyClient.backendJWT(serverId);
    final token = (jwt != null && jwt.isNotEmpty) ? jwt : fallbackToken;
    if (token != null && token.isNotEmpty) {
      out['Authorization'] = 'Bearer $token';
    }
    return out;
  }

  bool _looksLikeConnectionFailure(Object error) {
    final text = error.toString();
    return text.contains('WebSocket connection failed') ||
        text.contains('TimeoutException') ||
        text.contains('Not connected') ||
        text.contains('Connection closed') ||
        text.contains('timed out');
  }

  /// Minimum throughput we assume a healthy download can sustain. As long as
  /// the real rate stays above this, the adaptive timeout below is never hit,
  /// so large books no longer trip the old fixed 30s cap.
  static const int _minThroughputBps = 10 * 1024; // 10 KB/s

  /// Adaptive request timeout.
  ///
  /// A large book downloading at >= 10 KB/s should never be reported as timed
  /// out. We therefore size the cap from the declared file size at that minimum
  /// rate: a 50 MB book gets ~5000s. Unknown sizes fall back to the underlying
  /// 5-minute transport timeout so we never kill a request we can't judge.
  Duration _requestTimeout(int? expectedBytes) {
    const floor = Duration(seconds: 30);
    if (expectedBytes == null || expectedBytes <= 0) {
      return const Duration(minutes: 5);
    }
    final byRate = Duration(
      seconds: (expectedBytes / _minThroughputBps).ceil(),
    );
    return byRate > floor ? byRate : floor;
  }

  Future<TransportResponse> _get(
    String path,
    Map<String, String>? headers,
    int? expectedBytes, {
    Duration? timeout,
  }) async {
    if (!proxyClient.isConnected) {
      await proxyClient.connect();
    }

    // Attach to server on first request (idempotent — safe to call repeatedly)
    if (!_attached) {
      await proxyClient.connectServer(
        serverId,
        username: username,
        password: password,
        profile: profile,
      );
      _attached = true;
    }

    final effectiveTimeout = timeout ?? _requestTimeout(expectedBytes);
    print('[TRANS] GET server=$serverId path=$path '
        'expectedBytes=$expectedBytes timeout=${effectiveTimeout.inSeconds}s');
    final result = await proxyClient.sendRequest(
      serverId: serverId,
      method: 'GET',
      path: path,
      headers: _withAuth(headers),
    ).timeout(effectiveTimeout, onTimeout: () {
      throw Exception(
          'proxy request timed out after ${effectiveTimeout.inSeconds}s '
          '(large download at low throughput?)');
    });
    print('[TRANS] resp status=${result['status_code']} bodyType=${result['body']?.runtimeType} bodyLen=${result['body'] is String ? (result['body'] as String).length : (result['body'] is List<int> ? (result['body'] as List<int>).length : 'null')}');
    if (result['body'] is String && (result['body'] as String).isNotEmpty) {
      final s = result['body'] as String;
      print('[TRANS] body preview: ${s.length > 200 ? s.substring(0, 200) : s}');
    }

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
    // The proxy always base64-encodes the response body when tunneling
    // HTTP-over-WebSocket, because JSON frames cannot carry raw bytes.
    // Always try base64 first; fall back to raw text on failure.
    try {
      return base64Decode(body);
    } catch (_) {
      // Not valid base64 — treat as raw text (e.g. plain JSON).
    }
    return Uint8List.fromList(utf8.encode(body));
  }
}
