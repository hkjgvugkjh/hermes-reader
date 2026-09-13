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
  /// Backend JWTs returned by the proxy in the TypeDIConnectAck (0x31) frame,
  /// keyed by serverId. The proxy obtains these during mcu-login; the reader
  /// uses them to authenticate Socket.IO namespaces (e.g. /chat-run) instead
  /// of its own proxy auth token.
  final _backendJWTs = <String, String>{};
  final _sessionUpdateController = StreamController<Map<String, dynamic>>.broadcast();
  int _requestId = 0;
  StreamSubscription? _subscription;

  /// Active WS tunnels keyed by conn_id.
  final _tunnels = <String, ProxyTunnel>{};

  /// Serializes all outbound frame writes so concurrent encrypt()/send() calls
  /// cannot interleave and corrupt the single shared socket.
  Future<void>? _writeChain;

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
    await _sendFrame(0x32, '');

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

    await _sendFrame(0x34, jsonEncode({'server_id': serverId}));
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
  ///
  /// On success the proxy's ConnectAck also carries the backend JWT (obtained
  /// during mcu-login), which is cached and retrievable via [backendJWT].
  String? backendJWT(String serverId) => _backendJWTs[serverId];

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

    await _sendFrame(0x30, jsonEncode(payloadMap));
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

    // Encrypt payload and write the [type][4 length][encrypted] frame.
    await _sendFrame(0x10, jsonEncode(payload));

    return completer.future.timeout(const Duration(minutes: 5));
  }

  /// Open a WebSocket tunnel to [path] on [serverId] through the proxy.
  ///
  /// The proxy relays frames opaquely to the upstream server, so higher-level
  /// protocols (Socket.IO / Engine.IO) run unmodified inside the tunnel. The
  /// caller is responsible for authorizing the upstream (e.g. via [headers]).
  Future<ProxyTunnel> openTunnel({
    required String serverId,
    required String path,
    Map<String, String>? headers,
  }) async {
    if (!_connected || _channel == null) {
      throw StateError('Not connected to proxy');
    }
    final connId = 'ws_${_randomId()}';
    final tunnel = ProxyTunnel._(this, connId, serverId);
    _tunnels[connId] = tunnel;

    final payloadMap = <String, dynamic>{
      'conn_id': connId,
      'server_id': serverId,
      'path': path,
    };
    if (headers != null && headers.isNotEmpty) {
      payloadMap['headers'] = headers;
    }
    await _sendFrame(0x20, jsonEncode(payloadMap));

    try {
      await tunnel.opened.timeout(const Duration(seconds: 15));
    } catch (e) {
      _tunnels.remove(connId);
      rethrow;
    }
    return tunnel;
  }

  String _randomId() {
    final rnd = _requestId++;
    return '${rnd}_${DateTime.now().microsecondsSinceEpoch}';
  }

  Future<void> _sendTunnelData(String connId, String text) {
    return _sendFrame(0x22, jsonEncode({
      'conn_id': connId,
      'binary': false,
      'data': base64Encode(utf8.encode(text)),
    }));
  }

  Future<void> _closeTunnel(String connId) async {
    final tunnel = _tunnels.remove(connId);
    await _sendFrame(0x23, jsonEncode({'conn_id': connId, 'reason': 'client close'}));
    tunnel?._onClosed('client close');
  }

  /// Disconnect from the proxy.
  void disconnect() {
    _connected = false;
    _sharedKey = null;
    _recreateConnectedCompleter();
    for (final tunnel in _tunnels.values) {
      tunnel._onClosed('disconnected');
    }
    _tunnels.clear();
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
          final token = response['token'] as String?;
          if (serverId != null && token != null && token.isNotEmpty) {
            _backendJWTs[serverId] = token;
          }
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
        } else if (type == 0x21) {
          // TypeWSOpened - upstream WebSocket connected
          final connId = response['conn_id'] as String?;
          if (connId != null) _tunnels[connId]?._onOpened();
        } else if (type == 0x22) {
          // TypeWSData - frame payload relayed from upstream
          final connId = response['conn_id'] as String?;
          final data = response['data'];
          if (connId != null && data != null) {
            final tunnel = _tunnels[connId];
            if (tunnel != null) {
              try {
                final bytes = data is String ? base64Decode(data) : List<int>.from(data as List);
                tunnel._onData(utf8.decode(bytes));
              } catch (_) {
                // non-text (binary) frame; ignore for now
              }
            }
          }
        } else if (type == 0x23) {
          // TypeWSClose - upstream closed
          final connId = response['conn_id'] as String?;
          if (connId != null) {
            final tunnel = _tunnels.remove(connId);
            tunnel?._onClosed(response['reason'] as String?);
          }
        } else if (type == 0x24) {
          // TypeWSError - tunnel error
          final connId = response['conn_id'] as String?;
          if (connId != null) {
            final tunnel = _tunnels.remove(connId);
            tunnel?._onError(response['error'] as String? ?? 'ws error ${response['code']}');
          }
        }
      } catch (e) {
        // Decryption or parse failed
      }
    });
  }

  /// Serialize an outbound task behind any in-flight writes so concurrent
  /// [sendRequest]/tunnel frames can't interleave on the single socket.
  Future<void> _enqueueWrite(Future<void> Function() task) {
    final prev = _writeChain;
    final completer = Completer<void>();
    _writeChain = completer.future;
    (prev ?? Future<void>.value()).whenComplete(() {
      task().then((_) {
        if (!completer.isCompleted) completer.complete();
      }, onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      });
    });
    return completer.future;
  }

  /// Encrypt [payload] and write a single protocol frame of the form
  /// `[1 type][4 length big-endian][encrypted payload]`.
  Future<void> _sendFrame(int type, String payload) {
    return _enqueueWrite(() async {
      final encrypted = await _encrypt(payload);
      final frame = BytesBuilder();
      frame.addByte(type);
      final lengthBytes = Uint8List(4);
      final lengthData = ByteData.view(lengthBytes.buffer);
      lengthData.setUint32(0, encrypted.length, Endian.big);
      frame.add(lengthBytes);
      frame.add(encrypted);
      _channel!.sink.add(frame.toBytes());
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

/// A relayed upstream WebSocket tunnel over the proxy DI protocol.
///
/// [data] delivers decoded text frames from the upstream server; [send] writes
/// text frames upstream. Higher-level protocols (Socket.IO / Engine.IO) ride on
/// top transparently. Close it when done so the proxy tears down the upstream
/// connection.
class ProxyTunnel {
  final ProxyClient _client;
  final String connId;
  final String serverId;

  final _data = StreamController<String>.broadcast();
  final _opened = Completer<void>();
  final _done = Completer<void>();
  String? _closeReason;
  bool _finished = false;

  ProxyTunnel._(this._client, this.connId, this.serverId);

  /// Upstream text frames in the order they arrive.
  Stream<String> get data => _data.stream;

  /// Completes once the proxy reports the upstream socket is open.
  Future<void> get opened => _opened.future;

  /// Completes when the tunnel is fully closed (locally or by the proxy).
  Future<void> get done => _done.future;

  /// Reason reported by the proxy when the tunnel closed, if any.
  String? get closeReason => _closeReason;

  void _onOpened() {
    if (!_opened.isCompleted) _opened.complete();
  }

  void _onData(String text) {
    if (!_data.isClosed) _data.add(text);
  }

  void _onClosed(String? reason) {
    _closeReason = reason;
    _finish();
  }

  void _onError(String reason) {
    _closeReason = reason;
    if (!_opened.isCompleted) _opened.completeError(ProxyTunnelException(reason));
    _finish();
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    if (!_data.isClosed) _data.close();
    if (!_done.isCompleted) _done.complete();
  }

  /// Send a text frame upstream.
  Future<void> send(String text) => _client._sendTunnelData(connId, text);

  /// Close the tunnel (tears down the upstream connection).
  Future<void> close() => _client._closeTunnel(connId);
}

/// Exception thrown when a [ProxyTunnel] fails to open or errors mid-stream.
class ProxyTunnelException implements Exception {
  final String message;
  ProxyTunnelException(this.message);
  @override
  String toString() => 'ProxyTunnelException: $message';
}
