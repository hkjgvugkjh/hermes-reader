import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'external_library_dir.dart';
import 'library_cache_index.dart';

import '../models/book.dart';
import 'book_text_extractor.dart';
import 'pdf_image_decoder.dart';
import 'file_body_decoder.dart';
import 'file_type_detector.dart';
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

/// Request handed to the background isolate. Every field is sendable so the
/// whole object can cross the isolate boundary.
class _ExtractRequest {
  const _ExtractRequest(this.sendPort, this.bytes, this.type, [this.encoding]);
  final SendPort sendPort;
  final Uint8List bytes;
  final FileType type;
  final String? encoding;
}

/// Error returned from the background isolate. It carries a string (not the
/// raw exception) so it is always sendable across isolates.
class _ExtractError {
  const _ExtractError(this.message);
  final String message;
}

/// Runs in the background isolate: turns raw bytes into readable text without
/// touching the UI thread. Errors are stringified so they survive the trip back.
Future<void> _extractIsolateEntry(_ExtractRequest req) async {
  try {
    final text = await DefaultBookTextExtractor().extract(
      req.bytes,
      req.type,
      encoding: req.encoding,
    );
    req.sendPort.send(text);
  } catch (e) {
    req.sendPort.send(_ExtractError('$e'));
  }
}

/// Lists and downloads books from a server's `library` directory.
///
/// Every path passes through [LibrarySandbox] before a request is made, so the
/// app cannot be tricked into reading outside that directory.
class LibraryService {
  final LibrarySandbox sandbox;
  final LibraryCacheIndex _index;

  LibraryService({
    LibrarySandbox? sandbox,
    this.storage,
    FileBodyDecoder? bodyDecoder,
    LibraryCacheIndex? index,
  })  : sandbox = sandbox ?? const LibrarySandbox(),
        _bodyDecoder = bodyDecoder ?? const FileBodyDecoder(),
        _index = index ?? const LibraryCacheIndex();

  final FileTypeDetector _fileTypeDetector = const FileTypeDetector();

  /// Removes the server's JSON envelope before anything else looks at a file.
  final FileBodyDecoder _bodyDecoder;

  /// Where downloaded files land. Injectable so tests do not need platform
  /// channels, and so the storage policy lives in one place: the user-visible
  /// `hermes-reader/books` folder on external storage (see [ExternalLibraryDir]),
  /// which survives an app uninstall.
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
    final dir = (subdir.isEmpty || subdir == '/' || subdir == '.') ? 'library' : sandbox.resolveDir(subdir);
    final encodedPath = Uri.encodeComponent(dir);

    final response = await transport.get(
      '/api/studio/files/list?path=$encodedPath',
    );
    print('[SHELF] GET dir=$dir status=${response.statusCode} bodyLen=${response.body.length}');

    if (!response.isOk) {
      // Extract error detail from response body for better diagnostics
      String detail = '${response.statusCode}';
      if (response.body.isNotEmpty) {
        try {
          detail = utf8.decode(response.body, allowMalformed: true).trim();
          if (detail.length > 200) detail = '${detail.substring(0, 200)}...';
        } catch (_) {}
      }
      throw LibrarySandboxError('listing failed: $detail');
    }

    if (response.body.isEmpty) {
      throw LibrarySandboxError('listing returned empty body from server');
    }

    final decoded = _decodeJson(response.body);
    final entries = _extractEntries(decoded);

    final books = <Book>[];
    for (final entry in entries) {
      final name = entry['name'] as String? ?? '';
      if (name.isEmpty) continue;

      final isDir = entry['is_dir'] as bool? ??
          entry['isDirectory'] as bool? ??
          entry['isDir'] as bool? ??
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

      final modified = entry['modified'] ?? entry['modified_at'] ?? entry['modTime'];
      final fileType = _fileTypeDetector.detect(name);

      // Skip files with unsupported formats
      if (fileType == FileType.unknown) continue;

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
        fileType: fileType,
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
    String? encoding,
  }) async {
    // Re-validate even for a Book that came from our own listing — the object
    // may have been persisted and tampered with.
    final safePath = sandbox.resolve(book.relativePath);
    sandbox.checkTransfer(book.sizeBytes);

    final type = _typeOf(book);
    final bytes = await _fetchBytes(transport, safePath, type);
    final validated = sandbox.validateContent(
      bytes,
      declaredSize: book.sizeBytes,
    );

    final text = await _extractOffThread(validated, type, encoding: encoding);

    // Persist into the external `hermes-reader/books` folder (see
    // [ExternalLibraryDir]) so the download survives an app uninstall. Done
    // outside the try above so a disk error is not reported as a network error.
    await _storage.save(book, validated);

    final cacheName = sandbox.localFileName(book.serverId, book.relativePath);
    await _index.recordDownload(
      cacheFileName: cacheName,
      serverId: book.serverId,
      relativePath: book.relativePath,
      title: book.title,
      sizeBytes: book.sizeBytes,
    );

    return BookContent(
      bookId: book.id,
      text: text.text,
      pageBreaks: text.breaks,
    );
  }

  /// Reads a previously downloaded book from local storage, or null.
  ///
  /// [encoding] forces a specific codepage (e.g. 'gbk') to fix mojibake and is
  /// persisted via [LibraryCacheIndex] so the choice survives restarts. When
  /// null/absent, the index's stored encoding (default 'auto') is used.
  ///
  /// Text formats re-decode on every open so a charset fix applies immediately;
  /// slow binary formats (PDF/EPUB) reuse the cached extraction.
  Future<BookContent?> readCached(Book book, {String? encoding}) async {
    final type = _typeOf(book);
    final cacheName = sandbox.localFileName(book.serverId, book.relativePath);
    final enc = encoding ?? await _index.encodingOf(cacheName);

    if (encoding != null) {
      // A manual pick always wins and is remembered.
      await _index.setEncoding(cacheName, encoding);
    }

    if (!_isTextual(type)) {
      final meta = await _storage.loadMeta(book);
      if (meta != null) {
        return BookContent(
          bookId: book.id,
          text: meta.text,
          pageBreaks: meta.breaks,
          images: meta.images,
        );
      }
    }

    final raw = await _storage.load(book);
    if (raw == null) return null;

    // Cached copies written by an older build may still carry the envelope.
    final bytes = _bodyDecoder.decode(raw, type: type);
    final text = await _extractOffThread(
      bytes,
      type,
      encoding: enc == 'auto' ? null : enc,
    );
    await _storage.saveMeta(book, text.text, text.breaks, text.images);
    return BookContent(
      bookId: book.id,
      text: text.text,
      pageBreaks: text.breaks,
      images: text.images,
    );
  }

  /// True for formats that decode fast enough to re-run on every open instead
  /// of trusting a possibly stale cached extraction.
  static bool _isTextual(FileType type) =>
      type == FileType.plainText ||
      type == FileType.html ||
      type == FileType.mobi ||
      type == FileType.json ||
      type == FileType.unknown;

  /// Extracts readable text off the UI thread so large/garbled PDFs and EPUBs
  /// cannot freeze the app (they used to block the main isolate for up to a
  /// minute, triggering an Android "not responding" dialog).
  Future<ExtractedText> _extractOffThread(
    List<int> bytes,
    FileType type, {
    String? encoding,
  }) async {
    final sw = Stopwatch()..start();
    print('[EXTRACT] start bytes=${bytes.length} type=$type encoding=$encoding');
    final receivePort = ReceivePort();
    await Isolate.spawn(
      _extractIsolateEntry,
      _ExtractRequest(receivePort.sendPort, Uint8List.fromList(bytes), type, encoding),
    );
    final response = await receivePort.first;
    if (response is _ExtractError) {
      throw Exception(response.message);
    }
    final r = response as ExtractedText;
    print('[EXTRACT] done in ${sw.elapsedMilliseconds}ms len=${r.text.length} '
        'breaks=${r.breaks.length}');
    return r;
  }

  /// Fetches a file, unwrapping the server's JSON envelope.
  ///
  /// Binary formats cannot survive the server's string round-trip: bytes above
  /// 0x7F come back as U+FFFD and the file is ruined. When that is detected we
  /// ask once more for base64, which some servers support; if that also fails
  /// the damaged payload is returned so the user at least sees a reason.
  Future<Uint8List> _fetchBytes(
    FileTransport transport,
    String safePath,
    FileType type,
  ) async {
    final response = await transport.get(_readPath(safePath));
    if (!response.isOk) {
      throw LibrarySandboxError(
          'download failed with status ${response.statusCode}');
    }

    final payload = _bodyDecoder.decode(response.body, type: type);
    if (!_fileTypeDetector.needsExtraction(type) || !_isDamaged(payload)) {
      return payload;
    }

    final retry = await transport.get(_readPath(safePath, encoding: 'base64'));
    if (!retry.isOk) return payload;
    return _decodeBase64Body(retry.body, type) ?? payload;
  }

  String _readPath(String safePath, {String? encoding}) {
    final query = <String, String>{'path': safePath};
    if (encoding != null) query['encoding'] = encoding;
    return Uri(
      path: '/api/studio/files/read',
      queryParameters: query,
    ).toString();
  }

  /// True when the payload is text that carries UTF-8 replacement characters,
  /// i.e. a binary file that went through a string round-trip.
  bool _isDamaged(Uint8List bytes) {
    try {
      return FileBodyDecoder.looksBinaryDamaged(utf8.decode(bytes));
    } catch (_) {
      return false;
    }
  }

  /// Unwraps and base64-decodes a retry response; null when it is not usable.
  Uint8List? _decodeBase64Body(Uint8List body, FileType type) {
    final payload = _bodyDecoder.decode(body, type: type);
    String text;
    try {
      text = utf8.decode(payload).trim();
    } catch (_) {
      // Already binary — the retry gave us the real file.
      return payload;
    }
    try {
      final decoded = base64Decode(text);
      if (decoded.isNotEmpty && !_isDamaged(decoded)) return decoded;
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Books persisted before [Book.fileType] existed carry a null type, so fall
  /// back to the extension rather than treating them as unknown.
  FileType _typeOf(Book book) =>
      book.fileType ?? _fileTypeDetector.detect(book.relativePath);

  /// Deletes the local copy.
  Future<void> deleteCached(Book book) => _storage.delete(book);

  /// True when a local copy exists.
  Future<bool> isCached(Book book) => _storage.exists(book);

  // ---- internals ----------------------------------------------------------

  static Map<String, dynamic> _decodeJson(Uint8List body) {
    try {
      final text = utf8.decode(body, allowMalformed: true).trim();
      if (text.isEmpty) {
        throw LibrarySandboxError('response body is empty');
      }
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is List) return {'entries': decoded};
      return {'entries': []};
    } on FormatException catch (e) {
      throw LibrarySandboxError('malformed listing response: ${e.message}');
    } catch (e) {
      if (e is LibrarySandboxError) rethrow;
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

  static String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return name;
    return name.substring(0, dot);
  }
}

/// Persists downloaded books in the app's private documents directory.
///
/// Cached books now live in the user-visible `hermes-reader/books` folder on
/// the device's external storage (see [ExternalLibraryDir]), so downloads
/// survive an app uninstall. The folder is created on demand; if external
/// storage is unavailable the caller surfaces the error.
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

  /// Saves the extracted text and page breaks alongside the file so a cached
  /// book opens instantly on later taps, instead of re-running the (slow)
  /// extractor every time.
  Future<void> saveMeta(
    Book book,
    String text,
    List<int> breaks, [
    List<PdfImage> images = const [],
  ]) async {
    try {
      final file = await _metaFile(book);
      await file.writeAsString(jsonEncode({
        'version': _metaVersion,
        'text': text,
        'breaks': breaks,
        'images': images
            .map((e) => {
                  'mime': e.mime,
                  'width': e.width,
                  'height': e.height,
                  'data': base64Encode(e.bytes),
                })
            .toList(),
      }));
    } catch (_) {
      // Best effort — re-extraction next time is harmless.
    }
  }

  /// Loads a previously saved extraction, or null.
  ///
  /// A mismatched [BookTextMeta.version] means the cache was written by an
  /// older extractor (e.g. before PDF font/ToUnicode decoding was fixed) and
  /// must be re-derived, so stale/garbled text is never served from cache.
  Future<BookTextMeta?> loadMeta(Book book) async {
    try {
      final file = await _metaFile(book);
      if (!await file.exists()) return null;
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (map['version'] != _metaVersion) return null;
      final raw = map['images'];
      final images = raw is List
          ? [
              for (final e in raw)
                PdfImage(
                  base64Decode(e['data'] as String),
                  e['mime'] as String,
                  e['width'] as int,
                  e['height'] as int,
                )
            ]
          : const <PdfImage>[];
      return BookTextMeta(
        map['text'] as String,
        List<int>.from(map['breaks'] as List),
        images,
      );
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
      final meta = await _metaFile(book);
      if (await meta.exists()) {
        await meta.delete();
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
    final dir = await ExternalLibraryDir.booksDirectory();
    final name = const LibrarySandbox()
        .localFileName(book.serverId, book.relativePath);
    return File('${dir.path}/$name');
  }

  Future<File> _metaFile(Book book) async {
    final file = await _file(book);
    return File('${file.path}.meta');
  }
}

/// Extracted text plus page-break offsets, persisted next to a cached book.
class BookTextMeta {
  const BookTextMeta(this.text, this.breaks, this.images);
  final String text;
  final List<int> breaks;
  final List<PdfImage> images;
}

/// Bump when the extraction logic changes in a way that invalidates cached
/// text (e.g. the PDF font/ToUnicode decoding fix). Old `.meta` files are
/// ignored and re-extracted.
const int _metaVersion = 4;
