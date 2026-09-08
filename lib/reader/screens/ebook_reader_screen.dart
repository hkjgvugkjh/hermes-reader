import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';

import '../providers/library_provider.dart';
import '../providers/server_provider.dart';
import '../providers/global_config_provider.dart';
import '../services/tts_service.dart';
import '../services/voice_command_service.dart';
import '../models/book.dart';

/// Full-screen ebook reader with:
/// - Top: book title + current server name
/// - Middle: reading area (tap to toggle controls, swipe to navigate)
/// - Bottom: progress slider, server selector, voice input
/// - Hardware key detection (volume down = next page)
/// - Event overlay for session changes
class EbookReaderScreen extends StatefulWidget {
  const EbookReaderScreen({super.key});

  @override
  State<EbookReaderScreen> createState() => _EbookReaderScreenState();
}

class _EbookReaderScreenState extends State<EbookReaderScreen> {
  bool _controlsVisible = true;
  bool _narrating = false;
  String? _fallbackNotice;
  TtsService? _tts;
  final VoiceCommandService _voiceSvc = VoiceCommandService();

  // Hardware key focus node
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tts = context.read<TtsService?>();
  }

  @override
  void dispose() {
    _tts?.stop();
    _focusNode.dispose();
    _voiceSvc.dispose();
    super.dispose();
  }

  /// Handle hardware key events (volume keys)
  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
        context.read<ReaderProvider>().nextPage();
        return true;
      } else if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
        context.read<ReaderProvider>().previousPage();
        return true;
      }
    }
    return false;
  }

  void _toggleControls() => setState(() => _controlsVisible = !_controlsVisible);

  Future<void> _toggleNarration() async {
    final tts = _tts;
    final reader = context.read<ReaderProvider>();
    if (tts == null) {
      _notice('朗读功能未初始化');
      return;
    }

    if (_narrating) {
      await tts.stop();
      if (mounted) setState(() => _narrating = false);
      return;
    }

    setState(() => _narrating = true);
    try {
      var page = reader.currentPage;
      while (page != null && _narrating && mounted) {
        final result = await tts.speak(page.content);
        if (!mounted || !_narrating) return;

        if (result.fellBack && _fallbackNotice == null) {
          if (mounted) {
            _notice('服务端朗读不可用，已使用本机语音（${result.fallbackReason}）');
            setState(() => _fallbackNotice = result.fallbackReason);
          }
        }

        if (!reader.config.autoTurnPage || !reader.nextPage()) break;
        await Future.delayed(const Duration(milliseconds: 600));
        page = reader.currentPage;
      }
    } catch (e) {
      if (mounted) _notice('朗读失败：$e');
    } finally {
      if (mounted) setState(() => _narrating = false);
    }
  }

  Future<void> _startVoiceInput() async {
    final globalConfig = context.read<GlobalConfigProvider>();
    final serverProvider = context.read<ServerProvider>();
    final server = serverProvider.activeServer ?? serverProvider.servers.first;

    try {
      final result = await _voiceSvc.recordAndSend(
        baseUrl: globalConfig.config.proxyUrl,
        authToken: globalConfig.config.proxyAuthToken,
      );
      if (mounted) {
        _notice(result.success ? '语音: ${result.transcript}' : '识别失败: ${result.error}');
      }
    } catch (e) {
      if (mounted) _notice('语音输入失败: $e');
    }
  }

  void _showServerSelector() {
    final serverProvider = context.read<ServerProvider>();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('选择服务器', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ...serverProvider.servers.map((s) => ListTile(
              title: Text(s.name),
              subtitle: Text(s.url),
              selected: serverProvider.activeServer?.id == s.id,
              onTap: () {
                serverProvider.setActiveServer(s);
                Navigator.pop(ctx);
              },
            )),
          ],
        ),
      ),
    );
  }

  void _notice(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<ReaderProvider, ServerProvider>(
      builder: (context, reader, serverProvider, _) {
        final book = reader.book;
        final page = reader.currentPage;
        final serverName = serverProvider.activeServer?.name ?? '未连接';

        return KeyboardListener(
          focusNode: _focusNode,
          onKeyEvent: _handleKeyEvent,
          child: Scaffold(
            appBar: _controlsVisible
                ? AppBar(
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(book?.title ?? '阅读', style: const TextStyle(fontSize: 16)),
                        Text(serverName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
                      ],
                    ),
                    actions: [
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
                      // Reading area
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _toggleControls,
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
                      // Bottom controls
                      if (_controlsVisible) _buildBottomControls(reader),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _buildBottomControls(ReaderProvider reader) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Progress slider
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Slider(
            value: reader.progress.clamp(0.0, 1.0),
            onChanged: (v) {
              final pageIndex = (v * (reader.pageCount - 1)).round();
              reader.goToPage(pageIndex);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // Server selector
              TextButton.icon(
                onPressed: _showServerSelector,
                icon: const Icon(Icons.dns, size: 18),
                label: const Text('服务器'),
              ),
              const Spacer(),
              Text('${reader.pageIndex + 1} / ${reader.pageCount}'),
              const Spacer(),
              // Voice input
              IconButton(
                onPressed: _startVoiceInput,
                icon: const Icon(Icons.mic),
                tooltip: '语音输入',
              ),
            ],
          ),
        ),
      ],
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
            child: Text('已降级为本机语音（$reason）', style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
