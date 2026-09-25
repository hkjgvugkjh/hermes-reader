import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/chapter_page_info.dart';
import '../models/reader_config.dart';
import '../services/paginator_service.dart';
import '../services/pdf_image_decoder.dart';
import '../services/narration_progress_service.dart';
import '../services/reader_config_storage.dart';
import '../services/reading_progress_service.dart';
import '../services/library_sandbox.dart';
import '../services/library_service.dart';
import '../services/chapter_detector.dart';
import '../services/annotation_store.dart';
import '../services/comment_sync_service.dart';
import '../models/reader_annotations.dart';

/// Runs chapter detection off the UI thread (see [ChapterDetector.detect]).
/// Must be a top-level function so it can be passed to [compute].
List<Map<String, dynamic>> _detectChaptersTask(String text) =>
    ChapterDetector.detect(text)
        .map((c) => <String, dynamic>{'title': c.title, 'offset': c.offset})
        .toList();

/// Owns the bookshelf: listing, downloading and cached copies.
class LibraryProvider extends ChangeNotifier {
  LibraryProvider(this._service);

  final LibraryService _service;

  final List<Book> _books = [];
  List<Book> get books => List.unmodifiable(_books);

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  /// Books already on the device, by id.
  final Set<String> _cached = {};
  bool isCached(Book book) => _cached.contains(book.id);

  /// Download progress keyed by book id, 0.0 - 1.0.
  final Map<String, double> _progress = {};
  double progressFor(String bookId) => _progress[bookId] ?? 0.0;

  /// Live download stats keyed by book id, so the UI can show
  /// "downloaded x of y" and the current transfer rate.
  final Map<String, DownloadProgress> _dl = {};
  DownloadProgress? downloadStatsFor(String bookId) => _dl[bookId];

  /// Which server's listing is currently shown.
  String? _activeServerId;
  String? get activeServerId => _activeServerId;

  /// Loads the shelf for [serverId]. [transport] is supplied by the caller so
  /// this provider stays independent of the connection mode.
  Future<void> refresh({
    required FileTransport transport,
    required String serverId,
    required String serverName,
  }) async {
    _loading = true;
    _error = null;
    _activeServerId = serverId;
    notifyListeners();

    try {
      final books = await _service.listBooks(
        transport: transport,
        serverId: serverId,
        serverName: serverName,
      );
      print('[SHELF] got ${books.length} books for $serverId');
      _books
        ..clear()
        ..addAll(books);

      // Mark which ones are already local so the UI can show "read" vs
      // "download" without a network round trip.
      _cached.clear();
      for (final book in books) {
        if (await _service.isCached(book)) {
          _cached.add(book.id);
        }
      }
    } catch (e, st) {
      print('[SHELF] listBooks failed: $e');
      print('[SHELF] $st');
      _error = e is LibrarySandboxError ? e.message : e.toString();
      _books.clear();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Books currently being downloaded, by id. Lets the UI show a spinner and
  /// block re-entrant taps while a download is in flight.
  final Set<String> _downloading = {};
  bool isDownloading(String bookId) => _downloading.contains(bookId);

  /// Downloads a book and returns its content, or null on failure.
  Future<BookContent?> download({
    required FileTransport transport,
    required Book book,
    String? encoding,
  }) async {
    if (_downloading.contains(book.id)) return null;
    _error = null;
    _downloading.add(book.id);
    _progress[book.id] = 0.0;
    _dl[book.id] = DownloadProgress(
      received: 0,
      total: book.sizeBytes,
      rateBps: 0,
    );
    notifyListeners();

    try {
      final content = await _service.downloadBook(
        transport: transport,
        book: book,
        encoding: encoding,
        onProgress: (p) {
          _progress[book.id] = p.total > 0
              ? p.fraction
              : (p.received > 0 ? 0.01 : 0.0);
          _dl[book.id] = p;
          notifyListeners();
        },
      );
      _cached.add(book.id);
      _progress[book.id] = 1.0;
      notifyListeners();
      return content;
    } catch (e) {
      _error = e is LibrarySandboxError ? e.message : e.toString();
      _progress.remove(book.id);
      notifyListeners();
      return null;
    } finally {
      _downloading.remove(book.id);
      _dl.remove(book.id);
      notifyListeners();
    }
  }

  /// Opens a book, using the local copy when present.
  ///
  /// [encoding] forces a specific codepage (e.g. 'gbk') so a manual charset
  /// fix is reapplied (and persisted) for either the cached or freshly
  /// downloaded copy.
  Future<BookContent?> open({
    required FileTransport transport,
    required Book book,
    String? encoding,
  }) async {
    final cached = await _service.readCached(book, encoding: encoding);
    if (cached != null) return cached;
    return download(transport: transport, book: book, encoding: encoding);
  }

  /// Reads the locally cached copy of [book], optionally forcing a specific
  /// [encoding] (e.g. 'gbk') so a manual charset fix is reapplied and persisted.
  Future<BookContent?> readCached(Book book, {String? encoding}) =>
      _service.readCached(book, encoding: encoding);

  Future<void> remove(Book book) async {
    await _service.deleteCached(book);
    _cached.remove(book.id);
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}

/// Owns the currently open book: pagination, position and narration.
class ReaderProvider extends ChangeNotifier {
  ReaderProvider({
    ReaderConfig? config,
    PaginatorLike? paginator,
    ReadingProgressService? progressService,
    NarrationProgressService? narrationProgressService,
    ReaderConfigStorage? configStorage,
    AnnotationStore? annotationStore,
    CommentSync? commentSync,
    String? deviceId,
  }) : _config = config ?? const ReaderConfig(),
       _paginator = paginator,
       _progressService = progressService ?? ReadingProgressService(),
       _narrationProgress =
           narrationProgressService ?? NarrationProgressService(),
       _configStorage = configStorage,
       _annotations = annotationStore ?? AnnotationStore(),
       _commentSync = commentSync,
       _deviceId = deviceId ?? 'device';

  ReaderConfig _config;
  ReaderConfig get config => _config;

  final PaginatorLike? _paginator;

  Book? _book;
  Book? get book => _book;

  String? _error;
  String? get error => _error;

  void setError(String? message) {
    _error = message;
    notifyListeners();
  }

  /// Persists settings when a storage was injected; optional so tests can run
  /// without platform channels.
  final ReaderConfigStorage? _configStorage;

  void updateConfig(ReaderConfig config) {
    final fontChanged = config.fontScale != _config.fontScale;
    _config = config;
    // Re-paginate only when the page size actually changed — re-paginating on
    // an unrelated setting would jump the reader back to page 0.
    if (_content != null && config.charsPerPage != _lastPageChars) {
      _viewportSig = ''; // force re-pagination on the next layout pass
      savePosition();
    }
    // Font size change invalidates all chapter page caches — the pages were
    // computed for the old font metrics. Clear caches and recompute.
    if (fontChanged && _content != null) {
      _chapterPages.clear();
    }
    // Any config change may alter the page size; force the reader screen's
    // next layout pass to re-sync the viewport-based pagination.
    _viewportSig = '';
    notifyListeners();
    _configStorage?.save(config);
  }

  /// The open book's content, kept whole so page breaks survive re-pagination.
  BookContent? _content;
  int _lastPageChars = 700;

  /// Exposes the raw content so the screen can re-flow it with real metrics.
  BookContent? get content => _content;

  final List<BookPage> _pages = [];
  List<BookPage> get pages => List.unmodifiable(_pages);

  /// Chapter headings detected in the background, in document order.
  List<ChapterMark> _chapters = const [];
  List<ChapterMark> get chapters => _chapters;

  /// True once enough headings were found to build a usable table of contents.
  bool get hasChapters => _chapters.length >= 2;

  /// Index of the chapter containing the current page, or -1 when none.
  int get currentChapterIndex {
    if (_chapters.isEmpty) return -1;
    final offset = currentPage?.startOffset ?? 0;
    var idx = 0;
    for (var i = 0; i < _chapters.length; i++) {
      if (_chapters[i].offset <= offset) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  /// Chapter pagination info, keyed by chapter index.
  final Map<int, ChapterPageInfo> _chapterPages = {};

  /// Returns the [ChapterPageInfo] for [chapterIndex], or null if not computed.
  ChapterPageInfo? chapterPageInfo(int chapterIndex) =>
      _chapterPages[chapterIndex];

  /// Whether the initial 5-page batch has been computed for [chapterIndex].
  bool hasChapterInitialBatch(int chapterIndex) =>
      _chapterPages[chapterIndex]?.hasInitialBatch ?? false;

  /// Scans the full book text for chapter boundaries and stores the ranges.
  ///
  /// This is called once on book open. The actual per-chapter pagination is
  /// done lazily via [ensureChapterPages].
  List<ChapterRange> _chapterRanges = const [];

  /// Scans the book text for chapter boundaries. Called on book open.
  void _scanChapters(String text) {
    final breaks = _content?.pageBreaks;
    // Large plain-text books have no PDF/EPUB breaks and (usually) no markdown
    // headings, so splitting the whole text just to find none would block the
    // UI for seconds. Skip it and let [_detectChapters] find real "第N章"
    // boundaries asynchronously.
    if ((breaks == null || breaks.isEmpty) && text.length > 200000) {
      _chapterRanges = [ChapterRange(startOffset: 0, endOffset: text.length)];
      return;
    }
    _chapterRanges = PaginatorService()
        .scanChapters(text, breakOffsets: breaks)
        .map(
          (r) =>
              ChapterRange(startOffset: r.startOffset, endOffset: r.endOffset),
        )
        .toList();
  }

  /// Ensures that the initial 5-page batch has been computed for [chapterIndex].
  ///
  /// If the chapter has not been paginated yet, computes the first 5 pages
  /// in a background isolate. Subsequent calls are no-ops until the batch
  /// is ready.
  Future<void> ensureChapterPages(
    int chapterIndex, {
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    required double nonFullscreenMaxHeight,
    bool force = false,
  }) async {
    if (_chapterPages.containsKey(chapterIndex) && !force) return;
    if (chapterIndex < 0 || chapterIndex >= _chapterRanges.length) return;

    final range = _chapterRanges[chapterIndex];
    final text = _content?.text;
    if (text == null) return;

    final info = await PaginatorService.paginateChapterIsolate(
      text,
      chapterIndex: chapterIndex,
      chapterTitle: chapterIndex < _chapters.length
          ? _chapters[chapterIndex].title
          : '章节 ${chapterIndex + 1}',
      chapterStartOffset: range.startOffset,
      chapterEndOffset: range.endOffset,
      style: style,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      nonFullscreenMaxHeight: nonFullscreenMaxHeight,
      initialBatch: 5,
    );

    _chapterPages[chapterIndex] = info;
    // Sync the page list for the current mode into _pages so the reader
    // screen can keep using reader.pages / reader.currentPage.
    _syncPagesForMode(info, fullscreen: _isFullscreen);
    notifyListeners();
  }

  /// Incrementally computes remaining pages for [chapterIndex] after the
  /// initial 5-page batch has been shown.
  ///
  /// Called after the user has finished paging through the initial batch,
  /// so the UI stays responsive while the rest of the chapter is computed.
  Future<void> computeRemainingChapterPages(
    int chapterIndex, {
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    required double nonFullscreenMaxHeight,
  }) async {
    final existing = _chapterPages[chapterIndex];
    if (existing == null || !existing.hasInitialBatch) return;
    if (chapterIndex < 0 || chapterIndex >= _chapterRanges.length) return;

    final range = _chapterRanges[chapterIndex];
    final text = _content?.text;
    if (text == null) return;

    final info = await PaginatorService.paginateChapterIsolate(
      text,
      chapterIndex: chapterIndex,
      chapterTitle: existing.chapterTitle,
      chapterStartOffset: range.startOffset,
      chapterEndOffset: range.endOffset,
      style: style,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      nonFullscreenMaxHeight: nonFullscreenMaxHeight,
      initialBatch: -1, // compute all remaining pages
    );

    _chapterPages[chapterIndex] = info;
    _syncPagesForMode(info, fullscreen: _isFullscreen);
    notifyListeners();
  }

  /// Syncs the page list for [info] into [_pages] based on [fullscreen].
  void _syncPagesForMode(ChapterPageInfo info, {required bool fullscreen}) {
    final source = fullscreen ? info.fullScreenPages : info.notFullScreenPages;
    if (source.isEmpty) return;
    _pages
      ..clear()
      ..addAll(
        source.map(
          (e) => BookPage(
            index: e.pageIndex,
            content:
                pageContentAtOffset(e.startOffset, fullscreen: fullscreen) ??
                '',
            startOffset: e.startOffset,
          ),
        ),
      );
    if (_pageIndex >= _pages.length) {
      _pageIndex = _pages.isEmpty ? 0 : _pages.length - 1;
    }
  }

  /// Returns the page index within the current chapter for [chapterIndex],
  /// or -1 when the chapter has not been paginated yet.
  int pageIndexInChapter(int chapterIndex, {required bool fullscreen}) {
    final info = _chapterPages[chapterIndex];
    if (info == null) return -1;
    final pages = fullscreen ? info.fullScreenPages : info.notFullScreenPages;
    if (pages.isEmpty) return -1;
    return pages.last.pageIndex;
  }

  /// Returns the content for the page starting at [offset].
  ///
  /// Used by [_syncPagesForMode] to populate [BookPage.content] from the
  /// chapter page info. Returns null when the offset is out of range.
  ///
  /// The returned content is rtrimmed to remove trailing whitespace/newlines
  /// that would otherwise cause the rendered Text to overflow its measured
  /// height (trailing whitespace is collapsed by the layout engine but
  /// still occupies vertical space in some font configurations).
  String? pageContentAtOffset(int offset, {required bool fullscreen}) {
    final text = _content?.text;
    if (text == null || offset < 0 || offset >= text.length) return null;
    final chapterIdx = _chapterRanges.indexWhere(
      (r) => r.startOffset <= offset && r.endOffset > offset,
    );
    if (chapterIdx < 0) return null;
    final info = _chapterPages[chapterIdx];
    if (info == null) return null;
    final pages = fullscreen ? info.fullScreenPages : info.notFullScreenPages;
    if (pages.isEmpty) return null;
    final idx = pages.indexWhere((p) => p.startOffset == offset);
    if (idx < 0) return null;
    final end = (idx + 1 < pages.length)
        ? pages[idx + 1].startOffset
        : _chapterRanges[chapterIdx].endOffset;
    // rtrim 去除尾部空白/换行，避免渲染溢出
    return text.substring(offset, end).trimRight();
  }

  /// Returns the total number of pages in [chapterIndex] for the given mode.
  int chapterPageCount(int chapterIndex, {required bool fullscreen}) {
    return _chapterPagesCount(chapterIndex);
  }

  /// Total pages across all chapters.
  ///
  /// 已测量章节用真实页数；未测量章节用字符数估算（每页 ~_estimatedCharsPerPage
  /// 字），避免在全局分页完成前 Z 值失真（旧逻辑未测量章节一律算 1 页）。
  /// 该估算不触发任何测量，绝不阻塞主线程。
  int get totalBookPages {
    if (_chapterRanges.isEmpty) return pageCount > 0 ? pageCount : 1;
    var total = 0;
    for (var i = 0; i < _chapterRanges.length; i++) {
      total += _chapterPagesCount(i);
    }
    return total;
  }

  /// Whether background pagination is currently running.
  bool get isGlobalPaginating => _globalPaginating;

  /// Progress of background pagination: chapters completed / total chapters.
  double get globalPaginationProgress {
    if (_chapterRanges.isEmpty) return 0;
    return _paginatedChapterCount / _chapterRanges.length;
  }

  /// Number of chapters already paginated (for progress display).
  int get paginatedChapterCount => _paginatedChapterCount;

  /// Total number of chapters in the book (for progress display).
  int get totalChapterCount => _chapterRanges.length;

  /// Current chapter being paginated (for progress display).
  int? _globalPaginatingChapterIndex;
  bool _globalPaginating = false;
  int _paginatedChapterCount = 0;

  /// Paginates all chapters in the background, updating [totalBookPages] and
  /// [chapterPageCount] as each chapter completes. Shows progress in the footer.
  ///
  /// Uses [initialBatch] = 5 for fast first pass: each chapter computes only
  /// the first 5 pages quickly, so the progress bar moves within seconds.
  /// Subsequent pages are computed incrementally as the user pages through.
  ///
  /// If [updateCurrentChapter] is true and the current chapter is paginated,
  /// the current chapter's page list is also refreshed.
  Future<void> paginateAllChapters({
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    required double nonFullscreenMaxHeight,
    bool updateCurrentChapter = true,
  }) async {
    if (_chapterRanges.isEmpty || _globalPaginating) return;
    _globalPaginating = true;
    _paginatedChapterCount = 0;
    _globalPaginatingChapterIndex = null;
    notifyListeners();

    final totalChapters = _chapterRanges.length;
    final stopwatch = Stopwatch()..start();
    debugPrint('[分页] 开始全局分页(非阻塞估算): $totalChapters 章');

    // 不再逐章调用 paginateChapterIsolate：其实现在主 isolate 同步执行
    // TextPainter，1498 章 × ~45ms ≈ 67s 霸占主线程，导致首屏空白/UI 冻结。
    // totalBookPages(Z) 现已用字符数即时估算（见 _estimatedChapterPages），
    // 无需真正测量即可得到合理 Z。本循环仅做非阻塞的进度推进：每章 yield 一次，
    // 让出主线程，进度条正常动画；真实测量由各章懒加载（syncViewportChars/
    // _ensureAhead）在用户翻到时按需完成。
    final batchYieldEvery = 1; // 每章让出一次，保证 UI 不卡
    for (var i = 0; i < totalChapters; i++) {
      // 取消检查：如果 _globalPaginating 被重置（如打开新书），立即停止
      if (!_globalPaginating) {
        debugPrint('[分页] 全局分页被取消（第 $i 章）');
        return;
      }
      _globalPaginatingChapterIndex = i;
      _paginatedChapterCount = i + 1;
      // 每章让出主线程，避免阻塞（await 一个微任务即可让出 UI 帧）
      if (i % batchYieldEvery == 0) {
        await Future.delayed(Duration.zero);
      }
      notifyListeners();
    }

    stopwatch.stop();
    debugPrint('[分页] 全局分页(估算)完成: $totalChapters 章, 总耗时 ${stopwatch.elapsedMilliseconds}ms');
    _globalPaginating = false;
    _globalPaginatingChapterIndex = null;
    notifyListeners();
  }

  /// Current page number across the whole book (1-based).
  ///
  /// Sum of pages in all chapters before [currentChapterIndex], plus the
  /// current page index within the chapter, plus 1. Unpaginated chapters
  /// are estimated as 1 page each.
  int get globalPageIndex {
    final chapterIdx = currentChapterIndex;
    if (chapterIdx < 0) return pageIndex + 1;
    var offset = 0;
    for (var i = 0; i < chapterIdx; i++) {
      offset += _chapterPagesCount(i);
    }
    return offset + pageIndex + 1;
  }

  /// Returns the character offset of the first page in [chapterIndex].
  int chapterStartOffset(int chapterIndex) {
    if (chapterIndex < 0 || chapterIndex >= _chapterRanges.length) return 0;
    return _chapterRanges[chapterIndex].startOffset;
  }

  /// Returns the character offset of the last page in [chapterIndex].
  int chapterEndOffset(int chapterIndex) {
    if (chapterIndex < 0 || chapterIndex >= _chapterRanges.length) return 0;
    return _chapterRanges[chapterIndex].endOffset;
  }

  /// Images pulled from the source, indexed by the [imageMarker] tokens embedded
  /// in each [BookPage.content].
  List<PdfImage> get images => _content?.images ?? const [];

  int _pageIndex = 0;
  int get pageIndex => _pageIndex;
  int get pageCount => _pages.length;
  bool get hasBook => _pages.isNotEmpty;

  /// Full-screen reading mode (no app bar, no footer, just text).
  bool _isFullscreen = false;
  bool get isFullscreen => _isFullscreen;

  void toggleFullscreen() {
    _isFullscreen = !_isFullscreen;
    // Re-sync pages for the current chapter in the new mode
    final chapterIdx = currentChapterIndex;
    if (chapterIdx >= 0) {
      final info = _chapterPages[chapterIdx];
      if (info != null) {
        _syncPagesForMode(info, fullscreen: _isFullscreen);
      }
    }
    notifyListeners();
  }

  BookPage? get currentPage => (_pages.isEmpty || _pageIndex >= _pages.length)
      ? null
      : _pages[_pageIndex];

  bool get atEnd => _pages.isEmpty || _pageIndex >= _pages.length - 1;
  bool get atStart => _pageIndex <= 0;

  /// Whole-book progress. Pages now only cover the current chapter, so progress
  /// is derived from the character offset instead of the page index.
  double get progress {
    final text = _content?.text;
    final offset = currentPage?.startOffset;
    if (text == null || text.isEmpty || offset == null) return 0.0;
    return (offset / text.length).clamp(0.0, 1.0);
  }

  final ReadingProgressService _progressService;
  final NarrationProgressService _narrationProgress;

  /// Saved reading position for [bookId], used by the shelf to offer
  /// "continue" instead of a blind restart.
  Future<ReadingProgress?> loadProgress(String bookId) =>
      _progressService.load(bookId);

  /// Where narration stopped, or null when the book has never been read aloud.
  Future<NarrationProgress?> loadNarration(String bookId) =>
      _narrationProgress.load(bookId);

  /// Records the spoken position so the next session can resume.
  Future<void> saveNarration({
    required int pageIndex,
    required int charOffset,
  }) {
    final book = _book;
    if (book == null) return Future<void>.value();
    return _narrationProgress.save(
      NarrationProgress(
        bookId: book.id,
        pageIndex: pageIndex,
        charOffset: charOffset,
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// Clears the spoken position once a book has been read to the end.
  Future<void> clearNarration() {
    final book = _book;
    if (book == null) return Future<void>.value();
    return _narrationProgress.clear(book.id);
  }

  /// Opens [content] for [book], restoring saved position when available.
  Future<void> openBook(Book book, BookContent content) async {
    _book = book;
    _content = content;
    _error = null;
    _chapters = const [];
    _chapterPages.clear();
    _pages.clear();
    _viewportSig = ''; // force re-pagination with the new content
    // 重置全局分页状态：避免旧任务阻塞新打开的书
    _globalPaginating = false;
    _paginatedChapterCount = 0;
    _globalPaginatingChapterIndex = null;
    _scanChapters(content.text);

    // Seed the reader with a character-based pass so there is always a page to
    // show (and turning pages works) before — or in the worst case instead
    // of — the viewport-accurate pass. syncViewportChars() replaces these with
    // real measured pages as soon as the first layout is available.
    try {
      _rebuildPages();
    } catch (e) {
      debugPrint('[reader] seed pagination failed: $e');
    }

    // Restore the saved reading position by offset. Exact pagination runs
    // lazily from the first layout pass (see syncViewportChars).
    final saved = await _progressService.load(book.id);
    _resumeOffset =
        (saved != null &&
            saved.offset > 0 &&
            saved.offset < content.text.length)
        ? saved.offset
        : 0;
    _pageIndex = _pages.isEmpty ? 0 : _pageIndexForOffset(_resumeOffset);
    notifyListeners();

    // Build the table of contents on a background isolate (see _detectChapters).
    // It used to be deferred to addPostFrameCallback, but detection never
    // blocks the UI thread anyway, and the deferral made it never run outside a
    // pumped widget tree (unit tests never see a TOC at all).
    _detectChapters();
    // Load local bookmarks/notes and any shared comments for this book.
    await loadAnnotations();
  }

  /// Detects chapter headings on a background isolate and publishes them.
  ///
  /// Best-effort: any failure silently leaves [_chapters] empty so reading is
  /// never blocked on detection.
  Future<void> _detectChapters() async {
    final text = _content?.text;
    if (text == null || text.isEmpty) return;
    try {
      final raw = await compute(_detectChaptersTask, text);
      _chapters = raw
          .map(
            (m) => ChapterMark(
              title: m['title'] as String,
              offset: m['offset'] as int,
            ),
          )
          .toList();
      // Detection found real chapter boundaries (e.g. "第N章") — adopt them as
      // the pagination ranges so each chapter is paginated on its own instead
      // of treating the whole book as one giant chapter (which would force
      // _ensureAhead to paginate millions of characters at once).
      final textLen = _content?.text.length ?? 0;
      _chapterRanges = _chaptersToRanges(_chapters, textLen);
      _chapterComplete.clear();
      // Chapter detection finishing changes the page breaks (each heading
      // starts a new page), so invalidate the viewport pagination cache and
      // let the next layout pass re-flow with the new boundaries.
      _viewportSig = '';
      notifyListeners();
      // 章节检测完成后，触发全局分页：后台逐章计算总页数，更新 Z 值。
      // 实际测量参数由阅读界面 LayoutBuilder 提供；此处先以章节单位估算，
      // 待布局完成后按真实可视尺寸重新计算。
      debugPrint('[分页] _detectChapters 完成, ${_chapterRanges.length} 章, 准备触发全局分页');
      if (_chapterRanges.isNotEmpty && !_globalPaginating) {
        final fontSize = ReaderConfig.baseFontSize * _config.fontScale;
        final style = TextStyle(
          fontSize: fontSize,
          height: _config.lineHeightFactor,
        );
        debugPrint('[分页] 触发 paginateAllChapters: maxWidth=400, maxHeight=400');
        // 延迟到下一帧，避免阻塞章节检测完成后的 UI 刷新
        Future.delayed(Duration.zero, () {
          debugPrint('[分页] Future.delayed 回调执行, 开始调用 paginateAllChapters');
          paginateAllChapters(
            style: style,
            maxWidth: 400, // 占位值；真实值由阅读界面的 LayoutBuilder 覆盖
            maxHeight: 400,
            nonFullscreenMaxHeight: 300,
            updateCurrentChapter: true,
          ).then((_) {
            debugPrint('[分页] paginateAllChapters 完成');
          }).catchError((e) {
            debugPrint('[分页] paginateAllChapters 错误: $e');
          });
        });
      } else {
        debugPrint('[分页] 跳过全局分页: ranges=${_chapterRanges.length}, paginating=$_globalPaginating');
      }
    } catch (_) {
      _chapters = const [];
    }
  }

  /// Builds [ChapterRange]s from detected chapter [marks], covering the whole
  /// text. A preamble before the first heading (if any) becomes its own range.
  List<ChapterRange> _chaptersToRanges(List<ChapterMark> marks, int textLen) {
    if (marks.isEmpty || textLen == 0) {
      return [ChapterRange(startOffset: 0, endOffset: textLen)];
    }
    final sorted = [...marks]..sort((a, b) => a.offset.compareTo(b.offset));
    final ranges = <ChapterRange>[];
    var prev = 0;
    for (final m in sorted) {
      if (m.offset > prev) {
        ranges.add(ChapterRange(startOffset: prev, endOffset: m.offset));
      } else if (m.offset < prev) {
        continue;
      }
      prev = m.offset;
    }
    if (prev < textLen) {
      ranges.add(ChapterRange(startOffset: prev, endOffset: textLen));
    }
    return ranges.isEmpty
        ? [ChapterRange(startOffset: 0, endOffset: textLen)]
        : ranges;
  }

  /// Maps a character [offset] in the full text to the page that contains it.
  int _pageIndexForOffset(int offset) {
    if (_pages.isEmpty) return 0;
    var idx = 0;
    for (var i = 0; i < _pages.length; i++) {
      if (_pages[i].startOffset <= offset) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  /// Jumps to the page where the chapter at [index] begins.
  ///
  /// Because chapter heading offsets are passed as page breaks to the
  /// paginator, the heading always starts a fresh page whose `startOffset`
  /// equals the heading offset, so the heading lands at the screen top.
  Future<void> goToChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    final offset = _chapters[index].offset;
    if (!_canPaginate()) {
      // No layout yet (unit tests, or before the reader's first layout pass):
      // jump inside the character-based pages instead of silently doing
      // nothing — otherwise tapping a chapter would look broken.
      if (_pages.isNotEmpty) {
        _pageIndex = _pageIndexForOffset(
          offset,
        ).clamp(0, _pages.length - 1).toInt();
        notifyListeners();
      }
      await savePosition();
      return;
    }
    final target = _chapterIndexForOffset(offset);
    await _paginateChapter(target, initialBatch: 5, keepOffset: false);
    savePosition();
  }

  /// Saves the current reading position before navigating away.
  Future<void> savePosition() async {
    final book = _book;
    if (book == null || _pages.isEmpty) return;
    final progress = ReadingProgress(
      bookId: book.id,
      pageIndex: _pageIndex,
      offset: _pages[_pageIndex].startOffset,
      percent: this.progress,
      updatedAt: DateTime.now(),
    );
    await _progressService.save(progress);
  }

  void _rebuildPages() {
    final content = _content;
    if (content == null) return;
    _lastPageChars = _config.charsPerPage;
    final pages =
        _paginator?.paginate(
          content.text,
          _config.charsPerPage,
          breakOffsets: content.pageBreaks,
        ) ??
        defaultPaginate(
          content.text,
          _config.charsPerPage,
          breakOffsets: content.pageBreaks,
        );
    _pages
      ..clear()
      ..addAll(pages);
    if (_pageIndex >= _pages.length) {
      _pageIndex = _pages.isEmpty ? 0 : _pages.length - 1;
    }
  }

  String _viewportSig = '';

  /// Geometry from the last layout pass; cached so on-demand pagination
  /// (turning a page, jumping chapters) can re-paginate without waiting for
  /// the next build.
  TextStyle? _layoutStyle;
  double _layoutMaxWidth = 0;
  double _layoutMaxHeight = 0;

  /// 估算的每页字符数（由真实布局尺寸推导），用于未测量章节的总页数估算，
  /// 使 totalBookPages(Z) 在全局分页完成前即为合理值，且不阻塞主线程。
  double _estimatedCharsPerPage = 0;
  double get estimatedCharsPerPage => _estimatedCharsPerPage;

  /// 估算第 [i] 章的页数（未测量章节用字符数估算，避免返回 1 导致 Z 失真）。
  int _estimatedChapterPages(int i) {
    if (i < 0 || i >= _chapterRanges.length) return 1;
    final len = _chapterRanges[i].endOffset - _chapterRanges[i].startOffset;
    final cpp = _estimatedCharsPerPage;
    if (cpp <= 0) return 1;
    return (len / cpp).ceil().clamp(1, 1000000);
  }

  /// 第 [i] 章的页数：已测量用真实值，否则用估算值。
  int _chapterPagesCount(int i) {
    final info = _chapterPages[i];
    if (info != null) {
      final pages = _isFullscreen ? info.fullScreenPages : info.notFullScreenPages;
      if (pages.isNotEmpty) return pages.length;
    }
    return _estimatedChapterPages(i);
  }

  /// Saved reading offset restored on open, used to locate the starting
  /// chapter before any page has been paginated.
  int _resumeOffset = 0;

  /// Chapters whose pages are fully computed (as opposed to just the opening
  /// batch), so [_ensureAhead] knows whether more pages exist in this chapter.
  final Set<int> _chapterComplete = {};

  /// Re-flows pages so each page fits the actual visible viewport.
  ///
  /// The reader screen measures the real text area (screen minus app bar,
  /// footer and safe areas) and converts it into a conservative character
  /// budget: chars-per-line × lines × safety factor. Because CJK glyphs are
  /// at most 1em wide, the real line count can only be lower than the
  /// estimate, so pages never overflow the fixed-height text surface.
  ///
  /// The user's `charsPerPage` setting acts as an upper bound: choosing a
  /// smaller value still yields smaller pages.
  ///
  /// Chapter heading offsets (from [ChapterDetector]) are merged with the
  /// source's own page breaks and passed as `breakOffsets`: each heading
  /// therefore starts a fresh page, so jump-to-chapter lands on the heading
  /// at the screen top instead of burying it mid-page.
  ///
  /// Debounced: repeated calls with the same budget *and* the same chapter
  /// signature are no-ops, so it is safe to invoke from every layout pass.
  /// The current reading position is kept by re-locating the page that
  /// contains the current character offset.
  /// Re-flows the whole book with exact, measurement-based pagination so every
  /// page fills the screen — no wasted third-of-a-page gap, no overflow.
  ///
  /// The screen hands the real text area; the work runs in a background isolate
  /// and [isPaginating] drives a spinner until the pages are ready. Debounced by
  /// a geometry+content signature so it only recomputes when the viewport or the
  /// book actually changes. The current reading position (by character offset)
  /// is preserved across re-flows.
  Future<void> syncViewportChars({
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    required bool fullscreen,
  }) async {
    final content = _content;
    if (content == null || content.text.isEmpty) return;

    final chapterSig = _chapterRanges.isEmpty
        ? '0'
        : '${_chapterRanges.length}:${_chapterRanges.first.startOffset}:${_chapterRanges.last.endOffset}';
    final sig =
        '$maxWidth|$maxHeight|$fullscreen|${content.text.length}|${style.fontSize}|${style.height}|$chapterSig';
    if (sig == _viewportSig) return;
    _viewportSig = sig;
    debugPrint(
      '[pag] syncViewport ch=${_currentChapterIndex()} ranges=${_chapterRanges.length} fs=${style.fontSize} w=$maxWidth h=$maxHeight',
    );

    _layoutStyle = style;
    _layoutMaxWidth = maxWidth;
    _layoutMaxHeight = maxHeight;

    // 由真实布局尺寸推导每页估算字符数（CJK 1em 宽、行高固定），
    // 供未测量章节的总页数估算使用，使 totalBookPages(Z) 即时合理。
    if (maxWidth > 0 && maxHeight > 0 && style.fontSize != null && style.height != null) {
      final fs = style.fontSize!;
      final lh = (style.height! * fs);
      if (lh > 0) {
        final cols = (maxWidth / fs).floor();
        final rows = (maxHeight / lh).floor();
        final cpp = (cols * rows);
        if (cpp > 0) _estimatedCharsPerPage = cpp.toDouble();
      }
    }

    // Lazy, per-chapter pagination: only the chapter being read is paginated,
    // and only its opening pages (see [_paginateChapter]). Paging the whole
    // book up-front took minutes on large books — this keeps opening instant.
    await _paginateChapter(_currentChapterIndex(), initialBatch: 5);
  }

  /// Paginates [chapterIndex] into [_pages] with the cached layout geometry.
  ///
  /// Only [initialBatch] pages are computed when it is > 0; the rest are
  /// fetched on demand by [_ensureAhead]. Runs in a background isolate and
  /// drives [isPaginating]. When [toLast] the reader lands on the chapter's
  /// last page; [advanceAfter] steps forward once the new pages arrive.
  Future<void> _paginateChapter(
    int chapterIndex, {
    required int initialBatch,
    bool keepOffset = true,
    bool toLast = false,
    int advanceAfter = 0,
  }) async {
    final content = _content;
    final style = _layoutStyle;
    // Every bail-out below must clear the viewport signature: syncViewportChars
    // commits it *before* calling us, so leaving it set would debounce every
    // later layout pass into a no-op and the reader would stay on the spinner
    // (or on "没有可显示的内容") forever.
    void bail(String reason) {
      debugPrint('[pag] return: $reason');
      _viewportSig = '';
    }

    if (content == null) {
      bail('content null');
      return;
    }
    if (style == null) {
      bail('style null');
      return;
    }
    if (_layoutMaxWidth <= 0 || _layoutMaxHeight <= 0) {
      bail('geometry0 w=$_layoutMaxWidth h=$_layoutMaxHeight');
      return;
    }
    if (chapterIndex < 0 || chapterIndex >= _chapterRanges.length) {
      bail('chIdx $chapterIndex oob ${_chapterRanges.length}');
      return;
    }
    debugPrint(
      '[pag] _paginateChapter ch=$chapterIndex batch=$initialBatch range=[${_chapterRanges[chapterIndex].startOffset},${_chapterRanges[chapterIndex].endOffset}]',
    );

    // Yield first — this runs from inside a build (LayoutBuilder), and
    // notifying during build triggers "setState() or markNeedsBuild()".
    await WidgetsBinding.instance.endOfFrame;
    _paginating = true;
    notifyListeners();
    // Let the spinner paint before the work starts.
    await WidgetsBinding.instance.endOfFrame;

    try {
      final entries = await PaginatorService.paginateBookExactIsolate(
        content.text,
        style: style,
        maxWidth: _layoutMaxWidth,
        maxHeight: _layoutMaxHeight,
        chapters: [_chapterRanges[chapterIndex]],
        initialBatch: initialBatch,
      );

      final chapterEnd = _chapterRanges[chapterIndex].endOffset;
      // A batch asked for initialBatch+1 boundaries; getting more than
      // initialBatch means the chapter was truncated (more pages remain).
      final truncated = initialBatch > 0 && entries.length > initialBatch;
      final oldOffset = currentPage?.startOffset ?? _resumeOffset;
      debugPrint(
        '[pag] entries=${entries.length} truncated=$truncated oldOffset=$oldOffset resume=$_resumeOffset pagesBefore=${_pages.length}',
      );
      _pages
        ..clear()
        ..addAll(
          _entriesToPages(
            entries,
            content.text,
            chapterEnd,
            hasMore: truncated,
          ),
        );

      if (initialBatch < 0 || !truncated) {
        _chapterComplete.add(chapterIndex);
      } else {
        _chapterComplete.remove(chapterIndex);
      }

      final maxIdx = _pages.isEmpty ? 0 : _pages.length - 1;
      if (toLast) {
        _pageIndex = maxIdx;
      } else if (keepOffset && oldOffset != null) {
        final v = _pageIndexForOffset(oldOffset) + advanceAfter;
        _pageIndex = v.clamp(0, maxIdx).toInt();
      } else {
        _pageIndex = 0;
      }
    } catch (e) {
      // Never leave the reader stuck on the spinner: fall back to the
      // character-based pages so the book stays readable.
      debugPrint('[paginator] exact pagination failed: $e');
      _rebuildPages();
    } finally {
      _paginating = false;
      notifyListeners();
    }
  }

  /// Index of the chapter containing the current page (0 when unknown).
  int _currentChapterIndex() =>
      _chapterIndexForOffset(currentPage?.startOffset ?? _resumeOffset);

  /// Index of the chapter containing [offset] (0 when none matches).
  int _chapterIndexForOffset(int offset) {
    final idx = _chapterRanges.indexWhere(
      (r) => r.startOffset <= offset && r.endOffset > offset,
    );
    return idx < 0 ? 0 : idx;
  }

  /// True when enough layout information is known to measure real pages.
  ///
  /// Until the reader screen has run a layout pass there is no text style or
  /// viewport size, so viewport pagination cannot produce anything. Callers
  /// must use this to avoid promising pages that will never arrive.
  bool _canPaginate() =>
      _content != null &&
      _layoutStyle != null &&
      _layoutMaxWidth > 0 &&
      _layoutMaxHeight > 0;

  /// Computes more pages when the reader reaches the end of what is known:
  /// the rest of the current chapter first, then the next chapter's opening.
  void _ensureAhead() {
    if (!_canPaginate()) return; // no layout yet — nothing could be computed
    if (_pageIndex < _pages.length - 1) return; // pages already available
    final ch = _currentChapterIndex();
    if (ch < 0) return;
    if (!_chapterComplete.contains(ch)) {
      _paginateChapter(ch, initialBatch: -1, keepOffset: true, advanceAfter: 1);
    } else if (ch + 1 < _chapterRanges.length) {
      _paginateChapter(ch + 1, initialBatch: 5, keepOffset: false);
    }
  }

  /// Converts exact [PageEntry] offsets into [BookPage]s with their text content.
  ///
  /// [chapterEnd] bounds the final page (entries only cover one chapter, so the
  /// page must not run to the end of the whole book). When [hasMore] the last
  /// entry is only a boundary marker from a truncated batch and is not turned
  /// into a page.
  List<BookPage> _entriesToPages(
    List<PageEntry> entries,
    String text,
    int chapterEnd, {
    bool hasMore = false,
  }) {
    if (entries.isEmpty) return const [];
    final count = hasMore ? entries.length - 1 : entries.length;
    final pages = <BookPage>[];
    for (var i = 0; i < count; i++) {
      final s = entries[i].startOffset;
      final e = (i + 1 < entries.length)
          ? entries[i + 1].startOffset
          : chapterEnd;
      final c = text.substring(s, e);
      pages.add(
        BookPage(index: i, content: c, startOffset: s),
      );
    }
    return pages;
  }

  void goToPage(int index) {
    if (_pages.isEmpty) return;
    _pageIndex = index.clamp(0, _pages.length - 1);
    notifyListeners();
    savePosition();
  }

  /// Whether the initial layout pass is still running. The reader shows a
  /// spinner while this is true so the UI never appears frozen.
  bool _paginating = false;
  bool get isPaginating => _paginating;

  /// Runs [paginateWithLayout] in a background isolate and applies the result.
  ///
  /// [PaginatorService.paginateWithLayout] can take several seconds for large
  /// books because it lays out every paragraph with TextPainter. Running it
  /// synchronously in the build method blocks the main thread and triggers
  /// ANR — this method offloads it to a background isolate and shows a
  /// progress indicator until the pages are ready.
  Future<void> paginateAsync(
    String text,
    TextStyle style,
    double maxWidth,
    double maxHeight, {
    List<int>? breakOffsets,
  }) async {
    _paginating = true;
    notifyListeners();

    // Defer to next frame so the spinner paints before the heavy work starts.
    await WidgetsBinding.instance.endOfFrame;

    final pages = await PaginatorService.paginateWithLayoutIsolate(
      text,
      style: style,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      breakOffsets: breakOffsets,
    );

    _pages
      ..clear()
      ..addAll(pages);
    if (_pageIndex >= _pages.length) {
      _pageIndex = _pages.isEmpty ? 0 : _pages.length - 1;
    }
    _paginating = false;
    notifyListeners();
    savePosition();
  }

  // ---- Annotations: bookmarks, notes, shared comments ----

  final AnnotationStore _annotations;
  CommentSync? _commentSync;
  final String _deviceId;

  List<Bookmark> _bookmarks = const [];
  List<Bookmark> get bookmarks => List.unmodifiable(_bookmarks);

  List<Note> _notes = const [];
  List<Note> get notes => List.unmodifiable(_notes);

  List<SharedComment> _sharedComments = const [];
  List<SharedComment> get sharedComments => List.unmodifiable(_sharedComments);

  /// Whether a shared-comment backend is wired (used by the UI to show the
  /// "publish" action on local notes).
  CommentSync? get commentSync => _commentSync;

  /// Whether the current page position has a bookmark.
  bool get isBookmarkedAtCurrentPage {
    final offset = currentPage?.startOffset ?? -1;
    return _bookmarks.any((b) => b.offset == offset);
  }

  /// Notes overlapping the current page's text range.
  List<Note> notesOnCurrentPage(int pageStart, int pageEnd) => _notes
      .where((n) => n.endOffset > pageStart && n.startOffset < pageEnd)
      .toList();

  /// Loads local bookmarks/notes for the open book and (when a sync backend is
  /// wired) pulls shared comments. Call after [openBook].
  Future<void> loadAnnotations() async {
    if (_book == null) return;
    _bookmarks = await _annotations.loadBookmarks(_book!.id);
    _notes = await _annotations.loadNotes(_book!.id);
    if (_commentSync != null) {
      _sharedComments = await _commentSync!.pull(_book!.id);
    }
    notifyListeners();
  }

  /// Adds or removes a bookmark at the current page's start offset.
  Future<void> toggleBookmark({String? label}) async {
    if (_book == null) return;
    final offset = currentPage?.startOffset ?? 0;
    if (_bookmarks.any((b) => b.offset == offset)) {
      await _annotations.removeBookmarkAt(_book!.id, offset);
    } else {
      await _annotations.addBookmark(
        Bookmark(
          bookId: _book!.id,
          offset: offset,
          pageIndex: _pageIndex,
          label: label,
        ),
      );
    }
    _bookmarks = await _annotations.loadBookmarks(_book!.id);
    notifyListeners();
  }

  /// Saves a highlight+comment anchored to [startOffset..endOffset].
  Future<void> saveNote({
    required int startOffset,
    required int endOffset,
    required String quotedText,
    String? comment,
    int color = 0xFFFFEB3B,
  }) async {
    if (_book == null) return;
    final note = Note(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      bookId: _book!.id,
      startOffset: startOffset,
      endOffset: endOffset,
      quotedText: quotedText,
      comment: comment,
      color: color,
    );
    await _annotations.saveNote(note);
    _notes = await _annotations.loadNotes(_book!.id);
    notifyListeners();
  }

  Future<void> removeNote(String id) async {
    if (_book == null) return;
    await _annotations.removeNote(_book!.id, id);
    _notes = await _annotations.loadNotes(_book!.id);
    notifyListeners();
  }

  /// Publishes a local note to the shared layer, returning whether it succeeded.
  Future<bool> publishComment(Note note, {String author = 'me'}) async {
    if (_commentSync == null || _book == null) return false;
    final shared = SharedComment(
      id: note.id,
      bookId: _book!.id,
      deviceId: _deviceId,
      author: author,
      startOffset: note.startOffset,
      endOffset: note.endOffset,
      quotedText: note.quotedText,
      comment: note.comment ?? '',
    );
    final ok = await _commentSync!.push(shared);
    if (ok) {
      _sharedComments = await _commentSync!.pull(_book!.id);
      notifyListeners();
    }
    return ok;
  }

  /// Re-pulls shared comments from the sync backend (e.g. after a peer pushed).
  Future<void> refreshSharedComments() async {
    if (_commentSync == null || _book == null) return;
    _sharedComments = await _commentSync!.pull(_book!.id);
    notifyListeners();
  }

  /// Injects the shared-comment backend. The reader screen wires this up once a
  /// server connection is available (the [CommentSync] impl needs the active
  /// transport), so [ReaderProvider] itself stays transport-agnostic.
  void setCommentSync(CommentSync? sync) {
    _commentSync = sync;
    if (sync != null && _book != null) {
      refreshSharedComments();
    }
  }

  /// Replaces the current page layout with pre-computed pages (e.g. produced by
  /// the screen using real screen/font metrics via [PaginatorService.paginateWithLayout]).
  ///
  /// When [preserveOffset] is true (e.g. after a fullscreen toggle) the current
  /// page's [startOffset] is remembered and the new page list is scanned for the
  /// page that contains it, so the reader stays on the same text after the
  /// layout change.
  void setPages(List<BookPage> pages, {bool preserveOffset = false}) {
    if (pages.isEmpty) return;
    final oldOffset =
        preserveOffset && _pages.isNotEmpty && _pageIndex < _pages.length
        ? _pages[_pageIndex].startOffset
        : null;
    _pages
      ..clear()
      ..addAll(pages);
    if (oldOffset != null) {
      // Find the page containing the old offset.
      var idx = 0;
      for (var i = 0; i < _pages.length; i++) {
        if (_pages[i].startOffset <= oldOffset) {
          idx = i;
        } else {
          break;
        }
      }
      _pageIndex = idx;
    } else if (_pageIndex >= _pages.length) {
      _pageIndex = _pages.length - 1;
    }
    notifyListeners();
  }

  bool nextPage() {
    if (_pages.isEmpty) return false;
    if (_pageIndex < _pages.length - 1) {
      _pageIndex++;
      _ensureAhead(); // pre-fetch when the last known page is reached
      notifyListeners();
      savePosition();
      return true;
    }
    // At the end of the pages computed so far — fetch the rest of this chapter
    // or the opening of the next one. Pagination is async, so the new page
    // appears once it arrives (see [_ensureAhead]). Only claim there is more
    // when pages actually can be computed; otherwise every consumer that loops
    // on nextPage() would spin forever.
    if (!_canPaginate()) return false;
    final ch = _currentChapterIndex();
    if (!_chapterComplete.contains(ch) || ch + 1 < _chapterRanges.length) {
      _ensureAhead();
      return true;
    }
    return false;
  }

  bool previousPage() {
    if (_pages.isEmpty) return false;
    if (_pageIndex > 0) {
      _pageIndex--;
      notifyListeners();
      savePosition();
      return true;
    }
    // At the chapter's first page — go to the last page of the previous chapter.
    final ch = _currentChapterIndex();
    if (ch <= 0 || !_canPaginate()) return false;
    _paginateChapter(ch - 1, initialBatch: -1, keepOffset: false, toLast: true);
    return true;
  }

  /// Handle tap on a horizontal position [fraction] (0.0 - 1.0) within the
  /// reading area, using the configured [TapZoneMode].
  void handleTap(double fraction) {
    switch (_config.tapZoneMode) {
      case TapZoneMode.thirds:
        if (fraction < 0.333) {
          _config.leftZoneForward ? nextPage() : previousPage();
        } else if (fraction > 0.667) {
          _config.leftZoneForward ? previousPage() : nextPage();
        } else {
          // Center toggles controls — handled by parent
        }
        break;
      case TapZoneMode.halves:
        if (_config.leftZoneForward) {
          if (fraction < 0.5)
            nextPage();
          else
            previousPage();
        } else {
          if (fraction < 0.5)
            previousPage();
          else
            nextPage();
        }
        break;
      case TapZoneMode.edges:
        if (fraction < 0.1) {
          _config.leftZoneForward ? nextPage() : previousPage();
        } else if (fraction > 0.9) {
          _config.leftZoneForward ? previousPage() : nextPage();
        }
        // Center area (0.1-0.9) toggles controls
        break;
      case TapZoneMode.whole:
        // Any tap advances; controls toggle via the footer buttons.
        nextPage();
        break;
    }
  }

  /// Returns true when tapping [fraction] should toggle controls (not navigate).
  bool isToggleZone(double fraction) {
    switch (_config.tapZoneMode) {
      case TapZoneMode.thirds:
        return fraction >= 0.333 && fraction <= 0.667;
      case TapZoneMode.halves:
        return false; // halves mode: always navigate
      case TapZoneMode.edges:
        return fraction >= 0.1 && fraction <= 0.9;
      case TapZoneMode.whole:
        return false; // whole mode: tap always navigates
    }
  }

  void close() {
    _book = null;
    _content = null;
    _pages.clear();
    _pageIndex = 0;
    _chapters = const [];
    notifyListeners();
  }
}

/// Minimal pagination seam so the provider can be tested without the real
/// (fairly involved) paginator implementation.
abstract class PaginatorLike {
  List<BookPage> paginate(
    String text,
    int charsPerPage, {
    List<int>? breakOffsets,
  });
}

/// Default pagination: one page per PDF page / EPUB chapter when the source
/// supplies breaks, otherwise flow by character count.
List<BookPage> defaultPaginate(
  String text,
  int charsPerPage, {
  List<int>? breakOffsets,
}) {
  return PaginatorService().paginate(
    text,
    charsPerPage: charsPerPage,
    breakOffsets: breakOffsets,
  );
}
