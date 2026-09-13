import 'package:flutter/material.dart';

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

  /// Real layout-based pagination.
  ///
  /// Unlike [paginate] (which guesses by character count) this uses a
  /// [TextPainter] with the exact [style], [maxWidth] and [maxHeight] that the
  /// reader surface actually has, so each page fits the screen with no
  /// scrolling — regardless of font size or device density.
  ///
  /// Paragraphs are kept whole where possible; an over-long paragraph is split
  /// on sentence boundaries. When [breakOffsets] is given those boundaries
  /// always start a new page.
  List<BookPage> paginateWithLayout(
    String text, {
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    List<int>? breakOffsets,
  }) {
    if (text.isEmpty || maxHeight <= 0 || maxWidth <= 0) return const [];

    final usableBreaks = _sanitizeBreaks(breakOffsets, text.length);
    if (usableBreaks != null) {
      // Honor logical breaks, but re-flow each block to the real page height.
      final blocks = <String>[];
      final bounds = [0, ...usableBreaks, text.length];
      for (var i = 0; i < bounds.length - 1; i++) {
        final block = text.substring(bounds[i], bounds[i + 1]).trim();
        if (block.isNotEmpty) blocks.add(block);
      }
      return _flowBlocks(blocks, style, maxWidth, maxHeight);
    }

    final paragraphs = _splitParagraphs(text)
        .map((p) => p.text)
        .where((s) => s.trim().isNotEmpty)
        .toList();
    return _flowBlocks(paragraphs, style, maxWidth, maxHeight);
  }

  /// Lays [blocks] (paragraphs) out into pages that never exceed [maxHeight].
  ///
  /// Each paragraph is laid out at most once and the running page height is
  /// tracked, so the whole pass is O(n). A multi-megabyte paragraph is never
  /// measured in one [TextPainter] call (that blocks the UI thread for tens of
  /// seconds and triggers ANR); instead it is estimated and hard-split.
  List<BookPage> _flowBlocks(
    List<String> blocks,
    TextStyle style,
    double maxWidth,
    double maxHeight,
  ) {
    final pages = <BookPage>[];
    final buffer = StringBuffer();
    var startOffset = 0;
    var cursor = 0;
    var used = 0;

    void flush() {
      final content = buffer.toString();
      if (content.trim().isNotEmpty) {
        pages.add(BookPage(
          index: pages.length,
          content: content,
          startOffset: startOffset,
        ));
        cursor = startOffset + content.length;
        startOffset = cursor;
      }
      buffer.clear();
      used = 0;
    }

    // Rough character capacity of one screen. Pagination is done purely by
    // character counting at paragraph boundaries — never by laying every
    // paragraph out with TextPainter. A book split into tens of thousands of
    // paragraphs would otherwise trigger tens of thousands of layout calls and
    // block the UI thread for 15s+ (ANR). Over-long paragraphs are still
    // hard-split without any layout pass.
    final screenChars = _estimateCharsPerScreen(style, maxWidth, maxHeight);

    for (final para in blocks) {
      if (para.length > screenChars) {
        if (used > 0) flush();
        final limit = (screenChars * 0.9).round().clamp(50, 1 << 20);
        for (final chunk in _splitLongParagraph(para, limit)) {
          pages.add(BookPage(
            index: pages.length,
            content: chunk,
            startOffset: cursor,
          ));
          cursor += chunk.length;
        }
        continue;
      }
      if (used > 0 && used + para.length > screenChars) {
        flush();
      }
      buffer.write(para);
      used += para.length;
    }
    flush();
    return pages;
  }

  /// Rough character capacity of one screen, used to avoid laying out huge
  /// paragraphs all at once. A slightly over-estimated bound is fine: paragraphs
  /// judged longer are split, which is always correct.
  static int _estimateCharsPerScreen(
      TextStyle style, double maxWidth, double maxHeight) {
    final fs = style.fontSize ?? 17.0;
    final lh = style.height ?? 1.0;
    final perLine = (maxWidth / fs).ceil().clamp(1, 1 << 20);
    final lines = (maxHeight / (fs * lh)).ceil().clamp(1, 1 << 20);
    return perLine * lines;
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
  ///
  /// Cutting walks the paragraph by index (never repeatedly re-slicing the
  /// whole tail) so a million-character paragraph costs O(n), not O(n^2).
  List<String> _splitLongParagraph(String para, int limit) {
    if (para.length <= limit) return [para];

    final chunks = <String>[];

    // A very large paragraph is stream-cut by index directly — running a
    // regex allMatches over a million characters is needlessly slow and the
    // sentence boundaries are meaningless there. O(n), no regex.
    if (para.length > 20000) {
      var i = 0;
      final n = para.length;
      while (i < n) {
        var end = (i + limit < n) ? i + limit : n;
        end = _safeCut(para, end);
        chunks.add(para.substring(i, end));
        i = end;
      }
      return chunks;
    }

    // Smaller paragraphs: cut on sentence boundaries where possible to keep
    // reading natural, falling back to an index stream so cost stays O(n).
    final buffer = StringBuffer();
    final sentences = para.splitMapped(
      RegExp(r'(?<=[。！？!?.;；])'),
    );

    for (final sentence in sentences) {
      if (sentence.isEmpty) continue;
      if (buffer.isNotEmpty && buffer.length + sentence.length > limit) {
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
        // Stream through the sentence by index so we copy O(n) characters total
        // instead of re-slicing a shrinking tail on every loop iteration.
        var i = 0;
        final n = sentence.length;
        while (i < n) {
          var end = (i + limit < n) ? i + limit : n;
          end = _safeCut(sentence, end);
          chunks.add(sentence.substring(i, end));
          i = end;
        }
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
