import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'builtin_tts_source.dart';

/// Real on-device TTS backed by sherpa-onnx.
///
/// Piper models are loaded through the VITS config family in sherpa-onnx
/// 1.x (the dedicated Piper config was merged into [sherpa.OfflineTtsVitsModelConfig]).
///
/// This factory is what makes [BuiltinTtsSource] actually produce audio. It is
/// kept in its own file so the `sherpa_onnx` import (and its native deps) are
/// isolated: if the package is not in pubspec, only this file fails to compile,
/// and [BuiltinTtsSource] can fall back to the no-op [_DefaultSherpaOnnxFactory].
class SherpaOnnxImplFactory implements SherpaOnnxFactory {
  const SherpaOnnxImplFactory();

  @override
  Future<Object?> create(String modelDir) async {
    final tts = sherpa.OfflineTts(
      sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: '$modelDir/model.onnx',
            tokens: '$modelDir/tokens.txt',
          ),
          numThreads: 1,
          debug: false,
          provider: 'cpu',
        ),
      ),
    );
    return tts;
  }

  @override
  Future<Uint8List> generate(Object tts, String text) async {
    final engine = tts as sherpa.OfflineTts;
    final audio = engine.generate(text: text, sid: 0, speed: 1.0);
    // sherpa-onnx returns 16-bit PCM mono; wrap as a WAV buffer for just_audio.
    return _encodeWav(audio.samples, audio.sampleRate);
  }

  @override
  Future<void> dispose(Object tts) async {
    (tts as sherpa.OfflineTts).free();
  }

  Uint8List _encodeWav(Float32List samples, int sampleRate) {
    const channels = 1;
    const bitsPerSample = 16;
    final dataSize = samples.length * 2;
    final fileSize = 36 + dataSize;
    final out = ByteData(44 + dataSize);
    final bytes = out.buffer.asUint8List();
    final writeTag = (String s) {
      for (var i = 0; i < s.length; i++) bytes[i] = s.codeUnitAt(i);
    };
    writeTag('RIFF');
    out.setUint32(4, fileSize, Endian.little);
    writeTag('WAVE');
    writeTag('fmt ');
    out.setUint32(16, 16, Endian.little);
    out.setUint16(20, 1, Endian.little); // PCM
    out.setUint16(22, channels, Endian.little);
    out.setUint32(24, sampleRate, Endian.little);
    out.setUint32(28, sampleRate * channels * bitsPerSample ~/ 8, Endian.little);
    out.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
    out.setUint16(34, bitsPerSample, Endian.little);
    writeTag('data');
    out.setUint32(40, dataSize, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      final s = (samples[i] * 32767).clamp(-32768, 32767).round();
      out.setInt16(44 + i * 2, s, Endian.little);
    }
    return bytes;
  }
}
