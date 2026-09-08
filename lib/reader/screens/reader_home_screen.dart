import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../providers/library_provider.dart';
import '../services/library_service.dart';
import 'book_reader_screen.dart';

/// Bookshelf: lists what a server exposes under its `library` directory and
/// lets the user pull a book onto the device.
class ReaderHomeScreen extends StatefulWidget {
  const ReaderHomeScreen({
    super.key,
    required this.serverId,
    required this.serverName,
    required this.transport,
  });

  final String serverId;
  final String serverName;
  final FileTransport transport;

  @override
  State<ReaderHomeScreen> createState() => _ReaderHomeScreenState();
}

class _ReaderHomeScreenState extends State<ReaderHomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() {
    return context.read<LibraryProvider>().refresh(
          transport: widget.transport,
          serverId: widget.serverId,
          serverName: widget.serverName,
        );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('书架 — ${widget.serverName}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _refresh,
          ),
        ],
      ),
      body: Consumer<LibraryProvider>(
        builder: (context, library, _) {
          if (library.loading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (library.error != null) {
            return _ErrorView(message: library.error!, onRetry: _refresh);
          }

          if (library.books.isEmpty) {
            return const _EmptyShelf();
          }

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: library.books.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final book = library.books[index];
                return _BookTile(
                  book: book,
                  cached: library.isCached(book),
                  progress: library.progressFor(book.id),
                  onTap: () => _openBook(context, book),
                  onDownload: () => _download(context, book),
                  onDelete: () =>
                      context.read<LibraryProvider>().remove(book),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _openBook(BuildContext context, Book book) async {
    final library = context.read<LibraryProvider>();
    // Capture the reader before the await: once this frame's element is
    // deactivated, looking it up again is unsafe.
    final reader = context.read<ReaderProvider>();
    final content = await library.open(
      transport: widget.transport,
      book: book,
    );
    if (!mounted || content == null) return;

    reader.openBook(book, content);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BookReaderScreen()),
    );
  }

  Future<void> _download(BuildContext context, Book book) async {
    final library = context.read<LibraryProvider>();
    final content = await library.download(
      transport: widget.transport,
      book: book,
    );
    if (!mounted) return;

    // Snapshot the error while the provider is still reachable.
    final message = content != null
        ? '《${book.title}》已下载'
        : '下载失败：${library.error ?? "未知错误"}';

    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({
    required this.book,
    required this.cached,
    required this.progress,
    required this.onTap,
    required this.onDownload,
    required this.onDelete,
  });

  final Book book;
  final bool cached;
  final double progress;
  final VoidCallback onTap;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final downloading = progress > 0 && progress < 1;

    return ListTile(
      leading: Icon(
        cached ? Icons.menu_book : Icons.cloud_download_outlined,
        color: cached
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).disabledColor,
      ),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${book.sizeLabel}${cached ? '  ·  已下载' : ''}'),
          if (downloading)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(value: progress),
            ),
        ],
      ),
      trailing: cached
          ? IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除本地副本',
              onPressed: onDelete,
            )
          : IconButton(
              icon: const Icon(Icons.download),
              tooltip: '下载',
              onPressed: onDownload,
            ),
      onTap: onTap,
    );
  }
}

class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shelves,
                size: 64, color: Theme.of(context).disabledColor),
            const SizedBox(height: 16),
            const Text('书架上还没有书', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text(
              '把 .txt 或 .md 文件放到服务器工作区的 library/ 目录下即可看到。\n'
              '为保护隐私，只有该目录内的文件会被读取。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).disabledColor),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
