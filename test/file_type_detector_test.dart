import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_reader/reader/models/book.dart';
import 'package:hermes_reader/reader/services/file_type_detector.dart';

void main() {
  const detector = FileTypeDetector();

  test('detects every supported extension', () {
    expect(detector.detect('a.txt'), FileType.plainText);
    expect(detector.detect('a.md'), FileType.plainText);
    expect(detector.detect('a.pdf'), FileType.pdf);
    expect(detector.detect('a.EPUB'), FileType.epub);
    expect(detector.detect('a.mobi'), FileType.mobi);
    expect(detector.detect('a.html'), FileType.html);
    expect(detector.detect('a.htm'), FileType.html);
    expect(detector.detect('a.json'), FileType.json);
  });

  test('unknown or malformed names fall back to unknown', () {
    expect(detector.detect('README'), FileType.unknown);
    expect(detector.detect('archive.zip'), FileType.unknown);
    expect(detector.detect('trailing.'), FileType.unknown);
    expect(detector.detect(''), FileType.unknown);
  });

  test('only text-bearing formats are narratable', () {
    expect(detector.isNarratable(FileType.plainText), isTrue);
    expect(detector.isNarratable(FileType.pdf), isTrue);
    expect(detector.isNarratable(FileType.epub), isTrue);
    expect(detector.isNarratable(FileType.mobi), isFalse);
    expect(detector.isNarratable(FileType.html), isFalse);
    expect(detector.isNarratable(FileType.json), isFalse);
    expect(detector.isNarratable(FileType.unknown), isFalse);
  });

  test('everything but unknown is readable', () {
    for (final type in FileType.values) {
      expect(detector.isReadable(type), type != FileType.unknown);
    }
  });

  test('container formats need extraction before display', () {
    expect(detector.needsExtraction(FileType.plainText), isFalse);
    expect(detector.needsExtraction(FileType.pdf), isTrue);
    expect(detector.needsExtraction(FileType.epub), isTrue);
    expect(detector.needsExtraction(FileType.mobi), isTrue);
  });
}
