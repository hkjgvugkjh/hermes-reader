import 'package:flutter/material.dart';

import '../services/voice_command_service.dart';

/// A button that records a voice command while held, sends on release, and
/// shows the transcript + reply.
class VoiceCommandButton extends StatefulWidget {
  final String baseUrl;
  final String? authToken;
  final void Function(String transcript)? onResult;

  const VoiceCommandButton({
    super.key,
    required this.baseUrl,
    this.authToken,
    this.onResult,
  });

  @override
  State<VoiceCommandButton> createState() => _VoiceCommandButtonState();
}

class _VoiceCommandButtonState extends State<VoiceCommandButton> {
  final _svc = VoiceCommandService();
  bool _recording = false;
  bool _sending = false;
  String? _transcript;

  @override
  void dispose() {
    _svc.dispose();
    super.dispose();
  }

  Future<void> _onPointerDown() async {
    setState(() {
      _recording = true;
      _sending = false;
      _transcript = null;
    });
    try {
      await _svc.start();
    } catch (e) {
      setState(() => _recording = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法启动录音: $e')),
        );
      }
    }
  }

  Future<void> _onPointerUp() async {
    if (!_recording) return;
    setState(() {
      _recording = false;
      _sending = true;
    });
    final path = await _svc.stopAndSave();
    if (path == null) {
      setState(() => _sending = false);
      return;
    }
    final result = await _svc.sendTurn(
      baseUrl: widget.baseUrl,
      authToken: widget.authToken,
      filePath: path,
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _transcript = result.transcript;
    });
    if (result.success) {
      widget.onResult?.call(result.transcript);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('语音识别失败: ${result.error ?? "未知错误"}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _recording ? Colors.red : Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTapDown: (_) => _onPointerDown(),
      onTapUp: (_) => _onPointerUp(),
      onTapCancel: () => _onPointerUp(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        height: 80,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color),
        ),
        child: Center(
          child: _buildInner(),
        ),
      ),
    );
  }

  Widget _buildInner() {
    if (_sending) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(strokeWidth: 2),
          SizedBox(height: 4),
          Text('识别中…', style: TextStyle(fontSize: 12)),
        ],
      );
    }
    if (_recording) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mic, color: Colors.red, size: 32),
          SizedBox(height: 4),
          Text('正在录音…松开发送', style: TextStyle(fontSize: 12)),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.mic_none, color: Theme.of(context).colorScheme.primary, size: 32),
        const SizedBox(height: 4),
        Text(
          _transcript != null ? '识别结果: $_transcript' : '按住说话',
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}
