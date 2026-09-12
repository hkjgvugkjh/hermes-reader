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
import '../services/tts_service.dart';

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tts = context.read<TtsService?>();
    if (tts != _tts) {
      _tts = tts;
      tts?.setProgressHandler(_onNarrationProgress);
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
                              child: _buildPageBody(context, reader),
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
  Widget _buildPageBody(BuildContext context, ReaderProvider reader) {
    final page = reader.currentPage;
    if (page == null) return const SizedBox.shrink();

    final images = reader.images;
    final fontScale = reader.config.fontScale;
    final style = TextStyle(
      fontSize: 17 * fontScale,
      height: 1.7 * fontScale.clamp(1.0, 1.3),
    );
    final maxWidth = MediaQuery.of(context).size.width - 40;

    final content = page.content;
    final widgets = <Widget>[];
    var last = 0;
    for (final m in imageMarkerRegex.allMatches(content)) {
      final text = content.substring(last, m.start);
      if (text.isNotEmpty) {
        widgets.add(Text(text, style: style, textAlign: TextAlign.justify));
      }
      final index = int.tryParse(m.group(1)!);
      final img = index != null && index < images.length ? images[index] : null;
      if (img != null) widgets.add(_buildImage(img, maxWidth));
      last = m.end;
    }
    final tail = content.substring(last);
    if (tail.isNotEmpty) {
      widgets.add(Text(tail, style: style, textAlign: TextAlign.justify));
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
  });

  final int pageIndex;
  final int pageCount;
  final double progress;
  final bool narrating;
  final bool canNarrate;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final Future<void> Function() onNarrate;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LinearProgressIndicator(value: pageCount > 1 ? progress : 1.0),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text('${pageIndex + 1} / $pageCount',
                  style: const TextStyle(fontSize: 13)),
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
