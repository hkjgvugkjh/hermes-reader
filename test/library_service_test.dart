import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_reader/reader/models/book.dart';
import 'package:hermes_reader/reader/services/file_body_decoder.dart';
import 'package:hermes_reader/reader/services/file_type_detector.dart';
import 'package:hermes_reader/reader/services/library_sandbox.dart';
import 'package:hermes_reader/reader/services/library_service.dart';

class _FakeTransport implements FileTransport {
  _FakeTransport(this._respond);

  final TransportResponse Function(String path, int call) _respond;
  final List<String> paths = [];
  int _call = 0;

  @override
  Future<TransportResponse> get(String path,
      {Map<String, String>? headers, int? expectedBytes}) async {
    paths.add(path);
    return _respond(path, _call++);
  }

  // The fakes exercise the single-shot path; range support is off so
  // downloadBook falls back to a whole-file get.
  @override
  bool get supportsRange => false;

  @override
  Future<TransportResponse> getRange(String path,
      {required int offset,
      required int length,
      Map<String, String>? headers,
      int? expectedBytes}) async {
    paths.add(path);
    return _respond(path, _call++);
  }
}

class _FakeStorage extends BookStorage {
  final files = <String, Uint8List>{};

  @override
  Future<void> save(Book book, Uint8List bytes) async => files[book.id] = bytes;

  @override
  Future<Uint8List?> load(Book book) async => files[book.id];

  @override
  Future<void> delete(Book book) async => files.remove(book.id);

  @override
  Future<bool> exists(Book book) async => files.containsKey(book.id);
}

TransportResponse _ok(Uint8List body) =>
    TransportResponse(statusCode: 200, body: body);

Uint8List _body(String text) => Uint8List.fromList(utf8.encode(text));

/// Exactly what the server sends for a text file.
Uint8List _envelope(String content) => _body(jsonEncode({'content': content}));

/// What the server sends for a binary file: every byte above 0x7F is already
/// gone by the time it reaches us.
Uint8List _damagedEnvelope(String head) =>
    _envelope('$head${'\uFFFD' * 1000}');

Book _book(String name, FileType type, int size) => Book(
      id: 's1::library/$name',
      serverId: 's1',
      serverName: 'srv',
      relativePath: 'library/$name',
      title: name,
      sizeBytes: size,
      fileType: type,
    );

const _pdfSource =
    '%PDF-1.4\n3 0 obj\n<< >>\nstream\nBT (Hello from PDF) Tj ET\nendstream\nendobj\n';

/// Declared size is the real file size; what arrives is far bigger because the
/// binary bytes were replaced with U+FFFD and then JSON-wrapped.
Book _pdfBook() =>
    _book('a.pdf', FileType.pdf, utf8.encode(_pdfSource).length);

/// A range-capable transport backed by an in-memory file. Serves byte ranges
/// (mirroring what the proxy does) so the chunked download path is exercised.
///
/// It caps every response at [chunkSize] bytes regardless of the requested
/// length, which simulates a server that streams a large file in small pieces
/// and forces the service through several range requests.
class _RangeTransport implements FileTransport {
  _RangeTransport(this.file, {this.chunkSize = 8});

  final Uint8List file;
  final int chunkSize;
  final List<int> requestedOffsets = [];

  @override
  Future<TransportResponse> get(String path,
          {Map<String, String>? headers, int? expectedBytes}) async =>
      TransportResponse(
        statusCode: 200,
        body: Uint8List.fromList(file),
        headers: {'X-Hermes-Total': '${file.length}'},
      );

  @override
  bool get supportsRange => true;

  @override
  Future<TransportResponse> getRange(String path,
      {required int offset,
      required int length,
      Map<String, String>? headers,
      int? expectedBytes}) async {
    requestedOffsets.add(offset);
    final want = length < chunkSize ? length : chunkSize;
    final end = (offset + want) > file.length ? file.length : offset + want;
    return TransportResponse(
      statusCode: 200,
      body: Uint8List.sublistView(file, offset, end),
      headers: {
        'X-Hermes-Total': '${file.length}',
        'X-Hermes-Offset': '$offset',
      },
    );
  }
}

void main() {
  late _FakeStorage storage;

  setUp(() => storage = _FakeStorage());

  LibraryService _service({LibrarySandbox? sandbox}) =>
      LibraryService(storage: storage, sandbox: sandbox ?? const _RelaxedSandbox());

  test('a range-capable transport downloads in chunks and reports progress',
      () async {
    // 32 bytes served in 8-byte chunks via a transport that ignores the
    // requested chunk size (so 4 progress updates are expected).
    final payload = _body('ABCDEFGHIJKLMNOPQRSTUVWXYZ012345');
    final transport = _RangeTransport(payload);
    final service = _service();

    final updates = <DownloadProgress>[];
    final content = await service.downloadBook(
      transport: transport,
      book: _book('a.txt', FileType.plainText, payload.length),
      onProgress: updates.add,
    );

    // The whole file was assembled byte-for-byte.
    expect(content.text, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345');
    // Progress was reported (one update per chunk, at least two).
    expect(updates.length, greaterThanOrEqualTo(2));
    // The final update reflects the complete transfer.
    expect(updates.last.received, payload.length);
    expect(updates.last.total, payload.length);
    expect(updates.last.fraction, 1.0);
    // Chunks were requested sequentially from offset 0.
    expect(transport.requestedOffsets.first, 0);
    expect(transport.requestedOffsets, orderedEquals(List.generate(4, (i) => i * 8)));
  });

  test('text files are unwrapped from the JSON envelope', () async {
    final transport = _FakeTransport((_, __) => _ok(_envelope('第一章 正文')));
    final service = _service();

    final content = await service.downloadBook(
      transport: transport,
      book: _book('a.txt', FileType.plainText, 20),
    );

    expect(content.text, '第一章 正文');
  });

  test('a json file is left alone', () async {
    const raw = '{"content": "inner"}';
    final transport = _FakeTransport((_, __) => _ok(_body(raw)));
    final service = _service();

    final content = await service.downloadBook(
      transport: transport,
      book: _book('a.json', FileType.json, raw.length),
    );

    expect(content.text, contains('inner'));
  });

  test('a damaged pdf is re-requested as base64', () async {
    final transport = _FakeTransport((path, call) {
      if (call == 0) return _ok(_damagedEnvelope('%PDF-1.4'));
      // Second call carries the intact file, base64 encoded.
      return _ok(_body(base64Encode(utf8.encode(_pdfSource))));
    });
    final service = _service();

    final content = await service.downloadBook(
      transport: transport,
      book: _pdfBook(),
    );

    expect(transport.paths.length, 2);
    expect(transport.paths[1], contains('encoding=base64'));
    expect(content.text, contains('Hello from PDF'));
    // The clean bytes are what got cached, not the damaged ones.
    expect(utf8.decode(storage.files.values.first!), contains('Hello from PDF'));
  });

  test('when base64 is unsupported the damaged payload is still used', () async {
    final transport =
        _FakeTransport((_, __) => _ok(_damagedEnvelope('%PDF-1.4')));
    final service = _service();

    final content = await service.downloadBook(
      transport: transport,
      book: _pdfBook(),
    );

    expect(transport.paths.length, 2);
    expect(content.text, isNotEmpty);
  });

  test('the cached copy is unwrapped too', () async {
    final service = _service();
    final book = _book('a.txt', FileType.plainText, 20);
    await storage.save(book, _envelope('缓存内容'));

    final content = await service.readCached(book);
    expect(content!.text, '缓存内容');
  });

  group('FileBodyDecoder', () {
    const decoder = FileBodyDecoder();

    test('passes binary payloads through untouched', () {
      // 0x80+ bytes make this invalid UTF-8, i.e. genuinely binary.
      final binary = Uint8List.fromList([0x25, 0x50, 0x80, 0xFF]);
      expect(decoder.decode(binary), same(binary));
    });

    test('detects replacement-character damage', () {
      expect(FileBodyDecoder.looksBinaryDamaged('正常文本'), isFalse);
      expect(
          FileBodyDecoder.looksBinaryDamaged(
              '头部${'\uFFFD' * 500}尾部'),
          isTrue);
    });
  });

  group('validateContent', () {
    const sandbox = LibrarySandbox();

    test('a 2.5x encoded payload is accepted', () {
      // The real TG7221B case: 1210136 declared, 3070633 received once the
      // server JSON-wraps and re-encodes binary bytes.
      expect(
        () => sandbox.validateContent(Uint8List(3070633),
            declaredSize: 1210136),
        returnsNormally,
      );
    });

    test('a truncated payload is rejected', () {
      expect(
        () => sandbox.validateContent(Uint8List(10), declaredSize: 100000),
        throwsA(isA<LibrarySandboxError>()),
      );
    });

    test('a runaway payload is rejected', () {
      expect(
        () => sandbox.validateContent(Uint8List(70000), declaredSize: 10),
        throwsA(isA<LibrarySandboxError>()),
      );
    });

    test('empty payloads are rejected', () {
      expect(
        () => sandbox.validateContent(Uint8List(0), declaredSize: 10),
        throwsA(isA<LibrarySandboxError>()),
      );
    });
  });
}

/// Bypasses the path checks so the tests can focus on payload handling; the
/// sandbox is exercised on its own above.
class _RelaxedSandbox extends LibrarySandbox {
  const _RelaxedSandbox();

  @override
  String resolve(String input) => input;

  @override
  void checkTransfer(int totalBytes) {}

  @override
  bool sizeAllowed(int size) => true;
}
