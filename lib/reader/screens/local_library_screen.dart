import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hermes_shared/hermes_shared.dart' hide ProxyClient;
import 'package:provider/provider.dart';

import '../services/external_library_dir.dart';

import '../models/book.dart';
import '../providers/library_provider.dart';
import '../providers/local_library_provider.dart';
import '../providers/server_provider.dart';
import '../services/proxy_client.dart';
import 'book_reader_screen.dart';

/// Screen for the device-local library: list files stored on the phone,
/// open/read them, upload new files, rename, delete, and forward a file to a
/// remote server's library. Everything except [forward] is pure local
/// filesystem access — no proxy and no network are required to browse, open,
/// upload, rename or delete.
class LocalLibraryScreen extends StatefulWidget {
  const LocalLibraryScreen({super.key, required this.proxyClient});

  /// A connectable proxy [ProxyClient]. Only used for [forward], which pushes a
  /// local file to a remote server through the proxy; the rest of the library is
  /// device-local and never touches this client.
  final ProxyClient proxyClient;

  @override
  State<LocalLibraryScreen> createState() => _LocalLibraryScreenState();
}

class _LocalLibraryScreenState extends State<LocalLibraryScreen> {
  late final Directory _rootDir;
  late final LocalLibraryProvider _provider;
  bool _connecting = true;
  String? _error;

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
    try {
      await _provider.refresh();
    } catch (e) {
      // refresh() swallows listing errors into _provider.error; this catch is
      // only for unexpected transport failures so we never spin forever.
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = '加载失败：$e';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _connecting = false);
  }

  Future<void> _openBook(BuildContext context, Book book) async {
    final reader = context.read<ReaderProvider>();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('正在打开《${book.title}》…'),
        duration: const Duration(seconds: 30),
      ),
    );
    BookContent? content;
    try {
      content = await _provider.open(book);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开失败：$e')),
      );
      return;
    }
    if (!mounted || content == null) return;
    await reader.openBook(book, content);
    if (!mounted) return;
    // Content is loaded; clear the "opening" hint before showing the reader.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BookReaderScreen()),
    );
  }

  Future<void> _upload() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.singleOrNull;
    if (file == null || file.bytes == null) return;
    final name = file.name;
    try {
      await _provider.upload('library', name, file.bytes!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已上传《$name》到本地文库')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传失败：$e')),
        );
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
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == book.title) return;
    try {
      await _provider.renameRemote(book.relativePath, name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重命名失败：$e')),
        );
      }
    }
  }

  Future<void> _delete(BuildContext context, Book book) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件'),
        content: Text('确定从本地文库删除《${book.title}》吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _provider.deleteRemote(book.relativePath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$e')),
        );
      }
    }
  }

  Future<void> _forward(BuildContext context, Book book) async {
    final servers = context.read<ServerProvider>().servers;
    if (servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可用的远程服务器')),
      );
      return;
    }
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('转发到远程库'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: servers.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(servers[i].name),
              subtitle: Text(servers[i].id),
              onTap: () => Navigator.pop(ctx, servers[i].id),
            ),
          ),
        ),
      ),
    );
    if (target == null) return;
    try {
      // Forwarding is the only network operation: connect the proxy on demand.
      await widget.proxyClient.connect();
      await _provider.forward(book.relativePath, target, 'library');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已转发《${book.title}》到 $target')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('转发失败：$e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _provider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地文库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: '上传文件',
            onPressed: _upload,
          ),
        ],
      ),
      body: ListenableBuilder(
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
          if (_provider.error != null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('加载失败：${_provider.error}'),
              ),
            );
          }
          final books = _provider.books;
          if (books.isEmpty) {
            return const Center(
              child: Text('文库为空，点击右上角上传文件'),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 160,
              childAspectRatio: 0.7,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: books.length,
            itemBuilder: (_, i) {
              final book = books[i];
              return _BookCard(
                book: book,
                cached: _provider.isCached(book),
                onOpen: () => _openBook(context, book),
                onRename: () => _rename(context, book),
                onDelete: () => _delete(context, book),
                onForward: () => _forward(context, book),
              );
            },
          );
        },
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.cached,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    required this.onForward,
  });

  final Book book;
  final bool cached;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: Theme.of(context).colorScheme.primaryContainer,
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
                  if (cached)
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
                IconButton(
                  icon: const Icon(Icons.forward, size: 18),
                  tooltip: '转发到远程库',
                  onPressed: onForward,
                ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: '重命名',
                  onPressed: onRename,
                ),
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
