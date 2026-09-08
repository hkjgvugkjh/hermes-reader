import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Client for connecting to hermes-proxy via WebSocket with X25519 key exchange
/// and ChaCha20-Poly1305 encryption.
class ProxyClient {
  final String proxyUrl;
  final String? authToken;
  final String? wsPath;
  final Duration timeout;

  WebSocketChannel? _channel;
  List<int>? _sharedKey;
  bool _connected = false;
  String? _clientId;

  final _responseCallbacks = <String, Completer<Map<String, dynamic>>>{};
  int _requestId = 0;
  StreamSubscription? _subscription;

  bool get isConnected => _connected;
  String? get clientId => _clientId;

  ProxyClient({
    required this.proxyUrl,
    this.authToken,
    this.wsPath = '/ws',
    this.timeout = const Duration(seconds: 30),
  });

  /// Get the admin URL from proxy URL
  String get adminUrl {
    final uri = Uri.parse(proxyUrl);
    return '${uri.scheme == 'wss' ? 'https' : 'http'}://${uri.host}:${uri.port}';
  }

  /// Fetch server list from proxy admin API
  Future<List<Map<String, dynamic>>> fetchServers() async {
    try {
      final response = await http.get(
        Uri.parse('$adminUrl/api/config'),
        headers: authToken != null ? {'Authorization': 'Bearer $authToken'} : {},
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final servers = (data['servers'] as List? ?? [])
            .map((s) => s as Map<String, dynamic>)
            .toList();
        return servers;
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Connect to the proxy server and perform X25519 key exchange.
  Future<void> connect() async {
    if (_connected) return;

    try {
      final uri = Uri.parse(proxyUrl);
      _channel = WebSocketChannel.connect(uri);

      // Generate X25519 key pair
      final x25519 = cryptography.X25519();
      final keyPair = await x25519.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();

      // Send handshake with auth token
      final handshake = {
        'public_key': base64Encode(publicKey.bytes),
        'token': authToken ?? '',
      };
      _channel!.sink.add(jsonEncode(handshake));

      // Wait for server handshake response
      final response = await _channel!.stream.first.timeout(timeout);
      final serverHandshake = jsonDecode(response as String);
      final serverPublicKeyBytes = base64Decode(serverHandshake['public_key'] as String);

      // Compute shared secret using X25519 ECDH
      final serverPublicKey = cryptography.SimplePublicKey(
        serverPublicKeyBytes,
        type: cryptography.KeyPairType.x25519,
      );
      final sharedSecret = await x25519.sharedSecretKey(
        keyPair: keyPair,
        remotePublicKey: serverPublicKey,
      );
      _sharedKey = await sharedSecret.extractBytes();

      _clientId = 'hive-${base64Encode(publicKey.bytes).substring(0, 8)}';
      _connected = true;

      // Listen for incoming messages
      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: (e) {
          _connected = false;
        },
        onDone: () {
          _connected = false;
        },
      );
    } catch (e) {
      _connected = false;
      throw Exception('WebSocket connection failed: $e');
    }
  }

  /// Send an HTTP request through the proxy.
  Future<Map<String, dynamic>> sendRequest({
    required String serverId,
    required String method,
    required String path,
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    if (!_connected || _channel == null) {
      throw StateError('Not connected to proxy');
    }

    final requestId = 'req_${_requestId++}';
    final completer = Completer<Map<String, dynamic>>();
    _responseCallbacks[requestId] = completer;

    // Build request payload
    final payload = {
      'request_id': requestId,
      'server_id': serverId,
      'method': method,
      'path': path,
      'headers': headers ?? {},
      'body': body != null ? base64Encode(body) : null,
    };

    // Encrypt payload
    final encrypted = await _encrypt(jsonEncode(payload));

    // Build frame: [1 type][4 length][payload]
    final frame = BytesBuilder();
    frame.addByte(0x10); // TypeHTTPRequest
    final lengthBytes = Uint8List(4);
    final lengthData = ByteData.view(lengthBytes.buffer);
    lengthData.setUint32(0, encrypted.length, Endian.big);
    frame.add(lengthBytes);
    frame.add(encrypted);

    _channel!.sink.add(frame.toBytes());

    return completer.future.timeout(const Duration(minutes: 5));
  }

  /// Disconnect from the proxy.
  void disconnect() {
    _connected = false;
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
  }

  void _onMessage(dynamic data) {
    if (data is! List<int>) return;

    final bytes = data;
    if (bytes.length < 5) return;

    final type = bytes[0];
    final lengthData = ByteData.view(Uint8List.fromList(bytes.sublist(1, 5)).buffer);
    final length = lengthData.getUint32(0, Endian.big);

    if (bytes.length < 5 + length) return;

    final encrypted = bytes.sublist(5, 5 + length);

    _decrypt(encrypted).then((decrypted) {
      try {
        final response = jsonDecode(decrypted);

        if (type == 0x11) {
          // HTTP Response
          final requestId = response['request_id'] as String?;
          if (requestId != null && _responseCallbacks.containsKey(requestId)) {
            _responseCallbacks[requestId]!.complete(response);
            _responseCallbacks.remove(requestId);
          }
        } else if (type == 0xFF) {
          // Error
          final requestId = response['request_id'] as String?;
          if (requestId != null && _responseCallbacks.containsKey(requestId)) {
            _responseCallbacks[requestId]!.completeError(
              Exception(response['message'] ?? 'Unknown error'),
            );
            _responseCallbacks.remove(requestId);
          }
        }
      } catch (e) {
        // Decryption or parse failed
      }
    });
  }

  Future<List<int>> _encrypt(String plaintext) async {
    if (_sharedKey == null) throw StateError('No shared key');

    final algorithm = cryptography.Chacha20.poly1305Aead();
    final secretKey = cryptography.SecretKey(_sharedKey!);
    final nonce = algorithm.newNonce();

    final secretBox = await algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
    );

    return [
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ];
  }

  Future<String> _decrypt(List<int> ciphertext) async {
    if (_sharedKey == null) throw StateError('No shared key');

    final algorithm = cryptography.Chacha20.poly1305Aead();
    final secretKey = cryptography.SecretKey(_sharedKey!);

    // ChaCha20-Poly1305: nonce=12 bytes, mac=16 bytes
    final nonce = ciphertext.sublist(0, 12);
    final macBytes = ciphertext.sublist(ciphertext.length - 16);
    final cipherText = ciphertext.sublist(12, ciphertext.length - 16);

    final secretBox = cryptography.SecretBox(
      cipherText,
      nonce: nonce,
      mac: cryptography.Mac(macBytes),
    );

    final decrypted = await algorithm.decrypt(
      secretBox,
      secretKey: secretKey,
    );

    return utf8.decode(decrypted);
  }
}
