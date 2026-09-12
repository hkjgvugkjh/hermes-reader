import '../models/book.dart';

/// Detects a book's format from its filename extension.
///
/// Used to decide whether the book can be read visually, narrated, or both.
class FileTypeDetector {
  const FileTypeDetector();

  /// Returns the [FileType] for [fileName], defaulting to [FileType.unknown].
  FileType detect(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return FileType.unknown;
    final ext = fileName.substring(dot).toLowerCase();

    switch (ext) {
      case '.txt':
      case '.md':
        return FileType.plainText;
      case '.pdf':
        return FileType.pdf;
      case '.epub':
        return FileType.epub;
      case '.mobi':
        return FileType.mobi;
      case '.html':
      case '.htm':
        return FileType.html;
      case '.json':
        return FileType.json;
      default:
        return FileType.unknown;
    }
  }

  /// True when this file type can be displayed visually.
  bool isReadable(FileType type) => type != FileType.unknown;

  /// True when this file type supports text extraction for narration.
  bool isNarratable(FileType type) =>
      type == FileType.plainText ||
      type == FileType.pdf ||
      type == FileType.epub;

  /// True when this file type requires special extraction before display.
  bool needsExtraction(FileType type) =>
      type == FileType.pdf ||
      type == FileType.epub ||
      type == FileType.html ||
      type == FileType.mobi ||
      type == FileType.json;
}