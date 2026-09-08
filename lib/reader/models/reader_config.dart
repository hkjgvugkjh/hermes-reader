/// Configuration for the hermes-reader feature.
///
/// Privacy-relevant limits live here so they are visible in one place rather
/// than scattered through the services.
library;

/// Which engine produces the audio when reading aloud.
enum TtsMode {
  /// Prefer the server (/api/hermes/tts/synthesize); fall back to local on
  /// failure or when offline. This is the default.
  auto('Auto (server, fallback local)'),

  /// Always use the server engine. Fails loudly if unavailable.
  server('Server only'),

  /// Always use the on-device engine. Works offline.
  local('Local only');

  const TtsMode(this.label);
  final String label;
}

class ReaderConfig {
  // ---- privacy / safety limits -------------------------------------------

  /// Only files under this directory (relative to the server workspace) may be
  /// read. Everything else is refused before any request leaves the device.
  static const String libraryRoot = 'library';

  /// Refuse files larger than this. Protects both memory and data usage.
  static const int maxFileBytes = 20 * 1024 * 1024;

  /// Refuse a single transfer exceeding this.
  static const int maxTransferBytes = 50 * 1024 * 1024;

  /// How deep directory listing may recurse.
  static const int maxListDepth = 3;

  /// Extensions we are willing to open.
  static const List<String> allowedExtensions = ['.txt', '.md'];

  // ---- behaviour ----------------------------------------------------------

  final TtsMode ttsMode;

  /// Polling interval for the session monitor.
  final Duration monitorInterval;

  /// How long a session must sit with an unchanged timestamp before we call it
  /// stopped. Must exceed [monitorInterval] or we would flag healthy sessions.
  final Duration sessionIdleThreshold;

  /// Speech rate for local TTS (0.0 - 1.0).
  final double speechRate;

  /// Characters per page when paginating.
  final int charsPerPage;

  /// Font scale multiplier in the reader.
  final double fontScale;

  /// Automatically advance to the next page when narration finishes.
  final bool autoTurnPage;

  const ReaderConfig({
    this.ttsMode = TtsMode.auto,
    this.monitorInterval = const Duration(seconds: 60),
    this.sessionIdleThreshold = const Duration(seconds: 90),
    this.speechRate = 0.5,
    this.charsPerPage = 700,
    this.fontScale = 1.0,
    this.autoTurnPage = true,
  }) : assert(charsPerPage > 0, 'charsPerPage must be positive');

  ReaderConfig copyWith({
    TtsMode? ttsMode,
    Duration? monitorInterval,
    Duration? sessionIdleThreshold,
    double? speechRate,
    int? charsPerPage,
    double? fontScale,
    bool? autoTurnPage,
  }) =>
      ReaderConfig(
        ttsMode: ttsMode ?? this.ttsMode,
        monitorInterval: monitorInterval ?? this.monitorInterval,
        sessionIdleThreshold: sessionIdleThreshold ?? this.sessionIdleThreshold,
        speechRate: speechRate ?? this.speechRate,
        charsPerPage: charsPerPage ?? this.charsPerPage,
        fontScale: fontScale ?? this.fontScale,
        autoTurnPage: autoTurnPage ?? this.autoTurnPage,
      );

  Map<String, dynamic> toJson() => {
        'ttsMode': ttsMode.name,
        'monitorInterval': monitorInterval.inSeconds,
        'sessionIdleThreshold': sessionIdleThreshold.inSeconds,
        'speechRate': speechRate,
        'charsPerPage': charsPerPage,
        'fontScale': fontScale,
        'autoTurnPage': autoTurnPage,
      };

  factory ReaderConfig.fromJson(Map<String, dynamic> json) => ReaderConfig(
        ttsMode: TtsMode.values.firstWhere(
          (e) => e.name == json['ttsMode'],
          orElse: () => TtsMode.auto,
        ),
        monitorInterval:
            Duration(seconds: json['monitorInterval'] as int? ?? 60),
        sessionIdleThreshold:
            Duration(seconds: json['sessionIdleThreshold'] as int? ?? 90),
        speechRate: (json['speechRate'] as num? ?? 0.5).toDouble(),
        charsPerPage: json['charsPerPage'] as int? ?? 700,
        fontScale: (json['fontScale'] as num? ?? 1.0).toDouble(),
        autoTurnPage: json['autoTurnPage'] as bool? ?? true,
      );
}
