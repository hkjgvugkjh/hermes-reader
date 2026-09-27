import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibEncoder, getCrc32;

/// A decoded image that Flutter's [Image.memory] can render.
class PdfImage {
  const PdfImage(this.bytes, this.mime, this.width, this.height);

  /// Decoded pixels (PNG) or the raw JPEG stream (DCTDecode).
  final Uint8List bytes;

  /// `image/jpeg` for DCTDecode streams, `image/png` otherwise.
  final String mime;
  final int width;
  final int height;
}

/// Sentinel placed inside extracted text to mark where a PDF image belongs.
///
/// The marker survives pagination (the paginator never cuts it in half), so the
/// reader can re-insert the picture inline with the surrounding text. The number
/// is an index into the document's image list.
String imageMarker(int index) => '\u0000IMG$index\u0000';

final RegExp imageMarkerRegex = RegExp(r'\u0000IMG(\d+)\u0000');

/// Removes image markers before text is shown as plain text or spoken aloud.
String stripImageMarkers(String text) => text.replaceAll(imageMarkerRegex, '');

/// Encodes raw 8-bit RGBA pixels as a PNG (colour type 6, no interlacing).
///
/// Used to turn PDF image streams decoded from FlateDecode (DeviceRGB/Gray/
/// CMYK/Indexed) into a format Flutter can display. Returns null for unusable
/// dimensions so callers can skip the image instead of crashing.
Uint8List? encodePngRgba(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0) return null;
  final stride = width * 4;
  if (rgba.length < stride * height) return null;

  // Each scanline is prefixed with a filter byte (0 = none), then zlib-compressed.
  final raw = Uint8List(stride * height + height);
  var p = 0;
  for (var y = 0; y < height; y++) {
    raw[p++] = 0;
    raw.setRange(p, p + stride, rgba, y * stride);
    p += stride;
  }
  final compressed = ZLibEncoder().encodeBytes(raw, level: 6);

  final out = BytesBuilder();
  out.add(_pngSignature);
  _writeChunk(out, 'IHDR', _ihdr(width, height));
  _writeChunk(out, 'IDAT', compressed);
  _writeChunk(out, 'IEND', const <int>[]);
  return out.takeBytes();
}

const List<int> _pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

List<int> _ihdr(int width, int height) => <int>[
      (width >> 24) & 0xff,
      (width >> 16) & 0xff,
      (width >> 8) & 0xff,
      width & 0xff,
      (height >> 24) & 0xff,
      (height >> 16) & 0xff,
      (height >> 8) & 0xff,
      height & 0xff,
      8, // bit depth
      6, // colour type: RGBA
      0, // compression
      0, // filter
      0, // interlace
    ];

void _writeChunk(BytesBuilder out, String type, List<int> data) {
  final typeBytes = latin1.encode(type);
  final len = data.length;
  out.addByte((len >> 24) & 0xff);
  out.addByte((len >> 16) & 0xff);
  out.addByte((len >> 8) & 0xff);
  out.addByte(len & 0xff);
  out.add(typeBytes);
  out.add(data);
  final crc = getCrc32(<int>[...typeBytes, ...data]);
  out.addByte((crc >> 24) & 0xff);
  out.addByte((crc >> 16) & 0xff);
  out.addByte((crc >> 8) & 0xff);
  out.addByte(crc & 0xff);
}
