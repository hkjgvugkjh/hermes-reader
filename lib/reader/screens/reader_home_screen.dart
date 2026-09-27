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
  /// Saved positions for books that have been opened before, by book id.
  Map<String, ReadingProgress> _saved = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    await context.read<LibraryProvider>().refresh(
          transport: widget.transport,
          serverId: widget.serverId,
          serverName: widget.serverName,
        );
    await _loadProgress();
  }

  /// Pulls every saved position so the shelf can offer "continue".
  ///
  /// Sequential on purpose: the list is short, and hammering
  /// SharedPreferences in parallel gains nothing.
  Future<void> _loadProgress() async {
    final library = context.read<LibraryProvider>();
    final reader = context.read<ReaderProvider>();
    final loaded = <String, ReadingProgress>{};

    for (final book in library.books) {
      final progress = await reader.loadProgress(book.id);
      if (progress != null && progress.pageIndex > 0) {
        loaded[book.id] = progress;
      }
    }
    if (mounted) setState(() => _saved = loaded);
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
                final saved = _saved[book.id];
                return _BookTile(
                  book: book,
                  cached: library.isCached(book),
                  downloading: library.isDownloading(book.id),
                  progress: library.progressFor(book.id),
                  stats: library.downloadStatsFor(book.id),
                  saved: saved,
                  onTap: () => _openBook(context, book),
                  onRestart: saved == null
                      ? null
                      : () => _openBook(context, book, fromStart: true),
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

  /// Opens [book]; pass [fromStart] to ignore the saved position.
  Future<void> _openBook(BuildContext context, Book book,
      {bool fromStart = false}) async {
    final library = context.read<LibraryProvider>();
    // Immediate feedback: opening extracts text off-thread, but even the
    // hand-off can take a moment for large books, so tell the user now.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('正在打开《${book.title}》…'),
        duration: const Duration(seconds: 30),
      ),
    );
    // Capture the reader before the await: once this frame's element is
    // deactivated, looking it up again is unsafe.
    final reader = context.read<ReaderProvider>();
    BookContent? content;
    final sw = Stopwatch()..start();
    print('[OPEN] start open ${book.id}');
    try {
      content = await library.open(
        transport: widget.transport,
        book: book,
      );
    } catch (e) {
      print('[OPEN] open threw after ${sw.elapsedMilliseconds}ms: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败：$e')),
        );
      }
      return;
    }
    print('[OPEN] open returned after ${sw.elapsedMilliseconds}ms '
        'content=${content == null ? 'NULL' : 'len=${content.text.length}'}');
    if (!mounted || content == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法读取本地副本，请尝试重新下载')),
        );
      }
      return;
    }

    await reader.openBook(book, content);
    if (fromStart) reader.goToPage(0);
    if (!mounted) return;
    // Content is now loaded and the reader will display it; clear the
    // "opening" hint right away so it does not linger on the reader screen.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BookReaderScreen()),
    );

    // The reader saved its position on the way out; show it on the shelf.
    await _loadProgress();
  }

  Future<void> _download(BuildContext context, Book book) async {
    final library = context.read<LibraryProvider>();
    // Re-entrancy guard: the provider already blocks concurrent downloads, but
    // show a clear hint instead of a misleading "download failed" later.
    if (library.isDownloading(book.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《${book.title}》正在下载中…')),
      );
      return;
    }

    // Immediate feedback: the click registered and a download is starting.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('开始下载《${book.title}》…')),
    );
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
    required this.stats,
    required this.saved,
    required this.onTap,
    required this.onRestart,
    required this.downloading,
    required this.onDownload,
    required this.onDelete,
  });

  final Book book;
  final bool cached;
  final double progress;
  final DownloadProgress? stats;
  final ReadingProgress? saved;
  final VoidCallback onTap;
  final VoidCallback? onRestart;
  final bool downloading;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final percent = saved == null ? 0 : (saved!.percent * 100).round();

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
          Text(
            saved != null
                ? '${book.sizeLabel}  ·  已读 $percent%'
                : (cached
                    ? '${book.sizeLabel}  ·  已下载'
                    : (downloading
                        ? '${book.sizeLabel}  ·  下载中…'
                        : book.sizeLabel)),
          ),
          if (downloading)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: progress > 0 ? progress : null,
              ),
            ),
          // Downloaded-so-far and live transfer rate, so a long download shows
          // movement instead of an indeterminate bar. Falls back to a hint
          // before the first chunk lands and the numbers exist.
          if (downloading)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _progressLine(stats),
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.outline,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onRestart != null)
            IconButton(
              icon: const Icon(Icons.replay),
              tooltip: '从头开始',
              onPressed: onRestart,
            ),
          if (cached)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除本地副本',
              onPressed: onDelete,
            )
          else if (downloading)
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          else
            IconButton(
              icon: const Icon(Icons.download),
              tooltip: '下载',
              onPressed: onDownload,
            ),
        ],
      ),
      onTap: onTap,
    );
  }

  /// Builds the "1.2 MB / 5.0 MB · 320 KB/s" line shown while downloading.
  ///
  /// Returns a placeholder before the first chunk arrives, when neither the
  /// byte counts nor the rate are meaningful yet.
  static String _progressLine(DownloadProgress? stats) {
    if (stats == null) return '下载中…';
    final size = stats.sizeLabel;
    final rate = stats.rateBps > 0 ? '  ·  ${stats.rateLabel}' : '';
    return '$size$rate';
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
              '把 .txt / .md / .pdf / .epub / .mobi / .html / .json 文件放到服务器'
              '工作区的 library/ 目录下即可看到。\n'
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
