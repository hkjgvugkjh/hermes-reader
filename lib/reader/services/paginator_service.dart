import '../models/book.dart';
import '../models/reader_config.dart';

/// Splits plain text into readable pages.
///
/// Pages are built from whole paragraphs so text never breaks mid-sentence
/// when the font size changes. Paging is deterministic for a given
/// [charsPerPage], which keeps progress stable across devices and rotations.
class PaginatorService {
  /// Paginates [text] into pages of roughly [charsPerPage] characters.
  ///
  /// When [breakOffsets] is given (PDF pages, EPUB chapters) those boundaries
  /// win: each becomes at least one page, and only a block longer than
  /// [charsPerPage] is split further. Without them the text flows by length.
  List<BookPage> paginate(
    String text, {
    int? charsPerPage,
    List<int>? breakOffsets,
  }) {
    final limit = charsPerPage ?? ReaderConfigDefault.charsPerPage;
    if (text.isEmpty) return const [];

    final usableBreaks = _sanitizeBreaks(breakOffsets, text.length);
    if (usableBreaks != null) {
      return _paginateByBreaks(text, usableBreaks, limit);
    }

    // Split into paragraphs, preserving the separators so we can rejoin
    // without losing blank lines.
    final paragraphs = _splitParagraphs(text);
    if (paragraphs.isEmpty) return const [];

    final pages = <BookPage>[];
    final buffer = StringBuffer();
    var startOffset = 0;
    var cursor = 0;

    for (final para in paragraphs) {
      final candidate =
          buffer.isEmpty ? para.text : '${buffer.toString()}${para.text}';

      // A single paragraph longer than the limit gets hard-split by sentence
      // so a wall of text cannot produce one gigantic page.
      if (para.text.length > limit && buffer.isEmpty) {
        for (final chunk in _splitLongParagraph(para.text, limit)) {
          pages.add(BookPage(
            index: pages.length,
            content: chunk,
            startOffset: cursor,
          ));
          cursor += chunk.length;
        }
        continue;
      }

      if (candidate.length > limit && buffer.isNotEmpty) {
        // Flush what we have, then start the new paragraph on a fresh page.
        final content = buffer.toString();
        pages.add(BookPage(
          index: pages.length,
          content: content,
          startOffset: startOffset,
        ));
        cursor = startOffset + content.length;
        startOffset = cursor;
        buffer.clear();
        buffer.write(para.text);
      } else {
        buffer.write(para.text);
      }
    }

    if (buffer.isNotEmpty) {
      final content = buffer.toString();
      pages.add(BookPage(
        index: pages.length,
        content: content,
        startOffset: startOffset,
      ));
    }

    return pages;
  }

  /// 0.0 - 1.0 through the book.
  double progressFor(int pageIndex, int totalPages) {
    if (totalPages <= 1) return totalPages == 1 ? 1.0 : 0.0;
    return (pageIndex / (totalPages - 1)).clamp(0.0, 1.0);
  }

  /// Strips markdown noise so narration does not read out punctuation.
  String toSpeechText(String markdown) {
    return markdown
        .replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => m.group(1) ?? '')
        .replaceAllMapped(RegExp(r'\*([^*]+)\*'), (m) => m.group(1) ?? '')
        .replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1) ?? '')
        .replaceAllMapped(RegExp(r'^#{1,6}\s+', multiLine: true), (_) => '')
        .replaceAllMapped(RegExp(r'!\[[^\]]*\]\([^)]*\)'), (_) => '')
        .replaceAllMapped(
            RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1) ?? '')
        .replaceAllMapped(RegExp(r'^\s*[-*+]\s+', multiLine: true), (_) => '')
        .replaceAllMapped(RegExp(r'^\s*>\s?', multiLine: true), (_) => '')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// Keeps only strictly ascending offsets inside the text. Returns null when
  /// there is nothing usable, so the caller falls back to length-based paging.
  List<int>? _sanitizeBreaks(List<int>? offsets, int length) {
    if (offsets == null || offsets.isEmpty) return null;

    final result = <int>[];
    for (final offset in offsets) {
      if (offset <= 0 || offset >= length) continue;
      if (result.isNotEmpty && offset <= result.last) continue;
      result.add(offset);
    }
    return result.isEmpty ? null : result;
  }

  /// One page per logical block; oversized blocks are cut by sentence.
  List<BookPage> _paginateByBreaks(
      String text, List<int> breaks, int limit) {
    final pages = <BookPage>[];
    final bounds = [0, ...breaks, text.length];

    for (var i = 0; i < bounds.length - 1; i++) {
      final start = bounds[i];
      final end = bounds[i + 1];
      if (end <= start) continue;

      final block = text.substring(start, end).trim();
      if (block.isEmpty) continue;

      if (block.length <= limit) {
        pages.add(BookPage(index: pages.length, content: block, startOffset: start));
        continue;
      }

      for (final chunk in _splitLongParagraph(block, limit)) {
        final trimmed = chunk.trim();
        if (trimmed.isEmpty) continue;
        pages.add(BookPage(
          index: pages.length,
          content: trimmed,
          startOffset: start + block.indexOf(trimmed),
        ));
      }
    }

    return pages;
  }

  /// Returns [cut] adjusted so it never lands inside an inline image marker
  /// (\u0000IMG<n>\u0000) — a marker split across two reader pages would render
  /// as garbage text and the picture would be lost.
  int _safeCut(String s, int cut) {
    if (cut <= 0 || cut >= s.length) return cut;
    final from = (cut - 6).clamp(0, s.length);
    final to = (cut + 8).clamp(0, s.length);
    final m = RegExp(r'\u0000IMG\d+\u0000').firstMatch(s.substring(from, to));
    if (m != null) {
      final start = from + m.start;
      final end = from + m.end;
      if (cut > start && cut < end) return end;
    }
    return cut;
  }

  List<_Paragraph> _splitParagraphs(String text) {
    final result = <_Paragraph>[];
    final regex = RegExp(r'[^\n]*(?:\n+|$)');
    for (final match in regex.allMatches(text)) {
      final raw = match.group(0);
      if (raw == null || raw.isEmpty) continue;
      result.add(_Paragraph(raw));
    }
    return result;
  }

  /// Breaks an over-long paragraph on sentence boundaries where possible,
  /// falling back to a hard cut so progress is always bounded.
  List<String> _splitLongParagraph(String para, int limit) {
    if (para.length <= limit) return [para];

    final chunks = <String>[];
    final buffer = StringBuffer();

    // Sentence terminators for both Latin and CJK punctuation.
    final sentences = para.splitMapped(
      RegExp(r'(?<=[。！？!?.;；])'),
    );

    for (final sentence in sentences) {
      if (buffer.length + sentence.length > limit && buffer.isNotEmpty) {
        chunks.add(buffer.toString());
        buffer.clear();
      }
      // A single sentence longer than the limit must be cut — otherwise a
      // run-on line would produce an unbounded page.
      if (sentence.length > limit) {
        if (buffer.isNotEmpty) {
          chunks.add(buffer.toString());
          buffer.clear();
        }
        var rest = sentence;
        while (rest.length > limit) {
          final cut = _safeCut(rest, limit);
          chunks.add(rest.substring(0, cut));
          rest = rest.substring(cut);
        }
        buffer.write(rest);
      } else {
        buffer.write(sentence);
      }
    }
    if (buffer.isNotEmpty) chunks.add(buffer.toString());
    return chunks.isEmpty ? [para] : chunks;
  }
}

/// Defaults mirrored from [ReaderConfig] so the paginator can run standalone.
class ReaderConfigDefault {
  static const int charsPerPage = 700;
}

class _Paragraph {
  final String text;
  const _Paragraph(this.text);
}

extension _SplitMapped on String {
  /// Splits on [pattern] while keeping the delimiters attached to each piece.
  List<String> splitMapped(Pattern pattern) {
    final parts = <String>[];
    var lastEnd = 0;
    for (final match in pattern.allMatches(this)) {
      final end = match.end;
      if (end > lastEnd) {
        parts.add(substring(lastEnd, end));
        lastEnd = end;
      }
    }
    if (lastEnd < length) parts.add(substring(lastEnd));
    return parts;
  }
}

/// Convenience: paginate a [BookContent] using a [ReaderConfig].
extension PaginateContent on BookContent {
  List<BookPage> pages({int? charsPerPage}) =>
      PaginatorService().paginate(text, charsPerPage: charsPerPage);
}
