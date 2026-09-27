/// Annotation models shared by the local bookmark / note store and the
/// (optionally) synced comment layer.
///
/// A [Bookmark] is a lightweight saved position. A [Note] is a highlight +
/// optional personal comment anchored to a text range. A [SharedComment] is a
/// [Note] published to the shared layer (server-backed for now, with a P2P /
/// torrent transport pluggable behind [CommentSync] later).

class Bookmark {
  final String bookId;
  final int offset;
  final int? pageIndex;
  final String? label;
  final int createdAt;

  Bookmark({
    required this.bookId,
    required this.offset,
    this.pageIndex,
    this.label,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        bookId: json['bookId'] as String,
        offset: json['offset'] as int,
        pageIndex: json['pageIndex'] as int?,
        label: json['label'] as String?,
        createdAt: json['createdAt'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'offset': offset,
        'pageIndex': pageIndex,
        'label': label,
        'createdAt': createdAt,
      };

  Bookmark copyWith({String? label}) =>
      Bookmark(bookId: bookId, offset: offset, pageIndex: pageIndex, label: label ?? this.label, createdAt: createdAt);
}

class Note {
  final String id;
  final String bookId;
  final int startOffset;
  final int endOffset;
  final String quotedText;
  final String? comment;
  final int color;
  final int createdAt;
  final int updatedAt;

  Note({
    required this.id,
    required this.bookId,
    required this.startOffset,
    required this.endOffset,
    required this.quotedText,
    this.comment,
    this.color = 0xFFFFEB3B,
    int? createdAt,
    int? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory Note.fromJson(Map<String, dynamic> json) => Note(
        id: json['id'] as String,
        bookId: json['bookId'] as String,
        startOffset: json['startOffset'] as int,
        endOffset: json['endOffset'] as int,
        quotedText: json['quotedText'] as String,
        comment: json['comment'] as String?,
        color: json['color'] as int? ?? 0xFFFFEB3B,
        createdAt: json['createdAt'] as int?,
        updatedAt: json['updatedAt'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'startOffset': startOffset,
        'endOffset': endOffset,
        'quotedText': quotedText,
        'comment': comment,
        'color': color,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  Note copyWith({String? comment, int? color}) => Note(
        id: id,
        bookId: bookId,
        startOffset: startOffset,
        endOffset: endOffset,
        quotedText: quotedText,
        comment: comment ?? this.comment,
        color: color ?? this.color,
        createdAt: createdAt,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
}

/// A [Note] published to the shared layer. Carries authorship so peers can
/// attribute and de-duplicate. [deviceId] + [id] form a stable global key.
class SharedComment {
  final String id;
  final String bookId;
  final String deviceId;
  final String author;
  final int startOffset;
  final int endOffset;
  final String quotedText;
  final String comment;
  final int createdAt;

  SharedComment({
    required this.id,
    required this.bookId,
    required this.deviceId,
    required this.author,
    required this.startOffset,
    required this.endOffset,
    required this.quotedText,
    required this.comment,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  factory SharedComment.fromJson(Map<String, dynamic> json) => SharedComment(
        id: json['id'] as String,
        bookId: json['bookId'] as String,
        deviceId: json['deviceId'] as String? ?? '',
        author: json['author'] as String? ?? 'anonymous',
        startOffset: json['startOffset'] as int,
        endOffset: json['endOffset'] as int,
        quotedText: json['quotedText'] as String,
        comment: json['comment'] as String,
        createdAt: json['createdAt'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'deviceId': deviceId,
        'author': author,
        'startOffset': startOffset,
        'endOffset': endOffset,
        'quotedText': quotedText,
        'comment': comment,
        'createdAt': createdAt,
      };

  String get globalKey => '$deviceId/$id';
}
