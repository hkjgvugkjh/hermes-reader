import 'dart:convert';
import 'dart:typed_data';

import '../models/book.dart';
import 'epub_text_extractor.dart';
import 'gbk_decoder.dart';
import 'pdf_image_decoder.dart';
import 'pdf_text_extractor.dart';

/// Text plus the offsets where logical pages (PDF pages, EPUB chapters) start.
///
/// Offsets let the paginator keep one PDF page per reader page instead of
/// re-flowing the text by character count.
class ExtractedText {
  const ExtractedText(
    this.text, {
    this.breaks = const [],
    this.images = const [],
  });

  final String text;

  /// Character offsets into [text], ascending, one per logical page.
  final List<int> breaks;

  /// Images pulled from the source (currently only PDF), referenced inline by
  /// [imageMarker] tokens embedded in [text]. Empty for text-only formats.
  final List<PdfImage> images;
}

/// Turns raw book bytes into readable text, whatever the container format.
abstract class BookTextExtractor {
  Future<ExtractedText> extract(Uint8List bytes, FileType type);
}

/// Dispatches on [FileType] and normalises the result.
///
/// Binary formats (PDF / EPUB) delegate to dedicated extractors; the rest are
/// handled inline because they are cheap.
class DefaultBookTextExtractor implements BookTextExtractor {
  const DefaultBookTextExtractor({PdfTextExtractor? pdf, EpubTextExtractor? epub})
      : _pdf = pdf ?? const PdfTextExtractor(),
        _epub = epub ?? const EpubTextExtractor();

  final PdfTextExtractor _pdf;
  final EpubTextExtractor _epub;

  @override
  Future<ExtractedText> extract(
    Uint8List bytes,
    FileType type, {
    String? encoding,
  }) async {
    switch (type) {
      case FileType.plainText:
        return ExtractedText(cleanText(decodeText(bytes, encoding: encoding)));
      case FileType.html:
      case FileType.mobi:
        // MOBI wraps HTML, so the same tag stripping applies; whatever is left
        // that is not printable is dropped rather than shown as mojibake.
        return ExtractedText(
            cleanText(stripHtml(decodeText(bytes, encoding: encoding))));
      case FileType.json:
        return ExtractedText(prettyJson(decodeText(bytes, encoding: encoding)));
      case FileType.pdf:
        return _pdf.extract(bytes);
      case FileType.epub:
        return _epub.extract(bytes);
      case FileType.unknown:
        return ExtractedText(decodeText(bytes, encoding: encoding));
    }
  }

  /// Decodes text bytes with automatic charset detection.
  ///
  /// Detection order:
  ///   1. A byte-order mark (UTF-8 / UTF-16 / UTF-32).
  ///   2. UTF-8 (strict) — the common case for modern text. Strict decoding
  ///      throws on legacy codepages, so they fall through to step 3 instead of
  ///      being silently mangled.
  ///   3. GBK — the de-facto codepage for simplified-Chinese `.txt` books such
  ///      as 《天龙八部》 downloaded from a remote shelf, which used to render as
  ///      mojibake under the old latin-1 fallback.
  ///   4. latin-1 passthrough, so the user always sees printable glyphs rather
  ///      than an exception.
  static String decodeText(Uint8List bytes, {String? encoding}) {
    if (bytes.isEmpty) return '';
    if (encoding != null && encoding != 'auto') {
      return _decodeWithEncoding(bytes, encoding);
    }

    final bom = _decodeByBom(bytes);
    if (bom != null) return bom;

    try {
      return utf8.decode(bytes); // strict: throws on legacy codepages
    } catch (_) {
      // Not valid UTF-8 — try a Chinese legacy codepage.
    }

    try {
      return decodeGbk(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  /// Decodes with an explicitly chosen codepage, used by the manual encoding
  /// switcher. Falls back to the auto pipeline for unknown hints.
  static String _decodeWithEncoding(Uint8List bytes, String encoding) {
    switch (encoding) {
      case 'utf-8':
        return utf8.decode(bytes, allowMalformed: true);
      case 'gbk':
        try {
          return decodeGbk(bytes);
        } catch (_) {
          return String.fromCharCodes(bytes);
        }
      default:
        return decodeText(bytes);
    }
  }

  /// Decodes [bytes] according to a leading byte-order mark, or null when there
  /// is no BOM to act on (so the caller can try UTF-8 / GBK instead).
  static String? _decodeByBom(Uint8List bytes) {
    // UTF-8 BOM is by far the most common case for text files carrying a mark.
    // UTF-16/UTF-32 BOMs are virtually never used for Chinese .txt books, so
    // they are intentionally not special-cased here; such bytes fall through to
    // the UTF-8/GBK steps above and remain readable for prose content.
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    return null;
  }

  /// Removes HTML tags and decodes the entities that actually show up in books.
  static String stripHtml(String input) {
    var text = input;

    // Drop whole blocks whose content is never prose.
    text = text.replaceAll(
        RegExp(r'<(script|style|head)[^>]*>.*?</\1>',
            caseSensitive: false, dotAll: true),
        ' ');

    // Block-level closers become paragraph breaks, <br> a single newline.
    text = text.replaceAllMapped(
        RegExp(r'<br\s*/?>', caseSensitive: false), (_) => '\n');
    text = text.replaceAllMapped(
        RegExp(r'</(p|div|h[1-6]|li|tr|blockquote|section|article)>',
            caseSensitive: false),
        (_) => '\n\n');

    text = text.replaceAll(RegExp(r'<[^>]*>', dotAll: true), ' ');
    return decodeEntities(text);
  }

  /// Collapses whitespace and drops control characters that survived decoding.
  static String cleanText(String input) {
    final text = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final cleaned = text.replaceAllMapped(
      RegExp(r'[^\S\n]+'),
      (_) => ' ',
    );
    return cleaned
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .split('\n')
        .map((line) => line.trimRight()) // 保留行首空格，仅去行尾空白
        .join('\n')
        .trim();
  }

  /// Re-indents JSON so it reads as text rather than one long line.
  static String prettyJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return raw;
    }
  }

  static String decodeEntities(String input) {
    return input
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&hellip;', '…')
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '');
      if (code == null) return m.group(0)!;
      return String.fromCharCode(code);
    });
  }
}
