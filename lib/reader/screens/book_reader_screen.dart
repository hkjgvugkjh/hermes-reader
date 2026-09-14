import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../models/reader_config.dart';
import '../providers/library_provider.dart';
import '../services/file_type_detector.dart';
import '../services/library_cache_index.dart';
import '../services/library_sandbox.dart';
import '../services/library_service.dart';
import '../services/pdf_image_decoder.dart';
import '../services/paginator_service.dart';
import '../services/tts_service.dart';
import '../providers/server_provider.dart';
import '../services/comment_sync_service.dart';
import '../models/reader_annotations.dart';

/// Full-screen reader with pagination and read-aloud controls.
class BookReaderScreen extends StatefulWidget {
  const BookReaderScreen({super.key});

  @override
  State<BookReaderScreen> createState() => _BookReaderScreenState();
}

class _BookReaderScreenState extends State<BookReaderScreen> {
  bool _controlsVisible = true;
  bool _narrating = false;
  String? _fallbackNotice;
  String? _encodingLabel;

  TtsService? _tts;

  /// How far the engine has got into the current page, in characters.
  int _charOffset = 0;

  /// Characters skipped over when resuming, so a saved offset stays absolute.
  int _spokenBase = 0;

  static const FileTypeDetector _detector = FileTypeDetector();

  static const Map<String, String> _encodingChoices = {
    'auto': '自动',
    'utf-8': 'UTF-8',
    'gbk': 'GBK',
  };

  /// Cached key of the last layout pass so we only re-flow pages when the
  /// font/size or available area actually changes.
  String? _layoutKey;

  /// Text the user has highlighted on the current page, pending a note.
  _TextSelection? _pendingSelection;

  /// Comment-sync mode that has already been applied, so we only rebuild the
  /// sync channels when the user actually changes the setting.
  CommentSyncMode? _appliedCommentSyncMode;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tts = context.read<TtsService?>();
    if (tts != _tts) {
      _tts = tts;
      tts?.setProgressHandler(_onNarrationProgress);
    }
    final reader = context.read<ReaderProvider>();
    final mode = reader.config.commentSyncMode;
    if (reader.commentSync == null || _appliedCommentSyncMode != mode) {
      final server = context.read<ServerProvider>();
      final channels = <CommentSync>[];
      if (mode != CommentSyncMode.torrent && server.activeServer != null) {
        try {
          channels.add(ServerCommentSync(server.getClient(server.activeServer!)));
        } catch (_) {
          // Server unreachable — fall back to whatever else is enabled.
        }
      }
      if (mode != CommentSyncMode.server) {
        channels.add(TorrentCommentSync());
      }
      if (channels.isNotEmpty) {
        _appliedCommentSyncMode = mode;
        reader.setCommentSync(
          channels.length == 1 ? channels.first : CompositeCommentSync(channels),
        );
      } else {
        _appliedCommentSyncMode = null;
      }
    }
    _loadEncodingLabel();
  }

  /// Reflects the encoding persisted for the open book in the cache index.
  Future<void> _loadEncodingLabel() async {
    final book = context.read<ReaderProvider>().book;
    if (book == null) return;
    final name =
        const LibrarySandbox().localFileName(book.serverId, book.relativePath);
    final enc = await LibraryCacheIndex().encodingOf(name);
    if (mounted) setState(() => _encodingLabel = enc);
  }

  Future<void> _switchEncoding(BuildContext context) async {
    final reader = context.read<ReaderProvider>();
    final book = reader.book;
    if (book == null) return;
    final current = _encodingLabel ?? 'auto';
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('文本编码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in _encodingChoices.entries)
              ListTile(
                leading: current == e.key ? const Icon(Icons.check) : null,
                title: Text(e.value),
                subtitle: Text(e.key),
                onTap: () => Navigator.pop(ctx, e.key),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    try {
      final content =
          await LibraryService().readCached(book, encoding: chosen);
      if (content == null) {
        _notice('无法重新解码，请返回文库列表切换');
        return;
      }
      await reader.openBook(book, content);
      if (mounted) setState(() => _encodingLabel = chosen);
      _notice('已切换编码：${_encodingChoices[chosen] ?? chosen}');
    } catch (e) {
      _notice('切换编码失败：$e');
    }
  }

  @override
  void dispose() {
    if (_narrating) {
      // Leaving mid-sentence should still remember where we were.
      _saveNarration();
    }
    // Clear this *before* stopping: the narration loop is suspended inside
    // `await speak()` and re-checks `_narrating` when it returns. `mounted` is
    // still true while dispose() runs, so without clearing the flag the loop
    // would advance to the next page and start speaking again after this
    // screen is gone.
    _narrating = false;
    _tts?.setProgressHandler(null);
    _tts?.stop();
    context.read<ReaderProvider>().savePosition();
    super.dispose();
  }

  void _onNarrationProgress(int offset) {
    _charOffset = offset;
  }

  void _toggleControls() =>
      setState(() => _controlsVisible = !_controlsVisible);

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  /// Only formats we can actually extract text from may be read aloud.
  bool _canNarrate(Book? book) {
    if (book == null) return false;
    final type = book.fileType ?? _detector.detect(book.relativePath);
    return _detector.isNarratable(type);
  }

  Future<void> _toggleNarration() async {
    final tts = _tts;
    final reader = context.read<ReaderProvider>();

    if (tts == null) {
      _notice('朗读功能未初始化');
      return;
    }

    if (_narrating) {
      await _stopNarration();
      return;
    }

    final book = reader.book;
    if (book == null) return;
    if (!_canNarrate(book)) {
      _notice('该格式不支持语音朗读，仅可翻阅');
      return;
    }

    // Tell the server TTS engine which backend to forward to (proxy mode).
    tts.setServerId(book.serverId);

    // Resume where the last session stopped, when there is one.
    final saved = await reader.loadNarration(book.id);
    if (saved != null && saved.pageIndex < reader.pageCount) {
      reader.goToPage(saved.pageIndex);
      _spokenBase = saved.charOffset;
    } else {
      _spokenBase = 0;
    }
    _charOffset = 0;

    setState(() => _narrating = true);
    var finished = false;
    try {
      var page = reader.currentPage;
      while (page != null && _narrating && mounted) {
        final from = (_spokenBase > 0 && _spokenBase < page.content.length)
            ? _spokenBase
            : 0;
        _spokenBase = 0;

        final result = await tts.speak(stripImageMarkers(page.content.substring(from)));
        if (!mounted || !_narrating) return;

        if (result.fellBack && _fallbackNotice == null) {
          _notice(
              '服务端朗读不可用，已使用本机语音（${result.fallbackReason}）');
          setState(() => _fallbackNotice = result.fallbackReason);
        }

        if (!reader.config.autoTurnPage || !reader.nextPage()) {
          // Either the user turned auto-advance off, or this was the last page.
          finished = !reader.config.autoTurnPage ? false : true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
        page = reader.currentPage;
      }

      if (finished) {
        await reader.clearNarration();
      } else {
        await _saveNarration();
      }
    } catch (e) {
      if (mounted) _notice('朗读失败：$e');
      await _saveNarration();
    } finally {
      if (mounted) setState(() => _narrating = false);
    }
  }

  Future<void> _stopNarration() async {
    try {
      await _tts?.stop();
    } catch (_) {
      // Stopping an already-stopped engine must not reach the user.
    }
    await _saveNarration();
    if (mounted) setState(() => _narrating = false);
  }

  /// Persists page + in-page offset so narration can resume later.
  Future<void> _saveNarration() async {
    final reader = context.read<ReaderProvider>();
    await reader.saveNarration(
      pageIndex: reader.pageIndex,
      charOffset: _spokenBase + _charOffset,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ReaderProvider>(
      builder: (context, reader, _) {
        final book = reader.book;
        final page = reader.currentPage;
        final narratable = _canNarrate(book);

        return Scaffold(
          floatingActionButton: _pendingSelection == null
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _showNoteEditor(_pendingSelection!),
                  icon: const Icon(Icons.edit_note),
                  label: const Text('批注选区'),
                ),
          appBar: _controlsVisible
              ? AppBar(
                  title: Text(book?.title ?? '阅读'),
                  actions: [
                    PopupMenuButton<double>(
                      icon: const Icon(Icons.text_fields),
                      tooltip: '字号',
                      onSelected: (scale) {
                        reader.updateConfig(
                            reader.config.copyWith(fontScale: scale));
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 0.85, child: Text('小')),
                        PopupMenuItem(value: 1.0, child: Text('标准')),
                        PopupMenuItem(value: 1.2, child: Text('大')),
                        PopupMenuItem(value: 1.5, child: Text('特大')),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.translate),
                      tooltip: _encodingLabel != null && _encodingLabel != 'auto'
                          ? '文本编码：${_encodingLabel!.toUpperCase()}'
                          : '文本编码',
                      onPressed: () => _switchEncoding(context),
                    ),
                    IconButton(
                      icon: const Icon(Icons.tune),
                      tooltip: '阅读设置',
                      onPressed: () => _showSettings(context, reader),
                    ),
                    IconButton(
                      icon: Icon(
                        reader.isBookmarkedAtCurrentPage
                            ? Icons.bookmark
                            : Icons.bookmark_border,
                        color: reader.isBookmarkedAtCurrentPage
                            ? Colors.amber
                            : null,
                      ),
                      tooltip: '书签',
                      onPressed: () async {
                        await reader.toggleBookmark();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(reader.isBookmarkedAtCurrentPage
                                  ? '已添加书签'
                                  : '已移除书签'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.comment_outlined),
                      tooltip: '书评',
                      onPressed: () => _showComments(),
                    ),
                  ],
                )
              : null,
          body: page == null
              ? const Center(child: Text('没有可显示的内容'))
              : Column(
                  children: [
                    if (_fallbackNotice != null && _controlsVisible)
                      _FallbackBanner(reason: _fallbackNotice!),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // Re-flow pages to the real screen using exact font
                          // metrics, so each page fits without scrolling.
                          final content = reader.content;
                          if (content != null && constraints.maxHeight > 0) {
                            final fontScale = reader.config.fontScale;
                            final style = TextStyle(
                              fontSize: 17 * fontScale,
                              height: 1.7 * fontScale.clamp(1.0, 1.3),
                            );
                            final key =
                                '${content.text.length}:$fontScale:'
                                '${constraints.maxWidth.toInt()}:'
                                '${constraints.maxHeight.toInt()}';
                            if (key != _layoutKey) {
                              _layoutKey = key;
                              final pages = PaginatorService()
                                  .paginateWithLayout(
                                content.text,
                                style: style,
                                maxWidth: constraints.maxWidth - 40,
                                maxHeight: constraints.maxHeight - 32,
                                breakOffsets: content.pageBreaks,
                              );
                              // Apply after this frame to avoid notify-during-build.
                              WidgetsBinding.instance
                                  .addPostFrameCallback((_) => reader.setPages(pages));
                            }
                          }
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (details) {
                              final renderBox =
                                  context.findRenderObject() as RenderBox;
                              final localPos = renderBox
                                  .globalToLocal(details.globalPosition);
                              final fraction = renderBox.size.width > 0
                                  ? localPos.dx / renderBox.size.width
                                  : 0.5;

                              if (reader.isToggleZone(fraction)) {
                                _toggleControls();
                              } else {
                                reader.handleTap(fraction);
                              }
                            },
                            onHorizontalDragEnd: (details) {
                              final dx = details.primaryVelocity ?? 0;
                              if (dx < -300) {
                                reader.nextPage();
                              } else if (dx > 300) {
                                reader.previousPage();
                              }
                            },
                            child: SafeArea(
                              child: _buildPageBody(context, reader,
                                  onSelection: _onPageSelection),
                            ),
                          );
                        },
                      ),
                    ),
                    if (_controlsVisible)
                      _ReaderFooter(
                        pageIndex: reader.pageIndex,
                        pageCount: reader.pageCount,
                        progress: reader.progress,
                        narrating: _narrating,
                        canNarrate: narratable,
                        onPrev: reader.previousPage,
                        onNext: reader.nextPage,
                        onNarrate: _toggleNarration,
                        onJump: () => _showJump(reader),
                        chapterTitle: reader.hasChapters
                            ? (reader.currentChapterIndex >= 0
                                ? reader.chapters[reader.currentChapterIndex].title
                                : null)
                            : null,
                      ),
                  ],
                ),
        );
      },
    );
  }

  /// Tap-zone layout, direction and auto-advance.
  void _showSettings(BuildContext context, ReaderProvider reader) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final config = context.watch<ReaderProvider>().config;

            void apply(ReaderConfig next) {
              reader.updateConfig(next);
              setSheetState(() {});
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('阅读设置',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text('点击分区',
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                            fontWeight: FontWeight.bold)),
                    ...TapZoneMode.values.map(
                      (mode) => RadioListTile<TapZoneMode>(
                        title: Text(mode.label),
                        value: mode,
                        groupValue: config.tapZoneMode,
                        onChanged: (value) {
                          if (value == null) return;
                          apply(config.copyWith(tapZoneMode: value));
                        },
                      ),
                    ),
                    SwitchListTile(
                      title: const Text('左侧区域向后翻页'),
                      subtitle: const Text('开启后左右方向对调'),
                      value: config.leftZoneForward,
                      onChanged: (value) =>
                          apply(config.copyWith(leftZoneForward: value)),
                    ),
                    SwitchListTile(
                      title: const Text('朗读自动翻页'),
                      value: config.autoTurnPage,
                      onChanged: (value) =>
                          apply(config.copyWith(autoTurnPage: value)),
                    ),
                    const SizedBox(height: 8),
                    const Text('共享评论通道',
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                            fontWeight: FontWeight.bold)),
                    ...CommentSyncMode.values.map(
                      (mode) => RadioListTile<CommentSyncMode>(
                        title: Text(mode.label),
                        value: mode,
                        groupValue: config.commentSyncMode,
                        onChanged: (value) {
                          if (value == null) return;
                          apply(config.copyWith(commentSyncMode: value));
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('每页字数：${config.charsPerPage}',
                        style: const TextStyle(fontSize: 12)),
                    Slider(
                      value: config.charsPerPage.toDouble(),
                      min: 300,
                      max: 2000,
                      divisions: 17,
                      label: '${config.charsPerPage}',
                      onChanged: (value) => apply(
                        config.copyWith(
                            charsPerPage: (value ~/ 50) * 50),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Opens the jump UI: the chapter table of contents when one was detected,
  /// otherwise a plain page-number jump.
  void _showJump(ReaderProvider reader) {
    if (reader.hasChapters) {
      _showChapterList(reader);
    } else {
      _showPageJump(reader);
    }
  }

  /// Shows the detected table of contents as a bottom sheet; tapping an entry
  /// jumps to that chapter's first page.
  void _showChapterList(ReaderProvider reader) {
    final current = reader.currentChapterIndex;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('目录',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: reader.chapters.length,
                itemBuilder: (_, i) {
                  final ch = reader.chapters[i];
                  final active = i == current;
                  return ListTile(
                    dense: true,
                    title: Text(
                      ch.title,
                      style: TextStyle(
                        fontWeight: active ? FontWeight.bold : FontWeight.normal,
                        color: active
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    ),
                    trailing: active
                        ? Icon(Icons.bookmark,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () {
                      reader.goToChapter(i);
                      Navigator.pop(ctx);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shows a page-number jump dialog with a slider and a numeric field.
  void _showPageJump(ReaderProvider reader) {
    var target = reader.pageIndex + 1;
    final controller = TextEditingController(text: '$target');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳页'),
        content: StatefulBuilder(
          builder: (_, setS) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Slider(
                value: target.toDouble(),
                min: 1,
                max: reader.pageCount.toDouble(),
                divisions: reader.pageCount > 1 ? reader.pageCount - 1 : 1,
                label: '$target',
                onChanged: (v) {
                  target = v.toInt();
                  controller.text = '$target';
                  setS(() {});
                },
              ),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: '输入页码 1-${reader.pageCount}',
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null) target = n.clamp(1, reader.pageCount);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              reader.goToPage(target - 1);
              Navigator.pop(ctx);
            },
            child: const Text('跳转'),
          ),
        ],
      ),
    );
  }

  void _onPageSelection(int start, int end, String text) {
    setState(() {
      _pendingSelection =
          (text.isEmpty || end <= start) ? null : _TextSelection(start, end, text);
    });
  }

  void _showNoteEditor(_TextSelection sel) {
    final reader = context.read<ReaderProvider>();
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
          left: 16,
          right: 16,
          top: 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('选中文本', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.yellow.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(sel.text, maxLines: 4, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: '笔记 / 评论', border: OutlineInputBorder()),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    await reader.saveNote(
                      startOffset: sel.start,
                      endOffset: sel.end,
                      quotedText: sel.text,
                      comment: controller.text.trim().isEmpty
                          ? null
                          : controller.text.trim(),
                    );
                    if (mounted) Navigator.pop(ctx);
                    setState(() => _pendingSelection = null);
                  },
                  child: const Text('保存笔记'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showComments() {
    final reader = context.read<ReaderProvider>();
    final page = reader.currentPage;
    final pageStart = page?.startOffset ?? 0;
    final pageEnd = pageStart + (page?.content.length ?? 0);
    final notesHere = reader.notesOnCurrentPage(pageStart, pageEnd);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        minChildSize: 0.4,
        expand: false,
        builder: (c, scroll) => _CommentsSheet(
          reader: reader,
          notesHere: notesHere,
          onPublish: (note) async {
            final ok = await reader.publishComment(note);
            if (mounted && !ok && ctx.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('发布失败：未连接到共享服务器')),
              );
            }
          },
          onRemoveNote: (id) => reader.removeNote(id),
        ),
      ),
    );
  }
}

class _FallbackBanner extends StatelessWidget {
  const _FallbackBanner({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.amber.withValues(alpha: 0.18),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16, color: Colors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '已降级为本机语音（$reason）',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

}

  /// Renders the current page's text with any inline images interleaved. The
  /// body scrolls so a picture taller than the screen stays reachable.
  Widget _buildPageBody(
    BuildContext context,
    ReaderProvider reader, {
    void Function(int start, int end, String text)? onSelection,
  }) {
    final page = reader.currentPage;
    if (page == null) return const SizedBox.shrink();

    final images = reader.images;
    final fontScale = reader.config.fontScale;
    final style = TextStyle(
      fontSize: 17 * fontScale,
      height: reader.config.lineHeightFactor,
    );
    final maxWidth = MediaQuery.of(context).size.width - 40;

    final content = page.content;
    final widgets = <Widget>[];
    var last = 0;
    for (final m in imageMarkerRegex.allMatches(content)) {
      final text = content.substring(last, m.start);
      if (text.isNotEmpty) {
        final base = last;
        widgets.add(
          SelectableText(
            text,
            style: style,
            textAlign: TextAlign.justify,
            onSelectionChanged: onSelection == null
                ? null
                : (sel, _) {
                    if (!sel.isValid || sel.isCollapsed) {
                      onSelection(page.startOffset + base, page.startOffset + base, '');
                      return;
                    }
                    onSelection(
                      page.startOffset + base + sel.start,
                      page.startOffset + base + sel.end,
                      text.substring(sel.start, sel.end),
                    );
                  },
          ),
        );
      }
      final index = int.tryParse(m.group(1)!);
      final img = index != null && index < images.length ? images[index] : null;
      if (img != null) widgets.add(_buildImage(img, maxWidth));
      last = m.end;
    }
    final tail = content.substring(last);
    if (tail.isNotEmpty) {
      final base = last;
      widgets.add(
        SelectableText(
          tail,
          style: style,
          textAlign: TextAlign.justify,
          onSelectionChanged: onSelection == null
              ? null
              : (sel, _) {
                  if (!sel.isValid || sel.isCollapsed) {
                    onSelection(page.startOffset + base, page.startOffset + base, '');
                    return;
                  }
                  onSelection(
                    page.startOffset + base + sel.start,
                    page.startOffset + base + sel.end,
                    tail.substring(sel.start, sel.end),
                  );
                },
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: widgets,
      ),
    );
  }

  Widget _buildImage(PdfImage img, double maxWidth) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: 520,
          ),
          child: Image.memory(
            img.bytes,
            fit: BoxFit.contain,
            cacheWidth: 1200,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

class _ReaderFooter extends StatelessWidget {
  const _ReaderFooter({
    required this.pageIndex,
    required this.pageCount,
    required this.progress,
    required this.narrating,
    required this.canNarrate,
    required this.onPrev,
    required this.onNext,
    required this.onNarrate,
    required this.onJump,
    this.chapterTitle,
  });

  final int pageIndex;
  final int pageCount;
  final double progress;
  final bool narrating;
  final bool canNarrate;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final Future<void> Function() onNarrate;
  final VoidCallback onJump;
  final String? chapterTitle;

  @override
  Widget build(BuildContext context) {
    final footerStyle = const TextStyle(fontSize: 13);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (chapterTitle != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Text(
              chapterTitle!,
              style: footerStyle.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        Tooltip(
          message: chapterTitle != null ? '目录 / 跳章' : '跳页',
          child: GestureDetector(
            onTap: onJump,
            behavior: HitTestBehavior.opaque,
            child: LinearProgressIndicator(
              value: pageCount > 1 ? progress : 1.0,
              minHeight: 6,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              InkWell(
                onTap: onJump,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        chapterTitle != null ? Icons.menu_book : Icons.explore,
                        size: 15,
                        color: footerStyle.color,
                      ),
                      const SizedBox(width: 4),
                      Text('${pageIndex + 1} / $pageCount',
                          style: footerStyle),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: '上一页',
                onPressed: onPrev,
              ),
              IconButton(
                icon: Icon(narrating
                    ? Icons.stop_circle_outlined
                    : Icons.record_voice_over),
                tooltip: !canNarrate
                    ? '该格式不支持朗读'
                    : narrating
                        ? '停止朗读'
                        : '朗读',
                // Resuming from a saved offset is handled inside onNarrate.
                onPressed: canNarrate ? () => onNarrate() : null,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: '下一页',
                onPressed: onNext,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TextSelection {
  final int start;
  final int end;
  final String text;
  const _TextSelection(this.start, this.end, this.text);
}

class _CommentsSheet extends StatelessWidget {
  final ReaderProvider reader;
  final List<Note> notesHere;
  final Future<void> Function(Note) onPublish;
  final void Function(String) onRemoveNote;

  const _CommentsSheet({
    required this.reader,
    required this.notesHere,
    required this.onPublish,
    required this.onRemoveNote,
  });

  @override
  Widget build(BuildContext context) {
    final comments = reader.sharedComments;
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: '本页笔记'),
              Tab(text: '共享书评'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final n in notesHere)
                      _NoteTile(
                        note: n,
                        onRemove: () => onRemoveNote(n.id),
                        onPublish: () => onPublish(n),
                        canPublish: reader.commentSync != null,
                      ),
                    if (notesHere.isEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('本页还没有笔记，选中正文后点“批注选区”即可添加。'),
                        ),
                      ),
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final c in comments) _CommentTile(comment: c),
                    if (comments.isEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('还没有共享书评。连接服务器后，其他人发布的评论会显示在这里。'),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteTile extends StatelessWidget {
  final Note note;
  final VoidCallback onRemove;
  final VoidCallback onPublish;
  final bool canPublish;

  const _NoteTile({
    required this.note,
    required this.onRemove,
    required this.onPublish,
    required this.canPublish,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.yellow.withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(note.quotedText,
                  maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
            if (note.comment != null && note.comment!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(note.comment!),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('删除'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: canPublish ? onPublish : null,
                  child: const Text('发布到共享'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  final SharedComment comment;
  const _CommentTile({required this.comment});

  @override
  Widget build(BuildContext context) {
    final t = comment.createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(comment.createdAt)
            .toLocal()
            .toString()
            .substring(0, 16)
        : '';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (comment.quotedText.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(comment.quotedText,
                    maxLines: 3, overflow: TextOverflow.ellipsis),
              ),
            if (comment.comment.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(comment.comment),
            ],
            const SizedBox(height: 6),
            Text(
              '${comment.deviceId}${t.isNotEmpty ? ' · $t' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
