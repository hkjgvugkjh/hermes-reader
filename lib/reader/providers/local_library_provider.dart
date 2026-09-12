import 'package:flutter/foundation.dart';
import 'package:hermes_shared/hermes_shared.dart';

import '../models/book.dart';
import '../services/library_service.dart';
import '../services/local_library_transport.dart';
import 'library_provider.dart';

/// Manages the proxy-hosted local library for the reader UI.
///
/// Listing, opening, downloading and on-device caching reuse the existing
/// [LibraryProvider] + [LibraryService] pipeline via [LocalLibraryFileTransport]
/// (so extracted text/images behave exactly like a normal server shelf). Upload,
/// rename, server-side delete and forwarding to a remote library go through the
/// [LocalLibraryClient] directly.
class LocalLibraryProvider extends ChangeNotifier {
  LocalLibraryProvider({required this.client, LibraryService? service})
      : shelf = LibraryProvider(service ?? LibraryService());

  final LocalLibraryClient client;
  final LibraryProvider shelf;

  FileTransport get transport => LocalLibraryFileTransport(client: client);

  Future<void> refresh() => shelf.refresh(
        transport: transport,
        serverId: kLocalLibraryServerID,
        serverName: '本地文库',
      );

  Future<BookContent?> open(Book book) => shelf.open(transport: transport, book: book);
  Future<BookContent?> download(Book book) =>
      shelf.download(transport: transport, book: book);
  Future<void> removeLocal(Book book) => shelf.remove(book);

  Future<void> upload(String dir, String name, List<int> bytes) async {
    await client.write(dir, name, bytes);
    await refresh();
  }

  Future<void> deleteRemote(String relPath) async {
    await client.delete(relPath);
    await refresh();
  }

  Future<void> renameRemote(String relPath, String newName) async {
    await client.rename(relPath, newName);
    await refresh();
  }

  Future<void> forward(String relPath, String targetServerId, String remotePath) =>
      client.forward(relPath, targetServerId, remotePath);

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
}
