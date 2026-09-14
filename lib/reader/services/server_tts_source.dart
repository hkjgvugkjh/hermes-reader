import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:hermes_shared/hermes_shared.dart'
    show HermesTtsClient, TtsSynthesizeRequest, TtsSynthesizeResponse;
import 'package:just_audio/just_audio.dart';

import 'proxy_client.dart' as reader_proxy;
import 'playback_wait.dart';
import 'tts_service.dart';

/// Server-side TTS via hermes-proxy (or, as a fallback, a direct HTTP call to
/// the backend). Audio comes from `/api/hermes/tts/synthesize` and is played
/// with just_audio.
///
/// When [proxyClient] is supplied the synthesis request is tunneled through the
/// proxy using [HermesTtsClient] (from hermes_shared), which handles backend
/// JWT auth and the `status_code` + base64 `body` response envelope. When only
/// [baseUrl] is given the request goes directly to the backend HTTP API.
class ServerTtsSource implements SpeechSource {
  ServerTtsSource({
    required this.baseUrl,
    reader_proxy.ProxyClient? proxyClient,
    String? serverId,
  })  : _proxyClient = proxyClient,
        _serverId = serverId {
    if (proxyClient != null) {
      _tts = HermesTtsClient.proxy(proxyClient, serverId: serverId);
    }
  }

  final String baseUrl;
  reader_proxy.ProxyClient? _proxyClient;
  String? _serverId;

  /// High-level TTS client used in proxy mode. Null when talking to the backend
  /// directly via HTTP.
  HermesTtsClient? _tts;

  final AudioPlayer _player = AudioPlayer();

  bool get _proxyMode => _proxyClient != null && _serverId != null && _serverId!.isNotEmpty;

  double _rate = 0.5;

  @override
  SpeechEngine get engine => SpeechEngine.server;

  @override
  Future<bool> isAvailable() async {
    if (_proxyMode) return true;
    return baseUrl.isNotEmpty;
  }

  @override
  void setServerId(String? serverId) {
    _serverId = serverId;
    _tts?.setServerId(serverId);
  }

  /// Update the proxy client used to tunnel synthesis requests, without
  /// recreating the source. Called by [TtsService] when the session's proxy
  /// client changes so that the engine stays alive across reconnects.
  @override
  void setProxyClient(reader_proxy.ProxyClient? client) {
    _proxyClient = client;
    _tts = client != null ? HermesTtsClient.proxy(client, serverId: _serverId) : null;
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate.clamp(0.0, 1.0);
  }

  @override
  void setProgressHandler(NarrationProgressHandler? handler) {
    // Server TTS does not expose word-level progress.
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) {
      return;
    }
    if (_proxyMode) {
      await _speakViaProxy(text);
    } else {
      await _speakDirect(text);
    }
  }

  Future<void> _speakViaProxy(String text) async {
    final resp = await _tts!.synthesize(
      TtsSynthesizeRequest(text: text, speed: _rate),
    );
    await _play(resp);
  }

  Future<void> _play(TtsSynthesizeResponse resp) async {
    final audio = resp.audio;
    if (audio.isEmpty) {
      throw Exception('TTS returned empty audio');
    }
    await _player.setAudioSource(
      AudioSource.uri(
        Uri.dataFromBytes(audio, mimeType: resp.contentType),
      ),
    );
    await _player.play();
    // Wait for the utterance to finish so narration is not cut off by the
    // next page. stop() unblocks this through the state stream.
    await waitForPlaybackEnd(_player);
  }

  Future<void> _speakDirect(String text) async {
    final uri = Uri.parse(baseUrl).replace(
      path: '/api/hermes/tts/synthesize',
    );
    final client = http.Client();
    try {
      final response = await client.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': text, 'speed': _rate}),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('TTS request failed (${response.statusCode})');
      }
      final bytes = response.bodyBytes;
      if (bytes.isEmpty) {
        throw Exception('TTS returned empty audio');
      }
      final mime = response.headers['content-type'] ?? 'audio/wav';
      await _player.setAudioSource(
        AudioSource.uri(Uri.dataFromBytes(bytes, mimeType: mime)),
      );
      await _player.play();
      await waitForPlaybackEnd(_player);
    } finally {
      client.close();
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    try {
      await _player.dispose();
    } catch (_) {}
  }
}
