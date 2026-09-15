import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hermes_shared/hermes_shared.dart' hide ProxyClient;
import 'package:provider/provider.dart';

import '../models/book.dart' hide FileType;
import '../models/book.dart' as models;
import '../providers/library_provider.dart';
import '../providers/local_library_provider.dart';
import '../providers/server_provider.dart';
import '../services/external_library_dir.dart';
import '../services/proxy_client.dart';
import 'book_reader_screen.dart';

class LocalLibraryScreen extends StatefulWidget {
  const LocalLibraryScreen({super.key, required this.proxyClient});
  final ProxyClient proxyClient;
  @override
  State<LocalLibraryScreen> createState() => _LocalLibraryScreenState();
}

/// One grouped library shown as its own section in the local library view.
class LocalLibrarySection {
  const LocalLibrarySection({
    required this.marker,
    required this.name,
    required this.isLocal,
    required this.books,
  });
  final String marker;
  final String name;
  final bool isLocal;
  final List<Book> books;
}

class _LocalLibraryScreenState extends State<LocalLibraryScreen> {
  late final Directory _rootDir;
  late final LocalLibraryProvider _provider;
  bool _ready = false;
  bool _connecting = true;
  bool _reloading = false;
  String? _error;
  List<LocalLibrarySection> _sections = const [];
  Map<String, String> _encodingLabels = const {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final granted = await ExternalLibraryDir.ensurePermission();
    if (!granted) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = '需要「所有文件访问」权限，才能在手机存储中创建 hermes-reader 目录';
        });
      }
      return;
    }
    final ext = await ExternalLibraryDir.ensure();
    _rootDir = await ext.library;
    _provider = LocalLibraryProvider(
      rootDir: _rootDir,
      forwardClient: LocalLibraryClient(widget.proxyClient.sendRequest),
    );
    if (!mounted) return;
    setState(() => _ready = true);
    await _loadSections(firstLoad: true);
  }

  /// Rebuilds the sectioned view: the device-local library plus, for every
  /// remote server that has downloaded books in the `books/` cache, its own
  /// section. Books from the local server id are excluded because those cached
  /// files are only extraction artifacts of the local library.
  Future<void> _loadSections({bool firstLoad = false}) async {
    if (!mounted) return;
    setState(() {
      if (firstLoad) _connecting = true;
      _reloading = true;
    });
    try {
      await _provider.refresh();
      final servers = context.read<ServerProvider>().servers;
      final cached = await _provider.cachedFilesByServer(
        servers.map((s) => s.id).toList(),
      );

      final sections = <LocalLibrarySection>[];
      sections.add(LocalLibrarySection(
        marker: '×',
        name: '本地文库',
        isLocal: true,
        books: _provider.books,
      ));

      final remaining = Map<String, List<File>>.from(cached);
      for (final server in servers) {
        if (server.id == kLocalLibraryServerID) continue;
        final files = remaining.remove(server.id);
        if (files == null || files.isEmpty) continue;
        final books = await Future.wait(
          files.map((f) => _provider.bookFromCache(f, server.id)),
        );
        sections.add(LocalLibrarySection(
          marker: '*',
          name: server.name,
          isLocal: false,
          books: books,
        ));
      }
      for (final entry in remaining.entries) {
        if (entry.key == kLocalLibraryServerID) continue;
        if (entry.value.isEmpty) continue;
        final books = await Future.wait(
          entry.value.map((f) => _provider.bookFromCache(f, entry.key)),
        );
        sections.add(LocalLibrarySection(
          marker: '*',
          name: entry.key,
          isLocal: false,
          books: books,
        ));
      }

      if (!mounted) return;
      // Refresh the per-book encoding labels alongside the listing.
      final labels = <String, String>{};
      await Future.wait(
        sections.expand((s) => s.books).map((book) async {
          labels[book.id] = await _provider.encodingLabelOf(book);
        }),
      );
      _encodingLabels = labels;
      setState(() {
        _sections = sections;
        _connecting = false;
        _reloading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _reloading = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _openBook(BuildContext context, Book book, [BookContent? preloaded]) async {
    try {
      final content = preloaded ?? await _provider.open(book);
      if (content == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('打开失败：本地无缓存且无法重新获取')),
          );
        }
        return;
      }
      if (mounted) {
        await context.read<ReaderProvider>().openBook(book, content);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const BookReaderScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('打开失败：$e')));
      }
    }
  }

  /// Whether [book] is a text format where a charset switch helps.
  bool _isText(Book book) {
    final t = book.fileType;
    return t == null ||
        t == models.FileType.plainText ||
        t == models.FileType.html ||
        t == models.FileType.mobi ||
        t == models.FileType.json ||
        t == models.FileType.unknown;
  }

  static const Map<String, String> _encodingChoices = {
    'auto': '自动',
    'utf-8': 'UTF-8',
    'gbk': 'GBK',
  };

  Future<void> _setEncoding(BuildContext context, Book book) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('文本编码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in _encodingChoices.entries)
              ListTile(
                title: Text(e.value),
                subtitle: Text(e.key),
                onTap: () => Navigator.pop(ctx, e.key),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    // Apply + persist, then open the (re-decoded) book with the new encoding.
    final content = await _provider.readCached(book, encoding: chosen);
    _encodingLabels[book.id] = chosen;
    if (mounted) setState(() {});
    if (content != null) {
      await _openBook(context, book, content);
    } else {
      await _provider.setEncoding(book, chosen);
      final c = await _provider.open(book);
      await _openBook(context, book, c);
    }
  }

  Future<void> _upload() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.any,
    );
    if (result == null) return;
    try {
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null) continue;
        await _provider.upload('', file.name, bytes);
      }
      await _loadSections();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('上传失败：$e')));
      }
    }
  }

  Future<void> _rename(BuildContext context, Book book) async {
    final controller = TextEditingController(text: book.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '新文件名'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await _provider.renameRemote(book.relativePath, name);
      await _loadSections();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重命名失败：$e')));
      }
    }
  }

  Future<void> _delete(BuildContext context, Book book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件'),
        content: Text('确定从本地文库删除《${book.title}》吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _provider.deleteRemote(book.relativePath);
      await _loadSections();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    }
  }

  Future<void> _removeCache(BuildContext context, Book book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除下载'),
        content: Text('确定从本机删除《${book.title}》的下载缓存吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _provider.removeLocal(book);
      await _loadSections();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    }
  }

  Future<void> _forward(BuildContext context, Book book) async {
    final servers = context.read<ServerProvider>().servers;
    if (servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有可用的远程服务器')));
      return;
    }
    String? targetId = servers.first.id;
    final nameController = TextEditingController(text: book.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('转发到远程库'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: targetId,
              items: [
                for (final s in servers)
                  DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (v) => targetId = v,
              decoration: const InputDecoration(labelText: '目标服务器'),
            ),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '保存为'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('转发')),
        ],
      ),
    );
    if (ok != true || targetId == null) return;
    try {
      await _provider.forward(book.relativePath, targetId!, 'library/${nameController.text}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已转发')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('转发失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Swipe right anywhere on the page to go back to the previous screen.
    // The list itself only scrolls vertically, so a horizontal drag is
    // unambiguous.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (details) {
        final vx = details.primaryVelocity ?? 0;
        if (vx > 250) {
          Navigator.maybePop(context);
        }
      },
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地文库'),
        actions: [
          IconButton(
            icon: _reloading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _reloading ? null : () => _loadSections(),
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: '上传文件',
            onPressed: _upload,
          ),
        ],
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : ListenableBuilder(
              listenable: _provider,
              builder: (context, _) {
                if (_connecting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (_error != null) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center),
                    ),
                  );
                }
          final total = _sections.fold(0, (sum, s) => sum + s.books.length);
          if (total == 0) {
            return const Center(child: Text('文库为空，点击右上角上传文件'));
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final section in _sections)
                  if (section.books.isNotEmpty) ...[
                    _SectionHeader(
                      marker: section.marker,
                      name: section.name,
                      count: section.books.length,
                    ),
                    const SizedBox(height: 8),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 160,
                        childAspectRatio: 0.7,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: section.books.length,
                      itemBuilder: (_, i) {
                        final book = section.books[i];
                        return _BookCard(
                          book: book,
                          isLocal: section.isLocal,
                          cached: _provider.isCached(book),
                          onOpen: () => _openBook(context, book),
                          onRename: section.isLocal ? () => _rename(context, book) : null,
                          onDelete: section.isLocal ? () => _delete(context, book) : null,
                          onForward: section.isLocal ? () => _forward(context, book) : null,
                          onRemoveCache: section.isLocal ? null : () => _removeCache(context, book),
                          onEncoding: _isText(book) ? () => _setEncoding(context, book) : null,
                          encodingLabel: _encodingLabels[book.id],
                        );
                      },
                    ),
                    const SizedBox(height: 20),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.marker,
    required this.name,
    required this.count,
  });
  final String marker;
  final String name;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            marker,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            name,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        Text(
          '$count',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
        ),
      ],
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.isLocal,
    required this.cached,
    required this.onOpen,
    this.onRename,
    this.onDelete,
    this.onForward,
    this.onRemoveCache,
    this.onEncoding,
    this.encodingLabel,
  });
  final Book book;
  final bool isLocal;
  final bool cached;
  final VoidCallback onOpen;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final VoidCallback? onForward;
  final VoidCallback? onRemoveCache;
  final VoidCallback? onEncoding;
  final String? encodingLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: theme.colorScheme.primaryContainer,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(8),
                child: Text(
                  book.title,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  if (isLocal)
                    const Icon(Icons.folder, size: 16, color: Colors.blueGrey)
                  else if (cached)
                    const Icon(Icons.check_circle, size: 16, color: Colors.green)
                  else
                    const Icon(Icons.cloud_download, size: 16),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onEncoding != null) ...[
                  if (encodingLabel != null && encodingLabel != 'auto')
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Text(
                        encodingLabel!,
                        style: const TextStyle(fontSize: 11, color: Colors.orange),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.translate, size: 18),
                    tooltip: '切换编码',
                    onPressed: onEncoding,
                  ),
                ],
                if (onForward != null)
                  IconButton(
                    icon: const Icon(Icons.forward, size: 18),
                    tooltip: '转发到远程库',
                    onPressed: onForward,
                  ),
                if (onRename != null)
                  IconButton(
                    icon: const Icon(Icons.edit, size: 18),
                    tooltip: '重命名',
                    onPressed: onRename,
                  ),
                if (onRemoveCache != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: '删除下载',
                    onPressed: onRemoveCache,
                  ),
                if (onDelete != null)
                  IconButton(
                    icon: const Icon(Icons.delete, size: 18),
                    tooltip: '删除',
                    onPressed: onDelete,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
