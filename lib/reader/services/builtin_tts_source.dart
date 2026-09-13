import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'tts_service.dart';
import 'builtin_tts_sherpa.dart' show SherpaOnnxImplFactory;

/// On-device neural TTS bundled with the app.
///
/// Uses the sherpa-onnx (Piper) Flutter plugin to run a small Chinese model
/// entirely on the device, so narration works with no network and no
/// system TTS engine. This is the offline fallback that keeps reading
/// possible on devices where flutter_tts has no engine (e.g. Linux boxes).
///
/// The model ships under `assets/tts/` and is unpacked to the app's private
/// directory on first use (see [_ensureModel]). When the plugin or model is
/// unavailable, [isAvailable] returns false and this source is skipped by
/// the fallback chain.
class BuiltinTtsSource implements SpeechSource {
  BuiltinTtsSource({
    this.modelDir = 'assets/tts',
    AudioPlayerPort? player,
    SherpaOnnxFactory? sherpaFactory,
  }) : _player = player ?? _JustAudioPort(),
       _sherpaFactory = sherpaFactory ?? const SherpaOnnxImplFactory();

  /// Asset path (or absolute dir) holding model.onnx + tokens.txt + config.
  final String modelDir;

  final AudioPlayerPort _player;
  final SherpaOnnxFactory _sherpaFactory;

  bool _initialized = false;
  bool _available = false;
  Object? _tts; // sherpa_onnx Tts instance, typed via factory to avoid hard dep.
  String? _modelPath;

  @override
  SpeechEngine get engine => SpeechEngine.builtin;

  @override
  Future<bool> isAvailable() async {
    if (_initialized) return _available;
    await _ensureInit();
    return _available;
  }

  @override
  Future<void> speak(String text) async {
    await _ensureInit();
    if (!_available || _tts == null) {
      throw Exception('builtin TTS model not available');
    }
    final audio = await _sherpaFactory.generate(_tts!, text);
    await _player.playBytes(audio, contentType: 'audio/wav');
  }

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> setRate(double rate) async {
    // sherpa-onnx Piper does not support live rate changes; speed is baked
    // into the model. No-op until we add a post-process resampler.
  }

  @override
  void setProgressHandler(NarrationProgressHandler? handler) {
    // sherpa-onnx returns the full clip at once; no word-level offset to
    // report. The default no-op stands, so offline narration still resumes
    // from the saved page offset (just not mid-sentence).
  }

  @override
  void setServerId(String? serverId) {
    // Builtin engine does not use the proxy; ignored.
  }

  @override
  Future<void> dispose() async {
    await _player.dispose();
    if (_tts != null) {
      await _sherpaFactory.dispose(_tts!);
      _tts = null;
    }
  }

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    try {
      _modelPath = await _ensureModel();
      _tts = await _sherpaFactory.create(_modelPath!);
      _available = _tts != null;
    } catch (e) {
      // Missing plugin/model on this platform: stay unavailable, never throw
      // during the availability probe so the chain can fall through.
      _available = false;
      debugPrint('builtin TTS unavailable: $e');
    }
  }

  /// Copies the bundled model out of assets into a writable directory.
  /// Returns the directory path containing model.onnx.
  Future<String> _ensureModel() async {
    final dir = await getApplicationSupportDirectory();
    final out = Directory('${dir.path}/tts_model');
    if (await out.exists()) {
      final marker = File('${out.path}/.unpacked');
      if (await marker.exists()) return out.path;
    }
    await out.create(recursive: true);
    for (final name in const [
      'model.onnx',
      'tokens.txt',
      'model.onnx.json',
      'README.md',
    ]) {
      try {
        final data = await rootBundle.load('$modelDir/$name');
        await File('${out.path}/$name')
            .writeAsBytes(data.buffer.asUint8List());
      } catch (_) {
        // Optional files (json/readme) may be absent; ignore.
      }
    }
    await File('${out.path}/.unpacked').writeAsString('1');
    return out.path;
  }
}

/// Plays audio bytes. Abstracted so tests can inject a fake.
abstract class AudioPlayerPort {
  Future<void> playBytes(Uint8List bytes, {String? contentType});
  Future<void> stop();
  Future<void> dispose();
}

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
  // ignore: prefer_initializing_formals
  _BytesAudioSource(this._bytes, {String? contentType})
      : _contentType = contentType;

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
      contentType: _contentType ?? 'audio/wav',
    );
  }
}

/// Factory isolating the sherpa_onnx dependency so the rest of the app does
/// not need to import it. The real implementation lives in
/// `builtin_tts_sherpa.dart` (imports `package:sherpa_onnx/sherpa_onnx.dart`).
abstract class SherpaOnnxFactory {
  Future<Object?> create(String modelDir);
  Future<Uint8List> generate(Object tts, String text);
  Future<void> dispose(Object tts);
}
