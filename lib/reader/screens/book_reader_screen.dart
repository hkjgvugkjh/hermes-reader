import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../models/reader_config.dart';
import '../providers/library_provider.dart';
import '../services/file_type_detector.dart';
import '../services/library_cache_index.dart';
import '../services/library_sandbox.dart';
import '../services/library_service.dart';
import '../services/pdf_image_decoder.dart';
import '../services/text_break_utils.dart';
import '../services/tts_service.dart';
import '../providers/server_provider.dart';
import '../services/comment_sync_service.dart';
import '../models/reader_annotations.dart';

/// 单段文字划选结果的回调：起始/结束字符偏移与选中文本。
typedef _SelectionCallback = void Function(int start, int end, String text);

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

  /// Full-screen reading mode (no app bar, no footer, just text).
  bool _isFullscreen = false;

  /// Annotation mode: when true, text selection is enabled and tapping does
  /// not navigate pages.
  bool _annotationMode = false;

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

  /// Text the user has highlighted on the current page, pending a note.
  _TextSelection? _pendingSelection;

  /// Comment-sync mode that has already been applied, so we only rebuild the
  /// sync channels when the user actually changes the setting.
  CommentSyncMode? _appliedCommentSyncMode;

  /// Bridge to the native layer that forwards hardware volume-key presses so
  /// they can be used for page navigation while this screen is active.
  static const MethodChannel _volumeChannel = MethodChannel('hermes/volume');
  bool _volumeHandlerRegistered = false;

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
          channels.add(
            ServerCommentSync(server.getClient(server.activeServer!)),
          );
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
          channels.length == 1
              ? channels.first
              : CompositeCommentSync(channels),
        );
      } else {
        _appliedCommentSyncMode = null;
      }
    }
    _loadEncodingLabel();
    _registerVolumeKeys();
  }

  /// Forward hardware volume keys as page navigation. Only active while this
  /// screen is mounted, so other screens keep normal volume behaviour.
  void _registerVolumeKeys() {
    if (_volumeHandlerRegistered) return;
    _volumeHandlerRegistered = true;
    _volumeChannel.setMethodCallHandler((call) async {
      if (call.method == 'volumeKey') {
        final direction = call.arguments as String?;
        final reader = context.read<ReaderProvider>();
        if (direction == 'up') {
          reader.nextPage();
        } else if (direction == 'down') {
          reader.previousPage();
        }
      }
      return null;
    });
    _volumeChannel.invokeMethod<void>('setEnabled', {'enabled': true});
  }

  void _unregisterVolumeKeys() {
    if (!_volumeHandlerRegistered) return;
    _volumeHandlerRegistered = false;
    _volumeChannel.invokeMethod<void>('setEnabled', {'enabled': false});
    _volumeChannel.setMethodCallHandler(null);
  }

  /// Reflects the encoding persisted for the open book in the cache index.
  Future<void> _loadEncodingLabel() async {
    final book = context.read<ReaderProvider>().book;
    if (book == null) return;
    final name = const LibrarySandbox().localFileName(
      book.serverId,
      book.relativePath,
    );
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
      final content = await LibraryService().readCached(book, encoding: chosen);
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
    _unregisterVolumeKeys();
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

    // Resume where the last session stopped, when there is one. When the saved
    // point is on a *different* page, ask whether to continue there or read the
    // current page instead. The engine is warmed up in the background while the
    // dialog is open so playback starts without the usual model-load latency.
    final saved = await reader.loadNarration(book.id);
    if (saved != null &&
        saved.pageIndex < reader.pageCount &&
        saved.pageIndex != reader.pageIndex) {
      tts.warmUp();
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('继续朗读？'),
          content: Text(
            '上次停在「第 ${saved.pageIndex + 1} 页」。'
            '要从此处继续，还是从当前页开始？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('thispage'),
              child: const Text('朗读本页'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop('continue'),
              child: const Text('继续朗读'),
            ),
          ],
        ),
      );
      if (choice == null) return; // 取消，不开始朗读
      if (choice == 'continue') {
        reader.goToPage(saved.pageIndex);
        _spokenBase = saved.charOffset;
      } else {
        _spokenBase = 0;
      }
    } else if (saved != null && saved.pageIndex < reader.pageCount) {
      // 历史点恰在当前页：直接续读本页偏移。
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

        final result = await tts.speak(
          stripImageMarkers(page.content.substring(from)),
        );
        if (!mounted || !_narrating) return;

        if (result.fellBack && _fallbackNotice == null) {
          _notice('服务端朗读不可用，已使用本机语音（${result.fallbackReason}）');
          setState(() => _fallbackNotice = result.fallbackReason);
        }

        if (!reader.config.autoTurnPage || !reader.nextPage()) {
          // Either the user turned auto-advance off, or this was the last page.
          finished = !reader.config.autoTurnPage ? false : true;
          break;
        }
        // 翻到新页后立即更新播放点，保证中途退出也能从该页续读。
        await _saveNarration();
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
        final content = reader.content;
        final narratable = _canNarrate(book);

        return Scaffold(
          floatingActionButton: _pendingSelection == null
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _showNoteEditor(_pendingSelection!),
                  icon: const Icon(Icons.edit_note),
                  label: const Text('批注选区'),
                ),
          appBar: (_controlsVisible && !_isFullscreen)
              ? AppBar(
                  title: Text(book?.title ?? '阅读'),
                  actions: [
                    PopupMenuButton<double>(
                      icon: const Icon(Icons.text_fields),
                      tooltip: '字号',
                      onSelected: (scale) {
                        reader.updateConfig(
                          reader.config.copyWith(fontScale: scale),
                        );
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
                      tooltip:
                          _encodingLabel != null && _encodingLabel != 'auto'
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
                              content: Text(
                                reader.isBookmarkedAtCurrentPage
                                    ? '已添加书签'
                                    : '已移除书签',
                              ),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        }
                      },
                    ),
                    IconButton(
                      icon: Icon(
                        _annotationMode ? Icons.edit : Icons.edit_outlined,
                      ),
                      tooltip: _annotationMode ? '退出批注' : '批注模式',
                      onPressed: () =>
                          setState(() => _annotationMode = !_annotationMode),
                    ),
                    IconButton(
                      icon: const Icon(Icons.comment_outlined),
                      tooltip: '书评',
                      onPressed: () => _showComments(),
                    ),
                  ],
                )
              : null,
          // NOTE: gate on *content*, not on the current page. Pagination is
          // kicked off by the LayoutBuilder below (syncViewportChars), so if we
          // hid it while `page == null` (which is exactly the state before the
          // first pagination finishes) the LayoutBuilder would never build, no
          // pages would ever be computed, and the reader would be stuck on
          // "没有可显示的内容" forever.
          body: content == null || content.text.trim().isEmpty
              ? const Center(child: Text('没有可显示的内容'))
              : Column(
                  children: [
                    if (_fallbackNotice != null &&
                        _controlsVisible &&
                        !_isFullscreen)
                      _FallbackBanner(reason: _fallbackNotice!),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // Compute max heights for pagination (available text area).
                          // These are used both for pagination and for constraining
                          // the rendered content to prevent scrolling.
                          //
                          // The body sits inside a SafeArea (see the builder's
                          // return value), so the SafeArea insets must come out of
                          // the fixed-height page box — otherwise the box is
                          // clamped shorter than the paginated height and the
                          // page Column overflows by the missing pixels.
                          final insets = MediaQuery.of(context).padding;
                          // 显示区域实际可用尺寸（body 已被 Scaffold 去掉 appBar/footer，
                          // 这里再减去系统安全区）。渲染盒子的总高/宽就是这两个值。
                          final availH =
                              constraints.maxHeight -
                              insets.top -
                              insets.bottom;
                          final availW = constraints.maxWidth;
                          if (constraints.maxHeight > 0) {
                            // Exact, measurement-based pagination: the screen
                            // hands the real text area to the paginator, which
                            // fills every page to the pixel (no third-of-a-page
                            // gap, no overflow). Debounced inside the provider.
                            final fontSize =
                                ReaderConfig.baseFontSize * reader.config.fontScale;
                            // 一行高度：同时作为渲染与测量的四边留白，二者必须一致；
                            // 亚像素级别的微小差异由 ClipRect 兜底裁切，不再额外预留 safety。
                            final lineH =
                                fontSize * reader.config.lineHeightFactor;
                            final margin = lineH; // 上下左右各空一行
                            // 渲染文字盒必须与分页测量的盒子逐一对齐：SafeArea 扣掉
                            // 左右安全区（insets.left/right），_wrapPagedColumn 的
                            // Padding 扣掉四边各 margin。不再额外减 safety，让每页文字
                            // 按真实容量填满、没有人为限制的空白；ClipRect 仅作亚像素
                            // 级别的兜底裁切。
                            final maxW =
                                availW - insets.left - insets.right - margin * 2;
                            final maxH = availH - margin * 2;
                            // TextStyle.height is a *multiplier* of fontSize, not
                            // an absolute pixel line height — it must match what
                            // [_buildPageBody] renders with, otherwise the
                            // measured page capacity is off and pages come out
                            // nearly empty.
                            // Hand the paginator a box one half-line smaller than
                            // the real render box, so even sub-pixel differences
                            // between TextPainter measurement and on-screen Text
                            // (and the trailing-newline blank line) never overflow.
                            // The render box keeps the full maxH; this is the
                            // "safety buffer" referenced in [_wrapPagedColumn].
                            reader.syncViewportChars(
                              style: TextStyle(
                                fontSize: fontSize,
                                height: reader.config.lineHeightFactor,
                              ),
                              maxWidth: maxW,
                              maxHeight: maxH - margin * 0.5,
                              fullscreen: _isFullscreen,
                            );
                          }
                          // Show spinner while pages are being computed.
                          if (reader.isPaginating || reader.pages.isEmpty) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (details) {
                              // In annotation mode, let SelectableText handle taps.
                              if (_annotationMode) return;

                              final renderBox =
                                  context.findRenderObject() as RenderBox;
                              final localPos = renderBox.globalToLocal(
                                details.globalPosition,
                              );
                              final fraction = renderBox.size.width > 0
                                  ? localPos.dx / renderBox.size.width
                                  : 0.5;

                              // In fullscreen mode: left/right zones navigate,
                              // center tap returns to non-fullscreen.
                              if (_isFullscreen) {
                                if (reader.config.tapZoneMode ==
                                        TapZoneMode.thirds &&
                                    reader.isToggleZone(fraction)) {
                                  setState(() => _isFullscreen = false);
                                } else {
                                  reader.handleTap(fraction);
                                }
                                return;
                              }

                              // In three-zone mode, center tap toggles fullscreen.
                              if (reader.config.tapZoneMode ==
                                      TapZoneMode.thirds &&
                                  reader.isToggleZone(fraction)) {
                                setState(() => _isFullscreen = true);
                                return;
                              }

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
                              child: _buildPageBody(
                                context,
                                reader,
                                onSelection: _onPageSelection,
                                contentMaxHeight: availH,
                                contentMaxWidth: availW,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (_controlsVisible && !_isFullscreen)
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
                                  ? reader
                                        .chapters[reader.currentChapterIndex]
                                        .title
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
              // Reflect the new engine choice on the live service immediately.
              context.read<TtsService?>()?.setMode(next.ttsMode);
              setSheetState(() {});
            }

            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '阅读设置',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '点击分区',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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
                    SwitchListTile(
                      title: const Text('[调试] 全角空格→口'),
                      subtitle: const Text('将 U+3000 替换为"口"以排查显示问题'),
                      value: config.debugReplaceFullwidthSpace,
                      onChanged: (value) => apply(
                          config.copyWith(debugReplaceFullwidthSpace: value)),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '共享评论通道',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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
                    const Text(
                      '朗读引擎',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    ...TtsMode.values.map(
                      (mode) => RadioListTile<TtsMode>(
                        title: Text(mode.label),
                        value: mode,
                        groupValue: config.ttsMode,
                        onChanged: (value) {
                          if (value == null) return;
                          apply(config.copyWith(ttsMode: value));
                        },
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
    final scrollController = ScrollController();
    // Fixed item extent so scroll math is exact: a free-form ListTile's real
    // height depends on font/theme and never matches a hand-picked constant,
    // which previously overshot (e.g. chapter 39 ended up below the fold with
    // chapter 45 on the first row).
    const itemExtent = 56.0;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        // Centre the current chapter in the visible area after the sheet is
        // laid out, so the active heading sits in the middle of the list
        // (clamped to the top/bottom near the ends).
        if (current >= 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!scrollController.hasClients) return;
            final pos = scrollController.position;
            final viewport = pos.viewportDimension;
            final target =
                (current * itemExtent + itemExtent / 2 - viewport / 2).clamp(
                  0.0,
                  pos.maxScrollExtent,
                );
            scrollController.jumpTo(target);
          });
        }
        return SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '选择章节',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemExtent: itemExtent,
                  itemCount: reader.chapters.length,
                  itemBuilder: (_, i) {
                    final ch = reader.chapters[i];
                    final active = i == current;
                    return ListTile(
                      dense: true,
                      title: Text(
                        ch.title,
                        style: TextStyle(
                          fontWeight: active
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: active
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      ),
                      trailing: active
                          ? Icon(
                              Icons.bookmark,
                              size: 16,
                              color: Theme.of(context).colorScheme.primary,
                            )
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
        );
      },
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
      _pendingSelection = (text.isEmpty || end <= start)
          ? null
          : _TextSelection(start, end, text);
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
              child: Text(
                sel.text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: '笔记 / 评论',
                border: OutlineInputBorder(),
              ),
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
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('发布失败：未连接到共享服务器')));
            }
          },
          onRemoveNote: (id) => reader.removeNote(id),
        ),
      ),
    );
  }

  Widget _buildPageBody(BuildContext context, ReaderProvider reader, {_SelectionCallback? onSelection, double? contentMaxHeight, double? contentMaxWidth}) {
    final page = reader.currentPage;
    if (page == null) return const SizedBox.shrink();

    final fontScale = reader.config.fontScale;
    final style = TextStyle(fontSize: ReaderConfig.baseFontSize * fontScale, height: reader.config.lineHeightFactor);
    // 渲染文字盒子的宽度：用 body 实际宽度（contentMaxWidth），不要用
    // MediaQuery.size.width（在带安全区/刘海的机型上会偏宽，导致渲染比测量宽、
    // 行数更多、从而溢出）。仅用于图片尺寸估算，文字宽度由外层 Padding 决定。
    final fontSize = style.fontSize ?? ReaderConfig.baseFontSize;
    final maxWidth = (contentMaxWidth ?? MediaQuery.of(context).size.width) - fontSize * 2;

    // 格式分派：只有 PDF 抽取时会在文本流里写入 \u0000IMG<n>\u0000 内联图标记，
    // 此时 reader.images 非空，需要图文交错渲染；其余格式（txt/epub/mobi/
    // html/json/unknown 等）都是纯文字，整段直接渲染即可。
    final widgets = reader.images.isEmpty
        ? _buildPlainTextPage(page.content, style, page, onSelection)
        : _buildPdfPage(page.content, style, reader.images, maxWidth, page, onSelection);

    return _wrapPagedColumn(widgets, style, contentMaxHeight);
  }

  /// 纯文字格式（txt/epub/mobi/html/json/unknown 等）：整页作为一段渲染。
  List<Widget> _buildPlainTextPage(String content, TextStyle style, BookPage page, _SelectionCallback? onSelection) => [_buildTextSegment(content, style, 0, page, onSelection)];

  /// PDF 页面：文本流里嵌有 `\u0000IMG<n>\u0000` 内联图标记，需把文字段与图片按
  /// 阅读顺序交错插入。
  List<Widget> _buildPdfPage(String content, TextStyle style, List<PdfImage> images, double maxWidth, BookPage page, _SelectionCallback? onSelection) {
    final widgets = <Widget>[];
    var last = 0;
    for (final m in imageMarkerRegex.allMatches(content)) {
      final text = content.substring(last, m.start);
      if (text.isNotEmpty) {
        widgets.add(_buildTextSegment(text, style, last, page, onSelection));
      }
      final index = int.tryParse(m.group(1)!);
      final img = index != null && index < images.length ? images[index] : null;
      if (img != null) widgets.add(_buildImage(img, maxWidth));
      last = m.end;
    }
    final tail = content.substring(last);
    if (tail.isNotEmpty) {
      widgets.add(_buildTextSegment(tail, style, last, page, onSelection));
    }
    return widgets;
  }

  // 与分页器测量用的 TextHeightBehavior 完全一致，保证“测量高度 == 渲染高度”，
  // 否则两端首尾行 ascent/descent 处理不同会让页面底部出现空白或溢出。
  static const TextHeightBehavior _kPageTextHeightBehavior = TextHeightBehavior(
    applyHeightToFirstAscent: true,
    applyHeightToLastDescent: true,
  );

  /// 渲染一段文字。批注模式下用 [SelectableText] 以支持划选高亮，否则用普通
  /// [Text]。
  ///
  /// 段首连续 U+3000（全角空格）在 `TextAlign.justify` 下会被折叠为零宽，
  /// 导致中文段首缩进消失。这里将段首 U+3000 替换为等宽 [WidgetSpan]，
  /// 使缩进作为内联 widget 渲染，不被 justify 折叠。
  Widget _buildTextSegment(String text, TextStyle style, int baseOffset, BookPage page, _SelectionCallback? onSelection) {
    // 临时调试开关：将全角空格 U+3000 替换为"口"以排查显示问题
    final config = context.read<ReaderProvider>().config;
    if (config.debugReplaceFullwidthSpace) {
      text = text.replaceAll('\u3000', '口');
    }

    // 检测段首连续 U+3000
    final indentMatch = RegExp(r'^(\u3000+)').firstMatch(text);
    final indentCount = indentMatch?.group(1)?.length ?? 0;
    final fontSize = style.fontSize ?? ReaderConfig.baseFontSize;

    // Pin textScaleFactor to 1.0 so the on-screen Text matches the paginator's
    // TextPainter measurement (which always uses 1.0). The app controls font
    // size via reader.config.fontSize, so letting the system font scaler apply
    // on top would make rendered text taller than measured and overflow pages.
    if (_annotationMode) {
      if (indentCount > 0) {
        final indentWidth = fontSize * indentCount;
        final textAfterIndent = text.substring(indentCount);
        return SelectableText.rich(
          TextSpan(
            children: [
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: SizedBox(width: indentWidth),
              ),
              TextSpan(text: textAfterIndent, style: style),
            ],
          ),
          textAlign: TextAlign.justify,
          textHeightBehavior: _kPageTextHeightBehavior,
          textScaler: TextScaler.linear(1.0),
          onSelectionChanged: onSelection == null
              ? null
              : (sel, _) => _reportSegmentSelection(
                    sel,
                    textAfterIndent,
                    baseOffset + indentCount,
                    page,
                    onSelection,
                  ),
        );
      }
      return SelectableText(
        text,
        style: style,
        textAlign: TextAlign.justify,
        textHeightBehavior: _kPageTextHeightBehavior,
        textScaler: TextScaler.linear(1.0),
        // onSelectionChanged 签名固定且需捕获本段局部状态，这里只做一行转发，
        // 真正的换算逻辑见 [_reportSegmentSelection]。
        onSelectionChanged: onSelection == null ? null : (sel, _) => _reportSegmentSelection(sel, text, baseOffset, page, onSelection),
      );
    }

    if (indentCount > 0) {
      final indentWidth = fontSize * indentCount;
      final textAfterIndent = text.substring(indentCount);
      return RichText(
        text: TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: SizedBox(width: indentWidth),
            ),
            TextSpan(text: textAfterIndent, style: style),
          ],
        ),
        textAlign: TextAlign.justify,
        textHeightBehavior: _kPageTextHeightBehavior,
        textScaler: TextScaler.linear(1.0),
      );
    }

    return Text(text, style: style, textAlign: TextAlign.justify, textHeightBehavior: _kPageTextHeightBehavior, textScaler: TextScaler.linear(1.0));
  }

  /// 把单段文字上的划选结果换算成全书字符区间并上报给 [onSelection]。
  ///
  /// [baseOffset] 是该段文字在整页 `content` 中的起始下标；[page.startOffset]
  /// 是整页在全书文本中的起始下标。空选（无效或已折叠）上报一个空区间。
  void _reportSegmentSelection(TextSelection sel, String text, int baseOffset, BookPage page, _SelectionCallback? onSelection) {
    if (!sel.isValid || sel.isCollapsed) {
      onSelection?.call(page.startOffset + baseOffset, page.startOffset + baseOffset, '');
      return;
    }
    onSelection?.call(page.startOffset + baseOffset + sel.start, page.startOffset + baseOffset + sel.end,
        // 渲染文本中的行首缩进占位 U+3164 还原成原字符 U+3000，保证上报的
        // 选中文本与书籍原文一致。
        text.substring(sel.start, sel.end).replaceAll('\u3164', '\u3000'));
  }

  /// 用定高、裁切的 Column 包裹整页 widget。
  ///
  /// 用固定高度 Column（而非 SingleChildScrollView）来禁止滚动：分页算法已保证
  /// 内容能放进 [contentMaxHeight]。外层 SizedBox 固定为 contentMaxHeight，内层
  /// Padding 四边各留一行（margin = 一行高度），文字盒子 = contentMaxHeight
  /// - 2*margin。分页器测量的盒子比这再小一个 safety 缓冲，所以即便渲染比
  /// 测量高几像素也绝不会溢出 Column。ClipRect 作为最终兜底裁掉任何溢出。
  Widget _wrapPagedColumn(List<Widget> widgets, TextStyle style, double? contentMaxHeight) {
    final column = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widgets);

    if (contentMaxHeight != null) {
      // 一行高度：与 LayoutBuilder 里传给分页器的 margin 完全一致。
      final margin = (style.fontSize ?? ReaderConfig.baseFontSize) * (style.height ?? 1.0);
      return SizedBox(height: contentMaxHeight, child: ClipRect(child: Padding(padding: EdgeInsets.all(margin), child: column)));
    }

    // Fallback when no valid max height is available (page null or constraints
    // not yet measured). Just return the column without constraint.
    return column;
  }

  Widget _buildImage(PdfImage img, double maxWidth) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: 520),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        chapterTitle != null ? Icons.menu_book : Icons.explore,
                        size: 15,
                        color: footerStyle.color,
                      ),
                      const SizedBox(width: 4),
                      Text('${pageIndex + 1} / $pageCount', style: footerStyle),
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
                icon: Icon(
                  narrating
                      ? Icons.stop_circle_outlined
                      : Icons.record_voice_over,
                ),
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
              child: Text(
                note.quotedText,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
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
        ? DateTime.fromMillisecondsSinceEpoch(
            comment.createdAt,
          ).toLocal().toString().substring(0, 16)
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
                child: Text(
                  comment.quotedText,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
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
