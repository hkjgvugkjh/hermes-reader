/// How the reading area is divided for tap navigation.
enum TapZoneMode {
  /// Left third = back, middle = toggle controls, right third = forward.
  thirds('左中右三区'),
  /// Left half = back, right half = forward.
  halves('左右两区'),
  /// Only edges respond; center toggles controls.
  edges('仅边缘区域'),
  /// Tapping anywhere advances to the next page (controls toggle via footer).
  whole('整屏单击翻页');

  const TapZoneMode(this.label);
  final String label;
}

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

/// Which channel(s) shared comments are published to / pulled from.
enum CommentSyncMode {
  /// Only the hermes server file channel.
  server('仅服务端'),

  /// Only the (reserved) torrent / P2P channel.
  torrent('仅 Torrent'),

  /// Publish to and merge from both channels.
  both('服务端 + Torrent 兼顾');

  const CommentSyncMode(this.label);
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
  static const List<String> allowedExtensions = [
    '.txt', '.md', '.pdf', '.epub', '.mobi', '.html', '.htm', '.json'
  ];

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

  /// Line-height multiplier used both for rendering and for page-flow
  /// measurement, so pre-computed pages fit the screen exactly.
  final double lineHeightFactor;

  /// Automatically advance to the next page when narration finishes.
  final bool autoTurnPage;

  /// How the reading area is divided for tap navigation.
  final TapZoneMode tapZoneMode;

  /// When true, left zone goes forward (next page); when false, goes back.
  final bool leftZoneForward;

  /// Which channel(s) shared comments use.
  final CommentSyncMode commentSyncMode;

  const ReaderConfig({
    this.ttsMode = TtsMode.auto,
    this.monitorInterval = const Duration(seconds: 60),
    this.sessionIdleThreshold = const Duration(seconds: 90),
    this.speechRate = 0.5,
    this.charsPerPage = 700,
    this.fontScale = 1.0,
    this.lineHeightFactor = 1.6,
    this.autoTurnPage = true,
    this.tapZoneMode = TapZoneMode.whole,
    this.leftZoneForward = false,
    this.commentSyncMode = CommentSyncMode.server,
  }) : assert(charsPerPage > 0, 'charsPerPage must be positive');

  ReaderConfig copyWith({
    TtsMode? ttsMode,
    Duration? monitorInterval,
    Duration? sessionIdleThreshold,
    double? speechRate,
    int? charsPerPage,
    double? fontScale,
    double? lineHeightFactor,
    bool? autoTurnPage,
    TapZoneMode? tapZoneMode,
    bool? leftZoneForward,
    CommentSyncMode? commentSyncMode,
  }) =>
      ReaderConfig(
        ttsMode: ttsMode ?? this.ttsMode,
        monitorInterval: monitorInterval ?? this.monitorInterval,
        sessionIdleThreshold: sessionIdleThreshold ?? this.sessionIdleThreshold,
        speechRate: speechRate ?? this.speechRate,
        charsPerPage: charsPerPage ?? this.charsPerPage,
        fontScale: fontScale ?? this.fontScale,
        lineHeightFactor: lineHeightFactor ?? this.lineHeightFactor,
        autoTurnPage: autoTurnPage ?? this.autoTurnPage,
        tapZoneMode: tapZoneMode ?? this.tapZoneMode,
        leftZoneForward: leftZoneForward ?? this.leftZoneForward,
        commentSyncMode: commentSyncMode ?? this.commentSyncMode,
      );

  Map<String, dynamic> toJson() => {
        'ttsMode': ttsMode.name,
        'monitorInterval': monitorInterval.inSeconds,
        'sessionIdleThreshold': sessionIdleThreshold.inSeconds,
        'speechRate': speechRate,
        'charsPerPage': charsPerPage,
        'fontScale': fontScale,
        'lineHeightFactor': lineHeightFactor,
        'autoTurnPage': autoTurnPage,
        'tapZoneMode': tapZoneMode.name,
        'leftZoneForward': leftZoneForward,
        'commentSyncMode': commentSyncMode.name,
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
        lineHeightFactor: (json['lineHeightFactor'] as num? ?? 1.6).toDouble(),
        autoTurnPage: json['autoTurnPage'] as bool? ?? true,
        tapZoneMode: TapZoneMode.values.firstWhere(
          (e) => e.name == json['tapZoneMode'],
          orElse: () => TapZoneMode.thirds,
        ),
        leftZoneForward: json['leftZoneForward'] as bool? ?? false,
        commentSyncMode: CommentSyncMode.values.firstWhere(
          (e) => e.name == json['commentSyncMode'],
          orElse: () => CommentSyncMode.server,
        ),
      );
}
