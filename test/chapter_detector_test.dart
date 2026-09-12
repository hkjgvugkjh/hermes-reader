import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_reader/reader/services/chapter_detector.dart';

void main() {
  test('detects 第N章 headings in document order', () {
    const text = '''
书名：示例
作者：测试

第一章 开端
一些正文内容。
第二章 发展
更多正文内容。
第三章 高潮
结尾内容。
''';
    final chapters = ChapterDetector.detect(text);
    expect(chapters.length, 3);
    expect(chapters[0].title, '第一章 开端');
    expect(chapters[1].title, '第二章 发展');
    expect(chapters[2].title, '第三章 高潮');
    // Offsets must point at the start of each heading line.
    expect(text.startsWith('第一章', chapters[0].offset), isTrue);
    expect(text.startsWith('第二章', chapters[1].offset), isTrue);
    expect(text.startsWith('第三章', chapters[2].offset), isTrue);
    // Later headings sit after earlier ones.
    expect(chapters[1].offset, greaterThan(chapters[0].offset));
  });

  test('collapses a repeated table-of-contents onto the real heading', () {
    const text = '''
目录
第一章 开端
第二章 发展

第一章 开端
正文。
第二章 发展
正文。
''';
    final chapters = ChapterDetector.detect(text);
    expect(chapters.length, 2);
    // The kept offset is the later (real) occurrence, not the TOC near the top.
    expect(text.startsWith('第一章', chapters[0].offset), isTrue);
    expect(chapters[0].offset, greaterThan(text.indexOf('目录')));
  });

  test('ignores ordinary prose that merely starts with 第', () {
    final text = List.generate(
      10,
      (i) =>
          '第十八条规定，任何单位和个人不得擅自改动，第$i次修订仍然长期有效。',
    ).join('\n');
    expect(ChapterDetector.detect(text), isEmpty);
  });

  test('returns nothing when fewer than two headings exist', () {
    const text = '前言\n只有一章内容。';
    expect(ChapterDetector.detect(text), isEmpty);
  });

  test('recognizes English Chapter / numeric / 序 headings', () {
    const text = '''
序
Chapter 1 The Beginning
正文。
2. The Middle
正文。
（三） The End
''';
    final chapters = ChapterDetector.detect(text);
    expect(chapters.map((c) => c.title), contains('序'));
    expect(chapters.map((c) => c.title), contains('Chapter 1 The Beginning'));
    expect(chapters.map((c) => c.title), contains('2. The Middle'));
    expect(chapters.map((c) => c.title), contains('（三） The End'));
  });
}
