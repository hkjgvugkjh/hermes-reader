import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';

import 'tts_service.dart';

/// On-device speech via flutter_tts.
///
/// Used as the fallback when the server engine is unreachable, and as the
/// primary engine when the user picks "local" — it works with no network at
/// all, which matters for reading on a phone.
class LocalTtsSource implements SpeechSource {
  LocalTtsSource({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  bool _initialized = false;

  @override
  SpeechEngine get engine => SpeechEngine.local;

  @override
  Future<bool> isAvailable() async {
    try {
      await _ensureInit();
      final languages = await _tts.getLanguages;
      final list = (languages as List?) ?? const [];
      if (list.isEmpty) return false;

      // A default engine must actually be selected, otherwise speak() hangs
      // silently on some devices.
      final engines = await _tts.getEngines;
      return (engines as List?)?.isNotEmpty ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> speak(String text) async {
    await _ensureInit();
    await _tts.stop();

    // Guard against an engine that never reports completion. Without this, a
    // device with no default TTS engine configured leaves the reader stuck
    // mid-narration with no way out but a restart.
    final result = await _tts.speak(text).timeout(
          _speakTimeout,
          onTimeout: () {
            throw TimeoutException(
              'local TTS did not complete within ${_speakTimeout.inSeconds}s '
              '(is a default TTS engine configured on this device?)',
              _speakTimeout,
            );
          },
        );

    // flutter_tts returns 1 on success; anything else means the engine
    // refused the utterance (common when no TTS data is installed).
    if (result != null && result is int && result != 1) {
      throw Exception('local TTS engine returned $result');
    }
  }

  /// Upper bound for one utterance. Generous: a full page of Chinese prose
  /// takes well under a minute, so this only trips on a hung engine.
  static const _speakTimeout = Duration(minutes: 2);

  @override
  Future<void> stop() => _tts.stop();

  @override
  Future<void> setRate(double rate) async {
    await _ensureInit();
    // flutter_tts wants 0.0 - 1.0 mapped to its own range.
    await _tts.setSpeechRate(rate.clamp(0.0, 1.0) * 1.0 + 0.2);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  @override
  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Engine may already be gone; nothing to clean up.
    }
  }

  Future<void> _ensureInit() async {
    if (_initialized) return;

    await _tts.setSharedInstance(true);
    await _tts.setIosAudioCategory(
      IosTextToSpeechAudioCategory.playback,
      const [
        IosTextToSpeechAudioCategoryOptions.allowBluetooth,
        IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        IosTextToSpeechAudioCategoryOptions.mixWithOthers,
      ],
    );

    // Prefer the device locale, but fall back to whatever the engine has.
    try {
      final localeName = Platform.localeName.replaceAll('_', '-');
      await _tts.setLanguage(localeName);
    } catch (_) {
      // Keep the engine default when the locale is unsupported.
    }

    await _tts.awaitSpeakCompletion(true);
    _initialized = true;
  }

  /// Completion signal from the platform engine.
  void setCompletionHandler(void Function() handler) {
    _tts.setCompletionHandler(handler);
  }

  @override
  void setProgressHandler(NarrationProgressHandler? handler) {
    if (handler == null) {
      // flutter_tts has no "clear handler"; an empty callback is equivalent.
      _tts.setProgressHandler((String text, int start, int end, String word) {});
      return;
    }
    _tts.setProgressHandler(
      (String text, int start, int end, String word) => handler(end),
    );
  }
}
