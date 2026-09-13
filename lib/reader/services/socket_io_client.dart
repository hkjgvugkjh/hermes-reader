import 'dart:async';
import 'dart:convert';

/// A minimal Socket.IO (Engine.IO) client that rides over an arbitrary String
/// duplex — for example a [ProxyTunnel] that relays raw frames to a Studio
/// server's `/socket.io` endpoint.
///
/// Only what the Hermes `/chat-run` namespace needs is implemented:
///  * Engine.IO handshake (`0{...}` open packet) and `2`/`3` ping-pong.
///  * Socket.IO namespace CONNECT (`40<ns>,{auth}`) and event emit/receive.
///
/// It deliberately does not implement ack IDs, binary attachments, or
/// multiplexing — the chat-run flow is a plain request/response stream.
class SocketIoClient {
  final Stream<String> _input;
  final void Function(String) _send;
  final String namespace;
  final Duration pingTimeout;

  final StreamController<SocketIoEvent> _events =
      StreamController<SocketIoEvent>.broadcast();
  final _opened = Completer<Map<String, dynamic>>();
  bool _connected = false;

  SocketIoClient({
    required Stream<String> input,
    required void Function(String) send,
    this.namespace = '/chat-run',
    this.pingTimeout = const Duration(seconds: 45),
  })  : _input = input,
        _send = send {
    _input.listen(
      _onFrame,
      onDone: _onDone,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  /// Engine.IO open packet data (sid, pingInterval, pingTimeout, ...).
  Future<Map<String, dynamic>> get opened => _opened.future;

  bool get connected => _connected;

  /// Stream of decoded Socket.IO events (`["name", data]`).
  Stream<SocketIoEvent> get events => _events.stream;

  void _onFrame(String frame) {
    // Engine.IO frames over a relayed WS are one-per-message, but be defensive
    // against concatenation: split on complete Engine.IO frames.
    for (final f in _splitFrames(frame)) {
      _handleEngineFrame(f);
    }
  }

  Iterable<String> _splitFrames(String frame) sync* {
    // A frame is self-delimited here (the proxy delivers one upstream message
    // per tunnel frame). If the upstream ever concatenates, Engine.IO text
    // frames are still parseable individually, so just yield the whole thing.
    yield frame;
  }

  void _handleEngineFrame(String f) {
    if (f.isEmpty) return;
    final type = f[0];
    switch (type) {
      case '0': // open
        final json = f.substring(1);
        final open = jsonDecode(json) as Map<String, dynamic>;
        if (!_opened.isCompleted) _opened.complete(open);
        break;
      case '2': // ping
        _send('3'); // pong
        break;
      case '3': // pong
        break;
      case '4': // message -> Socket.IO packet
        _handleSocketFrame(f.substring(1));
        break;
      case '1': // close
      case '5': // upgrade
      case '6': // noop
      default:
        break;
    }
  }

  void _handleSocketFrame(String s) {
    if (s.isEmpty) return;
    final type = s[0];
    if (type == '0') {
      // namespace CONNECT ack
      _connected = true;
      return;
    }
    if (type == '2') {
      // event: <ns>[,<json array>]
      var rest = s.substring(1);
      if (rest.startsWith('/')) {
        final idx = rest.indexOf(',');
        if (idx < 0) return; // no payload
        rest = rest.substring(idx + 1);
      }
      if (rest.isEmpty) return;
      try {
        final arr = jsonDecode(rest) as List<dynamic>;
        final name = arr[0] as String;
        final data = arr.length > 1 ? arr[1] : null;
        _events.add(SocketIoEvent(name: name, data: data));
      } catch (_) {
        // ignore malformed events
      }
    }
  }

  /// Connect to the namespace, supplying [auth] (e.g. `{'token': ...}`).
  void connectNamespace(Map<String, dynamic> auth) {
    _send('40$namespace,${jsonEncode(auth)}');
  }

  /// Emit a Socket.IO event [event] with a single [data] argument.
  void emit(String event, Map<String, dynamic> data) {
    _send('42$namespace,${jsonEncode([event, data])}');
  }

  void _onDone() {
    if (!_opened.isCompleted) _opened.completeError('socket closed');
  }
}

/// A decoded Socket.IO event.
class SocketIoEvent {
  final String name;
  final dynamic data;
  const SocketIoEvent({required this.name, this.data});
}
