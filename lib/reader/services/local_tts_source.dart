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

  /// Set when [stop] interrupts an in-flight [speak]. flutter_tts resolves the
  /// pending speak() promise with `0` on interruption, which would otherwise be
  /// mis-reported as an engine failure.
  bool _stopRequested = false;

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
    // Clear any stale flag left by an idle stop() so a genuine engine failure
    // on this utterance is still reported.
    _stopRequested = false;

    await _tts.stop();

    if (await _speakOnce(text)) {
      _stopRequested = false;
      return;
    }
    // The first attempt may fail while the engine is still binding on a cold
    // start (flutter_tts reports "not bound to TTS engine"). Retry once.
    if (_stopRequested) {
      _stopRequested = false;
      return;
    }
    await Future.delayed(const Duration(milliseconds: 400));
    if (await _speakOnce(text)) {
      _stopRequested = false;
      return;
    }
    if (_stopRequested) {
      _stopRequested = false;
      return;
    }
    throw Exception('local TTS engine returned 0');
  }

  /// Speaks [text] and resolves true on success. flutter_tts resolves the
  /// promise with `1` on success, `0` on a refused utterance, or `null` on some
  /// platforms (treated as success for compatibility).
  Future<bool> _speakOnce(String text) async {
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
    if (result == null) return true;
    if (result is int) return result == 1;
    return false;
  }

  /// Upper bound for one utterance. Generous: a full page of Chinese prose
  /// takes well under a minute, so this only trips on a hung engine.
  static const _speakTimeout = Duration(minutes: 2);

  @override
  Future<void> stop() async {
    _stopRequested = true; // mark the in-flight speak() as intentionally stopped
    await _tts.stop();
  }

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

    // Force the platform engine to finish binding before we configure/speak.
    // On Android this awaits onInit; without it the first speak() can fail with
    // "not bound to TTS engine" when no engine is selected as default.
    try {
      final engines = (await _tts.getEngines) as List?;
      if (engines == null || engines.isEmpty) {
        throw Exception(
          '本机未检测到可用的文字转语音(TTS)引擎。请到 系统设置 → 语言与输入法/辅助功能 '
          '→ 文字转语音输出 中安装并选择语音引擎（如讯飞语音、Google 文字转语音），'
          '下载语言包后重试。',
        );
      }
    } catch (e) {
      // A platform-level failure (e.g. getEngines unsupported) is re-thrown
      // only when it is our own "no engine" message; otherwise fall through and
      // let the first speak() surface the real error.
      if (e is Exception && e.toString().contains('TTS引擎')) rethrow;
    }

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

  @override
  void setServerId(String? serverId) {
    // Local engine does not use the proxy; ignored.
  }
}
