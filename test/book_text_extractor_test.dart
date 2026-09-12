import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_reader/reader/models/book.dart';
import 'package:hermes_reader/reader/services/book_text_extractor.dart';
import 'package:hermes_reader/reader/services/epub_text_extractor.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Builds a minimal but valid EPUB in memory.
Uint8List _buildEpub() {
  const container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';

  const opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>''';

  const chapter1 = '''<html><body>
<h1>第一章</h1><p>你好，世界。</p>
</body></html>''';

  const chapter2 = '''<html><body>
<p>第二章 &amp; 内容</p>
<script>var noise = 1;</script>
</body></html>''';

  final archive = Archive()
    ..addFile(ArchiveFile('META-INF/container.xml', container.length,
        utf8.encode(container)))
    ..addFile(ArchiveFile('OEBPS/content.opf', opf.length, utf8.encode(opf)))
    ..addFile(
        ArchiveFile('OEBPS/ch1.xhtml', chapter1.length, utf8.encode(chapter1)))
    ..addFile(
        ArchiveFile('OEBPS/ch2.xhtml', chapter2.length, utf8.encode(chapter2)));

  final zip = ZipEncoder().encode(archive);
  return Uint8List.fromList(zip!);
}

void main() {
  const extractor = DefaultBookTextExtractor();

  test('plain text passes through unchanged', () async {
    final result = await extractor.extract(_bytes('第一行\n第二行'), FileType.plainText);
    expect(result.text, '第一行\n第二行');
    expect(result.breaks, isEmpty);
  });

  test('html is stripped and entities decoded', () async {
    const html = '<html><head><title>丢弃</title></head><body>'
        '<h1>标题</h1><p>正文 &amp; 更多</p><br/><script>x=1</script>'
        '</body></html>';
    final result = await extractor.extract(_bytes(html), FileType.html);

    expect(result.text, contains('标题'));
    expect(result.text, contains('正文 & 更多'));
    expect(result.text, isNot(contains('丢弃')));
    expect(result.text, isNot(contains('x=1')));
    expect(result.text, isNot(contains('<p>')));
  });

  test('mobi is treated as html', () async {
    final result = await extractor.extract(
        _bytes('<p>口袋书</p>'), FileType.mobi);
    expect(result.text.trim(), '口袋书');
  });

  test('json is re-indented', () async {
    final result = await extractor.extract(
        _bytes('{"a":1,"b":[2,3]}'), FileType.json);
    expect(result.text, contains('\n'));
    expect(result.text, contains('"a": 1'));
  });

  test('malformed json is kept verbatim', () async {
    final result = await extractor.extract(_bytes('{oops'), FileType.json);
    expect(result.text, '{oops');
  });

  test('epub chapters are read in spine order', () {
    final result = EpubTextExtractor().extract(_buildEpub());

    expect(result.text, contains('第一章'));
    expect(result.text, contains('你好，世界。'));
    expect(result.text, contains('第二章 & 内容'));
    expect(result.text, isNot(contains('noise')));

    // One break per chapter, and the first chapter comes first.
    expect(result.breaks.length, 2);
    expect(result.text.indexOf('第一章'), lessThan(result.text.indexOf('第二章')));
  });

  test('a corrupt epub reports instead of throwing', () {
    final result = EpubTextExtractor().extract(_bytes('not a zip at all'));
    expect(result.text, contains('EPUB'));
  });

  test('whitespace is normalised', () {
    expect(DefaultBookTextExtractor.cleanText('a    b\t\tc'),
        'a b c');
    expect(DefaultBookTextExtractor.cleanText('a\n\n\n\n\nb'), 'a\n\nb');
  });
}
