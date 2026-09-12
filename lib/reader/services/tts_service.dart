import 'dart:async';

import '../models/reader_config.dart';

/// How the current utterance is being produced.
enum SpeechEngine {
  /// Server-side synthesis via /api/hermes/tts/synthesize.
  server('Server TTS'),

  /// On-device engine via flutter_tts.
  local('Local TTS');

  const SpeechEngine(this.label);
  final String label;

  bool get isServer => this == SpeechEngine.server;
}

/// Result of a speak attempt, including which engine actually produced audio.
class SpeakResult {
  final SpeechEngine engine;

  /// True when we had to fall back from the preferred engine.
  final bool fellBack;

  /// Why the preferred engine was unavailable, when it was.
  final String? fallbackReason;

  const SpeakResult({
    required this.engine,
    this.fellBack = false,
    this.fallbackReason,
  });
}

/// Reports how far into the current utterance the engine has got, as a
/// character offset. Used to resume narration from where it stopped.
typedef NarrationProgressHandler = void Function(int charOffset);

/// Produces audio for a chunk of text.
///
/// Implementations are separated so the reader UI does not care whether audio
/// came from the network or from the device.
abstract class SpeechSource {
  SpeechEngine get engine;

  /// True when this source can plausibly be used right now.
  Future<bool> isAvailable();

  Future<void> speak(String text);
  Future<void> stop();
  Future<void> setRate(double rate);
  Future<void> dispose();

  /// Optional: only engines that expose word-level progress implement this.
  void setProgressHandler(NarrationProgressHandler? handler) {}
}

/// Chooses between the server and on-device engines.
///
/// In [TtsMode.auto] the server is preferred for voice quality, but any
/// failure silently degrades to the local engine so narration never stalls
/// just because the network did.
class TtsService {
  TtsService({
    required SpeechSource serverSource,
    required SpeechSource localSource,
    this.connectivityCheck,
  })  : _server = serverSource,
        _local = localSource;

  final SpeechSource _server;
  final SpeechSource _local;

  /// Optional reachability probe. When it returns false the server engine is
  /// skipped entirely, avoiding a slow timeout before the fallback.
  final Future<bool> Function()? connectivityCheck;

  TtsMode _mode = TtsMode.auto;
  double _rate = 0.5;

  /// Set after a fallback so the UI can explain why audio sounds different.
  String? _lastFallbackReason;

  TtsMode get mode => _mode;
  double get rate => _rate;
  String? get lastFallbackReason => _lastFallbackReason;

  final _stateController = StreamController<TtsState>.broadcast();

  /// Emits as narration starts and stops, so the reader can drive page turns.
  Stream<TtsState> get stateStream => _stateController.stream;

  /// Where the current utterance has got to. Only the local engine reports it.
  void setProgressHandler(NarrationProgressHandler? handler) {
    _local.setProgressHandler(handler == null
        ? null
        : (offset) {
            _lastCharOffset = offset;
            handler(offset);
          });
  }

  int _lastCharOffset = 0;

  /// Last reported character offset, or 0 when the engine never reported one.
  int get lastCharOffset => _lastCharOffset;

  TtsState _state = TtsState.idle;
  TtsState get state => _state;

  void _emit(TtsState s) {
    _state = s;
    if (!_stateController.isClosed) {
      _stateController.add(s);
    }
  }

  Future<void> setMode(TtsMode mode) async {
    _mode = mode;
    await _local.setRate(_rate);
    await _server.setRate(_rate);
  }

  Future<void> setRate(double rate) async {
    _rate = rate.clamp(0.0, 1.0);
    await _local.setRate(_rate);
    await _server.setRate(_rate);
  }

  /// Speaks [text], resolving to the engine that was actually used.
  ///
  /// Throws only when every permitted engine fails.
  Future<SpeakResult> speak(String text) async {
    if (text.trim().isEmpty) {
      return const SpeakResult(engine: SpeechEngine.local);
    }

    _lastCharOffset = 0;
    _emit(TtsState.speaking);

    switch (_mode) {
      case TtsMode.local:
        _lastFallbackReason = null;
        await _speakWith(_local, text);
        return const SpeakResult(engine: SpeechEngine.local);

      case TtsMode.server:
        _lastFallbackReason = null;
        try {
          await _speakWith(_server, text);
          return const SpeakResult(engine: SpeechEngine.server);
        } catch (e) {
          // Strict mode: report the failure rather than quietly substituting a
          // different voice than the user asked for.
          _emit(TtsState.error);
          rethrow;
        }

      case TtsMode.auto:
        return _speakAuto(text);
    }
  }

  Future<SpeakResult> _speakAuto(String text) async {
    String? reason;

    if (connectivityCheck != null) {
      final reachable = await connectivityCheck!();
      if (!reachable) reason = 'offline';
    }

    if (reason == null) {
      if (!await _server.isAvailable()) {
        reason = 'server TTS not configured';
      }
    }

    if (reason == null) {
      try {
        await _speakWith(_server, text);
        _lastFallbackReason = null;
        return const SpeakResult(engine: SpeechEngine.server);
      } catch (e) {
        reason = 'server TTS failed: $e';
      }
    }

    // Degrade to the on-device engine.
    _lastFallbackReason = reason;
    try {
      await _speakWith(_local, text);
      return SpeakResult(
        engine: SpeechEngine.local,
        fellBack: true,
        fallbackReason: reason,
      );
    } catch (e) {
      _emit(TtsState.error);
      throw Exception('all TTS engines failed (last: $e)');
    }
  }

  Future<void> _speakWith(SpeechSource source, String text) async {
    await source.setRate(_rate);
    await source.speak(text);
  }

  Future<void> stop() async {
    try {
      await _server.stop();
    } catch (_) {
      // Stopping an already-stopped engine must not propagate.
    }
    try {
      await _local.stop();
    } catch (_) {}
    _emit(TtsState.idle);
  }

  Future<void> dispose() async {
    await _server.dispose();
    await _local.dispose();
    await _stateController.close();
  }
}

enum TtsState { idle, speaking, error }
