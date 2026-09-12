import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_reader/reader/services/paginator_service.dart';

void main() {
  final paginator = PaginatorService();

  test('empty text yields no pages', () {
    expect(paginator.paginate(''), isEmpty);
  });

  test('long text is split by character budget', () {
    final text = List.filled(20, '段落内容一二三四五六七八九十').join('\n');
    final pages = paginator.paginate(text, charsPerPage: 50);

    expect(pages.length, greaterThan(1));
    for (final page in pages) {
      expect(page.content.length, lessThanOrEqualTo(50 + 20));
    }
  });

  test('page breaks win over character budget', () {
    const text = 'AAA BBB CCC';
    final pages = paginator.paginate(text, charsPerPage: 500, breakOffsets: [4, 8]);

    expect(pages.length, 3);
    expect(pages[0].content, 'AAA');
    expect(pages[1].content, 'BBB');
    expect(pages[2].content, 'CCC');
  });

  test('a break block longer than the budget is split further', () {
    final text = List.filled(1, '一二三四五六七八九十'.padRight(200, '。'));
    final pages = paginator.paginate(text.first,
        charsPerPage: 60, breakOffsets: [0]);

    expect(pages.length, greaterThan(1));
    for (final page in pages) {
      expect(page.content.length, lessThanOrEqualTo(80));
    }
  });

  test('out-of-range and descending breaks are discarded', () {
    final pages = paginator.paginate('AAAA BBBB',
        charsPerPage: 500, breakOffsets: [0, 5, 3, 999, -1]);

    expect(pages.length, 2);
    expect(pages[0].content, 'AAAA');
    expect(pages[1].content, 'BBBB');
  });

  test('breaks that carry no text do not create empty pages', () {
    final pages = paginator.paginate('AA\n\n\n\nBB',
        charsPerPage: 500, breakOffsets: [0, 2, 4]);

    expect(pages.every((p) => p.content.trim().isNotEmpty), isTrue);
  });

  test('progress spans the whole book', () {
    expect(paginator.progressFor(0, 5), 0.0);
    expect(paginator.progressFor(4, 5), 1.0);
    expect(paginator.progressFor(2, 5), closeTo(0.5, 0.001));
  });

  test('markdown noise is removed for speech', () {
    final spoken = paginator.toSpeechText('# 标题\n**粗体** 和 `代码`\n> 引用');
    expect(spoken, isNot(contains('#')));
    expect(spoken, isNot(contains('**')));
    expect(spoken, contains('粗体'));
    expect(spoken, contains('代码'));
  });
}
