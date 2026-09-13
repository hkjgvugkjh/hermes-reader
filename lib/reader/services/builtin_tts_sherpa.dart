import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'builtin_tts_source.dart';

/// Real on-device TTS backed by sherpa-onnx.
///
/// Piper models are loaded through the VITS config family in sherpa-onnx
/// 1.x (the dedicated Piper config was merged into [sherpa.OfflineTtsVitsModelConfig]).
///
/// IMPORTANT: building the [sherpa.OfflineTts] engine loads a ~60MB onnx model
/// plus the espeak-ng frontend data, which is CPU-heavy and would block the UI
/// thread (ANR) if done on the main isolate. So the engine is created and all
/// inference run inside a dedicated background [Isolate]; this factory only
/// handles the message-passing bridge. [create] therefore returns the
/// background isolate's [SendPort] (carried as [Object?] by [BuiltinTtsSource]).
class SherpaOnnxImplFactory implements SherpaOnnxFactory {
  const SherpaOnnxImplFactory();

  @override
  Future<Object?> create(String modelDir) async {
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(_sherpaIsolateEntry, receive.sendPort);
    final SendPort sendPort = await receive.first as SendPort;
    // Tell the isolate to load the model and wait for readiness.
    final ready = ReceivePort();
    sendPort.send(_Msg(_Cmd.load, modelDir, ready.sendPort));
    final result = await ready.first;
    if (result is String) {
      // error string
      debugPrint('builtin TTS create failed: $result');
      isolate.kill();
      throw Exception(result);
    }
    debugPrint('builtin TTS engine ready');
    return _IsolateHandle(sendPort, isolate);
  }

  @override
  Future<Uint8List> generate(Object tts, String text) async {
    final handle = tts as _IsolateHandle;
    final reply = ReceivePort();
    handle.sendPort.send(_Msg(_Cmd.generate, text, reply.sendPort));
    final result = await reply.first;
    if (result is String) {
      debugPrint('builtin TTS generate failed: $result');
      throw Exception(result); // error string
    }
    final bytes = result as Uint8List;
    debugPrint('builtin TTS generated ${bytes.length} bytes wav');
    return bytes;
  }

  @override
  Future<void> dispose(Object tts) async {
    final handle = tts as _IsolateHandle;
    handle.sendPort.send(_Msg(_Cmd.dispose, null, null));
    handle.isolate.kill();
  }
}

/// Carries the background isolate's control port + reference so the main
/// isolate can talk to it and kill it on dispose.
class _IsolateHandle {
  const _IsolateHandle(this.sendPort, this.isolate);
  final SendPort sendPort;
  final Isolate isolate;
}

enum _Cmd { load, generate, dispose }

class _Msg {
  const _Msg(this.cmd, this.payload, this.reply);
  final _Cmd cmd;
  final Object? payload;
  final SendPort? reply;
}

/// Background isolate: owns the sherpa engine, never touches the UI thread.
void _sherpaIsolateEntry(SendPort sendPort) {
  final incoming = ReceivePort();
  sendPort.send(incoming.sendPort);

  sherpa.OfflineTts? engine;

  incoming.listen((dynamic message) async {
    final msg = message as _Msg;
    switch (msg.cmd) {
      case _Cmd.load:
        final modelDir = msg.payload as String;
        try {
          await sherpa.initBindingsAsync();
          engine = sherpa.OfflineTts(
            sherpa.OfflineTtsConfig(
              model: sherpa.OfflineTtsModelConfig(
                vits: sherpa.OfflineTtsVitsModelConfig(
                  model: '$modelDir/model.onnx',
                  tokens: '$modelDir/tokens.txt',
                  // Piper VITS 模型需要 espeak-ng 做前端文本正则化(G2P)。
                  // espeak-ng-data 以 zip 打包, BuiltinTtsSource 运行时解压到 modelDir 顶层,
                  // 因此 dataDir 直接指向 modelDir (内含 phondata/phonindex/phontab/voices/cmn_dict 等)。
                  dataDir: '$modelDir',
                ),
                numThreads: 1,
                debug: false,
                provider: 'cpu',
              ),
            ),
          );
          msg.reply?.send(true);
        } catch (e) {
          msg.reply?.send('builtin TTS load failed: $e');
        }
      case _Cmd.generate:
        final text = msg.payload as String;
        try {
          if (engine == null) {
            msg.reply?.send('builtin TTS: engine not loaded');
            return;
          }
          final audio = engine!.generate(text: text, sid: 0, speed: 1.0);
          final wav = _encodeWav(audio.samples, audio.sampleRate);
          msg.reply?.send(wav);
        } catch (e) {
          msg.reply?.send('builtin TTS generate failed: $e');
        }
      case _Cmd.dispose:
        engine?.free();
        engine = null;
        Isolate.exit();
    }
  });
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
