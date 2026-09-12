import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'book_text_extractor.dart';
import 'pdf_image_decoder.dart';

/// Pulls text out of a PDF without any native library.
///
/// PDFium (via `pdfrx`) would be more faithful, but it downloads a ~10 MB
/// binary from GitHub at build time, which fails on restricted networks and
/// slows every build. This instead walks the document structure:
///
///  * parse the page tree so only the real content streams are decoded
///    (images and embedded fonts are skipped — that alone removes the
///    multi-second stall on large files);
///  * for every text-showing operator, map the raw codes through the active
///    font's ToUnicode CMap or its /Encoding (WinAnsi, Standard, …) before
///    emitting a character. Naive byte-to-char decoding is what produced the
///    mojibake on real documents.
class PdfTextExtractor {
  const PdfTextExtractor();

  Future<ExtractedText> extract(Uint8List bytes) async {
    try {
      final doc = _PdfDocument(bytes);
      final pages = doc.extractPages();
      if (pages.isEmpty) {
        return const ExtractedText(
            '（未能从该 PDF 中提取文本，可能是扫描件或使用了外部字体映射）');
      }
      final buffer = StringBuffer();
      final breaks = <int>[];
      for (final page in pages) {
        final text = DefaultBookTextExtractor.cleanText(page);
        if (text.isEmpty) continue;
        if (buffer.isNotEmpty) buffer.write('\n\n');
        breaks.add(buffer.length);
        buffer.write(text);
        if (buffer.length > _maxText) break;
      }
      if (buffer.isEmpty) {
        return const ExtractedText(
            '（未能从该 PDF 中提取文本，可能是扫描件或使用了外部字体映射）');
      }
      return ExtractedText(
        buffer.toString(),
        breaks: breaks,
        images: doc.images,
      );
    } catch (e) {
      return ExtractedText('（PDF 解析失败：$e）');
    }
  }
}

const int _maxText = 6 * 1024 * 1024;

/// Result of scanning a literal `(...)` or hex `<...>` string in a stream.
class _PdfString {
  const _PdfString(this.bytes);
  final List<int> bytes;
}

class _Name {
  const _Name(this.name);
  final String name;
}

class _Ref {
  const _Ref(this.num, this.gen);
  final int num;
  final int gen;
}

/// A collected PDF object: its dictionary plus the raw (still-filtered) bytes
/// of its stream, if any.
class _Obj {
  _Obj(this.num, this.gen, this.dict, this.rawStream);
  final int num;
  final int gen;
  final Map<String, dynamic>? dict;
  final Uint8List? rawStream;
}

class _Font {
  const _Font({
    required this.subtype,
    required this.cmap,
    required this.encodingName,
    required this.baseEncoding,
    required this.diff,
    required this.isCid,
    required this.cidUnicode,
  });
  final String? subtype;
  final Map<int, String>? cmap;
  final String? encodingName;
  final String? baseEncoding;
  final Map<int, int>? diff;
  final bool isCid;
  final bool cidUnicode;
}

class _Page {
  const _Page(this.contentRefs, this.fonts, this.xobjects);
  final List<int> contentRefs;
  final Map<String, _Font> fonts;

  /// Name → object number of the page's `/XObject` resources (images drawn by
  /// the `Do` operator). Empty when the page has no images.
  final Map<String, int> xobjects;
}

/// Channel count (+ optional indexed palette) for a PDF colour space.
class _ColorSpaceInfo {
  const _ColorSpaceInfo(this.channels, this.palette);
  final int channels;
  final List<int>? palette;
}

class _PdfDocument {
  _PdfDocument(Uint8List bytes) : _src = latin1.decode(bytes) {
    _parseObjects();
    _resolveObjectStreams();
  }

  final String _src;
  final Map<int, _Obj> objects = {};

  /// Every image drawn by a `Do` operator, in document order. The index into
  /// this list is what the [imageMarker] token embedded in the text refers to.
  final List<PdfImage> images = [];

  int? catalogRef;

  void _parseObjects() {
    // Catalog reference may live in the trailer: `/Root N G R`.
    final root = RegExp(r'/Root\s+(\d+)\s+\d+\s+R').firstMatch(_src);
    if (root != null) catalogRef = int.tryParse(root.group(1)!);

    final objRe = RegExp(r'(\d+)\s+\d+\s+obj');
    for (final m in objRe.allMatches(_src)) {
      final number = int.parse(m.group(1)!);
      final bodyStart = m.end;
      final endobj = _src.indexOf('endobj', bodyStart);
      if (endobj < 0) continue;

      Map<String, dynamic>? dict;
      int dictEnd = -1;
      final dictStart = _src.indexOf('<<', bodyStart);
      if (dictStart >= 0 && dictStart < endobj) {
        dictEnd = _matchDict(_src, dictStart);
        if (dictEnd > 0) {
          dict = _DictParser(_src.substring(dictStart + 2, dictEnd - 2))
              .parseDict();
        }
      }

      Uint8List? rawStream;
      if (dictEnd > 0) {
        final streamKw = _src.indexOf('stream', dictEnd);
        if (streamKw >= 0 && streamKw < endobj) {
          var ds = streamKw + 6;
          if (ds < _src.length && _src[ds] == '\r') ds++;
          if (ds < _src.length && _src[ds] == '\n') ds++;
          final es = _src.indexOf('endstream', ds);
          if (es >= 0 && es <= endobj) {
            // Per spec an EOL marker precedes `endstream`; it is a delimiter,
            // not part of the stream data, so trim it off.
            var ee = es;
            if (ee > ds && _src[ee - 1] == '\n') ee--;
            if (ee > ds && _src[ee - 1] == '\r') ee--;
            rawStream = latin1.encode(_src.substring(ds, ee));
          }
        }
      }
      objects[number] = _Obj(number, 0, dict, rawStream);
    }
  }

  /// Finds the `>>` that closes the `<<` at [open] in [src], respecting
  /// nesting and strings.
  int _matchDict(String src, int open) {
    assert(src.startsWith('<<', open));
    var depth = 1;
    var i = open + 2;
    while (i < src.length) {
      final c = src[i];
      if (c == '(') {
        final end = _skipLiteral(src, i);
        if (end < 0) return -1;
        i = end;
        continue;
      }
      if (c == '<') {
        if (src.startsWith('<<', i)) {
          depth++;
          i += 2;
          continue;
        }
        final end = _skipHex(src, i);
        if (end < 0) return -1;
        i = end;
        continue;
      }
      if (c == '>') {
        if (src.startsWith('>>', i)) {
          depth--;
          i += 2;
          if (depth == 0) return i;
          continue;
        }
        i++;
        continue;
      }
      i++;
    }
    return -1;
  }

  int _skipLiteral(String src, int i) {
    var depth = 1;
    var j = i + 1;
    while (j < src.length) {
      final c = src[j];
      if (c == '\\') {
        j += 2;
        continue;
      }
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) return j + 1;
      }
      j++;
    }
    return -1;
  }

  int _skipHex(String src, int i) {
    var j = i + 1;
    while (j < src.length) {
      if (src[j] == '>') return j + 1;
      j++;
    }
    return -1;
  }

  int? _asInt(dynamic v) =>
      v is int ? v : (v is double ? v.toInt() : null);

  /// Modern PDFs (1.5+) pack objects into object streams (`/Type /ObjStm`)
  /// and the cross-reference into a stream too. The naive `obj`-regex scan
  /// only sees the top-level container objects, so the real page tree and
  /// content streams live inside those and are invisible. This walks every
  /// ObjStm (and ObjStms nested inside other ObjStms) and promotes the inner
  /// objects into [objects] so the rest of the extractor can find them.
  void _resolveObjectStreams() {
    final pending = <int>[];
    for (final o in objects.values) {
      if (_asName(o.dict?['/Type']) == 'ObjStm') pending.add(o.num);
    }
    final done = <int>{};
    while (pending.isNotEmpty) {
      final num = pending.removeLast();
      if (!done.add(num)) continue;
      final obj = objects[num];
      if (obj == null || obj.rawStream == null) continue;
      final decoded = _decodeStream(obj);
      if (decoded == null) continue;
      final first = _asInt(obj.dict?['/First']) ?? 0;
      final inner = _parseObjectStream(decoded, first);
      for (final io in inner) {
        objects.putIfAbsent(io.num, () => io);
        if (_asName(io.dict?['/Type']) == 'ObjStm' && !done.contains(io.num)) {
          pending.add(io.num);
        }
      }
    }
  }

  /// Decodes a `/Type /ObjStm` stream. The first [/First] bytes are a header
  /// of `<objnum> <offset>` pairs; [offset] is a byte offset into the data
  /// region (relative to the end of the header) where that object begins.
  /// Inner objects have **no** `endstream` delimiter — their stream data runs
  /// to the next object's offset (or to the end of the data region).
  List<_Obj> _parseObjectStream(Uint8List bytes, int first) {
    final out = <_Obj>[];
    if (first <= 0 || first > bytes.length) return out;
    final header = latin1.decode(bytes.sublist(0, first));
    final nums = RegExp(r'\d+')
        .allMatches(header)
        .map((m) => int.parse(m.group(0)!))
        .toList();
    if (nums.length % 2 != 0) return out;
    final pairs = <List<int>>[];
    for (var i = 0; i + 1 < nums.length; i += 2) {
      pairs.add([nums[i], nums[i + 1]]);
    }
    pairs.sort((a, b) => a[1].compareTo(b[1]));
    final data = latin1.decode(bytes.sublist(first));
    for (var i = 0; i < pairs.length; i++) {
      final objNum = pairs[i][0];
      final offset = pairs[i][1];
      final streamEnd = (i + 1 < pairs.length) ? pairs[i + 1][1] : data.length;
      if (offset < 0 || offset >= data.length) continue;
      final io = _parseInnerObject(data, offset, objNum, streamEnd);
      if (io != null) out.add(io);
    }
    return out;
  }

  /// Parses a single object embedded in an object stream at [offset] (a byte
  /// offset into [s]). [streamEnd] is the byte offset where this object's
  /// stream data ends (the next object's offset, or the end of the data
  /// region) — used because object streams have no `endstream` marker.
  _Obj? _parseInnerObject(String s, int offset, int num, int streamEnd) {
    final dictStart = s.indexOf('<<', offset);
    if (dictStart < 0) return null;
    final dictEnd = _matchDict(s, dictStart);
    if (dictEnd < 0) return null;
    final dict = _DictParser(s.substring(dictStart + 2, dictEnd - 2)).parseDict();

    Uint8List? rawStream;
    final streamKw = s.indexOf('stream', dictEnd);
    if (streamKw >= 0 && streamKw < s.length) {
      var ds = streamKw + 6;
      // Consume the EOL after `stream`: 2 bytes for CRLF, 1 otherwise.
      if (ds < s.length && s[ds] == '\r') {
        ds += (ds + 1 < s.length && s[ds + 1] == '\n') ? 2 : 1;
      } else if (ds < s.length && s[ds] == '\n') {
        ds += 1;
      }
      final end = streamEnd.clamp(ds, s.length);
      rawStream = latin1.encode(s.substring(ds, end));
    }
    return _Obj(num, 0, dict, rawStream);
  }

  int? _refOf(dynamic v) => v is _Ref ? v.num : null;

  Map<String, dynamic>? _derefDict(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is _Ref) return objects[v.num]?.dict;
    return null;
  }

  _Obj? _derefObj(dynamic v) => v is _Ref ? objects[v.num] : null;

  String? _asName(dynamic v) => v is _Name ? v.name : null;

  /// Decodes a stream object's filters (FlateDecode, ASCII85, ASCIIHex).
  /// Returns null when a filter is unsupported (e.g. an image) or fails.
  Uint8List? _decodeStream(_Obj obj) {
    if (obj.rawStream == null) return null;
    var bytes = obj.rawStream!;
    final filter = obj.dict?['/Filter'];
    final filters = <String>[];
    if (filter is _Name) {
      filters.add(filter.name);
    } else if (filter is List) {
      for (final e in filter) {
        if (e is _Name) filters.add(e.name);
      }
    }
    for (final f in filters) {
      bytes = _applyFilter(bytes, f);
      if (bytes.isEmpty) return null;
    }
    return bytes;
  }

  // ---- image extraction ----------------------------------------------------

  /// Resolves a colour space into its channel count and an optional indexed
  /// palette. Returns null for spaces the reader cannot render.
  _ColorSpaceInfo? _colorSpaceInfo(dynamic cs) {
    if (cs is _Name) {
      switch (cs.name) {
        case 'DeviceGray':
        case 'CalGray':
          return const _ColorSpaceInfo(1, null);
        case 'DeviceRGB':
        case 'CalRGB':
          return const _ColorSpaceInfo(3, null);
        case 'DeviceCMYK':
          return const _ColorSpaceInfo(4, null);
        default:
          return null;
      }
    }
    if (cs is List && cs.isNotEmpty) {
      final name = cs[0] is _Name ? cs[0].name : null;
      if (name == 'Indexed' || name == 'I') {
        if (cs.length < 4) return null;
        final base = _colorSpaceInfo(cs[1]);
        if (base == null) return null;
        final lookupRaw = cs[3];
        List<int> lookup;
        if (lookupRaw is _PdfString) {
          lookup = lookupRaw.bytes;
        } else if (lookupRaw is _Ref) {
          final obj = objects[lookupRaw.num];
          final decoded = obj != null ? _decodeImageStream(obj) : null;
          lookup = decoded == null ? const [] : List<int>.from(decoded);
        } else {
          return null;
        }
        if (lookup.isEmpty) return null;
        final entries = lookup.length ~/ base.channels;
        final palette = <int>[];
        for (var i = 0; i < base.channels * entries; i++) {
          palette.add(i < lookup.length ? lookup[i] : 0);
        }
        return _ColorSpaceInfo(base.channels, palette);
      }
      if (name == 'ICCBased') {
        final n = cs.length >= 2 && cs[1] is _Ref
            ? _asInt(objects[cs[1].num]?.dict?['/N']) ?? 3
            : 3;
        return _ColorSpaceInfo(n.clamp(1, 4), null);
      }
      // Separation / DeviceN / patterns are not rendered.
      return null;
    }
    return null;
  }

  /// Converts raw decoded image pixels into 8-bit RGBA for the PNG encoder.
  Uint8List? _toRgba(
    Uint8List data,
    int width,
    int height,
    int bpc,
    dynamic colorSpace,
  ) {
    if (bpc != 8 && bpc != 1) return null;
    final cs = _colorSpaceInfo(colorSpace);
    if (cs == null) return null;

    final baseChannels = cs.channels;
    final palette = cs.palette;
    final rowBytes = _bytesPerRow(width, bpc, baseChannels);
    if (data.length < rowBytes * height) return null;

    final rgba = Uint8List(width * height * 4);
    var out = 0;
    for (var y = 0; y < height; y++) {
      final rowStart = y * rowBytes;
      for (var x = 0; x < width; x++) {
        List<int> base;
        if (bpc == 1) {
          final byteIndex = rowStart + (x >> 3);
          final bit = 7 - (x & 7);
          final v = (data[byteIndex] >> bit) & 1;
          base = [v * 255];
        } else {
          final idx = rowStart + x * baseChannels;
          base = data.sublist(idx, idx + baseChannels);
        }
        List<int> rgb;
        if (palette != null) {
          final pidx = base[0] * baseChannels;
          rgb = palette.sublist(pidx, pidx + baseChannels);
        } else {
          rgb = base;
        }
        int r, g, b;
        if (rgb.length == 1) {
          r = g = b = rgb[0];
        } else if (rgb.length == 3) {
          r = rgb[0];
          g = rgb[1];
          b = rgb[2];
        } else if (rgb.length >= 4) {
          // CMYK → RGB (naive conversion, fine for reading).
          final c = rgb[0] / 255.0;
          final m = rgb[1] / 255.0;
          final y = rgb[2] / 255.0;
          final k = rgb[3] / 255.0;
          r = ((1 - c) * (1 - k) * 255).round();
          g = ((1 - m) * (1 - k) * 255).round();
          b = ((1 - y) * (1 - k) * 255).round();
        } else {
          r = g = b = 0;
        }
        rgba[out++] = r;
        rgba[out++] = g;
        rgba[out++] = b;
        rgba[out++] = 255;
      }
    }
    return rgba;
  }

  int _bytesPerRow(int width, int bpc, int channels) =>
      bpc == 1 ? ((width * channels + 7) >> 3) : width * channels;

  List<String> _filterNames(dynamic v) {
    final out = <String>[];
    if (v is _Name) {
      out.add(v.name);
    } else if (v is List) {
      for (final e in v) {
        if (e is _Name) out.add(e.name);
      }
    }
    return out;
  }

  /// Decodes an image stream through the supported filters, but leaves
  /// natively-encoded image formats (JPEG/JPEG2000/fax/JBIG2) untouched — those
  /// bytes *are* the encoded picture and would be destroyed by our filters.
  Uint8List? _decodeImageStream(_Obj obj) {
    if (obj.rawStream == null) return null;
    var bytes = obj.rawStream!;
    for (final f in _filterNames(obj.dict?['/Filter'])) {
      if (f == 'DCTDecode' ||
          f == 'JPXDecode' ||
          f == 'CCITTFaxDecode' ||
          f == 'JBIG2Decode') {
        continue;
      }
      bytes = _applyFilter(bytes, f);
      if (bytes.isEmpty) return null;
    }
    return bytes;
  }

  /// Decodes an image XObject into a renderable [PdfImage], or null when the
  /// format is one Flutter cannot display (CCITT fax, JBIG2, …).
  PdfImage? _decodeImageObject(int objNum) {
    final obj = objects[objNum];
    if (obj == null || obj.dict == null || obj.rawStream == null) return null;
    final dict = obj.dict!;
    if (_asName(dict['/Subtype']) != 'Image') return null;

    final w = _asInt(dict['/Width']);
    final h = _asInt(dict['/Height']);
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    // Guard against pathological sizes that would exhaust memory.
    if (w > 4096 || h > 4096) return null;

    final filters = _filterNames(dict['/Filter']);
    final lastFilter = filters.isEmpty ? null : filters.last;
    final decoded = _decodeImageStream(obj);
    if (decoded == null) return null;

    if (lastFilter == 'DCTDecode') {
      return PdfImage(decoded, 'image/jpeg', w, h);
    }
    if (lastFilter == 'JPXDecode' ||
        lastFilter == 'CCITTFaxDecode' ||
        lastFilter == 'JBIG2Decode') {
      return null;
    }

    final bpc = _asInt(dict['/BitsPerComponent']) ?? 8;
    final rgba = _toRgba(decoded, w, h, bpc, dict['/ColorSpace']);
    if (rgba == null) return null;
    final png = encodePngRgba(rgba, w, h);
    if (png == null) return null;
    return PdfImage(png, 'image/png', w, h);
  }

  List<String> extractPages() {
    if (catalogRef == null) {
      for (final obj in objects.values) {
        if (_asName(obj.dict?['/Type']) == 'Catalog') {
          catalogRef = obj.num;
          break;
        }
      }
    }
    if (catalogRef == null) return _scanAllStreams();
    final catalog = objects[catalogRef];
    if (catalog?.dict == null) return _scanAllStreams();

    final pagesRef = _refOf(catalog!.dict!['/Pages']);
    final pagesObj = pagesRef != null ? objects[pagesRef] : null;
    if (pagesObj == null) return _scanAllStreams();

    final collected = <_Page>[];
    _collectPages(pagesObj, null, collected);
    if (collected.isEmpty) return _scanAllStreams();

    final pages = <String>[];
    for (final page in collected) {
      final sb = StringBuffer();
      for (final ref in page.contentRefs) {
        final obj = objects[ref];
        final decoded = obj == null ? null : _decodeStream(obj);
        if (obj == null || decoded == null) continue;
        try {
          sb.write(_extractContent(decoded, page.fonts, page.xobjects));
        } catch (_) {
          // A single malformed content stream must not sink the whole page.
        }
      }
      pages.add(sb.toString());
    }
    return pages;
  }

  void _collectPages(
      _Obj pageObj, Map<String, dynamic>? inherited, List<_Page> out) {
    final dict = pageObj.dict;
    if (dict == null) return;

    final localRes = _derefDict(dict['/Resources']);
    final merged = <String, dynamic>{};
    if (inherited != null) merged.addAll(inherited);
    if (localRes != null) merged.addAll(localRes);

    final type = _asName(dict['/Type']);
    if (type == 'Pages') {
      final kids = dict['/Kids'];
      if (kids is List) {
        for (final k in kids) {
          final child = _derefObj(k);
          if (child != null) _collectPages(child, merged, out);
        }
      }
      return;
    }

    final contents = dict['/Contents'];
    final contentRefs = <int>[];
    if (contents is _Ref) {
      contentRefs.add(contents.num);
    } else if (contents is List) {
      for (final c in contents) {
        final r = _refOf(c);
        if (r != null) contentRefs.add(r);
      }
    }
    out.add(_Page(contentRefs, _fontsFor(merged), _xobjectsFor(merged)));
  }

  Map<String, int> _xobjectsFor(Map<String, dynamic>? resources) {
    final out = <String, int>{};
    if (resources == null) return out;
    final xo = _derefDict(resources['/XObject']);
    if (xo == null) return out;
    xo.forEach((key, value) {
      final id = _refOf(value);
      if (id != null) out[key] = id;
    });
    return out;
  }

  Map<String, _Font> _fontsFor(Map<String, dynamic>? resources) {
    final out = <String, _Font>{};
    if (resources == null) return out;
    final fontDict = _derefDict(resources['/Font']);
    if (fontDict == null) return out;
    fontDict.forEach((key, value) {
      final font = _buildFont(value);
      if (font != null) out[key] = font;
    });
    return out;
  }

  _Font? _buildFont(dynamic fontVal) {
    final dict = _derefDict(fontVal);
    if (dict == null) return null;

    final subtype = _asName(dict['/Subtype']);
    final isCid = subtype == 'Type0';

    Map<int, String>? cmap;
    final toUnicode = dict['/ToUnicode'];
    final tuObj = _derefObj(toUnicode);
    if (tuObj != null) {
      final decoded = _decodeStream(tuObj);
      if (decoded != null) cmap = _parseCMap(latin1.decode(decoded));
    }

    String? encodingName;
    String? baseEncoding;
    Map<int, int>? diff;
    final enc = dict['/Encoding'];
    if (enc is _Name) {
      encodingName = enc.name;
    } else if (enc is Map<String, dynamic>) {
      baseEncoding = _asName(enc['/BaseEncoding']);
      final diffList = enc['/Differences'];
      if (diffList is List) diff = _parseDifferences(diffList);
    }

    final cidUnicode = encodingName != null &&
        encodingName.startsWith('Uni') &&
        !encodingName.startsWith('Identity');

    return _Font(
      subtype: subtype,
      cmap: cmap,
      encodingName: encodingName,
      baseEncoding: baseEncoding,
      diff: diff,
      isCid: isCid,
      cidUnicode: cidUnicode,
    );
  }

  Map<int, int> _parseDifferences(List diffList) {
    final out = <int, int>{};
    var base = 0;
    for (final item in diffList) {
      if (item is int) {
        base = item;
      } else if (item is _Name) {
        // Glyph names would need the Adobe GlyphList; skip (best effort only
        // handles numeric character codes, which some /Differences carry).
        base++;
      } else if (item is _PdfString) {
        if (item.bytes.isNotEmpty) out[base] = item.bytes[0];
        base++;
      }
    }
    return out;
  }

  /// Fallback used when there is no usable page tree: scan every stream block
  /// and pull out any text-showing operators with a default (ASCII/WinAnsi)
  /// font.
  List<String> _scanAllStreams() {
    final pages = <String>[];
    for (final obj in objects.values) {
      final t = _asName(obj.dict?['/Type']);
      if (t == 'ObjStm' || t == 'XRef') continue;
      final decoded = _decodeStream(obj);
      if (decoded == null) continue;
      final content = latin1.decode(decoded);
      if (!content.contains('Tj') &&
          !content.contains('TJ') &&
          !content.contains('"')) {
        continue;
      }
      final text = _extractContent(decoded, const {}, const {});
      if (text.trim().isNotEmpty) pages.add(text);
      if (pages.length > 10000) break;
    }
    return pages;
  }

  String _extractContent(
    Uint8List bytes,
    Map<String, _Font> fonts,
    Map<String, int> xobjects,
  ) {
    final content = latin1.decode(bytes);
    final tokens = _tokenizeContent(content);
    final operands = <dynamic>[];
    final sb = StringBuffer();
    String? currentFont;

    void push(dynamic v) {
      if (operands.isNotEmpty && operands.last is List) {
        (operands.last as List).add(v);
      } else {
        operands.add(v);
      }
    }

    for (final t in tokens) {
      if (t is _PdfString) {
        push(t);
      } else if (t == '[') {
        push(<dynamic>[]);
      } else if (t == ']') {
        // The array is already the top operand; nothing to do.
      } else if (t is String) {
        if (t.startsWith('/')) {
          push(t);
        } else if (_isNum(t)) {
          push(num.parse(t));
        } else {
          currentFont =
              _handleOperator(t, operands, sb, fonts, currentFont, xobjects);
          operands.clear();
        }
      }
    }
    return sb.toString();
  }

  String? _handleOperator(
    String op,
    List<dynamic> operands,
    StringBuffer sb,
    Map<String, _Font> fonts,
    String? currentFont,
    Map<String, int> xobjects,
  ) {
    switch (op) {
      case 'Do':
        // Draw an XObject: only images are handled here; the form XObjects the
        // reader cares about are already flattened into the text flow.
        if (operands.isNotEmpty) {
          final name = operands.last;
          final key = name is String
              ? name
              : (name is _Name ? '/${name.name}' : null);
          if (key != null) {
            final id = xobjects[key];
            if (id != null) {
              final img = _decodeImageObject(id);
              if (img != null) {
                final idx = images.length;
                images.add(img);
                sb.write(imageMarker(idx));
              }
            }
          }
        }
      case 'Tf':
        if (operands.length >= 2) {
          final f = operands[operands.length - 2];
          if (f is String && f.startsWith('/')) return f;
        }
        return currentFont;
      case 'Tj':
        if (operands.isNotEmpty && operands.last is _PdfString) {
          _emit(sb, _decodeString(operands.last.bytes, fonts[currentFont]),
              separate: true);
        }
      case 'TJ':
        if (operands.isNotEmpty && operands.last is List) {
          for (final e in operands.last as List) {
            if (e is _PdfString) {
              _emit(sb, _decodeString(e.bytes, fonts[currentFont]),
                  separate: false);
            }
          }
        }
      case "'":
        if (operands.isNotEmpty && operands.last is _PdfString) {
          sb.write('\n');
          _emit(sb, _decodeString(operands.last.bytes, fonts[currentFont]),
              separate: true);
        }
      case '"':
        final strings = operands.whereType<_PdfString>().toList();
        if (strings.isNotEmpty) {
          sb.write('\n');
          _emit(sb, _decodeString(strings.last.bytes, fonts[currentFont]),
              separate: true);
        }
      case 'T*':
        sb.write('\n');
    }
    return currentFont;
  }

  void _emit(StringBuffer sb, String s, {required bool separate}) {
    if (s.isEmpty) return;
    if (separate && sb.isNotEmpty) {
      final last = sb.toString().codeUnitAt(sb.length - 1);
      if (!_isWs(last)) sb.write(' ');
    }
    sb.write(s);
  }

  String _decodeString(List<int> bytes, _Font? font) {
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _utf16be(bytes.sublist(2));
    }
    if (font?.isCid == true) {
      final sb = StringBuffer();
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        sb.write(_mapCode(font, (bytes[i] << 8) | bytes[i + 1]));
      }
      return sb.toString();
    }
    final sb = StringBuffer();
    for (final b in bytes) sb.write(_mapCode(font, b));
    return sb.toString();
  }

  String _mapCode(_Font? font, int code) {
    if (font?.cmap != null && font!.cmap!.containsKey(code)) {
      return font.cmap![code]!;
    }
    if (font?.cidUnicode == true) return _toStr(code);
    if (font?.diff != null && font!.diff!.containsKey(code)) {
      return String.fromCharCode(font.diff![code]!);
    }
    final enc = font?.encodingName ?? font?.baseEncoding;
    if (enc == 'WinAnsiEncoding') return _winAnsi(code);
    if (enc == 'StandardEncoding' || enc == 'MacExpertEncoding') {
      return _winAnsi(code);
    }
    if (enc == 'MacRomanEncoding') return _winAnsi(code);
    if (code < 0x80) return String.fromCharCode(code);
    return _winAnsi(code);
  }

  List<dynamic> _tokenizeContent(String c) {
    final tokens = <dynamic>[];
    var i = 0;
    while (i < c.length) {
      final ch = c[i];
      if (ch == ' ' ||
          ch == '\t' ||
          ch == '\n' ||
          ch == '\r' ||
          ch == '\r') {
        i++;
        continue;
      }
      if (ch == '%') {
        while (i < c.length && c[i] != '\n') i++;
        continue;
      }
      if (ch == '(') {
        final r = _scanLiteral(c, i);
        tokens.add(_PdfString(r.bytes));
        i = r.end;
        continue;
      }
      if (ch == '<') {
        if (c.startsWith('<<', i)) {
          tokens.add('<<');
          i += 2;
          continue;
        }
        final r = _scanHex(c, i);
        tokens.add(_PdfString(r.bytes));
        i = r.end;
        continue;
      }
      if (ch == '>') {
        if (c.startsWith('>>', i)) {
          tokens.add('>>');
          i += 2;
        } else {
          i++;
        }
        continue;
      }
      if (ch == '[') {
        tokens.add('[');
        i++;
        continue;
      }
      if (ch == ']') {
        tokens.add(']');
        i++;
        continue;
      }
      if (ch == '{') {
        var depth = 1;
        i++;
        while (i < c.length && depth > 0) {
          if (c[i] == '{') {
            depth++;
          } else if (c[i] == '}') {
            depth--;
          }
          i++;
        }
        continue;
      }
      if (ch == '}') {
        i++;
        continue;
      }
      if (ch == '/') {
        var j = i + 1;
        while (j < c.length && !_delim(c[j])) j++;
        tokens.add(c.substring(i, j));
        i = j;
        continue;
      }
      if (_isNum(ch)) {
        var j = i + 1;
        while (j < c.length && !_delim(c[j])) j++;
        tokens.add(c.substring(i, j));
        i = j;
        continue;
      }
      // General operator token.
      var j = i + 1;
      while (j < c.length && !_delim(c[j]) && c[j] != '/') j++;
      tokens.add(c.substring(i, j));
      i = j;
    }
    return tokens;
  }

  ({List<int> bytes, int end}) _scanLiteral(String s, int i) {
    var j = i + 1;
    var depth = 1;
    final out = <int>[];
    while (j < s.length) {
      final c = s[j];
      if (c == '\\') {
        if (j + 1 < s.length) {
          final n = s[j + 1];
          switch (n) {
            case 'n':
              out.add(0x0A);
              break;
            case 'r':
              out.add(0x0D);
              break;
            case 't':
              out.add(0x09);
              break;
            case 'b':
              out.add(0x08);
              break;
            case 'f':
              out.add(0x0C);
              break;
            case '(':
              out.add(0x28);
              break;
            case ')':
              out.add(0x29);
              break;
            case '\\':
              out.add(0x5C);
              break;
            default:
              if (n.compareTo('0') >= 0 && n.compareTo('7') <= 0) {
                var k = j + 1;
                var val = 0;
                var cnt = 0;
                while (k < s.length && cnt < 3 && s[k].compareTo('0') >= 0 && s[k].compareTo('7') <= 0) {
                  val = val * 8 + (s.codeUnitAt(k) - 0x30);
                  k++;
                  cnt++;
                }
                out.add(val & 0xFF);
                j = k - 1;
              } else {
                out.add(s.codeUnitAt(j + 1));
              }
          }
          j += 2;
          continue;
        }
        j++;
        continue;
      }
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) {
          j++;
          break;
        }
      }
      out.add(s.codeUnitAt(j));
      j++;
    }
    return (bytes: out, end: j);
  }

  ({List<int> bytes, int end}) _scanHex(String s, int i) {
    var j = i + 1;
    final out = <int>[];
    while (j < s.length && s[j] != '>') {
      final c = s[j];
      if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
        j++;
        continue;
      }
      final hi = _hexVal(c.codeUnitAt(0));
      j++;
      if (hi < 0) continue;
      if (j < s.length && s[j] != '>') {
        final lo = _hexVal(s[j].codeUnitAt(0));
        if (lo >= 0) {
          out.add(hi * 16 + lo);
          j++;
        } else {
          out.add(hi);
        }
      } else {
        out.add(hi);
      }
    }
    if (j < s.length) j++; // skip '>'
    return (bytes: out, end: j);
  }
}

/// Maps a code point (possibly supplementary) to a string.
String _toStr(int cp) {
  if (cp < 0x10000) return String.fromCharCode(cp);
  final c = cp - 0x10000;
  return String.fromCharCode(0xD800 + (c >> 10)) +
      String.fromCharCode(0xDC00 + (c & 0x3FF));
}

/// WinAnsi (CP1252) for the 0x80–0x9F range; 0x00–0x7F and 0xA0–0xFF line up
/// with ASCII / latin-1.
String _winAnsi(int code) {
  if (code < 0x80 || code >= 0xA0) return String.fromCharCode(code);
  const map = <int, String>{
    0x80: '€',
    0x82: '‚',
    0x83: 'ƒ',
    0x84: '„',
    0x85: '…',
    0x86: '†',
    0x87: '‡',
    0x88: 'ˆ',
    0x89: '‰',
    0x8A: 'Š',
    0x8B: '‹',
    0x8C: 'Œ',
    0x8E: 'Ž',
    0x91: '‘',
    0x92: '’',
    0x93: '“',
    0x94: '”',
    0x95: '•',
    0x96: '–',
    0x97: '—',
    0x98: '˜',
    0x99: '™',
    0x9A: 'š',
    0x9B: '›',
    0x9C: 'œ',
    0x9E: 'ž',
    0x9F: 'Ÿ',
  };
  return map[code] ?? String.fromCharCode(code);
}

String _utf16be(List<int> bytes) {
  final codes = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    codes.add((bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(codes);
}

Map<int, String> _parseCMap(String s) {
  final map = <int, String>{};
  final bfchar = _between(s, 'beginbfchar', 'endbfchar');
  if (bfchar != null) {
    final re = RegExp(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>');
    for (final m in re.allMatches(bfchar)) {
      final src = _hexToInt(m.group(1)!);
      final dst = _hexToInt(m.group(2)!);
      if (src != null && dst != null) map[src] = _toStr(dst);
    }
  }
  final bfrange = _between(s, 'beginbfrange', 'endbfrange');
  if (bfrange != null) {
    final re = RegExp(
        r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(?:<([0-9A-Fa-f]+)>|\[([\s\S]*?)\])');
    for (final m in re.allMatches(bfrange)) {
      final start = _hexToInt(m.group(1)!);
      final end = _hexToInt(m.group(2)!);
      if (start == null || end == null) continue;
      if (m.group(3) != null) {
        final dst0 = _hexToInt(m.group(3)!);
        if (dst0 != null) {
          var d = dst0;
          for (var c = start; c <= end; c++) {
            map[c] = _toStr(d);
            d++;
          }
        }
      } else {
        final listStr = m.group(4)!;
        final items = RegExp(r'<([0-9A-Fa-f]+)>')
            .allMatches(listStr)
            .map((x) => _hexToInt(x.group(1)!))
            .where((x) => x != null)
            .toList();
        var idx = 0;
        for (var c = start; c <= end; c++) {
          if (idx < items.length) map[c] = _toStr(items[idx]!);
          idx++;
        }
      }
    }
  }
  return map;
}

String? _between(String s, String start, String end) {
  final a = s.indexOf(start);
  if (a < 0) return null;
  final b = s.indexOf(end, a);
  if (b < 0) return null;
  return s.substring(a + start.length, b);
}

int? _hexToInt(String hex) {
  if (hex.isEmpty) return null;
  return int.tryParse(hex, radix: 16);
}

int _hexVal(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
  if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x41 + 10;
  if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10;
  return -1;
}

bool _isWs(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

bool _isNum(String s) {
  if (s.isEmpty) return false;
  final code = s.codeUnitAt(0);
  return (code >= 0x30 && code <= 0x39) ||
      code == 0x2D ||
      code == 0x2B ||
      code == 0x2E;
}

bool _delim(String c) =>
    c == ' ' ||
    c == '\n' ||
    c == '\r' ||
    c == '\t' ||
    c == '(' ||
    c == ')' ||
    c == '<' ||
    c == '>' ||
    c == '[' ||
    c == ']' ||
    c == '{' ||
    c == '}' ||
    c == '/';

Uint8List _applyFilter(Uint8List bytes, String filter) {
  switch (filter) {
    case 'FlateDecode':
    case 'Fl':
      try {
        return Uint8List.fromList(ZLibDecoder().decodeBytes(bytes, verify: false));
      } catch (_) {
        return Uint8List(0);
      }
    case 'ASCII85Decode':
    case 'A85':
      try {
        return _ascii85(bytes);
      } catch (_) {
        return Uint8List(0);
      }
    case 'ASCIIHexDecode':
    case 'AHx':
      try {
        return _asciiHex(bytes);
      } catch (_) {
        return Uint8List(0);
      }
    case 'LZWDecode':
    case 'LZW':
      try {
        return _lzw(bytes);
      } catch (_) {
        return Uint8List(0);
      }
    case 'DCTDecode':
    case 'JPXDecode':
    case 'CCITTFaxDecode':
    case 'JBIG2Decode':
      return Uint8List(0);
    default:
      return bytes;
  }
}

Uint8List _ascii85(Uint8List bytes) {
  final chars = <int>[];
  for (final b in bytes) {
    if (b == 0x7E) break; // '~' terminates
    if (b == 0x3C) continue; // '<' start marker
    if (b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D) continue;
    chars.add(b);
  }
  final out = <int>[];
  var i = 0;
  while (i < chars.length) {
    if (chars[i] == 0x7A) {
      out.addAll([0, 0, 0, 0]);
      i++;
      continue;
    }
    var value = 0;
    var count = 0;
    while (count < 5 && i < chars.length && chars[i] != 0x7E) {
      value = value * 85 + (chars[i] - 0x21);
      count++;
      i++;
    }
    while (count < 5) {
      value = value * 85 + 84;
      count++;
    }
    out.add((value >> 24) & 0xFF);
    out.add((value >> 16) & 0xFF);
    out.add((value >> 8) & 0xFF);
    out.add(value & 0xFF);
  }
  return Uint8List.fromList(out);
}

Uint8List _asciiHex(Uint8List bytes) {
  final out = <int>[];
  var i = 0;
  while (i < bytes.length) {
    if (bytes[i] == 0x3E) break; // '>'
    final hi = _hexVal(bytes[i]);
    i++;
    if (hi < 0) continue;
    if (i < bytes.length && bytes[i] != 0x3E) {
      final lo = _hexVal(bytes[i]);
      if (lo >= 0) {
        out.add(hi * 16 + lo);
        i++;
      } else {
        out.add(hi);
      }
    } else {
      out.add(hi);
    }
  }
  return Uint8List.fromList(out);
}

/// PDF LZW decoder (TIFF-variant with the PDF `EarlyChange` convention: the
/// code width grows one code earlier than the 2^width boundary).
Uint8List _lzw(Uint8List bytes) {
  const clear = 256;
  const eoi = 257;

  // Bit stream -> codes.
  final bits = <int>[];
  for (final b in bytes) {
    for (var k = 7; k >= 0; k--) bits.add((b >> k) & 1);
  }
  var bitPos = 0;
  int readCode(int width) {
    var v = 0;
    for (var i = 0; i < width; i++) {
      v = (v << 1) | (bitPos < bits.length ? bits[bitPos] : 0);
      bitPos++;
    }
    return v;
  }

  final out = <int>[];
  final table = <List<int>>[];
  void initTable() {
    table.clear();
    for (var i = 0; i < 256; i++) table.add([i]);
    table.add(const []); // 256 clear
    table.add(const []); // 257 EOI
  }

  initTable();
  var width = 9;
  var next = 258;
  var prev = const <int>[];
  while (true) {
    if (bitPos + width > bits.length + 8) break;
    final code = readCode(width);
    if (code == clear) {
      initTable();
      width = 9;
      next = 258;
      prev = const [];
      continue;
    }
    if (code == eoi) break;
    List<int> entry;
    if (code < 256) {
      entry = [code];
    } else if (code < next) {
      entry = table[code];
    } else {
      entry = [...prev, if (prev.isNotEmpty) prev[0]];
    }
    out.addAll(entry);
    if (prev.isNotEmpty) {
      table.add([...prev, if (entry.isNotEmpty) entry[0]]);
      next++;
      // EarlyChange: bump the code width when the next code would equal
      // (2^width - 1) rather than 2^width.
      if (next == (1 << width) - 1 && width < 12) width++;
    }
    prev = entry;
  }
  return Uint8List.fromList(out);
}

/// Parses a PDF dictionary (the text between `<<` and `>>`) into a [Map].
class _DictParser {
  _DictParser(this.s) : pos = 0;
  final String s;
  int pos;

  Map<String, dynamic> parseDict() {
    final m = <String, dynamic>{};
    _parseDictInto(m);
    return m;
  }

  void _ws() {
    while (pos < s.length) {
      final c = s[pos];
      if (c == ' ' ||
          c == '\n' ||
          c == '\r' ||
          c == '\t' ||
          c.codeUnitAt(0) == 0) {
        pos++;
      } else if (c == '%') {
        while (pos < s.length && s[pos] != '\n') pos++;
      } else {
        break;
      }
    }
  }

  void _parseDictInto(Map<String, dynamic> m) {
    while (pos < s.length) {
      _ws();
      if (pos >= s.length) return;
      if (s[pos] == '>') {
        if (s.startsWith('>>', pos)) {
          pos += 2;
          return;
        }
        pos++;
        continue;
      }
      if (s[pos] != '/') {
        parseValue();
        continue;
      }
      var j = pos + 1;
      while (j < s.length && !_delim(s[j])) j++;
      final key = s.substring(pos, j);
      pos = j;
      final val = parseValue();
      m[key] = val;
    }
  }

  dynamic parseValue() {
    _ws();
    if (pos >= s.length) return null;
    final c = s[pos];
    if (c == '<') {
      if (s.startsWith('<<', pos)) {
        pos += 2;
        final m = <String, dynamic>{};
        _parseDictInto(m);
        return m;
      }
      return _parseHex();
    }
    if (c == '(') return _parseLiteral();
    if (c == '[') {
      pos++;
      final list = <dynamic>[];
      _ws();
      while (pos < s.length && s[pos] != ']') {
        list.add(parseValue());
        _ws();
      }
      if (pos < s.length) pos++;
      return list;
    }
    if (c == '/') {
      var j = pos + 1;
      while (j < s.length && !_delim(s[j])) j++;
      final name = s.substring(pos + 1, j);
      pos = j;
      return _Name(name);
    }
    if (_isNum(c)) {
      var j = pos + 1;
      while (j < s.length && !_delim(s[j])) j++;
      final numStr = s.substring(pos, j);
      pos = j;
      _ws();
      if (pos < s.length && _isNum(s[pos])) {
        final save = pos;
        var k = pos + 1;
        while (k < s.length && !_delim(s[k])) k++;
        final num2 = s.substring(pos, k);
        pos = k;
        _ws();
        if (pos < s.length && s[pos] == 'R') {
          pos++;
          final n1 = int.tryParse(numStr);
          final n2 = int.tryParse(num2);
          if (n1 != null && n2 != null) return _Ref(n1, n2);
          pos = save;
          return _num(numStr);
        }
        pos = save;
      }
      return _num(numStr);
    }
    var j = pos + 1;
    while (j < s.length && !_delim(s[j])) j++;
    pos = j;
    return null;
  }

  dynamic _num(String str) {
    if (str.isEmpty) return null;
    try {
      if (str.contains('.')) return double.parse(str);
      return int.parse(str);
    } catch (_) {
      return null;
    }
  }

  _PdfString _parseLiteral() {
    var j = pos + 1;
    var depth = 1;
    final out = <int>[];
    while (j < s.length) {
      final c = s[j];
      if (c == '\\') {
        if (j + 1 < s.length) {
          final n = s[j + 1];
          switch (n) {
            case 'n':
              out.add(0x0A);
              break;
            case 'r':
              out.add(0x0D);
              break;
            case 't':
              out.add(0x09);
              break;
            case 'b':
              out.add(0x08);
              break;
            case 'f':
              out.add(0x0C);
              break;
            case '(':
              out.add(0x28);
              break;
            case ')':
              out.add(0x29);
              break;
            case '\\':
              out.add(0x5C);
              break;
            default:
              if (n.compareTo('0') >= 0 && n.compareTo('7') <= 0) {
                var k = j + 1;
                var val = 0;
                var cnt = 0;
                while (k < s.length &&
                    cnt < 3 &&
                    s[k].compareTo('0') >= 0 &&
                    s[k].compareTo('7') <= 0) {
                  val = val * 8 + (s.codeUnitAt(k) - 0x30);
                  k++;
                  cnt++;
                }
                out.add(val & 0xFF);
                j = k - 1;
              } else {
                out.add(s.codeUnitAt(j + 1));
              }
          }
          j += 2;
          continue;
        }
        j++;
        continue;
      }
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) {
          j++;
          break;
        }
      }
      out.add(s.codeUnitAt(j));
      j++;
    }
    pos = j;
    return _PdfString(out);
  }

  _PdfString _parseHex() {
    var j = pos + 1;
    final out = <int>[];
    while (j < s.length && s[j] != '>') {
      final c = s[j];
      if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
        j++;
        continue;
      }
      final hi = _hexVal(c.codeUnitAt(0));
      j++;
      if (hi < 0) continue;
      if (j < s.length && s[j] != '>') {
        final lo = _hexVal(s[j].codeUnitAt(0));
        if (lo >= 0) {
          out.add(hi * 16 + lo);
          j++;
        } else {
          out.add(hi);
        }
      } else {
        out.add(hi);
      }
    }
    if (j < s.length) j++;
    pos = j;
    return _PdfString(out);
  }
}
