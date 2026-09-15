import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'external_library_dir.dart';
import 'library_cache_index.dart';

import '../models/book.dart';
import '../utils/error_messages.dart';
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
  ///
  /// [expectedBytes] is the file's declared size (if known). Transports that
  /// apply a request timeout scale it from this so that large files downloading
  /// at a healthy rate (>= ~10 KB/s) are never reported as timed out.
  Future<TransportResponse> get(
    String path, {
    Map<String, String>? headers,
    int? expectedBytes,
  });

  /// Whether this transport can serve a byte range of a file via [getRange].
  ///
  /// When false, callers fall back to a single whole-file [get] and cannot
  /// report incremental progress.
  bool get supportsRange => false;

  /// Fetches up to [length] bytes of [path] starting at [offset].
  ///
  /// The response headers carry `X-Hermes-Total` (full file size) and
  /// `X-Hermes-Offset` so the caller can compute download progress without
  /// guessing. Only called when [supportsRange] is true.
  Future<TransportResponse> getRange(
    String path, {
    required int offset,
    required int length,
    Map<String, String>? headers,
    int? expectedBytes,
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

/// A snapshot of an in-flight download, surfaced to the UI so it can show
/// "downloaded x of y" plus a live transfer rate.
class DownloadProgress {
  const DownloadProgress({
    required this.received,
    required this.total,
    required this.rateBps,
  });

  /// Bytes received so far.
  final int received;

  /// Total bytes expected (0 when the server did not declare a size).
  final int total;

  /// Smoothed transfer rate in bytes per second (0 when not yet measurable).
  final double rateBps;

  /// Fraction downloaded, 0.0 - 1.0. Returns 0 while the total is unknown.
  double get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;

  /// Human-readable "1.2 MB / 5.0 MB" style label.
  String get sizeLabel {
    final r = _fmtBytes(received);
    return total > 0 ? '$r / ${_fmtBytes(total)}' : r;
  }

  /// Human-readable rate label, e.g. "320 KB/s".
  String get rateLabel =>
      rateBps <= 0 ? '—' : '${_fmtBytes(rateBps.round())}/s';

  static String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
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

  /// Progress snapshot emitted while [downloadBook] streams a file.
  ///
  /// [received] / [total] are byte counts (total may be 0 when the server does
  /// not declare a size); [rateBps] is a smoothed bytes-per-second estimate.
  DownloadProgress _progress(int received, int total, double rateBps) =>
      DownloadProgress(received: received, total: total, rateBps: rateBps);

  /// Byte size of each chunk pulled in a chunked download. Small enough that a
  /// single request can never stall long enough to look like a timeout, and
  /// large enough to keep per-request overhead negligible.
  static const int _chunkSize = 1 << 20; // 1 MiB

  /// Downloads a book and stores it in the app's private directory.
  ///
  /// When [transport] supports ranges the file is pulled in chunks and
  /// [onProgress] is invoked after each chunk with the running byte count and a
  /// live rate, so the UI can show progress instead of freezing at 0%.
  ///
  /// Returns the decoded [BookContent]. Throws [LibrarySandboxError] if the
  /// path or the payload violates any limit.
  Future<BookContent> downloadBook({
    required FileTransport transport,
    required Book book,
    String? encoding,
    void Function(DownloadProgress)? onProgress,
  }) async {
    // Re-validate even for a Book that came from our own listing — the object
    // may have been persisted and tampered with.
    final safePath = sandbox.resolve(book.relativePath);
    sandbox.checkTransfer(book.sizeBytes);

    final type = _typeOf(book);
    // Announce the transfer before the first byte arrives. The declared size is
    // already known from the listing, so the UI can show "0 B / 12.5 MB" right
    // away instead of an indeterminate bar that looks stuck while the proxy
    // seeds its buffer for the first slice.
    onProgress?.call(DownloadProgress(
      received: 0,
      total: book.sizeBytes,
      rateBps: 0,
    ));
    final bytes = transport.supportsRange
        ? await _fetchChunked(transport, safePath, type,
            expectedBytes: book.sizeBytes, onProgress: onProgress)
        : await _fetchBytes(transport, safePath, type,
            expectedBytes: book.sizeBytes);
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
    FileType type, {
    int? expectedBytes,
  }) async {
    final response = await transport.get(_readPath(safePath),
        expectedBytes: expectedBytes);
    if (!response.isOk) {
      throw LibrarySandboxError(
          'download failed with status ${response.statusCode}');
    }

    final payload = _bodyDecoder.decode(response.body, type: type);
    if (!_fileTypeDetector.needsExtraction(type) || !_isDamaged(payload)) {
      return payload;
    }

    final retry = await transport.get(_readPath(safePath, encoding: 'base64'),
        expectedBytes: expectedBytes);
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

  /// Pulls a file in fixed-size chunks, reporting progress after each one.
  ///
  /// The total size comes from the first response's `X-Hermes-Total` header
  /// (falling back to [expectedBytes]) so the progress bar is accurate even
  /// when the caller did not know the size up front. The rate is measured over
  /// a sliding window to avoid a jittery display.
  Future<Uint8List> _fetchChunked(
    FileTransport transport,
    String safePath,
    FileType type, {
    int? expectedBytes,
    void Function(DownloadProgress)? onProgress,
  }) async {
    final builder = BytesBuilder(copy: false);
    var offset = 0;
    var total = expectedBytes ?? 0;
    final sw = Stopwatch()..start();
    // Sliding-window rate：keeps the last few chunk timings so transient
    // stalls do not spike the reported speed.
    final recent = <int>[]; // bytes of the last N chunks
    final recentMs = <int>[];

    while (true) {
      final TransportResponse resp;
      try {
        resp = await transport.getRange(
          safePath,
          offset: offset,
          length: _chunkSize,
          expectedBytes: total > 0 ? total : null,
        );
      } catch (e) {
        // Report how far the download got before it broke, so a long stall is
        // diagnosable ("已下载 3.2 MB / 12 MB 后超时") rather than a bare timeout.
        final done = DownloadProgress(received: offset, total: total, rateBps: 0);
        final friendly = describeError(e);
        throw LibrarySandboxError(
            '${friendly.message}（已下载 ${done.sizeLabel}，中断于第 ${offset ~/ _chunkSize + 1} 块）');
      }
      if (!resp.isOk) {
        // A partial download is useless; surface the failure clearly.
        throw LibrarySandboxError(
            'download failed at offset $offset with status ${resp.statusCode}');
      }
      final headerTotal = int.tryParse(resp.headers['x-hermes-total'] ?? '');
      if (headerTotal != null && headerTotal > 0) total = headerTotal;
      final chunk = resp.body;
      // An empty chunk with bytes still outstanding would loop forever; treat
      // it as end-of-stream so a server quirk cannot hang the download.
      if (chunk.isEmpty) break;

      builder.add(chunk);
      offset += chunk.length;

      // Update the sliding window (drop timings older than ~3s of history).
      recent.add(chunk.length);
      recentMs.add(sw.elapsedMilliseconds);
      while (recentMs.length > 8) {
        recent.removeAt(0);
        recentMs.removeAt(0);
      }
      final windowBytes = recent.fold<int>(0, (a, b) => a + b);
      final windowMs = recentMs.length >= 2
          ? recentMs.last - recentMs.first
          : sw.elapsedMilliseconds;
      final rate =
          windowMs > 0 ? windowBytes * 1000 / windowMs : 0.0;

      onProgress?.call(_progress(offset, total, rate));
      print('[DL] $safePath offset=$offset total=$total '
          'rate=${rate.toStringAsFixed(0)}B/s');

      // Stop once we have the whole file. When the total is known we trust it
      // (a short response just means the server sliced smaller than asked);
      // otherwise a short chunk marks the tail.
      if (total > 0) {
        if (offset >= total) break;
      } else if (chunk.length < _chunkSize) {
        break;
      }
    }

    final raw = builder.takeBytes();
    // Reuse the single-shot unwrapping so the base64/JSON envelope handling
    // stays in one place.
    final payload = _bodyDecoder.decode(raw, type: type);
    if (!_fileTypeDetector.needsExtraction(type) || !_isDamaged(payload)) {
      onProgress?.call(_progress(offset, total > 0 ? total : offset, 0));
      return payload;
    }
    // Damaged binary payload: fall back to a single base64 read.
    final retry = await transport.get(_readPath(safePath, encoding: 'base64'),
        expectedBytes: expectedBytes);
    if (!retry.isOk) return payload;
    return _decodeBase64Body(retry.body, type) ?? payload;
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
