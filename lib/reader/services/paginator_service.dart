import 'dart:isolate';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/chapter_page_info.dart';
import '../models/reader_config.dart';
import 'text_break_utils.dart';

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
        // Preserve leading indentation; only drop a leading line break.
        final block = _preserveIndent(text.substring(bounds[i], bounds[i + 1]));
        if (block.trimRight().isNotEmpty) blocks.add(block);
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
    // Line-level flow: each page is filled with as many rendered lines as
    // actually fit, so paragraphs continue across page breaks instead of
    // being pushed wholesale to the next page (which left half-empty pages
    // whenever short paragraphs clustered together).
    final fullPages = _paginateChapterTextByLines(
      chapterText,
      style,
      maxWidth,
      maxHeight,
      chapterStartOffset,
      initialBatch: initialBatch,
    );
    final nonFullPages = _paginateChapterTextByLines(
      chapterText,
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

  /// Precise, measurement-based pagination of one chapter's text.
  ///
  /// Each page is filled by laying out the text with [TextPainter] at the exact
  /// rendering width and binary-searching the largest character offset whose
  /// measured height does not exceed [maxHeight]. The next character would
  /// overflow, so every page is filled to the pixel with no wasted space — and
  /// because the same [TextPainter] configuration is used for measuring and for
  /// rendering, a page never overflows or underfills regardless of CJK metrics,
  /// justification, or line-height quirks. Paragraphs (and even individual
  /// sentences, thanks to [_splitSentences]) continue across the break instead
  /// of jumping wholesale.
  ///
  /// Each page's [PageEntry.startOffset] is the page's first character in the
  /// full book text; the page content is the source range up to the next page's
  /// start, so characters are never dropped or duplicated.
  /// Whether [code] is whitespace that can lead a paragraph and therefore must
  /// stay attached to the text that follows it: ASCII space/tab, non-breaking
  /// space, and the ideographic (full-width) space U+3000 used for Chinese
  /// first-line indentation.
  bool _isPageWs(int code) =>
      code == 0x20 || code == 0x09 || code == 0x00A0 || code == 0x3000;

  List<PageEntry> _paginateChapterTextByLines(
    String chapterText,
    TextStyle style,
    double maxWidth,
    double maxHeight,
    int baseOffset, {
    int initialBatch = -1,
  }) {
    final pages = <PageEntry>[];
    if (chapterText.isEmpty || maxHeight <= 0 || maxWidth <= 0) return pages;
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: null,
      textAlign: TextAlign.justify,
      textHeightBehavior: TextHeightBehavior(
        applyHeightToFirstAscent: true,
        applyHeightToLastDescent: true,
      ),
    );

    final fs = style.fontSize ?? 17.0;
    final lh = style.height ?? 1.0;
    // Rough per-page character capacity, used only to seed the binary search.
    final estChars =
        ((maxHeight / (fs * lh)) * (maxWidth / fs) * 1.5).round().clamp(1, 1 << 20);
    final n = chapterText.length;

    var pos = 0;
    while (pos < n) {
      if (initialBatch > 0 && pages.length >= initialBatch) break;

      var lo = pos;
      var hi = (pos + estChars).clamp(pos, n);
      while (lo < hi) {
        final mid = (lo + hi + 1) ~/ 2;
        painter.text = TextSpan(
          text: chapterText.substring(pos, mid),
          style: style,
        );
        painter.layout(maxWidth: maxWidth);
        if (painter.height <= maxHeight) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      // Absorb any under-estimate from estChars (a few chars at most).
      while (lo < n) {
        painter.text = TextSpan(
          text: chapterText.substring(pos, lo + 1),
          style: style,
        );
        painter.layout(maxWidth: maxWidth);
        if (painter.height <= maxHeight) {
          lo++;
        } else {
          break;
        }
      }
      // Fill every page to the brim. The binary search above already found the
      // largest offset whose rendered height fits [maxHeight]; we keep [lo] at
      // exactly that point and let the next page continue from the cut — so a
      // paragraph is split at its tail (mid-sentence if necessary) instead of
      // being pushed wholesale to the next page, which used to leave the current
      // page half-empty. The leading-char guard below still ensures the *next*
      // page never opens with a lone closing quote/bracket.
      if (lo <= pos) lo = pos + 1; // guarantee forward progress

      // Keep a paragraph's leading whitespace (indent, e.g. the two full-width
      // spaces "　　" before a Chinese paragraph) attached to the text that
      // follows it. If the cut landed right before a non-space character whose
      // immediate predecessor is whitespace, pulling the whitespace run back
      // into the *next* page stops it from being orphaned as invisible trailing
      // space at the end of this page (which would make the next page open
      // without its indent). We never cross a newline, so we don't yank a
      // paragraph break back with it. The previous page ([pos, lo)) is a strict
      // subset of what we already measured to fit, so it still fits.
      if (lo < n &&
          !_isPageWs(chapterText.codeUnitAt(lo)) &&
          _isPageWs(chapterText.codeUnitAt(lo - 1))) {
        var k = lo;
        while (k > pos &&
            _isPageWs(chapterText.codeUnitAt(k - 1)) &&
            chapterText.codeUnitAt(k - 1) != 0x0A &&
            chapterText.codeUnitAt(k - 1) != 0x0D) {
          k--;
        }
        if (k > pos) lo = k;
      }

      // A page must never BEGIN with a character forbidden at line start
      // (closing quotes/brackets). If the cut landed right before one — e.g.
      // “…什么吧？” — absorb it into this page so the next page doesn't open
      // with a lone ”. Kept only when the extra character(s) still fit.
      if (lo < n && kLineStartForbidden.contains(chapterText[lo])) {
        var end = lo;
        while (end < n && kLineStartForbidden.contains(chapterText[end])) {
          end++;
        }
        painter.text = TextSpan(
          text: chapterText.substring(pos, end),
          style: style,
        );
        painter.layout(maxWidth: maxWidth);
        if (painter.height <= maxHeight) lo = end;
      }

      pages.add(PageEntry(
        pageIndex: pages.length,
        startOffset: baseOffset + pos,
      ));
      pos = lo;
      // Drop the paragraph separator that now sits at the page boundary so
      // the next page starts with real text instead of a blank first line.
      while (pos < n &&
          (chapterText[pos] == '\n' || chapterText[pos] == '\r')) {
        pos++;
      }
    }
    return pages;
  }

  /// Exact, measurement-based pagination of the whole book.
  ///
  /// The book is split into chapters ([chapters], usually from [scanChapters])
  /// and each chapter is flowed with [_paginateChapterTextByLines], so every
  /// page is filled to the pixel and each chapter starts on a fresh page. This
  /// is the single source of truth used by the reader surface — it replaces the
  /// old character-count heuristic that left half-empty pages.
  List<PageEntry> paginateBookExact(
    String text, {
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    List<ChapterRange>? chapters,
    int initialBatch = -1,
  }) {
    final ranges = (chapters != null && chapters.isNotEmpty)
        ? chapters
        : [ChapterRange(startOffset: 0, endOffset: text.length)];
    // When only an opening batch is requested, compute one extra page boundary
    // so the batch's last page still knows where it ends — otherwise it would
    // swallow the entire rest of the chapter.
    final batch = initialBatch > 0 ? initialBatch + 1 : -1;
    final out = <PageEntry>[];
    for (final r in ranges) {
      final chapterText = text.substring(r.startOffset, r.endOffset);
      out.addAll(_paginateChapterTextByLines(
        chapterText,
        style,
        maxWidth,
        maxHeight,
        r.startOffset,
        initialBatch: batch,
      ));
    }
    return out;
  }

  /// Runs [paginateBookExact] in a background isolate.
  static Future<List<PageEntry>> paginateBookExactIsolate(
    String text, {
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    List<ChapterRange>? chapters,
    int initialBatch = -1,
  }) async {
    // Deliberately NOT Isolate.run: TextPainter is a UI API and throws
    // "UI actions are only available on root isolate" when used from a
    // background isolate. Pagination therefore runs on the root isolate and is
    // kept cheap by paginating one chapter's opening batch at a time.
    return PaginatorService().paginateBookExact(
      text,
      style: style,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      chapters: chapters,
      initialBatch: initialBatch,
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
    // TextPainter is UI-only: it cannot run in a background isolate
    // ("UI actions are only available on root isolate"), so paginate here.
    return _paginateInIsolate(params);
  }

  /// Lays [blocks] (paragraphs) out into pages that never exceed [maxHeight].
  ///
  /// Each block is measured with [TextPainter] to get its real rendered height.
  /// A block that fits the space left on the current page is appended whole; a
  /// block that does not fit is cut from its tail (at a sentence boundary) so the
  /// current page is filled, and the remainder plus following blocks continue on
  /// the next page. Over-long blocks are split by height so each piece fits the
  /// available height exactly.
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
      final raw = buffer.toString();
      // Trim only *trailing* whitespace for display, so a page never closes with
      // a blank line (the buffer ends in the last paragraph's trailing \n+).
      // Leading spaces (paragraph indentation) and inter-paragraph blank lines
      // are preserved. The source offset still advances by the raw length so
      // page startOffsets stay continuous across pages.
      final content = raw.replaceAll(RegExp(r'[ \t\r\n]+$'), '');
      if (content.isNotEmpty) {
        pages.add(BookPage(
          index: pages.length,
          content: content,
          startOffset: startOffset,
        ));
        cursor = startOffset + raw.length;
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

    for (final block in blocks) {
      var text = block;
      // A single logical block may span several pages: keep cutting from its tail
      // until the whole block has been laid out.
      while (text.isNotEmpty) {
        final h = measureHeight(text);

        // Whole remaining text fits in the space left on the current page (or the
        // page is still empty) — append it as-is.
        if (usedHeight + h <= maxHeight) {
          buffer.write(text);
          usedHeight += h;
          text = '';
          continue;
        }

        // Page is empty but this single block is taller than a full page on its
        // own — split it by height and stream its pieces in.
        if (usedHeight == 0) {
          for (final chunk in _splitLongParagraphByHeight(text, style, maxWidth, maxHeight)) {
            final ch = measureHeight(chunk);
            if (usedHeight > 0 && usedHeight + ch > maxHeight) flush();
            buffer.write(chunk);
            usedHeight += ch;
          }
          text = '';
          continue;
        }

        // Block won't fit in the remaining space: keep as much of it as fits on
        // the current page (cut from the tail at a sentence boundary) and push the
        // rest to the next page — so the page is filled instead of left half-empty.
        final availH = maxHeight - usedHeight;
        final cut = _splitLongParagraphByHeight(text, style, maxWidth, availH * 0.95);
        final prefix = cut.first;
        buffer.write(prefix);
        usedHeight += measureHeight(prefix);
        flush();
        text = cut.length > 1 ? cut.sublist(1).join('') : '';
      }
    }
    flush();
    return pages;
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

  /// Drops only leading line breaks so a page never opens with a blank line,
  /// while preserving intentional leading spaces (paragraph indentation).
  String _preserveIndent(String s) {
    var i = 0;
    while (i < s.length && (s.codeUnitAt(i) == 0x0A || s.codeUnitAt(i) == 0x0D)) {
      i++;
    }
    return i == 0 ? s : s.substring(i);
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
  ///
  /// Each break offset forces a new page, so chapter headings (when chapter
  /// offsets are passed as breaks) always land at the top of a page — the
  /// reader's jump-to-chapter then shows the heading at the screen top instead
  /// of burying it mid-page.
  ///
  /// Page start offsets are tracked with a running cursor (not by re-searching
  /// the chunk inside the block, which is buggy when a trimmed chunk appears
  /// more than once), so [BookPage.startOffset] always matches the real
  /// character position in the source text.
  List<BookPage> _paginateByBreaks(
      String text, List<int> breaks, int limit) {
    final pages = <BookPage>[];
    final bounds = [0, ...breaks, text.length];

    for (var i = 0; i < bounds.length - 1; i++) {
      final start = bounds[i];
      final end = bounds[i + 1];
      if (end <= start) continue;

      // Keep leading spaces (paragraph indentation) but drop leading line
      // breaks so a page never opens with a blank line.
      final block = text.substring(start, end);
      final kept = _preserveIndent(block);
      if (kept.trimRight().isEmpty) continue;

      if (kept.length <= limit) {
        pages.add(BookPage(
            index: pages.length,
            content: kept.replaceAll(RegExp(r'[ \t\r\n]+$'), ''),
            startOffset: start));
        continue;
      }

      // Stream-cut the block so each page's startOffset is exact. Leading
      // indentation is preserved in the content, so startOffset points at the
      // real character that the page begins with.
      var cursor = start;
      for (final chunk in _splitLongParagraph(block, limit)) {
        final kc = _preserveIndent(chunk);
        if (kc.trimRight().isEmpty) {
          cursor += chunk.length;
          continue;
        }
        pages.add(BookPage(
            index: pages.length,
            content: kc.replaceAll(RegExp(r'[ \t\r\n]+$'), ''),
            startOffset: cursor));
        cursor += chunk.length;
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

    final sentences = _splitSentences(para);

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

  /// Splits [text] into sentence-like pieces on CJK/Latin terminal
  /// punctuation ([。！？!?.;；]), but keeps any closing quote that immediately
  /// follows the punctuation attached to the current piece.
  ///
  /// Without this, a closing quote right after a terminal mark — e.g. the "
  /// after ？ in “……？” — would be treated as the start of the *next* piece.
  /// The paginator could then place ？ at the bottom of one page and the
  /// orphaned " at the top of the next, visually breaking the quotation.
  List<String> _splitSentences(String text) {
    if (text.isEmpty) return const [];
    final result = <String>[];
    var lastEnd = 0;
    const terminators = '。！？!?.;；';
    const closingQuotes = {'"', '”', '’', '\'', '』', '」'};
    for (var i = 0; i < text.length; i++) {
      if (!terminators.contains(text[i])) continue;
      var end = i + 1;
      while (end < text.length && closingQuotes.contains(text[end])) {
        end++;
      }
      if (end > lastEnd) {
        result.add(text.substring(lastEnd, end));
        lastEnd = end;
      }
    }
    if (lastEnd < text.length) result.add(text.substring(lastEnd));
    return result.isEmpty ? [text] : result;
  }

  List<_Paragraph> _splitParagraphs(String text) {
    final result = <_Paragraph>[];
    final regex = RegExp(r'[^\n]*(?:\n+|$)');
    for (final match in regex.allMatches(text)) {
      final raw = match.group(0);
      if (raw == null || raw.isEmpty) continue;
      result.add(_Paragraph(raw, match.start));
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
    final sentences = _splitSentences(para);

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

  /// Offset of this paragraph within the text it was split from.
  final int offset;
  const _Paragraph(this.text, [this.offset = 0]);
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
