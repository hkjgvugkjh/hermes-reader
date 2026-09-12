import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_reader/reader/services/pdf_text_extractor.dart';

Uint8List _rawPdf(String contentStream) => Uint8List.fromList(latin1.encode(
      '%PDF-1.4\n'
      '1 0 obj<</Type/Catalog>>endobj\n'
      '2 0 obj<</Type/Page/Contents 3 0 R>>endobj\n'
      '3 0 obj\n<< /Length ${contentStream.length} >>\n'
      'stream\n$contentStream\nendstream\n'
      'endobj\ntrailer\n%%EOF\n',
    ));

Uint8List _flatePdf(String contentStream) {
  final deflated = ZLibEncoder().encode(latin1.encode(contentStream));
  final body = latin1.decode(deflated);
  return Uint8List.fromList(latin1.encode(
    '%PDF-1.4\n'
    '3 0 obj\n<< /Filter /FlateDecode >>\n'
    'stream\n$body\nendstream\n'
    'endobj\ntrailer\n%%EOF\n',
  ));
}

/// Minimal LZW encoder matching the decoder's PDF `EarlyChange` convention,
/// used only to exercise the [PdfTextExtractor] LZW path in tests.
Uint8List _lzwPdf(String contentStream) {
  final data = latin1.encode(contentStream);
  final table = <List<int>>[];
  for (var i = 0; i < 256; i++) table.add([i]);
  table.add(const []); // 256 clear
  table.add(const []); // 257 eoi
  var next = 258;
  var width = 9;
  final bits = <int>[];
  void write(int code) {
    for (var b = width - 1; b >= 0; b--) bits.add((code >> b) & 1);
  }

  int indexOfSeq(List<int> seq) {
    for (var i = 0; i < table.length; i++) {
      if (table[i].length != seq.length) continue;
      var eq = true;
      for (var j = 0; j < seq.length; j++) {
        if (table[i][j] != seq[j]) {
          eq = false;
          break;
        }
      }
      if (eq) return i;
    }
    return -1;
  }

  write(256); // clear
  List<int>? w;
  for (final k in data) {
    final wk = w == null ? [k] : [...w, k];
    if (indexOfSeq(wk) >= 0) {
      w = wk;
    } else {
      write(indexOfSeq(w!));
      table.add(wk);
      next++;
      if (next == (1 << width) - 1 && width < 12) width++;
      w = [k];
    }
  }
  if (w != null) write(indexOfSeq(w));
  write(257); // eoi

  final out = <int>[];
  for (var i = 0; i < bits.length; i += 8) {
    var byte = 0;
    for (var b = 0; b < 8; b++) {
      byte = (byte << 1) | (i + b < bits.length ? bits[i + b] : 0);
    }
    out.add(byte);
  }
  final body = latin1.decode(out);
  return Uint8List.fromList(latin1.encode(
    '%PDF-1.4\n'
    '3 0 obj\n<< /Filter /LZWDecode >>\n'
    'stream\n$body\nendstream\n'
    'endobj\ntrailer\n%%EOF\n',
  ));
}

/// A PDF whose page tree and content stream live inside an object stream
/// (`/Type /ObjStm`) rather than as top-level objects — the modern layout
/// that previously produced "未能提取文本".
Uint8List _objStmPdf() {
  const objStmStream =
      '10 0 << /Length 24 >>\nstream\nBT (Hello ObjStm) Tj ET\nendstream\n';
  // The ObjStm header ("10 0 ") is 5 bytes, so /First must be 5.
  return Uint8List.fromList(latin1.encode(
    '%PDF-1.5\n'
    '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
    '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
    '3 0 obj<</Type/Page/Parent 2 0 R/Contents 10 0 R/Resources<</Font<</>>>>>>endobj\n'
    '4 0 obj<</Type/ObjStm/N 1/First 5>>\nstream\n$objStmStream\nendstream\nendobj\n'
    'trailer<</Root 1 0 R>>\n%%EOF\n',
  ));
}

/// A PDF whose page draws a 2x2 DeviceRGB image (FlateDecode) via `Do`.
Uint8List _imagePdf() {
  final pixels = Uint8List.fromList([
    255, 0, 0, //
    0, 255, 0,
    0, 0, 255,
    255, 255, 255,
  ]);
  final deflated = ZLibEncoder().encode(pixels);
  final content = 'BT (See image) Tj ET /Img1 Do';
  return Uint8List.fromList(latin1.encode(
    '%PDF-1.4\n'
    '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
    '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
    '3 0 obj<</Type/Page/Parent 2 0 R/Contents 4 0 R/Resources<</XObject<</Img1 5 0 R>>>>>>endobj\n'
    '4 0 obj<</Length ${content.length}>>\nstream\n$content\nendstream\nendobj\n'
    '5 0 obj<</Type/XObject/Subtype/Image/Width 2/Height 2/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/FlateDecode/Length ${deflated.length}>>\nstream\n${latin1.decode(deflated)}\nendstream\nendobj\n'
    'trailer<</Root 1 0 R>>\n%%EOF\n',
  ));
}

/// A PDF that embeds a raw JPEG (DCTDecode) image.
Uint8List _imagePdfJpeg() {
  final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xAB, 0xCD, 0xFF, 0xD9]);
  final content = '/Img1 Do';
  return Uint8List.fromList(latin1.encode(
    '%PDF-1.4\n'
    '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
    '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
    '3 0 obj<</Type/Page/Parent 2 0 R/Contents 4 0 R/Resources<</XObject<</Img1 5 0 R>>>>>>endobj\n'
    '4 0 obj<</Length ${content.length}>>\nstream\n$content\nendstream\nendobj\n'
    '5 0 obj<</Type/XObject/Subtype/Image/Width 4/Height 4/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode/Length ${jpeg.length}>>\nstream\n${latin1.decode(jpeg)}\nendstream\nendobj\n'
    'trailer<</Root 1 0 R>>\n%%EOF\n',
  ));
}

void main() {
  const extractor = PdfTextExtractor();

  test('reads an uncompressed content stream', () async {
    final result = await extractor.extract(_rawPdf('BT (Hello, PDF!) Tj ET'));
    expect(result.text, 'Hello, PDF!');
  });

  test('inflates a FlateDecode stream', () async {
    final result = await extractor.extract(_flatePdf('BT (Compressed text) Tj ET'));
    expect(result.text, 'Compressed text');
  });

  test('joins the pieces of a TJ array', () async {
    final result =
        await extractor.extract(_rawPdf('BT [(Hello) -200 (world)] TJ ET'));
    expect(result.text, 'Helloworld');
  });

  test('decodes UTF-16BE hex strings', () async {
    // U+4F60 U+597D with a byte order mark.
    final result =
        await extractor.extract(_rawPdf('BT <FEFF4F60597D> Tj ET'));
    expect(result.text, '你好');
  });

  test('escapes are unwrapped', () async {
    final result = await extractor
        .extract(_rawPdf(r'BT (a\(b\)c\\d) Tj ET'));
    expect(result.text, r'a(b)c\d');
  });

  test('one reader page per content stream', () async {
    final pdf = Uint8List.fromList(latin1.encode(
      '%PDF-1.4\n'
      '3 0 obj\n<< >>\nstream\nBT (Page one) Tj ET\nendstream\nendobj\n'
      '4 0 obj\n<< >>\nstream\nBT (Page two) Tj ET\nendstream\nendobj\n',
    ));

    final result = await extractor.extract(pdf);
    expect(result.breaks.length, 2);
    expect(result.text, contains('Page one'));
    expect(result.text, contains('Page two'));
  });

  test('a PDF with no text reports instead of throwing', () async {
    final result = await extractor.extract(_rawPdf('q 1 0 0 1 0 0 cm Q'));
    expect(result.text, contains('未能'));
  });

  test('garbage input does not throw', () async {
    final result =
        await extractor.extract(Uint8List.fromList(latin1.encode('not a pdf')));
    expect(result.text, isNotEmpty);
  });

  test('decodes a content stream inside an object stream', () async {
    final result = await extractor.extract(_objStmPdf());
    expect(result.text, contains('Hello ObjStm'));
  });

  test('decodes an LZWDecode stream', () async {
    final result = await extractor.extract(_lzwPdf('BT (LZW text) Tj ET'));
    expect(result.text, 'LZW text');
  });

  test('extracts an XObject image and embeds a marker', () async {
    final result = await extractor.extract(_imagePdf());
    expect(result.images, hasLength(1));
    expect(result.images.first.mime, 'image/png');
    expect(result.images.first.width, 2);
    expect(result.images.first.height, 2);
    // PNG signature.
    expect(
      result.images.first.bytes.sublist(0, 8),
      [137, 80, 78, 71, 13, 10, 26, 10],
    );
    expect(result.text, contains('See image'));
    expect(result.text, contains('\u0000IMG0\u0000'));
  });

  test('keeps a DCTDecode image as JPEG', () async {
    final result = await extractor.extract(_imagePdfJpeg());
    expect(result.images, hasLength(1));
    expect(result.images.first.mime, 'image/jpeg');
    expect(result.images.first.bytes, [0xFF, 0xD8, 0xAB, 0xCD, 0xFF, 0xD9]);
  });
}
