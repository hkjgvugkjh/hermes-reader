import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

import 'tts_service.dart';
import '../services/proxy_client.dart' as reader_proxy;

/// Plays audio bytes. Abstracted so tests can inject a fake.
abstract class AudioPlayerPort {
  Future<void> playBytes(Uint8List bytes, {String? contentType});
  Future<void> stop();
  Future<void> dispose();
}

/// Production implementation backed by just_audio.
class _JustAudioPort implements AudioPlayerPort {
  final _player = AudioPlayer();

  @override
  Future<void> playBytes(Uint8List bytes, {String? contentType}) async {
    await _player.setAudioSource(_BytesAudioSource(bytes, contentType: contentType));
    await _player.play();
  }

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}

class _BytesAudioSource extends StreamAudioSource {
  final Uint8List _bytes;
  final String? _contentType;
  _BytesAudioSource(this._bytes, {String? contentType}) : _contentType = contentType;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final total = _bytes.length;
    final s = start ?? 0;
    final e = end ?? total;
    return StreamAudioResponse(
      sourceLength: total,
      contentLength: e - s,
      offset: s,
      stream: Stream.value(_bytes.sublist(s, e)),
      contentType: _contentType ?? 'audio/mpeg',
    );
  }
}

/// Produces audio from the Hermes server's /api/hermes/tts/synthesize endpoint.
///
/// Two transport modes:
///  * **Direct** (`baseUrl` set): hits the backend over plain HTTP. Used when the
///    reader can reach the backend directly (e.g. local library mode).
///  * **Via proxy** (`proxyClient` set): the request is tunneled through
///    hermes-proxy using [reader_proxy.ProxyClient.sendRequest], authenticated
///    with the backend JWT the proxy obtained during mcu-login. This is the
///    "all traffic goes through the proxy" path and needs no direct reachability.
///
/// [serverId] selects which backend the proxy forwards to; set it before each
/// [speak] via [setServerId] (the reader screen knows the book's serverId).
class ServerTtsSource implements SpeechSource {
  ServerTtsSource({
    this.baseUrl = '',
    this.authToken,
    this.provider,
    this.profile = 'default',
    this.proxyClient,
    this.serverId,
    http.Client? client,
    AudioPlayerPort? player,
  })  : _client = client ?? http.Client(),
        _player = player ?? _JustAudioPort();

  final String baseUrl;
  final String? authToken;
  final String? provider;
  final String profile;
  final reader_proxy.ProxyClient? proxyClient;
  String? serverId;
  final http.Client _client;
  final AudioPlayerPort _player;

  /// True when tunneling through the proxy is possible.
  bool get _proxyMode =>
      proxyClient != null && (serverId ?? '').isNotEmpty;

  /// When true the server engine is skipped entirely by the fallback chain.
  bool get configured => baseUrl.trim().isNotEmpty || _proxyMode;

  @override
  SpeechEngine get engine => SpeechEngine.server;

  /// Selects the backend server for the next [speak] (proxy mode).
  void setServerId(String? id) => serverId = id;

  @override
  Future<bool> isAvailable() async {
    if (baseUrl.trim().isNotEmpty) return true;
    return _proxyMode;
  }

  /// Probe the server to confirm a TTS provider is configured.
  static Future<bool> probe(String baseUrl, String? token, {http.Client? client}) async {
    try {
      final headers = <String, String>{'Accept': 'application/json'};
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
      final c = client ?? http.Client();
      final resp = await c
          .get(Uri.parse('$baseUrl/api/hermes/tts/settings'), headers: headers)
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return false;
      final body = jsonDecode(resp.body);
      final providers = body is List ? body : (body['providers'] as List? ?? []);
      return providers.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> speak(String text) async {
    if (_proxyMode) {
      await _speakViaProxy(text);
      return;
    }
    await _speakDirect(text);
  }

  Future<void> _speakDirect(String text) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'audio/mpeg, audio/wav, audio/*, */*',
    };
    if (authToken != null && authToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }
    headers['X-Hermes-Profile'] = profile;

    final body = <String, dynamic>{'text': text};
    if (provider != null) body['provider'] = provider;

    final resp = await _client
        .post(Uri.parse('$baseUrl/api/hermes/tts/synthesize'),
            headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw Exception('authorization required');
    }
    if (resp.statusCode != 200) {
      throw Exception('server TTS returned ${resp.statusCode}');
    }

    final contentType = resp.headers['content-type'] ?? '';
    _play(resp.bodyBytes, contentType);
  }

  Future<void> _speakViaProxy(String text) async {
    final id = serverId!;
    final token = proxyClient!.backendJWT(id);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'audio/mpeg, audio/wav, audio/*, */*',
      'X-Hermes-Profile': profile,
    };
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    final body = <String, dynamic>{'text': text};
    if (provider != null) body['provider'] = provider;

    final resp = await proxyClient!.sendRequest(
      serverId: id,
      method: 'POST',
      path: '/api/hermes/tts/synthesize',
      headers: headers,
      body: utf8.encode(jsonEncode(body)),
    );

    final status = resp['status'] as int? ?? 0;
    if (status == 401 || status == 403) {
      throw Exception('authorization required');
    }
    if (status != 200) {
      throw Exception('server TTS returned $status');
    }

    // The proxy returns the upstream body as base64 in `body`.
    final raw = resp['body'] as String?;
    if (raw == null || raw.isEmpty) {
      throw Exception('server TTS returned empty body');
    }
    final audioBytes = base64Decode(raw);
    final respHeaders = resp['headers'] as Map?;
    final contentType = (respHeaders?['content-type'] as String?) ?? '';
    _play(audioBytes, contentType);
  }

  void _play(Uint8List audioBytes, String contentType) {
    if (contentType.contains('pcm') || contentType.contains('x-pcm')) {
      final wavBytes = _wrapPcmAsWav(audioBytes);
      _player.playBytes(wavBytes, contentType: 'audio/wav');
    } else {
      _player.playBytes(audioBytes, contentType: contentType);
    }
  }

  Uint8List _wrapPcmAsWav(Uint8List pcm) {
    const sampleRate = 24000;
    const channels = 1;
    const bitsPerSample = 16;
    final dataSize = pcm.length;
    final fileSize = 36 + dataSize;
    final header = BytesBuilder()
      ..add('RIFF'.codeUnits)
      ..add(_u32(fileSize))
      ..add('WAVE'.codeUnits)
      ..add('fmt '.codeUnits)
      ..add(_u32(16))
      ..add(_u16(1))
      ..add(_u16(channels))
      ..add(_u32(sampleRate))
      ..add(_u32(sampleRate * channels * bitsPerSample ~/ 8))
      ..add(_u16(channels * bitsPerSample ~/ 8))
      ..add(_u16(bitsPerSample))
      ..add('data'.codeUnits)
      ..add(_u32(dataSize))
      ..add(pcm);
    return header.toBytes();
  }

  Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
  Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> setRate(double rate) async {
    // just_audio does not expose rate per source; no-op for now.
  }

  @override
  void setProgressHandler(NarrationProgressHandler? handler) {
    // The server returns one audio blob per request, so there is no
    // word-level position to report; the default no-op stands.
  }

  @override
  Future<void> dispose() async {
    await _player.dispose();
    _client.close();
  }
}
