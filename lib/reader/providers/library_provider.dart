import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../models/reader_config.dart';
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
    } catch (e) {
      _error = e is LibrarySandboxError ? e.message : e.toString();
      _books.clear();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Downloads a book and returns its content, or null on failure.
  Future<BookContent?> download({
    required FileTransport transport,
    required Book book,
  }) async {
    _error = null;
    _progress[book.id] = 0.0;
    notifyListeners();

    try {
      final content = await _service.downloadBook(
        transport: transport,
        book: book,
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
    }
  }

  /// Opens a book, using the local copy when present.
  Future<BookContent?> open({
    required FileTransport transport,
    required Book book,
  }) async {
    final cached = await _service.readCached(book);
    if (cached != null) return cached;
    return download(transport: transport, book: book);
  }

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
  })  : _config = config ?? const ReaderConfig(),
        _paginator = paginator;

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

  void updateConfig(ReaderConfig config) {
    _config = config;
    // Re-paginate only when the page size actually changed — re-paginating on
    // an unrelated setting would jump the reader back to page 0.
    if (_text != null && config.charsPerPage != _lastPageChars) {
      _rebuildPages();
    }
    notifyListeners();
  }

  String? _text;
  int _lastPageChars = 700;

  final List<BookPage> _pages = [];
  List<BookPage> get pages => List.unmodifiable(_pages);

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

  /// Opens [content] for [book].
  void openBook(Book book, BookContent content) {
    _book = book;
    _text = content.text;
    _error = null;
    _pageIndex = 0;
    _rebuildPages();
    notifyListeners();
  }

  void _rebuildPages() {
    if (_text == null) return;
    _lastPageChars = _config.charsPerPage;
    final pages = _paginator?.paginate(_text!, _config.charsPerPage) ??
        defaultPaginate(_text!, _config.charsPerPage);
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

  void close() {
    _book = null;
    _text = null;
    _pages.clear();
    _pageIndex = 0;
    notifyListeners();
  }
}

/// Minimal pagination seam so the provider can be tested without the real
/// (fairly involved) paginator implementation.
abstract class PaginatorLike {
  List<BookPage> paginate(String text, int charsPerPage);
}

List<BookPage> defaultPaginate(String text, int charsPerPage) {
  final pages = <BookPage>[];
  for (var i = 0; i < text.length; i += charsPerPage) {
    final end =
        (i + charsPerPage > text.length) ? text.length : i + charsPerPage;
    pages.add(BookPage(
      index: pages.length,
      content: text.substring(i, end),
      startOffset: i,
    ));
  }
  return pages;
}
