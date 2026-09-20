import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sanotts_flutter/sanotts_flutter.dart';

import 'playback_wait.dart';
import 'proxy_client.dart';
import 'tts_service.dart';

/// On-device tiny neural TTS backed by [sanoTTS](https://github.com/Ampixa/sanoTTS),
/// wired through the `sanotts_flutter` package (native runtime + Flutter FFI).
///
/// The runtime takes phoneme ids, not text, so this source performs G2P via
/// [MisakiPhonemizer]. The first G2P stage (text -> espeak-ng IPA) is supplied by
/// an [EspeakNgProvider] that uses the espeak-ng the `sanotts_flutter` plugin
/// bundles (`libespeak-ng.so`, built from vendored espeak-ng) and its matching
/// `espeak-ng-data`, unpacked here from `assets/sano/espeak-ng-data.zip` (falling
/// back to `assets/tts/espeak-ng-data.zip`) into the app support dir. Pass
/// [espeakDataPath] to override.
///
/// Availability requires the voice weights to be shipped as assets
/// (`assets/sano/heartnano.q8.{front,model}.bin`, see `sanotts_flutter`'s
/// `weights.dart`). Until those blobs are present the engine reports unavailable
/// and is skipped in the auto fallback chain.
class SanoTtsSource implements SpeechSource {
  SanoTtsSource({
    this.modelFamily = 'heartnano',
    EspeakProvider? espeakProvider,
    this.espeakDataPath,
  }) : _espeakProvider = espeakProvider {
    if (_espeakProvider != null) _g2p = MisakiPhonemizer(_espeakProvider!);
  }

  final String modelFamily;
  final String? espeakDataPath;
  EspeakProvider? _espeakProvider;

  MisakiPhonemizer? _g2p;
  String? _resolvedEspeakDataPath;

  final AudioPlayer _player = AudioPlayer();

  bool _initialized = false;
  bool _available = false;
  SanoTtsVoice? _voice;

  /// Supply the espeak-ng provider used for the text -> IPA stage. Call before
  /// the first [speak] if you want to synthesize from raw text (rather than
  /// pre-computed phoneme ids).
  void setEspeakProvider(EspeakProvider provider) {
    _espeakProvider = provider;
    _g2p = MisakiPhonemizer(provider);
  }

  @override
  SpeechEngine get engine => SpeechEngine.sano;

  @override
  Future<bool> isAvailable() async {
    if (_initialized) return _available;
    await _ensureInit();
    return _available;
  }

  @override
  Future<void> warmUp() async => _ensureInit();

  @override
  Future<void> speak(String text) async {
    await _ensureInit();
    if (_voice == null) {
      throw Exception('SanoTTS weights not available (ship assets/sano/*.bin)');
    }
    if (_g2p == null) {
      throw Exception(
          'SanoTTS: espeak-ng provider unavailable; check assets/sano/espeak-ng-data.zip');
    }
    final (ids, dropped) = _g2p!.phonemize(text);
    if (dropped.isNotEmpty) {
      debugPrint('sanoTTS dropped symbols: "$dropped"');
    }
    final pcm = _voice!.speakPhonemes(ids);
    final wav = _voice!.toWav(pcm);
    await _player.setAudioSource(
      AudioSource.uri(Uri.dataFromBytes(wav, mimeType: 'audio/wav')),
    );
    await _player.play();
    await waitForPlaybackEnd(_player);
  }

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {
      // Engine may already be stopped; nothing to clean up.
    }
  }

  @override
  Future<void> setRate(double rate) async {
    // sanoTTS rate is baked into the model; no live rate change yet.
  }

  @override
  void setProgressHandler(NarrationProgressHandler? handler) {
    // sanoTTS returns the full clip at once; no word-level offset to report.
  }

  @override
  void setServerId(String? serverId) {
    // sanoTTS is on-device; does not use the proxy. Ignored.
  }

  @override
  void setProxyClient(ProxyClient? client) {}

  @override
  Future<void> dispose() async {
    try {
      await _player.dispose();
    } catch (_) {}
    _voice?.dispose();
    _voice = null;
  }

  /// Unpack espeak-ng-data so the espeak-ng provider can find its voice rules.
  /// Prefers the version-matched `assets/sano/espeak-ng-data.zip` (built from the
  /// same espeak-ng source as the bundled `libespeak-ng.so`) and falls back to the
  /// app's `assets/tts/espeak-ng-data.zip`. Returns the data dir, or null if it
  /// could not be prepared.
  Future<String?> _ensureEspeakData() async {
    if (_resolvedEspeakDataPath != null) return _resolvedEspeakDataPath;
    if (espeakDataPath != null) {
      _resolvedEspeakDataPath = espeakDataPath;
      return _resolvedEspeakDataPath;
    }
    final dir = await getApplicationSupportDirectory();
    final out = Directory('${dir.path}/sano_tts/espeak-ng-data');
    if (await out.exists()) {
      _resolvedEspeakDataPath = out.path;
      return _resolvedEspeakDataPath;
    }
    _resolvedEspeakDataPath = await _unpackDataZip(out, 'assets/sano/espeak-ng-data.zip') ??
        await _unpackDataZip(out, 'assets/tts/espeak-ng-data.zip');
    return _resolvedEspeakDataPath;
  }

  /// Unpack [asset] (a zip of espeak-ng-data) into [out]. Returns [out.path] on
  /// success, or null if the asset is not present / fails to unpack.
  Future<String?> _unpackDataZip(Directory out, String asset) async {
    try {
      final zip = await rootBundle.load(asset);
      final archive = ZipDecoder().decodeBytes(
        zip.buffer.asUint8List(zip.offsetInBytes, zip.lengthInBytes),
      );
      await out.create(recursive: true);
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
      return out.path;
    } on FlutterError {
      // Asset not present; caller may try a fallback.
      return null;
    } catch (e) {
      debugPrint('sanoTTS: failed to unpack $asset ($e)');
      return null;
    }
  }

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    try {
      // Wire the espeak-ng provider (text -> IPA) unless one was injected.
      if (_g2p == null) {
        final dataPath = await _ensureEspeakData();
        try {
          _g2p = MisakiPhonemizer(
              EspeakNgProvider(dataPath: dataPath, voice: 'en-us'));
        } on EspeakException catch (e) {
          debugPrint('sanoTTS: espeak-ng provider unavailable ($e)');
        }
      }
      final w = SanoTtsWeights(modelFamily);
      final front = await rootBundle
          .load(w.frontAsset)
          .then((b) => b.buffer.asUint8List());
      final decoder = await rootBundle
          .load(w.decoderAsset)
          .then((b) => b.buffer.asUint8List());
      _voice = SanoTtsVoice.fromMemory(front: front, decoder: decoder);
      _available = true;
    } catch (e) {
      _available = false;
      debugPrint('sanoTTS unavailable (weights missing?): $e');
    }
  }
}
