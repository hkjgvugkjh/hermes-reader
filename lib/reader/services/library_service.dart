import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import 'library_sandbox.dart';

/// Knows how to talk to one server's file API. Implemented by the two
/// transports (direct HTTP and hermes-proxy) so [LibraryService] stays
/// transport-agnostic and testable without a network.
abstract class FileTransport {
  /// Performs a GET and returns the raw body bytes plus the status code.
  Future<TransportResponse> get(
    String path, {
    Map<String, String>? headers,
  });
}

class TransportResponse {
  final int statusCode;
  final Uint8List body;
  final Map<String, String> headers;

  const TransportResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  bool get isOk => statusCode >= 200 && statusCode < 300;
}

/// Lists and downloads books from a server's `library` directory.
///
/// Every path passes through [LibrarySandbox] before a request is made, so the
/// app cannot be tricked into reading outside that directory.
class LibraryService {
  final LibrarySandbox sandbox;

  LibraryService({LibrarySandbox? sandbox, this.storage})
      : sandbox = sandbox ?? const LibrarySandbox();

  /// Where downloaded files land. Injectable so tests do not need platform
  /// channels, and so the storage policy lives in one place: the app-private
  /// documents directory, never external storage.
  final BookStorage? storage;

  BookStorage get _storage => storage ?? const BookStorage();

  /// Lists the books available on [transport].
  ///
  /// [serverId] and [serverName] only label the results — they do not take
  /// part in any path decision.
  Future<List<Book>> listBooks({
    required FileTransport transport,
    required String serverId,
    required String serverName,
    String subdir = '',
  }) async {
    final dir = sandbox.resolveDir(subdir);

    final response = await transport.get(
      '/api/hermes/files/list?path=${Uri.encodeComponent(dir)}',
    );

    if (!response.isOk) {
      throw LibrarySandboxError(
          'listing failed with status ${response.statusCode}');
    }

    final decoded = _decodeJson(response.body);
    final entries = _extractEntries(decoded);

    final books = <Book>[];
    for (final entry in entries) {
      final name = entry['name'] as String? ?? '';
      if (name.isEmpty) continue;

      final isDir = entry['is_dir'] as bool? ??
          entry['isDirectory'] as bool? ??
          false;
      if (isDir) continue;

      final size = (entry['size'] as num? ?? 0).toInt();

      // Validate the candidate through the same sandbox the download uses.
      String resolved;
      try {
        resolved = sandbox.resolve('$subdir/$name'.replaceAll(RegExp('^/+'), ''));
        if (!sandbox.sizeAllowed(size)) continue;
      } on LibrarySandboxError {
        // Skip anything the sandbox rejects rather than failing the listing.
        continue;
      }

      final modified = entry['modified'] ?? entry['modified_at'];
      books.add(Book(
        id: '$serverId::$resolved',
        serverId: serverId,
        serverName: serverName,
        relativePath: resolved,
        title: _stripExtension(name),
        sizeBytes: size,
        modifiedAt: modified is num
            ? DateTime.fromMillisecondsSinceEpoch(modified.toInt() * 1000)
            : DateTime.tryParse(modified?.toString() ?? ''),
      ));
    }

    books.sort((a, b) => a.title.compareTo(b.title));
    return books;
  }

  /// Downloads a book and stores it in the app's private directory.
  ///
  /// Returns the decoded [BookContent]. Throws [LibrarySandboxError] if the
  /// path or the payload violates any limit.
  Future<BookContent> downloadBook({
    required FileTransport transport,
    required Book book,
  }) async {
    // Re-validate even for a Book that came from our own listing — the object
    // may have been persisted and tampered with.
    final safePath = sandbox.resolve(book.relativePath);
    sandbox.checkTransfer(book.sizeBytes);

    final response = await transport.get(
      '/api/hermes/files/read?path=${Uri.encodeComponent(safePath)}',
    );

    if (!response.isOk) {
      throw LibrarySandboxError(
          'download failed with status ${response.statusCode}');
    }

    final bytes = sandbox.validateContent(
      response.body,
      declaredSize: book.sizeBytes,
    );

    final text = _decodeText(bytes);

    // Persist into app-private storage — no external storage permission is
    // requested anywhere in this feature. Done outside the try above so a disk
    // error is not reported as a network error.
    await _storage.save(book, bytes);

    return BookContent(bookId: book.id, text: text);
  }

  /// Reads a previously downloaded book from local storage, or null.
  Future<BookContent?> readCached(Book book) async {
    final bytes = await _storage.load(book);
    if (bytes == null) return null;
    return BookContent(bookId: book.id, text: _decodeText(bytes));
  }

  /// Deletes the local copy.
  Future<void> deleteCached(Book book) => _storage.delete(book);

  /// True when a local copy exists.
  Future<bool> isCached(Book book) => _storage.exists(book);

  // ---- internals ----------------------------------------------------------

  static Map<String, dynamic> _decodeJson(Uint8List body) {
    try {
      final text = utf8.decode(body, allowMalformed: true);
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return {'entries': decoded as List<dynamic>? ?? []};
    } catch (e) {
      throw LibrarySandboxError('malformed listing response: $e');
    }
  }

  static List<Map<String, dynamic>> _extractEntries(Map<String, dynamic> json) {
    final raw = json['entries'] as List? ??
        json['files'] as List? ??
        json['items'] as List? ??
        json['list'] as List? ??
        const [];
    return raw.whereType<Map<String, dynamic>>().toList();
  }

  /// Decodes bytes to text, falling back to latin-1 for files that are not
  /// valid UTF-8 (older Chinese e-books are frequently GBK, which no decoder
  /// here can recover — we surface it instead of showing mojibake).
  static String _decodeText(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  static String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return name;
    return name.substring(0, dot);
  }
}

/// Persists downloaded books in the app's private documents directory.
///
/// Deliberately never touches external storage: the reader never asks for
/// READ/WRITE_EXTERNAL_STORAGE, so books stay inside the app sandbox and are
/// removed with the app.
class BookStorage {
  const BookStorage();

  Future<void> save(Book book, Uint8List bytes) async {
    final file = await _file(book);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<Uint8List?> load(Book book) async {
    try {
      final file = await _file(book);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> delete(Book book) async {
    try {
      final file = await _file(book);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best effort — a failed cleanup must not break the UI.
    }
  }

  Future<bool> exists(Book book) async {
    try {
      return await (await _file(book)).exists();
    } catch (_) {
      return false;
    }
  }

  Future<File> _file(Book book) async {
    final dir = await getApplicationDocumentsDirectory();
    final booksDir = Directory('${dir.path}/books');
    if (!await booksDir.exists()) {
      await booksDir.create(recursive: true);
    }
    final name = const LibrarySandbox()
        .localFileName(book.serverId, book.relativePath);
    return File('${booksDir.path}/$name');
  }
}
