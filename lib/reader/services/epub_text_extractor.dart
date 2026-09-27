import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'book_text_extractor.dart';

/// Reads an EPUB by unzipping it and walking the spine.
///
/// The unmaintained `epub` package was rejected (no null safety), so the OPF
/// container is parsed directly — enough to get chapters in reading order,
/// which is all the paginator and the narrator need.
class EpubTextExtractor {
  const EpubTextExtractor();

  ExtractedText extract(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final opfPath = _opfPath(archive);
      if (opfPath == null) {
        return const ExtractedText('（EPUB 缺少 META-INF/container.xml）');
      }

      final opf = _readText(archive, opfPath);
      if (opf == null) {
        return const ExtractedText('（无法读取 EPUB 的 OPF 清单）');
      }

      final base = _directory(opfPath);
      final manifest = _manifest(opf);
      final spine = _spine(opf, manifest);

      final buffer = StringBuffer();
      final breaks = <int>[];

      for (final href in spine) {
        final chapterPath = _join(base, href);
        final raw = _readText(archive, chapterPath);
        if (raw == null) continue;

        final text =
            DefaultBookTextExtractor.cleanText(stripHtml(raw));
        if (text.isEmpty) continue;

        if (buffer.isNotEmpty) buffer.write('\n\n');
        breaks.add(buffer.length);
        buffer.write(text);
      }

      if (buffer.isEmpty) {
        return const ExtractedText('（EPUB 中没有找到可读章节）');
      }
      return ExtractedText(buffer.toString(), breaks: breaks);
    } catch (e) {
      return ExtractedText('（EPUB 解析失败：$e）');
    }
  }

  /// Same tag stripping as [DefaultBookTextExtractor], re-declared so this
  /// file stays self-contained for tests.
  static String stripHtml(String input) =>
      DefaultBookTextExtractor.stripHtml(input);

  String? _opfPath(Archive archive) {
    final container = archive.findFile('META-INF/container.xml');
    if (container == null) return null;

    final xml = utf8.decode(container.content as List<int>, allowMalformed: true);
    final match =
        RegExp(r'full-path\s*=\s*"([^"]+)"').firstMatch(xml);
    return match?.group(1);
  }

  String? _readText(Archive archive, String path) {
    final file = archive.findFile(path);
    if (file == null) return null;
    // ArchiveFile.content is typed as Object by the archive package; the bytes
    // are what we need regardless of the declared type.
    final bytes = Uint8List.fromList(List<int>.from(file.content as List));
    return DefaultBookTextExtractor.decodeText(bytes);
  }

  Map<String, String> _manifest(String opf) {
    final manifest = <String, String>{};
    for (final match
        in RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(opf)) {
      final tag = match.group(0)!;
      final id = _attribute(tag, 'id');
      final href = _attribute(tag, 'href');
      if (id != null && href != null) manifest[id] = href;
    }
    return manifest;
  }

  /// Chapter files in spine order; falls back to every HTML file when the
  /// spine is missing or unreadable.
  List<String> _spine(String opf, Map<String, String> manifest) {
    final ordered = <String>[];
    for (final match
        in RegExp(r'<itemref\b[^>]*>', caseSensitive: false).allMatches(opf)) {
      final idref = _attribute(match.group(0)!, 'idref');
      final href = idref == null ? null : manifest[idref];
      if (href != null) ordered.add(href);
    }
    if (ordered.isNotEmpty) return ordered;
    return manifest.values
        .where((href) => RegExp(r'\.(x?html|htm)$', caseSensitive: false)
            .hasMatch(href))
        .toList()
      ..sort();
  }

  String? _attribute(String tag, String name) {
    final match = RegExp('$name\\s*=\\s*"([^"]*)"').firstMatch(tag);
    if (match != null) return match.group(1);
    final single = RegExp("$name\\s*=\\s*'([^']*)'").firstMatch(tag);
    return single?.group(1);
  }

  String _directory(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }

  String _join(String base, String relative) {
    if (base.isEmpty) return relative;
    if (relative.startsWith('/')) return relative.substring(1);
    return '$base/$relative';
  }
}
