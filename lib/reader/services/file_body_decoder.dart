import 'dart:convert';
import 'dart:typed_data';

import '../models/book.dart';

/// Strips the JSON envelope the server puts around a file read.
///
/// `/api/studio/files/read` answers with `{"content": "..."}` rather than the
/// raw file. For text that is harmless once unwrapped, but for binary formats
/// the bytes were already decoded as UTF-8 on the server: everything above
/// 0x7F has become U+FFFD and cannot be recovered. Unwrapping still beats
/// showing the raw JSON, and is what makes plain text readable at all.
class FileBodyDecoder {
  const FileBodyDecoder();

  /// Returns the payload bytes.
  ///
  /// [type] guards the one case where the envelope is the content: a `.json`
  /// file that happens to have a `content` key of its own.
  Uint8List decode(Uint8List body, {FileType? type}) {
    if (body.isEmpty || type == FileType.json) return body;

    String text;
    try {
      // Strict on purpose: a real binary payload fails here and passes through
      // untouched.
      text = utf8.decode(body);
    } catch (_) {
      return body;
    }

    if (!text.trimLeft().startsWith('{')) return body;

    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> && decoded['content'] is String) {
        return Uint8List.fromList(utf8.encode(decoded['content'] as String));
      }
    } catch (_) {
      // Malformed JSON — hand back the original bytes.
    }
    return body;
  }

  /// True when [text] carries UTF-8 replacement characters, which is how a
  /// binary file announces it went through a string round-trip.
  static bool looksBinaryDamaged(String text) =>
      text.contains('\uFFFD') &&
      RegExp('\uFFFD').allMatches(text).length > text.length ~/ 100;
}
