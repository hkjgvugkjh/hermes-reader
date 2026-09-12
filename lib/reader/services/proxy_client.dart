import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter/foundation.dart' show visibleForTesting;
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
  final _listResponseCompleter = Completer<List<Map<String, dynamic>>>();
  final _connectCompleters = <String, Completer<void>>{};
  final _sessionUpdateController = StreamController<Map<String, dynamic>>.broadcast();
  int _requestId = 0;
  StreamSubscription? _subscription;

  Stream<Map<String, dynamic>> get sessionUpdates => _sessionUpdateController.stream;

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

  /// Fetch server list via DI protocol (TypeDIList)
  Future<List<Map<String, dynamic>>> fetchServersDI() async {
    if (!_connected || _channel == null) {
      throw StateError('Not connected');
    }

    // Build DIList request (empty payload)
    final encrypted = await _encrypt('');
    final lengthBytes = Uint8List(4);
    final lengthData = ByteData.view(lengthBytes.buffer);
    lengthData.setUint32(0, encrypted.length, Endian.big);

    final encryptedFrame = BytesBuilder();
    encryptedFrame.addByte(0x32); // TypeDIList
    encryptedFrame.add(lengthBytes);
    encryptedFrame.add(encrypted);
    _channel!.sink.add(encryptedFrame.toBytes());

    try {
      final result = await _listResponseCompleter.future.timeout(const Duration(seconds: 10));
      return result;
    } catch (e) {
      return [];
    }
  }

  /// Connect to the proxy server and perform X25519 key exchange.
  ///
  /// Safe to call concurrently: callers that arrive while a handshake is in
  /// flight await that same handshake instead of starting a second one. Without
  /// this, two overlapping calls could each open a socket, and the loser would
  /// wait out its full timeout on a channel nothing feeds.
  Future<void> connect() {
    if (_connected) return Future<void>.value();

    // Join the in-flight handshake rather than starting another.
    final pending = _connecting;
    if (pending != null) return pending;

    // The handle is a plain completer future: everyone who joins — including
    // latecomers arriving after a failure — observes the same outcome, and the
    // single error handler below keeps a rejection from going unhandled.
    final completer = Completer<void>();
    final shared = completer.future;
    _connecting = shared;

    (handshakeOverride ?? _connectOnce)()
        .then((_) {
      if (!completer.isCompleted) completer.complete();
    }).catchError((Object e, StackTrace st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    }).whenComplete(() {
      // Cleared once settled so the next call starts a fresh attempt.
      if (identical(_connecting, shared)) _connecting = null;
    });

    return shared;
  }

  /// The handshake every concurrent [connect] caller is currently awaiting.
  Future<void>? _connecting;

  /// Builds the WebSocket URL for [proxyUrl].
  ///
  /// Three things the naive string concatenation got wrong:
  ///  * `Uri.hasPort` is true for schemes with a default port, and `uri.port`
  ///    then reports 0 — which produced `https://host:0/ws`, a URL that cannot
  ///    be dialled.
  ///  * a token already present in [proxyUrl] was appended to rather than
  ///    replaced, yielding `?token=a?token=b`.
  ///  * `http`/`https` are not WebSocket schemes.
  @visibleForTesting
  Uri buildUri() => _buildUri();

  Uri _buildUri() {
    final uri = Uri.parse(proxyUrl);

    // Normalise to a WebSocket scheme; honour ws/wss as given.
    final scheme = switch (uri.scheme) {
      'https' || 'wss' => 'wss',
      _ => 'ws',
    };

    // Only carry the port when the user named a non-default one.
    final defaultPort = scheme == 'wss' ? 443 : 80;
    final hasCustomPort = uri.hasPort && uri.port != 0 && uri.port != defaultPort;

    final query = <String, String>{...uri.queryParameters};
    if (authToken != null && authToken!.isNotEmpty) {
      query['token'] = authToken!;
    }

    return Uri(
      scheme: scheme,
      host: uri.host,
      port: hasCustomPort ? uri.port : null,
      path: uri.path.isEmpty ? wsPath : uri.path,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  /// Replaced by tests to drive the handshake without a real socket. The
  /// concurrency guard in [connect] is the part under test, not the socket.
  @visibleForTesting
  Future<void> Function()? handshakeOverride;

  /// Seam for tests: marks the client ready without a real socket.
  @visibleForTesting
  void markConnectedForTest() {
    _connected = true;
    if (!_connectedCompleter.isCompleted) _connectedCompleter.complete();
  }

  Future<void> _connectOnce() async {
    // Cancel any existing subscription to prevent "Stream already listened" error
    if (_subscription != null) {
      await _subscription!.cancel();
      _subscription = null;
    }

    // A fresh handshake invalidates previous state: the old channel is gone and
    // any *already completed* completer belongs to a dead connection. A pending
    // one is left alone — waiters on it are still waiting for this handshake.
    _connected = false;
    _sharedKey = null;
    if (_connectedCompleter.isCompleted) {
      _connectedCompleter = Completer<void>();
    }

    try {
      final parsedUri = _buildUri();
      _channel = WebSocketChannel.connect(parsedUri);

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

      // Single subscription for all messages (handshake + data)
      final handshakeCompleter = Completer<void>();
      
      _subscription = _channel!.stream.listen(
        (data) {
          // Handle handshake response first (before _connected is true)
          if (!_connected && data is String) {
            try {
              final serverHandshake = jsonDecode(data);
              final serverPublicKeyBytes = base64Decode(serverHandshake['public_key'] as String);
              
              // Compute shared secret using X25519 ECDH
              final serverPublicKey = cryptography.SimplePublicKey(
                serverPublicKeyBytes,
                type: cryptography.KeyPairType.x25519,
              );
              x25519.sharedSecretKey(
                keyPair: keyPair,
                remotePublicKey: serverPublicKey,
              ).then((sharedSecret) async {
                _sharedKey = await sharedSecret.extractBytes();
                // Derive key using SHA-256 (same as Go server)
                final keyHash = await cryptography.Sha256().hash(_sharedKey!);
                _sharedKey = keyHash.bytes;
                
                _clientId = 'hive-${base64Encode(publicKey.bytes).substring(0, 8)}';
                _connected = true;
                
                // Complete _connectedCompleter BEFORE handshakeCompleter
                // so that when connect() returns, the client is fully ready
                if (!_connectedCompleter.isCompleted) {
                  _connectedCompleter.complete();
                }
                
                if (!handshakeCompleter.isCompleted) {
                  handshakeCompleter.complete();
                }
              }).catchError((e) {
                if (!handshakeCompleter.isCompleted) {
                  handshakeCompleter.completeError(KeyExchangeException('Key exchange failed: $e'));
                }
              });
            } catch (e) {
              if (!handshakeCompleter.isCompleted) {
                handshakeCompleter.completeError(KeyExchangeException('Invalid handshake response: $e'));
              }
            }
          } else {
            // Already connected, process as normal message
            _onMessage(data);
          }
        },
        onError: (e) {
          _connected = false;
          _recreateConnectedCompleter();
          if (!handshakeCompleter.isCompleted) {
            handshakeCompleter.completeError(e);
          }
        },
        onDone: () {
          _connected = false;
          _recreateConnectedCompleter();
          if (!handshakeCompleter.isCompleted) {
            handshakeCompleter.completeError(ConnectionClosedException('Connection closed during handshake'));
          }
        },
      );

      // Wait for handshake to complete
      await handshakeCompleter.future.timeout(timeout);
    } catch (e) {
      _connected = false;
      _recreateConnectedCompleter();
      // Drop the dead channel so the next attempt starts clean.
      _channel = null;
      throw Exception('WebSocket connection failed: $e');
    }
  }

  Completer<void> _connectedCompleter = Completer<void>();

  /// A completer can only complete once, so a reconnect needs a fresh one —
  /// otherwise `await whenConnected` would resolve against a dead connection.
  void _recreateConnectedCompleter() {
    if (!_connectedCompleter.isCompleted) return;
    _connectedCompleter = Completer<void>();
  }

  Future<void> get whenConnected => _connectedCompleter.future;
  final _sessionUpdateCompleters = <String, Completer<Map<String, dynamic>>>{};

  /// Completer that fires when proxy client is set
  Completer<void>? _proxyClientSetCompleter;
  Future<void> pollSessions(String serverId) async {
    if (!_connected || _channel == null) {
      throw StateError('Not connected');
    }

    final payload = jsonEncode({'server_id': serverId});
    final encrypted = await _encrypt(payload);

    final frame = BytesBuilder();
    frame.addByte(0x34); // TypeDISessionPoll
    final lengthBytes = Uint8List(4);
    final lengthData = ByteData.view(lengthBytes.buffer);
    lengthData.setUint32(0, encrypted.length, Endian.big);
    frame.add(lengthBytes);
    frame.add(encrypted);
    _channel!.sink.add(frame.toBytes());
    print('[DI] Sent TypeDISessionPoll(0x34) server_id=$serverId');
  }

  /// Request sessions for a server and wait for the response.
  /// This attaches the listener BEFORE sending the poll to avoid race conditions.
  Future<Map<String, dynamic>> requestSessions(String serverId, {Duration timeout = const Duration(seconds: 15)}) async {
    if (!_connected || _channel == null) {
      throw StateError('Not connected');
    }

    // Create completer and register it BEFORE sending the poll
    final completer = Completer<Map<String, dynamic>>();
    _sessionUpdateCompleters[serverId] = completer;
    print('[DI] Registered completer for server_id=$serverId');

    // Now send the poll request
    try {
      await pollSessions(serverId);
      print('[DI] Sent poll for server_id=$serverId, waiting for response...');
    } catch (e) {
      _sessionUpdateCompleters.remove(serverId);
      rethrow;
    }

    // Wait for the response
    try {
      final result = await completer.future.timeout(timeout);
      print('[DI] Got response for server_id=$serverId, ${result['sessions']?.length ?? 0} sessions');
      return result;
    } catch (e) {
      print('[DI] Timeout/error for server_id=$serverId: $e');
      _sessionUpdateCompleters.remove(serverId);
      rethrow;
    }
  }

  /// Connect to a specific server via DI protocol (TypeDIConnect=0x30)
  ///
  /// Credentials are REQUIRED for a server the proxy has no stored creds for:
  /// without them the proxy's mcu-login fails and the client just waits for a
  /// ConnectAck that never comes, surfacing as an 8s timeout. Callers must pass
  /// [username]/[password] (and optionally [profile]) from their ServerConfig.
  Future<void> connectServer(
    String serverId, {
    String? username,
    String? password,
    String? profile,
    String? deviceCode,
    String? instanceId,
  }) async {
    if (!_connected || _channel == null) {
      throw StateError('Not connected');
    }

    final completer = Completer<void>();
    _connectCompleters[serverId] = completer;

    // Build a complete payload; omit empty fields so server-side defaults stay
    // in effect rather than being overwritten with "".
    final payloadMap = <String, dynamic>{'server_id': serverId};
    if (username != null && username.isNotEmpty) {
      payloadMap['username'] = username;
    }
    if (password != null && password.isNotEmpty) {
      payloadMap['password'] = password;
    }
    if (profile != null && profile.isNotEmpty) {
      payloadMap['profile'] = profile;
    }
    if (deviceCode != null && deviceCode.isNotEmpty) {
      payloadMap['device_code'] = deviceCode;
    }
    if (instanceId != null && instanceId.isNotEmpty) {
      payloadMap['instance_id'] = instanceId;
    }

    final payload = jsonEncode(payloadMap);
    final encrypted = await _encrypt(payload);

    final frame = BytesBuilder();
    frame.addByte(0x30); // TypeDIConnect
    final lengthBytes = Uint8List(4);
    final lengthData = ByteData.view(lengthBytes.buffer);
    lengthData.setUint32(0, encrypted.length, Endian.big);
    frame.add(lengthBytes);
    frame.add(encrypted);
    _channel!.sink.add(frame.toBytes());
    final sent = List<String>.of(payloadMap.keys)..remove('server_id');
    print('[DI] Sent TypeDIConnect(0x30) server_id=$serverId with=$sent');

    // Wait for TypeDIConnectAck
    await completer.future.timeout(timeout);
    print('[DI] Got TypeDIConnectAck server_id=$serverId');
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
    _sharedKey = null;
    _recreateConnectedCompleter();
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
        print('[DI] Received type=0x${type.toRadixString(16).padLeft(2, '0')} server=${response['server_id'] ?? '?'}');

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
        } else if (type == 0x33) {
          // TypeDIListResp
          final servers = response['servers'] as List? ?? [];
          final serverList = servers.map((s) => s as Map<String, dynamic>).toList();
          if (!_listResponseCompleter.isCompleted) {
            _listResponseCompleter.complete(serverList);
          }
        } else if (type == 0x31) {
          // TypeDIConnectAck - server accepted connection
          final serverId = response['server_id'] as String?;
          if (serverId != null && _connectCompleters.containsKey(serverId)) {
            _connectCompleters[serverId]!.complete();
            _connectCompleters.remove(serverId);
          }
        } else if (type == 0x35) {
          // TypeDISessionUpdate
          final serverId = response['server_id'] as String?;
          if (serverId != null && _sessionUpdateCompleters.containsKey(serverId)) {
            _sessionUpdateCompleters[serverId]!.complete(response);
            _sessionUpdateCompleters.remove(serverId);
          }
          if (!_sessionUpdateController.isClosed) {
            _sessionUpdateController.add(response);
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

/// Exception thrown when X25519 key exchange fails.
class KeyExchangeException implements Exception {
  final String message;
  KeyExchangeException(this.message);
  @override
  String toString() => 'KeyExchangeException: $message';
}

/// Exception thrown when connection closes unexpectedly.
class ConnectionClosedException implements Exception {
  final String message;
  ConnectionClosedException(this.message);
  @override
  String toString() => 'ConnectionClosedException: $message';
}
