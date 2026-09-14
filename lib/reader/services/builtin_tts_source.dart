import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'tts_service.dart';
import 'builtin_tts_sherpa.dart' show SherpaOnnxImplFactory;
import 'playback_wait.dart';
import 'proxy_client.dart';

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
  /// Set by [stop] to abort the per-chunk synthesis loop inside [speak].
  bool _stopRequested = false;

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
    _stopRequested = false;

    final chunks = _splitForSpeech(text);
    // Synthesize chunk i+1 inside the Sherpa isolate *while* chunk i is
    // playing, so the two overlap instead of running back to back. Speech
    // therefore starts after the first chunk instead of after the whole page.
    Future<Uint8List>? pending;
    for (var i = 0; i < chunks.length; i++) {
      if (_stopRequested) {
        pending?.ignore();
        return;
      }
      final audio = pending != null
          ? await pending
          : await _sherpaFactory.generate(_tts!, chunks[i]);
      pending = null;
      if (_stopRequested) return;
      if (i + 1 < chunks.length) {
        pending = _sherpaFactory.generate(_tts!, chunks[i + 1]);
      }
      debugPrint('builtin speak: playing ${audio.length} bytes (chunk ${i + 1}/${chunks.length})');
      await _player.playBytes(audio, contentType: 'audio/wav');
    }
  }

  @override
  Future<void> stop() async {
    // Also aborts the chunk loop in [speak] — stopping the player alone would
    // just end the current chunk and let the next one start.
    _stopRequested = true;
    await _player.stop();
  }

  @override
  Future<void> setRate(double rate) async {
    // sherpa-onnx Piper does not support live rate changes; speed is baked
    // into the model. No-op until we add a post-process resampler.
  }

  /// Characters marking a natural place to end a chunk (terminators, clause
  /// separators, closing quotes, line breaks).
  static const String _breakChars = '。！？!?；;\n，,、：:)]）」』”’';

  /// Target size of the **first** chunk. Deliberately small: this is the only
  /// chunk the user actually waits on.
  static const int _firstChunkChars = 50;

  /// Upper bound for any chunk.
  static const int _chunkMax = 200;

  /// How much each chunk may grow relative to the previous one.
  ///
  /// Synthesis runs at roughly half playback speed on this class of device, so
  /// a chunk may be up to ~2x its predecessor before its synthesis outlasts the
  /// previous chunk's playback and an audible gap opens up. 1.7 leaves margin;
  /// going straight to [_chunkMax] produced a ~4 s hole after the first chunk.
  static const double _chunkGrowth = 1.7;

  /// Splits [text] into chunks so narration can begin once the first chunk is
  /// ready, instead of after an entire page has been synthesized.
  ///
  /// The first chunk is cut aggressively small; later ones are larger because
  /// their synthesis overlaps with playback.
  List<String> _splitForSpeech(String text) {
    final chunks = <String>[];
    final buffer = StringBuffer();
    var limit = _firstChunkChars;

    void flush() {
      final chunk = buffer.toString().trim();
      if (chunk.isNotEmpty) chunks.add(chunk);
      buffer.clear();
      final grown = (limit * _chunkGrowth).round();
      limit = grown > _chunkMax ? _chunkMax : grown;
    }

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      buffer.write(ch);
      // Slight headroom, so a chunk only overshoots its target when there is
      // no break character anywhere nearby.
      final hard = (limit * 1.2).round();
      if (buffer.length >= hard ||
          (_breakChars.contains(ch) && buffer.length >= limit)) {
        flush();
      }
    }
    flush();
    return chunks;
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
  void setProxyClient(ProxyClient? client) {}

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
    // espeak-ng 前端数据(Piper VITS 中文 G2P 必需)打包为 zip 单 asset，
    // 运行时解压到 modelDir/espeak-ng-data。
    try {
      final zipBytes = await rootBundle.load('$modelDir/espeak-ng-data.zip');
      final archive = ZipDecoder().decodeBytes(
        zipBytes.buffer.asUint8List(zipBytes.offsetInBytes, zipBytes.lengthInBytes),
      );
      for (final file in archive) {
        final filePath = '${out.path}/${file.name}';
        if (file.isFile) {
          await File(filePath)
              .create(recursive: true)
              .then((f) => f.writeAsBytes(file.content as List<int>));
        } else {
          await Directory(filePath).create(recursive: true);
        }
      }
      debugPrint('builtin TTS: espeak-ng-data unpacked');
    } catch (e) {
      debugPrint('builtin TTS: espeak-ng-data missing ($e)');
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
    // Block until the utterance has actually been spoken. Without this the
    // caller advances to the next page after a fixed delay and cuts the audio
    // off mid-sentence. stop() still unblocks this via the state stream.
    await waitForPlaybackEnd(_player);
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
