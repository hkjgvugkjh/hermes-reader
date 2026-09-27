import 'package:gbk_codec/src/gbk_maps.dart' show json_gbk_to_char;

/// Fast GBK (GB2312-extended) byte → String decoder.
///
/// We reuse the mapping table shipped with `gbk_codec`, but decode in O(n)
/// time. The package's own decoder (`gbk_bytes.decode`) concatenates a growing
/// `String` inside its loop, which is O(n²) — on a 5 MB `.txt` that takes
/// minutes and makes the app appear to hang. This decoder builds the result
/// with a single [StringBuffer] pass, so even multi-megabyte books decode in a
/// few milliseconds.
Map<int, String>? _table;

Map<int, String> get _gbkToChar {
  return _table ??= {
    for (final e in json_gbk_to_char.entries) int.parse(e.key, radix: 16): e.value,
  };
}

/// Decodes [bytes] as GBK. Single bytes below 0x80 are ASCII; every other byte
/// is a lead byte combined with the following byte into a 2-byte GBK codepoint.
String decodeGbk(List<int> bytes) {
  final table = _gbkToChar;
  final buffer = StringBuffer();
  final n = bytes.length;
  var i = 0;
  while (i < n) {
    final b = bytes[i] & 0xff;
    i++;
    if (b < 0x80) {
      buffer.writeCharCode(b);
    } else if (i < n) {
      final code = (b << 8) | (bytes[i] & 0xff);
      i++;
      final ch = table[code];
      if (ch != null) {
        buffer.write(ch);
      } else {
        // Unknown lead byte — keep the raw byte rather than drop it.
        buffer.writeCharCode(b);
      }
    } else {
      // Trailing lead byte with no partner: emit as-is.
      buffer.writeCharCode(b);
    }
  }
  return buffer.toString();
}
