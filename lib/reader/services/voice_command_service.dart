import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:record/record.dart';

/// One-shot voice command result.
class VoiceTurnResult {
  final bool success;
  final String transcript;
  final String? replyAudio;
  final String? error;

  const VoiceTurnResult({
    required this.success,
    required this.transcript,
    this.replyAudio,
    this.error,
  });
}

/// Records audio and sends it to a Hermes server for transcription and response.
class VoiceCommandService {
  final _recorder = AudioRecorder();

  bool _recording = false;
  bool get isRecording => _recording;

  String? _currentPath;

  /// Request microphone permission (call before first [start]).
  Future<bool> ensurePermission() async {
    return await _recorder.hasPermission();
  }

  /// Start recording to a temporary file.
  Future<void> start() async {
    if (_recording) return;
    if (!await ensurePermission()) {
      throw Exception('microphone permission denied');
    }
    final dir = Directory.systemTemp;
    final path =
        '${dir.path}/voice_cmd_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000),
      path: path,
    );
    _currentPath = path;
    _recording = true;
  }

  /// Stop recording and return the file path, or null if recording failed.
  Future<String?> stopAndSave() async {
    if (!_recording) return null;
    final path = await _recorder.stop();
    _recording = false;
    _currentPath = null;
    return path;
  }

  /// Send a recorded audio file to the server for transcription.
  ///
  /// Returns a [VoiceTurnResult] with transcript and optional reply.
  Future<VoiceTurnResult> sendTurn({
    required String baseUrl,
    required String? authToken,
    required String filePath,
    Map<String, String>? extraHeaders,
  }) async {
    final bytes = await File(filePath).readAsBytes();
    final headers = <String, String>{
      'Content-Type': 'audio/wav',
      'Accept': 'application/json',
    };
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }
    if (extraHeaders != null) {
      headers.addAll(extraHeaders);
    }

    try {
      final resp = await http
          .post(
            Uri.parse('$baseUrl/api/hermes/mcu/voice-turn'),
            headers: headers,
            body: bytes,
          )
          .timeout(const Duration(seconds: 30));

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        return const VoiceTurnResult(
          success: false,
          transcript: '',
          error: 'authorization required',
        );
      }
      if (resp.statusCode != 200) {
        return VoiceTurnResult(
          success: false,
          transcript: '',
          error: 'server error ${resp.statusCode}',
        );
      }
      final body = Map<String, dynamic>.from(
          resp.body.isNotEmpty ? {} : <String, dynamic>{});
      // voice-turn returns JSON with transcript, accepted, error fields.
      return VoiceTurnResult(
        success: true,
        transcript: body['transcript']?.toString() ?? '',
      );
    } catch (e) {
      return VoiceTurnResult(
        success: false,
        transcript: '',
        error: e.toString(),
      );
    }
  }

  /// Record, send, and clean up — all in one call.
  Future<VoiceTurnResult> recordAndSend({
    required String baseUrl,
    required String? authToken,
    Duration maxDuration = const Duration(seconds: 30),
    Map<String, String>? extraHeaders,
  }) async {
    await start();
    await Future.delayed(maxDuration);
    final path = await stopAndSave();
    if (path == null) {
      return const VoiceTurnResult(
        success: false,
        transcript: '',
        error: 'recording failed',
      );
    }
    final result = await sendTurn(
      baseUrl: baseUrl,
      authToken: authToken,
      filePath: path,
      extraHeaders: extraHeaders,
    );
    // Best-effort cleanup.
    try {
      await File(path).delete();
    } catch (_) {}
    return result;
  }

  void dispose() {
    _recorder.dispose();
  }
}
