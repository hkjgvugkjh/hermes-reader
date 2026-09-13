/// A chapter heading found while scanning a book's full text.
class ChapterMark {
  /// Human-readable heading, e.g. "第一章 青衫磊落险峰行".
  final String title;

  /// Character offset of the heading in the book's full text, so it can be
  /// mapped onto a paginated page later.
  final int offset;

  const ChapterMark({required this.title, required this.offset});
}

/// Scans plain text for chapter/section headings.
///
/// Detection is deliberately conservative: a line only counts as a heading when
/// it begins with a recognizable marker (第N章, Chapter N, 1. …, 序, …) and is
/// short. Ordinary body paragraphs that merely start with "第" are ignored, so
/// a long novel is not chopped into thousands of fake chapters.
class ChapterDetector {
  /// Patterns that recognizably begin a heading at the start of a line.
  static final List<RegExp> _linePatterns = [
    // 第一章 / 第12章 / 第十二回 / 第叁卷 …
    // 数字与"章/回"之间、以及标题前允许半角/全角空格或制表符。
    RegExp(r'^第[ \t　]*[0-9零一二三四五六七八九十百千〇两]+[ \t　]*[章卷回节部篇集幕话][ \t　]*(.*)$'),
    // Chapter 1 / CHAPTER ONE / Volume 2 / Section 3
    RegExp(
      r'^(chapter|volume|section|part|vol|book)\s+'
      r'([0-9]+|[ivxlcdmIVXLCDM]+|[一二三四五六七八九十百千]+)'
      r'\s*[:.、\-]?\s*(.*)$',
      caseSensitive: false,
    ),
    // 1. Title / 12、 Title (numeral followed by a separator)
    RegExp(r'^([0-9]+|[一二三四五六七八九十百千]+)\s*[.、)）]\s*(.+)$'),
    // (1) Title / （一） Title
    RegExp(r'^[（(]\s*([0-9]+|[一二三四五六七八九十百千]+)\s*[）)]\s*(.+)$'),
    // 序 / 前言 / 楔子 / 引子 / 番外 / 后记 / 尾声 / 附录 / 终章 / 外传 / 题记 / 跋
    RegExp(
      r'^(序|序言|前言|楔子|引子|番外|后记|尾声|附录|终章|外传|题记|跋)'
      r'\s*(.*)$',
    ),
  ];

  /// Detects chapter headings in [text] and returns them in document order.
  ///
  /// Headings are matched by character offset so the caller can jump straight
  /// to the right page. When fewer than two headings are found the book is
  /// treated as un-chaptered and an empty list is returned, leaving the caller
  /// to fall back to plain page-jumping.
  static List<ChapterMark> detect(String text) {
    if (text.isEmpty) return const [];

    final result = <ChapterMark>[];
    // Maps a normalized (whitespace-free) title to its index in [result] so a
    // table-of-contents near the front doesn't shadow the real heading: the
    // later, genuine occurrence wins.
    final seen = <String, int>{};

    final lines = text.split('\n');
    var offset = 0;
    for (final raw in lines) {
      final lineStart = offset;
      offset += raw.length + 1; // +1 for the '\n' consumed by split

      // Strip leading indentation (spaces / full-width spaces / tabs) that some
      // TXT exports add even to chapter headings, then trim.
      final dedented = raw.replaceFirst(RegExp(r'^\s*'), '').trim();
      if (dedented.isEmpty) continue;
      // Headings are short — but allow a little trailing body text that some
      // exports glue onto the heading line by only considering the leading
      // portion when matching.
      if (dedented.length > 60) continue;

      final cleaned = dedented.replaceAll(RegExp(r'^[*\-=·#]+'), '').trim();
      if (cleaned.isEmpty) continue;

      final title = _matchHeading(cleaned);
      if (title == null) continue;

      final key = title.replaceAll(RegExp(r'\s+'), '');
      final existing = seen[key];
      if (existing != null) {
        // Keep one entry per title, pointing at the later (real) occurrence.
        result[existing] = ChapterMark(title: title, offset: lineStart);
      } else {
        seen[key] = result.length;
        result.add(ChapterMark(title: title, offset: lineStart));
      }
    }

    // 单章也返回(至少能跳转); 没有则返回空(调用方回退到普通翻页)。
    return result;
  }

  /// Returns the heading title for [line] (which must already be trimmed and
  /// stripped of decorative punctuation), or null when it is not a heading.
  static String? _matchHeading(String line) {
    for (final re in _linePatterns) {
      final m = re.firstMatch(line);
      if (m == null) continue;

      String? trailing;
      for (var i = m.groupCount; i >= 1; i--) {
        final g = m.group(i);
        if (g != null && g.trim().isNotEmpty) {
          trailing = g.trim();
          break;
        }
      }

      final leading = m.group(0)!.trim();
      // When the trailing title already appears inside the matched heading,
      // keep the heading as-is; otherwise append it (rare separator gaps).
      if (trailing != null && !leading.endsWith(trailing)) {
        return '$leading $trailing'.trim();
      }
      return leading;
    }
    return null;
  }
}
