import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../models/reader_config.dart';
import '../services/pdf_image_decoder.dart';
import '../services/narration_progress_service.dart';
import '../services/paginator_service.dart';
import '../services/reader_config_storage.dart';
import '../services/reading_progress_service.dart';
import '../services/library_sandbox.dart';
import '../services/library_service.dart';

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
    notifyListeners();

    try {
      final content = await _service.downloadBook(
        transport: transport,
        book: book,
        encoding: encoding,
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
  })  : _config = config ?? const ReaderConfig(),
        _paginator = paginator,
        _progressService = progressService ?? ReadingProgressService(),
        _narrationProgress =
            narrationProgressService ?? NarrationProgressService(),
        _configStorage = configStorage;

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
    }
    notifyListeners();
    _configStorage?.save(config);
  }

  /// The open book's content, kept whole so page breaks survive re-pagination.
  BookContent? _content;
  int _lastPageChars = 700;

  final List<BookPage> _pages = [];
  List<BookPage> get pages => List.unmodifiable(_pages);

  /// Images pulled from the source, indexed by the [imageMarker] tokens embedded
  /// in each [BookPage.content].
  List<PdfImage> get images => _content?.images ?? const [];

  int _pageIndex = 0;
  int get pageIndex => _pageIndex;
  int get pageCount => _pages.length;
  bool get hasBook => _pages.isNotEmpty;

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
    _rebuildPages();

    // Try to restore saved reading position
    final saved = await _progressService.load(book.id);
    if (saved != null && saved.pageIndex < _pages.length) {
      _pageIndex = saved.pageIndex;
    } else {
      _pageIndex = 0;
    }
    notifyListeners();
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
  }

  bool nextPage() {
    if (atEnd) return false;
    _pageIndex++;
    notifyListeners();
    return true;
  }

  bool previousPage() {
    if (atStart) return false;
    _pageIndex--;
    notifyListeners();
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
    }
  }

  void close() {
    _book = null;
    _content = null;
    _pages.clear();
    _pageIndex = 0;
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
