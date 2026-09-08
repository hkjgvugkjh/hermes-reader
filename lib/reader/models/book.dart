import 'dart:convert';
import 'dart:typed_data';

/// A book available on one of the connected servers.
class Book {
  /// Stable id: `serverId::relativePath`.
  final String id;
  final String serverId;
  final String serverName;

  /// Path relative to the server's library root.
  final String relativePath;
  final String title;
  final int sizeBytes;

  /// True once the file has been downloaded into the app's private storage.
  final bool downloaded;

  final DateTime? modifiedAt;

  const Book({
    required this.id,
    required this.serverId,
    required this.serverName,
    required this.relativePath,
    required this.title,
    required this.sizeBytes,
    this.downloaded = false,
    this.modifiedAt,
  });

  Book copyWith({
    String? id,
    String? serverId,
    String? serverName,
    String? relativePath,
    String? title,
    int? sizeBytes,
    bool? downloaded,
    DateTime? modifiedAt,
  }) =>
      Book(
        id: id ?? this.id,
        serverId: serverId ?? this.serverId,
        serverName: serverName ?? this.serverName,
        relativePath: relativePath ?? this.relativePath,
        title: title ?? this.title,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        downloaded: downloaded ?? this.downloaded,
        modifiedAt: modifiedAt ?? this.modifiedAt,
      );

  /// Human-readable size.
  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverId': serverId,
        'serverName': serverName,
        'relativePath': relativePath,
        'title': title,
        'sizeBytes': sizeBytes,
        'downloaded': downloaded,
        'modifiedAt': modifiedAt?.toIso8601String(),
      };

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        id: json['id'] as String,
        serverId: json['serverId'] as String,
        serverName: json['serverName'] as String? ?? '',
        relativePath: json['relativePath'] as String,
        title: json['title'] as String,
        sizeBytes: json['sizeBytes'] as int? ?? 0,
        downloaded: json['downloaded'] as bool? ?? false,
        modifiedAt: json['modifiedAt'] != null
            ? DateTime.tryParse(json['modifiedAt'] as String)
            : null,
      );
}

/// One screen of text produced by the paginator.
class BookPage {
  final int index;
  final String content;

  /// Offset into the full text where this page starts.
  final int startOffset;

  const BookPage({
    required this.index,
    required this.content,
    required this.startOffset,
  });
}

/// Saved position in a book, persisted across app restarts.
class ReadingProgress {
  final String bookId;
  final int pageIndex;

  /// 0.0 - 1.0, derived from page position.
  final double percent;
  final DateTime updatedAt;

  const ReadingProgress({
    required this.bookId,
    required this.pageIndex,
    required this.percent,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'pageIndex': pageIndex,
        'percent': percent,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory ReadingProgress.fromJson(Map<String, dynamic> json) =>
      ReadingProgress(
        bookId: json['bookId'] as String,
        pageIndex: json['pageIndex'] as int? ?? 0,
        percent: (json['percent'] as num? ?? 0.0).toDouble(),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// Decoded text of a downloaded book. Kept separate from [Book] so the shelf
/// list stays light.
class BookContent {
  final String bookId;
  final String text;
  final String encoding;

  const BookContent({
    required this.bookId,
    required this.text,
    this.encoding = 'utf-8',
  });

  int get length => text.length;

  /// Lazy byte length — used for sanity checks, not for display.
  int get byteLength => utf8.encode(text).length;

  Uint8List get bytes => Uint8List.fromList(utf8.encode(text));
}
