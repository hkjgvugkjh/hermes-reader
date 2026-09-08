import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/library_provider.dart';
import '../services/tts_service.dart';

/// Full-screen reader with pagination and read-aloud controls.
///
/// Immersive rather than a tab: reading wants the whole screen, and tapping
/// reveals the controls instead of leaving them permanently on screen.
class BookReaderScreen extends StatefulWidget {
  const BookReaderScreen({super.key});

  @override
  State<BookReaderScreen> createState() => _BookReaderScreenState();
}

class _BookReaderScreenState extends State<BookReaderScreen> {
  bool _controlsVisible = true;
  bool _narrating = false;
  String? _fallbackNotice;

  /// Cached in [didChangeDependencies] because [dispose] must not call
  /// `context.read` — the element tree is already unstable by then, and
  /// looking up an ancestor throws.
  TtsService? _tts;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tts = context.read<TtsService?>();
  }

  @override
  void dispose() {
    // Leaving the page must not leave narration running.
    _tts?.stop();
    super.dispose();
  }

  void _toggleControls() =>
      setState(() => _controlsVisible = !_controlsVisible);

  Future<void> _toggleNarration() async {
    final tts = _tts;
    final reader = context.read<ReaderProvider>();
    if (tts == null) {
      _notice(context, '朗读功能未初始化');
      return;
    }

    if (_narrating) {
      await tts.stop();
      if (!mounted) return;
      setState(() => _narrating = false);
      return;
    }

    final page = reader.currentPage;
    if (page == null) return;

    setState(() => _narrating = true);
    try {
      // Narrate forward page by page until the reader is stopped, the end is
      // reached, or an error occurs. A loop rather than recursion: the whole
      // run is cancelled by a single flag check, and there is no stack growth
      // for a long book.
      var page = reader.currentPage;
      while (page != null && _narrating && mounted) {
        final result = await tts.speak(page.content);
        if (!mounted || !_narrating) return;

        if (result.fellBack && _fallbackNotice == null) {
          if (mounted) {
            _notice(context,
                '服务端朗读不可用，已使用本机语音（${result.fallbackReason}）');
            setState(() => _fallbackNotice = result.fallbackReason);
          }
        }

        if (!reader.config.autoTurnPage || !reader.nextPage()) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
        page = reader.currentPage;
      }
    } catch (e) {
      if (!mounted) return;
      _notice(context, '朗读失败：$e');
    } finally {
      if (mounted) setState(() => _narrating = false);
    }
  }

  void _notice(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ReaderProvider>(
      builder: (context, reader, _) {
        final book = reader.book;
        final page = reader.currentPage;

        return Scaffold(
          appBar: _controlsVisible
              ? AppBar(
                  title: Text(book?.title ?? '阅读'),
                  actions: [
                    // Narration lives in the footer next to page turning —
                    // one entry point only, so its state is unambiguous.
                    PopupMenuButton<double>(
                      icon: const Icon(Icons.text_fields),
                      tooltip: '字号',
                      onSelected: (scale) {
                        reader.updateConfig(reader.config.copyWith(fontScale: scale));
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 0.85, child: Text('小')),
                        PopupMenuItem(value: 1.0, child: Text('标准')),
                        PopupMenuItem(value: 1.2, child: Text('大')),
                        PopupMenuItem(value: 1.5, child: Text('特大')),
                      ],
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
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _toggleControls,
                        // Swipe navigation: reading on a phone is one-handed.
                        onHorizontalDragEnd: (details) {
                          final dx = details.primaryVelocity ?? 0;
                          if (dx < -300) {
                            reader.nextPage();
                          } else if (dx > 300) {
                            reader.previousPage();
                          }
                        },
                        child: SafeArea(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                            child: Text(
                              page.content,
                              style: TextStyle(
                                fontSize: 17 * reader.config.fontScale,
                                height: 1.7 * reader.config.fontScale.clamp(1.0, 1.3),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_controlsVisible)
                      _ReaderFooter(
                        pageIndex: reader.pageIndex,
                        pageCount: reader.pageCount,
                        progress: reader.progress,
                        narrating: _narrating,
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

class _ReaderFooter extends StatelessWidget {
  const _ReaderFooter({
    required this.pageIndex,
    required this.pageCount,
    required this.progress,
    required this.narrating,
    required this.onPrev,
    required this.onNext,
    required this.onNarrate,
  });

  final int pageIndex;
  final int pageCount;
  final double progress;
  final bool narrating;
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
                tooltip: narrating ? '停止朗读' : '朗读',
                onPressed: () => onNarrate(),
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
