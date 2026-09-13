import 'dart:async';

import '../models/reader_config.dart';

/// How the current utterance is being produced.
enum SpeechEngine {
  /// Server-side synthesis via /api/hermes/tts/synthesize.
  server('Server TTS'),

  /// On-device engine via flutter_tts (system TTS).
  local('Local TTS'),

  /// On-device neural model bundled with the app (sherpa-onnx / Piper).
  builtin('Builtin TTS');

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

  /// Optional: selects the backend server for proxy-tunneled server TTS.
  /// Only [ServerTtsSource] uses this; others ignore it.
  void setServerId(String? serverId) {}
}

/// Chooses among the available engines.
///
/// Priority order for [TtsMode.auto] (per product decision: prefer on-device,
/// fall back to the network only when nothing local works):
///
///   1. [SpeechEngine.local]  — system TTS (flutter_tts), when an engine exists.
///   2. [SpeechEngine.builtin] — offline neural model bundled with the app.
///   3. [SpeechEngine.server]  — /api/hermes/tts/synthesize via the proxy.
///
/// Any failure silently degrades to the next candidate so narration never
/// stalls just because one engine is missing or the network is down.
class TtsService {
  TtsService({
    required SpeechSource serverSource,
    required SpeechSource localSource,
    SpeechSource? builtinSource,
    this.connectivityCheck,
  })  : _server = serverSource,
        _local = localSource,
        _builtin = builtinSource;

  final SpeechSource _server;
  final SpeechSource _local;
  final SpeechSource? _builtin;

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

  /// Per-engine availability, useful for UI diagnostics.
  Future<Map<SpeechEngine, bool>> get engineAvailability async => {
        SpeechEngine.local: await _local.isAvailable(),
        SpeechEngine.builtin: _builtin == null
            ? false
            : await _builtin.isAvailable(),
        SpeechEngine.server: await _server.isAvailable(),
      };

  final _stateController = StreamController<TtsState>.broadcast();

  /// Emits as narration starts and stops, so the reader can drive page turns.
  Stream<TtsState> get stateStream => _stateController.stream;

  /// Where the current utterance has got to. Only engines that report it do.
  void setProgressHandler(NarrationProgressHandler? handler) {
    final cb = handler == null
        ? null
        : (offset) {
            _lastCharOffset = offset;
            handler(offset);
          };
    _local.setProgressHandler(cb);
    _builtin?.setProgressHandler(cb);
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
    await _applyRate();
  }

  Future<void> setRate(double rate) async {
    _rate = rate.clamp(0.0, 1.0);
    await _applyRate();
  }

  /// Tells the server engine which backend to forward to (proxy mode). The
  /// reader screen calls this before [speak] with the book's serverId.
  void setServerId(String? serverId) => _server.setServerId(serverId);

  Future<void> _applyRate() async {
    await _local.setRate(_rate);
    await _builtin?.setRate(_rate);
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
        try {
          await _speakWith(_local, text);
          return const SpeakResult(engine: SpeechEngine.local);
        } catch (e) {
          // local mode: also allow the bundled offline model as the last
          // on-device resort before giving up.
          final builtin = _builtin;
          if (builtin != null) {
            try {
              await _speakWith(builtin, text);
              return const SpeakResult(engine: SpeechEngine.builtin);
            } catch (_) {}
          }
          _emit(TtsState.error);
          rethrow;
        }

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
    // On-device first: system TTS when an engine is present, else bundled model.
    if (await _local.isAvailable()) {
      try {
        await _speakWith(_local, text);
        _lastFallbackReason = null;
        return const SpeakResult(engine: SpeechEngine.local);
      } catch (e) {
        _emit(TtsState.error);
        // fall through to builtin/server
      }
    }

    final builtin = _builtin;
    if (builtin != null && await builtin.isAvailable()) {
      try {
        await _speakWith(builtin, text);
        _lastFallbackReason = 'system TTS unavailable';
        return SpeakResult(
          engine: SpeechEngine.builtin,
          fellBack: true,
          fallbackReason: _lastFallbackReason,
        );
      } catch (e) {
        _emit(TtsState.error);
        // fall through to server
      }
    }

    // Network last resort.
    String? reason;
    if (connectivityCheck != null) {
      final reachable = await connectivityCheck!();
      if (!reachable) reason = 'offline';
    }
    if (reason == null && !await _server.isAvailable()) {
      reason = 'server TTS not configured';
    }

    if (reason == null) {
      try {
        await _speakWith(_server, text);
        _lastFallbackReason = _builtin != null
            ? 'on-device engines unavailable'
            : 'on-device engine unavailable';
        return SpeakResult(
          engine: SpeechEngine.server,
          fellBack: true,
          fallbackReason: _lastFallbackReason,
        );
      } catch (e) {
        reason = 'server TTS failed: $e';
      }
    }

    _emit(TtsState.error);
    throw Exception('all TTS engines failed (last: $reason)');
  }

  Future<void> _speakWith(SpeechSource source, String text) async {
    await source.setRate(_rate);
    await source.speak(text);
  }

  Future<void> stop() async {
    for (final s in [_server, _local, _builtin]) {
      if (s == null) continue;
      try {
        await s.stop();
      } catch (_) {
        // Stopping an already-stopped engine must not propagate.
      }
    }
    _emit(TtsState.idle);
  }

  Future<void> dispose() async {
    for (final s in [_server, _local, _builtin]) {
      await s?.dispose();
    }
    await _stateController.close();
  }
}

enum TtsState { idle, speaking, error }
