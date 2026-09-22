import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/reader_config.dart';
import '../services/pdf_image_decoder.dart';
import '../services/narration_progress_service.dart';
import '../services/paginator_service.dart';
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
  })  : _config = config ?? const ReaderConfig(),
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
    _config = config;
    // Re-paginate only when the page size actually changed — re-paginating on
    // an unrelated setting would jump the reader back to page 0.
    if (_content != null && config.charsPerPage != _lastPageChars) {
      _rebuildPages();
      savePosition();
    }
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
    notifyListeners();
  }

  BookPage? get currentPage =>
      (_pages.isEmpty || _pageIndex >= _pages.length) ? null : _pages[_pageIndex];

  bool get atEnd => _pages.isEmpty || _pageIndex >= _pages.length - 1;
  bool get atStart => _pageIndex <= 0;

  double get progress =>
      _pages.isEmpty ? 0.0 : (_pageIndex / (_pages.length - 1)).clamp(0.0, 1.0);

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
  Future<void> saveNarration({required int pageIndex, required int charOffset}) {
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
    _rebuildPages();

    // Try to restore saved reading position
    final saved = await _progressService.load(book.id);
    if (saved != null && saved.pageIndex < _pages.length) {
      _pageIndex = saved.pageIndex;
    } else {
      _pageIndex = 0;
    }
    notifyListeners();

    // Build the table of contents off the UI thread; the jump dialog falls
    // back to plain page-jumping until (and unless) headings are found.
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
          .map((m) =>
              ChapterMark(title: m['title'] as String, offset: m['offset'] as int))
          .toList();
      notifyListeners();
    } catch (_) {
      _chapters = const [];
    }
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
  void goToChapter(int index) {
    if (index < 0 || index >= _chapters.length) return;
    goToPage(_pageIndexForOffset(_chapters[index].offset));
  }

  /// Saves the current reading position before navigating away.
  Future<void> savePosition() async {
    final book = _book;
    if (book == null || _pages.isEmpty) return;
    final progress = ReadingProgress(
      bookId: book.id,
      pageIndex: _pageIndex,
      percent: this.progress,
      updatedAt: DateTime.now(),
    );
    await _progressService.save(progress);
  }

  void _rebuildPages() {
    final content = _content;
    if (content == null) return;
    _lastPageChars = _config.charsPerPage;
    final pages = _paginator?.paginate(
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
  List<Note> notesOnCurrentPage(int pageStart, int pageEnd) =>
      _notes.where((n) => n.endOffset > pageStart && n.startOffset < pageEnd).toList();

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
      await _annotations.addBookmark(Bookmark(
        bookId: _book!.id,
        offset: offset,
        pageIndex: _pageIndex,
        label: label,
      ));
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
    final oldOffset = preserveOffset && _pages.isNotEmpty && _pageIndex < _pages.length
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
    if (atEnd) return false;
    _pageIndex++;
    notifyListeners();
    savePosition();
    return true;
  }

  bool previousPage() {
    if (atStart) return false;
    _pageIndex--;
    notifyListeners();
    savePosition();
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
          if (fraction < 0.5) nextPage();
          else previousPage();
        } else {
          if (fraction < 0.5) previousPage();
          else nextPage();
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
  List<BookPage> paginate(String text, int charsPerPage,
      {List<int>? breakOffsets});
}

/// Default pagination: one page per PDF page / EPUB chapter when the source
/// supplies breaks, otherwise flow by character count.
List<BookPage> defaultPaginate(
  String text,
  int charsPerPage, {
  List<int>? breakOffsets,
}) {
  return PaginatorService()
      .paginate(text, charsPerPage: charsPerPage, breakOffsets: breakOffsets);
}
