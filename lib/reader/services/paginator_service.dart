import 'dart:isolate';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/chapter_page_info.dart';
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

  /// Paginates a single chapter (identified by [chapterIndex]) starting from
  /// [chapterStartOffset] in the full book [text].
  ///
  /// Computes pages in both fullscreen ([maxHeight]) and non-fullscreen
  /// ([maxHeight] reduced by app-bar + footer) modes simultaneously. The
  /// result is stored as [ChapterPageInfo] with parallel page lists.
  ///
  /// [chapterEndOffset] is the start of the next chapter (or text.length for
  /// the last chapter). Only the range [chapterStartOffset, chapterEndOffset)
  /// is paginated.
  ///
  /// [initialBatch] controls how many pages are computed on the first call.
  /// Pass [initialBatch] = 5 for the opening batch; subsequent incremental
  /// calls should pass [initialBatch] = -1 to compute all remaining pages.
  ChapterPageInfo paginateChapter(
    String text, {
    required int chapterIndex,
    required String chapterTitle,
    required int chapterStartOffset,
    required int chapterEndOffset,
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    required double nonFullscreenMaxHeight,
    int initialBatch = 5,
  }) {
    final chapterLen = chapterEndOffset - chapterStartOffset;
    if (chapterLen <= 0 || text.isEmpty) {
      return ChapterPageInfo(
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
        startOffset: chapterStartOffset,
        fullScreenPages: const [],
        notFullScreenPages: const [],
      );
    }

    final chapterText = text.substring(chapterStartOffset, chapterEndOffset);
    final fullPages = _flowBlocksWithOffsets(
      _splitParagraphs(chapterText).map((p) => p.text).where((s) => s.trim().isNotEmpty).toList(),
      style,
      maxWidth,
      maxHeight,
      chapterStartOffset,
      initialBatch: initialBatch,
    );
    final nonFullPages = _flowBlocksWithOffsets(
      _splitParagraphs(chapterText).map((p) => p.text).where((s) => s.trim().isNotEmpty).toList(),
      style,
      maxWidth,
      nonFullscreenMaxHeight,
      chapterStartOffset,
      initialBatch: initialBatch,
    );

    return ChapterPageInfo(
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      startOffset: chapterStartOffset,
      fullScreenPages: fullPages,
      notFullScreenPages: nonFullPages,
    );
  }

  /// Runs [paginateChapter] in a background isolate.
  static Future<ChapterPageInfo> paginateChapterIsolate(
    String text, {
    required int chapterIndex,
    required String chapterTitle,
    required int chapterStartOffset,
    required int chapterEndOffset,
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    required double nonFullscreenMaxHeight,
    int initialBatch = 5,
  }) async {
    final params = _ChapterIsolateParams(
      text: text,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      chapterStartOffset: chapterStartOffset,
      chapterEndOffset: chapterEndOffset,
      fontSize: style.fontSize ?? 17,
      heightFactor: style.height ?? 1.0,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      nonFullscreenMaxHeight: nonFullscreenMaxHeight,
      initialBatch: initialBatch,
    );
    return Isolate.run(() => _paginateChapterInIsolate(params));
  }

  /// Full-book chapter scan: returns each chapter's offset range.
  ///
  /// Uses [breakOffsets] when available (PDF page boundaries, EPUB chapters).
  /// When no break offsets exist, falls back to a simple heading scan on the
  /// text. The returned list always starts with offset 0 and each entry is
  /// strictly ascending.
  List<ChapterRange> scanChapters(String text, {List<int>? breakOffsets}) {
    final ranges = <ChapterRange>[];
    if (text.isEmpty) return ranges;

    if (breakOffsets != null && breakOffsets.isNotEmpty) {
      final sorted = breakOffsets.where((o) => o > 0 && o < text.length).toList()..sort();
      var prev = 0;
      for (final off in sorted) {
        if (off > prev) {
          ranges.add(ChapterRange(startOffset: prev, endOffset: off));
        }
        prev = off;
      }
      if (prev < text.length) {
        ranges.add(ChapterRange(startOffset: prev, endOffset: text.length));
      }
      return ranges;
    }

    // Fallback: scan for markdown-style headings (lines starting with #)
    final lines = text.split('\n');
    var offset = 0;
    var chapterStart = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#') && i > 0) {
        ranges.add(ChapterRange(startOffset: chapterStart, endOffset: offset));
        chapterStart = offset;
      }
      offset += line.length + 1; // +1 for the \n
    }
    if (chapterStart < text.length) {
      ranges.add(ChapterRange(startOffset: chapterStart, endOffset: text.length));
    }
    return ranges;
  }

  /// Flows paragraphs into pages that never exceed [maxHeight], returning
  /// each page's offset relative to the full book text.
  ///
  /// When [initialBatch] > 0, only the first [initialBatch] pages are
  /// computed and the remaining text is ignored (for fast first-open).
  List<PageEntry> _flowBlocksWithOffsets(
    List<String> blocks,
    TextStyle style,
    double maxWidth,
    double maxHeight,
    int baseOffset, {
    int initialBatch = -1,
  }) {
    final pages = <PageEntry>[];
    final buffer = StringBuffer();
    var startOffset = 0;
    var usedHeight = 0.0;

    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: null,
      textAlign: TextAlign.justify,
      textHeightBehavior: TextHeightBehavior(
        applyHeightToFirstAscent: true,
        applyHeightToLastDescent: true,
      ),
    );

    void flush() {
      final content = buffer.toString();
      if (content.trim().isNotEmpty) {
        pages.add(PageEntry(
          pageIndex: pages.length,
          startOffset: baseOffset + startOffset,
        ));
        startOffset += content.length;
      }
      buffer.clear();
      usedHeight = 0.0;
    }

    double measureHeight(String text) {
      painter.text = TextSpan(text: text, style: style);
      painter.layout(maxWidth: maxWidth);
      return painter.height;
    }

    for (final para in blocks) {
      if (initialBatch > 0 && pages.length >= initialBatch) break;

      final paraHeight = measureHeight(para);

      if (usedHeight + paraHeight <= maxHeight && usedHeight > 0) {
        buffer.write(para);
        usedHeight += paraHeight;
        continue;
      }

      if (usedHeight > 0) flush();

      if (paraHeight <= maxHeight) {
        buffer.write(para);
        usedHeight = paraHeight;
        continue;
      }

      final limit = (maxHeight * 0.95);
      for (final chunk in _splitLongParagraphByHeight(para, style, maxWidth, limit)) {
        if (initialBatch > 0 && pages.length >= initialBatch) break;
        final chunkHeight = measureHeight(chunk);
        if (usedHeight > 0 && usedHeight + chunkHeight > maxHeight) {
          flush();
        }
        buffer.write(chunk);
        usedHeight += chunkHeight;
      }
    }
    flush();
    return pages;
  }

  /// Runs [paginateWithLayout] in a background isolate.
  ///
  /// [paginateWithLayout] calls [TextPainter.layout] for every paragraph —
  /// which can take several seconds for large books (tens of thousands of
  /// paragraphs). Running it on the UI thread causes jank and ANR. This
  /// method offloads the work to a background isolate and returns the
  /// computed pages.
  ///
  /// [TextStyle] cannot be sent across isolate boundaries directly, so its
  /// parameters are packed into a map and rebuilt inside the worker isolate.
  static Future<List<BookPage>> paginateWithLayoutIsolate(
    String text, {
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    List<int>? breakOffsets,
  }) async {
    final params = _IsolateParams(
      text: text,
      fontSize: style.fontSize ?? 17,
      heightFactor: style.height ?? 1.0,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      breakOffsets: breakOffsets,
    );
    return Isolate.run(() => _paginateInIsolate(params));
  }

  /// Lays [blocks] (paragraphs) out into pages that never exceed [maxHeight].
  ///
  /// Each paragraph is measured with [TextPainter] to get its real rendered
  /// height. A page is flushed when adding the next paragraph would overflow
  /// [maxHeight]. Over-long paragraphs are split by line ranges so each piece
  /// fits the available height exactly.
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
    var usedHeight = 0.0;

    // Reusable painter — never recreated inside the loop.
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: null,
      textAlign: TextAlign.justify,
      textHeightBehavior: TextHeightBehavior(
        applyHeightToFirstAscent: true,
        applyHeightToLastDescent: true,
      ),
    );

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
      usedHeight = 0.0;
    }

    /// Measures the actual rendered height of [text] at [maxWidth].
    double measureHeight(String text) {
      painter.text = TextSpan(text: text, style: style);
      painter.layout(maxWidth: maxWidth);
      return painter.height;
    }

    for (final para in blocks) {
      final paraHeight = measureHeight(para);

      // Paragraph fits on current page — append it.
      if (usedHeight + paraHeight <= maxHeight && usedHeight > 0) {
        buffer.write(para);
        usedHeight += paraHeight;
        continue;
      }

      // Current page has content and this paragraph won't fit — flush first.
      if (usedHeight > 0) flush();

      // Paragraph fits on a fresh page — start a new page with it.
      if (paraHeight <= maxHeight) {
        buffer.write(para);
        usedHeight = paraHeight;
        continue;
      }

      // Over-long paragraph: split by sentence boundaries, measuring each
      // candidate page with TextPainter so the break point is exact.
      final limit = (maxHeight * 0.95);
      for (final chunk in _splitLongParagraphByHeight(para, style, maxWidth, limit)) {
        final chunkHeight = measureHeight(chunk);
        if (usedHeight > 0 && usedHeight + chunkHeight > maxHeight) {
          flush();
        }
        buffer.write(chunk);
        usedHeight += chunkHeight;
      }
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

  /// Splits an over-long paragraph into chunks that each fit within
  /// [maxHeight] when rendered at [style] and [maxWidth].
  ///
  /// Sentences are accumulated and measured with [TextPainter] so the break
  /// point is exact — not estimated by character count. A very large paragraph
  /// is estimated and hard-split to avoid O(n) layout calls.
  List<String> _splitLongParagraphByHeight(
    String para,
    TextStyle style,
    double maxWidth,
    double maxHeight,
  ) {
    // Very large paragraphs: estimate by character ratio to avoid O(n) layout.
    // A rough cut is acceptable — the reader will re-paginate on next open.
    if (para.length > 20000) {
      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(text: para, style: style),
      )..layout(maxWidth: maxWidth);
      final lineHeight = painter.height / painter.computeLineMetrics().length;
      final linesPerPage = (maxHeight / lineHeight).floor().clamp(1, 1 << 20);
      final charLimit = (para.length * linesPerPage /
              painter.computeLineMetrics().length)
          .round()
          .clamp(50, 1 << 20);
      return _splitLongParagraph(para, charLimit);
    }

    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: null,
      textAlign: TextAlign.justify,
      textHeightBehavior: TextHeightBehavior(
        applyHeightToFirstAscent: true,
        applyHeightToLastDescent: true,
      ),
    );

    double measure(String text) {
      painter.text = TextSpan(text: text, style: style);
      painter.layout(maxWidth: maxWidth);
      return painter.height;
    }

    final sentences = para.splitMapped(
      RegExp(r'(?<=[。！？!?.;；])'),
    );

    final chunks = <String>[];
    final buffer = StringBuffer();
    var usedHeight = 0.0;

    for (final sentence in sentences) {
      if (sentence.isEmpty) continue;
      final sentenceHeight = measure(sentence);

      // Single sentence taller than a page — hard-split by character ratio.
      if (sentenceHeight > maxHeight) {
        if (buffer.isNotEmpty) {
          chunks.add(buffer.toString());
          buffer.clear();
          usedHeight = 0;
        }
        final ratio = maxHeight / sentenceHeight;
        final charLimit =
            (sentence.length * ratio * 0.95).round().clamp(50, 1 << 20);
        for (final piece in _splitLongParagraph(sentence, charLimit)) {
          chunks.add(piece);
        }
        continue;
      }

      // Adding this sentence would overflow — flush the current page.
      if (usedHeight > 0 && usedHeight + sentenceHeight > maxHeight) {
        chunks.add(buffer.toString());
        buffer.clear();
        usedHeight = 0;
      }

      buffer.write(sentence);
      usedHeight += sentenceHeight;
    }

    if (buffer.isNotEmpty) chunks.add(buffer.toString());
    return chunks.isEmpty ? [para] : chunks;
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

/// Chapter offset range within the full book text.
class ChapterRange {
  final int startOffset;
  final int endOffset;

  const ChapterRange({
    required this.startOffset,
    required this.endOffset,
  });
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

/// Parameters for isolate-based pagination.
class _IsolateParams {
  final String text;
  final double fontSize;
  final double heightFactor;
  final double maxWidth;
  final double maxHeight;
  final List<int>? breakOffsets;

  const _IsolateParams({
    required this.text,
    required this.fontSize,
    required this.heightFactor,
    required this.maxWidth,
    required this.maxHeight,
    this.breakOffsets,
  });
}

/// Top-level function that runs inside the worker isolate.
List<BookPage> _paginateInIsolate(_IsolateParams params) {
  final style = TextStyle(
    fontSize: params.fontSize,
    height: params.heightFactor,
  );
  return PaginatorService().paginateWithLayout(
    params.text,
    style: style,
    maxWidth: params.maxWidth,
    maxHeight: params.maxHeight,
    breakOffsets: params.breakOffsets,
  );
}

/// Parameters for isolate-based chapter pagination.
class _ChapterIsolateParams {
  final String text;
  final int chapterIndex;
  final String chapterTitle;
  final int chapterStartOffset;
  final int chapterEndOffset;
  final double fontSize;
  final double heightFactor;
  final double maxWidth;
  final double maxHeight;
  final double nonFullscreenMaxHeight;
  final int initialBatch;

  const _ChapterIsolateParams({
    required this.text,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.chapterStartOffset,
    required this.chapterEndOffset,
    required this.fontSize,
    required this.heightFactor,
    required this.maxWidth,
    required this.maxHeight,
    required this.nonFullscreenMaxHeight,
    required this.initialBatch,
  });
}

/// Top-level function that runs inside the worker isolate.
ChapterPageInfo _paginateChapterInIsolate(_ChapterIsolateParams params) {
  final style = TextStyle(
    fontSize: params.fontSize,
    height: params.heightFactor,
  );
  return PaginatorService().paginateChapter(
    params.text,
    chapterIndex: params.chapterIndex,
    chapterTitle: params.chapterTitle,
    chapterStartOffset: params.chapterStartOffset,
    chapterEndOffset: params.chapterEndOffset,
    style: style,
    maxWidth: params.maxWidth,
    maxHeight: params.maxHeight,
    nonFullscreenMaxHeight: params.nonFullscreenMaxHeight,
    initialBatch: params.initialBatch,
  );
}
