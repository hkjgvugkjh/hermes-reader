import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hermes_shared/hermes_shared.dart';

import '../models/book.dart';
import '../services/external_library_dir.dart';
import '../services/file_type_detector.dart';
import '../services/library_service.dart';
import '../services/local_library_transport.dart';
import 'library_provider.dart';

/// Manages the device-local library for the reader UI.
///
/// Listing and opening reuse the existing [LibraryProvider] + [LibraryService]
/// pipeline via [LocalFileSystemTransport] (extracted text and images behave
/// exactly like a normal server shelf, but the bytes come from the device
/// filesystem instead of a proxy). Upload, rename and delete are plain
/// filesystem operations under the app-private `library` folder. Only [forward]
/// reaches the network — it pushes the local file to a remote server through
/// the proxy.
class LocalLibraryProvider extends ChangeNotifier {
  LocalLibraryProvider({
    required this.rootDir,
    this.forwardClient,
    LibraryService? service,
  }) : shelf = LibraryProvider(service ?? LibraryService());

  final Directory rootDir;
  final LocalLibraryClient? forwardClient;
  final LibraryProvider shelf;

  FileTransport get transport => LocalFileSystemTransport(rootDir);

  Future<void> refresh() => shelf.refresh(
        transport: transport,
        serverId: kLocalLibraryServerID,
        serverName: '本地文库',
      );

  Future<BookContent?> open(Book book) =>
      shelf.open(transport: transport, book: book);
  Future<BookContent?> download(Book book) =>
      shelf.download(transport: transport, book: book);
  Future<void> removeLocal(Book book) => shelf.remove(book);

  /// Groups the on-device download cache (`books/`) by source server id so the
  /// local library can show each remote server's downloaded books as its own
  /// section. [knownServerIds] lets us recover the server id even when it
  /// contains underscores, because the cache filename is `<serverId>_<flatPath>`.
  Future<Map<String, List<File>>> cachedFilesByServer(
    List<String> knownServerIds,
  ) async {
    final dir = await ExternalLibraryDir.booksDirectory();
    if (!await dir.exists()) return const {};
    final out = <String, List<File>>{};
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.endsWith('.meta')) continue;
      final serverId = _serverIdFromCacheName(name, knownServerIds);
      if (serverId == null) continue;
      out.putIfAbsent(serverId, () => []).add(entity);
    }
    return out;
  }

  /// Reconstructs a [Book] for a cached download so it can be listed and opened
  /// from the local library. The relative path is the flattened cache name, which
  /// [BookStorage] maps back to the very same file.
  Future<Book> bookFromCache(File file, String serverId) async {
    final name = file.uri.pathSegments.last;
    final safeRel = name.substring(serverId.length + 1);
    final size = await file.length();
    return Book(
      id: '$serverId::$safeRel',
      serverId: serverId,
      serverName: '',
      relativePath: safeRel,
      title: _stripExtension(safeRel),
      sizeBytes: size,
      fileType: const FileTypeDetector().detect(safeRel),
    );
  }

  static String? _serverIdFromCacheName(String name, List<String> knownServerIds) {
    String? best;
    for (final id in knownServerIds) {
      if (id.isEmpty) continue;
      if (name.startsWith('${id}_') && (best == null || id.length > best.length)) {
        best = id;
      }
    }
    if (best != null) return best;
    final idx = name.indexOf('_');
    return idx > 0 ? name.substring(0, idx) : null;
  }

  static String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return name;
    return name.substring(0, dot);
  }

  Future<void> upload(String dir, String name, List<int> bytes) async {
    final target = Directory(_join(rootDir.path, _localRel(dir)));
    await target.create(recursive: true);
    await File('${target.path}/$name').writeAsBytes(bytes, flush: true);
    await refresh();
  }

  Future<void> deleteRemote(String relPath) async {
    final file = File(_join(rootDir.path, _localRel(relPath)));
    if (await file.exists()) await file.delete();
    await refresh();
  }

  Future<void> renameRemote(String relPath, String newName) async {
    final old = File(_join(rootDir.path, _localRel(relPath)));
    if (!await old.exists()) return;
    final renamed = File('${old.parent.path}/$newName');
    await old.rename(renamed.path);
    await refresh();
  }

  /// Pushes a local file to a remote server's studio library through the proxy.
  /// This is the only operation that needs the network.
  Future<void> forward(String relPath, String targetServerId, String remotePath) async {
    final client = forwardClient;
    if (client == null) throw Exception('未连接代理，无法转发');
    final file = File(_join(rootDir.path, _localRel(relPath)));
    if (!await file.exists()) throw Exception('本地文件不存在');
    final bytes = await file.readAsBytes();
    final name = _basename(relPath);
    await client.writeToServer(targetServerId, remotePath, name, bytes);
  }

  List<Book> get books => shelf.books;
  bool get loading => shelf.loading;
  String? get error => shelf.error;
  bool isCached(Book book) => shelf.isCached(book);
  bool isDownloading(String id) => shelf.isDownloading(id);
  double progressFor(String id) => shelf.progressFor(id);

  @override
  void dispose() {
    shelf.dispose();
    super.dispose();
  }

  static String _localRel(String p) {
    if (p.isEmpty || p == 'library' || p == '/') return '';
    if (p.startsWith('library/')) return p.substring(8);
    return p;
  }

  static String _join(String base, String rel) => rel.isEmpty ? base : '$base/$rel';

  static String _basename(String p) {
    final clean = p.endsWith('/') ? p.substring(0, p.length - 1) : p;
    final i = clean.lastIndexOf('/');
    return i < 0 ? clean : clean.substring(i + 1);
  }
}
