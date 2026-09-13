import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_reader/reader/models/book.dart';
import 'package:hermes_reader/reader/models/reader_config.dart';
import 'package:hermes_reader/reader/providers/library_provider.dart';

Book _book() => const Book(
      id: 's1::library/a.txt',
      serverId: 's1',
      serverName: 'server',
      relativePath: 'library/a.txt',
      title: 'a',
      sizeBytes: 100,
      fileType: FileType.plainText,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  ReaderProvider _provider({ReaderConfig? config}) => ReaderProvider(
        config: config ??
            const ReaderConfig(charsPerPage: 5, autoTurnPage: false),
      );

  Future<ReaderProvider> _opened({
    ReaderConfig? config,
    String text = 'AAAA BBBB CCCC DDDD EEEE',
  }) async {
    final reader = _provider(config: config);
    await reader.openBook(_book(), BookContent(bookId: _book().id, text: text));
    return reader;
  }

  test('opens on page 0 the first time', () async {
    final reader = await _opened();
    expect(reader.pageIndex, 0);
    expect(reader.pageCount, greaterThan(1));
  });

  group('tap zones', () {
    test('thirds: left goes back, right goes forward', () async {
      final reader = await _opened();
      reader.goToPage(1);

      reader.handleTap(0.1);
      expect(reader.pageIndex, 0);

      reader.handleTap(0.9);
      expect(reader.pageIndex, 1);
    });

    test('thirds: leftZoneForward reverses the direction', () async {
      final reader = await _opened(
        config: const ReaderConfig(
            charsPerPage: 5, tapZoneMode: TapZoneMode.thirds, leftZoneForward: true),
      );

      reader.handleTap(0.1);
      expect(reader.pageIndex, 1);

      reader.handleTap(0.9);
      expect(reader.pageIndex, 0);
    });

    test('halves: every tap navigates', () async {
      final reader = await _opened(
        config: const ReaderConfig(charsPerPage: 5, tapZoneMode: TapZoneMode.halves),
      );
      reader.goToPage(1);

      reader.handleTap(0.1);
      expect(reader.pageIndex, 0);

      reader.handleTap(0.9);
      expect(reader.pageIndex, 1);

      expect(reader.isToggleZone(0.5), isFalse);
    });

    test('edges: only the outer 10% navigate', () async {
      final reader = await _opened(
        config: const ReaderConfig(charsPerPage: 5, tapZoneMode: TapZoneMode.edges),
      );
      reader.goToPage(1);

      reader.handleTap(0.5);
      expect(reader.pageIndex, 1, reason: 'centre must not navigate');

      reader.handleTap(0.05);
      expect(reader.pageIndex, 0);

      reader.handleTap(0.95);
      expect(reader.pageIndex, 1);
    });

    test('centre of thirds toggles controls instead of paging', () async {
      final reader = await _opened();
      reader.goToPage(1);

      expect(reader.isToggleZone(0.5), isTrue);
      reader.handleTap(0.5);
      expect(reader.pageIndex, 1);
    });

    test('navigation stops at the boundaries', () async {
      final reader = await _opened();

      expect(reader.previousPage(), isFalse);
      for (var i = 0; i < 20; i++) {
        reader.nextPage();
      }
      expect(reader.pageIndex, reader.pageCount - 1);
      expect(reader.nextPage(), isFalse);
    });
  });

  group('reading progress', () {
    test('position survives a reopen', () async {
      final first = await _opened();
      first.goToPage(2);
      await first.savePosition();

      final second = await _opened();
      expect(second.pageIndex, 2);
    });

    test('a saved page beyond the current text falls back to 0', () async {
      final first = await _opened();
      first.goToPage(3);
      await first.savePosition();

      final second = await _opened(text: 'AB');
      expect(second.pageIndex, 0);
    });

    test('loadProgress exposes the saved position', () async {
      final reader = await _opened();
      reader.goToPage(1);
      await reader.savePosition();

      final saved = await reader.loadProgress(_book().id);
      expect(saved, isNotNull);
      expect(saved!.pageIndex, 1);
    });
  });

  group('narration progress', () {
    test('round-trips page and character offset', () async {
      final reader = await _opened();
      await reader.saveNarration(pageIndex: 2, charOffset: 42);

      final saved = await reader.loadNarration(_book().id);
      expect(saved, isNotNull);
      expect(saved!.pageIndex, 2);
      expect(saved.charOffset, 42);
    });

    test('clearing removes it', () async {
      final reader = await _opened();
      await reader.saveNarration(pageIndex: 1, charOffset: 7);
      await reader.clearNarration();

      expect(await reader.loadNarration(_book().id), isNull);
    });

    test('narration position is independent of reading position', () async {
      final reader = await _opened();
      reader.goToPage(2);
      await reader.savePosition();
      await reader.saveNarration(pageIndex: 3, charOffset: 10);

      final reading = await reader.loadProgress(_book().id);
      final narration = await reader.loadNarration(_book().id);

      expect(reading!.pageIndex, 2);
      expect(narration!.pageIndex, 3);
    });
  });

  test('changing page size re-paginates and clamps the index', () async {
    final reader = await _opened();
    while (reader.nextPage()) {}

    reader.updateConfig(reader.config.copyWith(charsPerPage: 1000));
    expect(reader.pageIndex, lessThan(reader.pageCount));
  });

  group('chapter detection', () {
    test('builds a toc in the background and jumps to a chapter', () async {
      final text = [
        '序言',
        '第一章 开始',
        '正文内容。' * 50,
        '第二章 发展',
        '正文内容。' * 50,
        '第三章 结束',
        '正文内容。' * 50,
      ].join('\n');
      final reader = await _opened(text: text);

      // Detection runs on a background isolate; wait for it to publish.
      for (var i = 0; i < 100 && !reader.hasChapters; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(reader.hasChapters, isTrue);
      expect(reader.chapters.length, 4);

      reader.goToPage(0);
      reader.goToChapter(2);
      expect(reader.pageIndex, greaterThan(0));
      expect(reader.currentChapterIndex, 2);
    });
  });
}
