import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../providers/debug_logger.dart';
import '../services/proxy_client.dart' as reader_proxy;
import '../utils/error_messages.dart';

/// One entry of a session transcript.
class _SessionMessage {
  _SessionMessage({
    required this.role,
    required this.content,
    this.timestamp,
  });

  final String role;
  final String content;
  final DateTime? timestamp;

  bool get isUser => role == 'user';
}

/// Shows a session's snapshot and lets the user continue it by typing.
///
/// Both calls go through the proxy, which owns the only connection to the
/// Hermes Studio backend:
///
/// * snapshot — `GET /api/studio/sessions/{id}/context`
///   returns `{title, messages: [{role, content, timestamp}], message_count}`.
/// * continue — `POST /api/studio/chat-run/runs` with `{"input", "session_id"}`.
///   Omitting `session_id` would start a brand new session, so it is always
///   sent here.
///
/// Message bodies are rendered as Markdown, since agents routinely reply with
/// headings, lists, tables and fenced code blocks.
class SessionDetailDialog extends StatefulWidget {
  const SessionDetailDialog({
    super.key,
    required this.serverId,
    required this.sessionId,
    required this.title,
    required this.proxyClient,
    this.fallbackToken,
  });

  final String serverId;
  final String sessionId;
  final String title;
  final reader_proxy.ProxyClient proxyClient;

  /// Used for `Authorization` only when the proxy did not issue a backend JWT
  /// (i.e. [ProxyClient.backendJWT] is null). The Studio API rejects the reader
  /// proxy token for some routes but accepts it for others, so we mirror the
  /// fallback used by [SessionProvider].
  final String? fallbackToken;

  @override
  State<SessionDetailDialog> createState() => _SessionDetailDialogState();
}

class _SessionDetailDialogState extends State<SessionDetailDialog> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  List<_SessionMessage> _messages = const [];
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Builds request headers with the per-server backend JWT attached.
  ///
  /// The Hermes Studio API requires `Authorization: Bearer <backend_jwt>`;
  /// without it the backend answers 401. The JWT is issued by the proxy during
  /// `connectServer` (mcu-login) and cached inside the ProxyClient.
  Map<String, String> _authHeaders({bool json = false}) {
    final headers = <String, String>{};
    if (json) headers['Content-Type'] = 'application/json';
    final jwt = widget.proxyClient.backendJWT(widget.serverId);
    final hasJwt = jwt != null && jwt.isNotEmpty;
    final token = hasJwt ? jwt : widget.fallbackToken;
    final source = hasJwt
        ? 'backend-jwt'
        : (widget.fallbackToken != null && widget.fallbackToken!.isNotEmpty
            ? 'server-auth-token'
            : 'none');
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
      // Length only — never log the token itself.
      DebugLogger.instance.info(
        '会话请求鉴权（server=$widget.serverId）',
        'source=$source token_len=${token.length}',
      );
    } else {
      DebugLogger.instance.warn(
        '会话请求缺少鉴权（server=$widget.serverId）',
        '代理未缓存后端 JWT，且无 authToken 回退；后端将返回 401',
      );
    }
    return headers;
  }

  /// The proxy returns the response body base64-encoded.
  String _decodeBody(Object? body) {
    if (body == null) return '';
    if (body is! String || body.isEmpty) return body.toString();
    try {
      return utf8.decode(base64Decode(body), allowMalformed: true);
    } catch (_) {
      // Already plain text.
      return body;
    }
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final resp = await widget.proxyClient.sendRequest(
        serverId: widget.serverId,
        method: 'GET',
        path: '/api/studio/sessions/${widget.sessionId}/context',
        headers: _authHeaders(),
      );
      final code = resp['status_code'] as int? ?? 0;
      final text = _decodeBody(resp['body']);
      if (code < 200 || code >= 300) {
        final detail = _summarize(text);
        DebugLogger.instance.error(
          '读取会话快照失败（HTTP $code）',
          'session=${widget.sessionId}${detail.isEmpty ? '' : ' :: $detail'}',
        );
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = describeError('HTTP status code $code').message;
        });
        return;
      }
      final data = jsonDecode(text) as Map<String, dynamic>;
      final raw = data['messages'] as List? ?? const [];
      final parsed = raw.map<_SessionMessage>((item) {
        final m = item as Map<String, dynamic>;
        return _SessionMessage(
          role: (m['role'] as String?) ?? 'assistant',
          content: (m['content'] as String?) ?? '',
          timestamp: _parseTimestamp(m['timestamp']),
        );
      }).toList();
      if (!mounted) return;
      setState(() {
        _messages = parsed;
        _loading = false;
        _error = null;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      final fe = describeError(e);
      DebugLogger.instance.error('读取会话快照失败', fe.detail);
      setState(() {
        _loading = false;
        _error = fe.message;
      });
    }
  }

  /// The backend stores seconds in some paths and milliseconds in others.
  DateTime? _parseTimestamp(Object? value) {
    if (value is! num) return null;
    final v = value.toInt();
    if (v <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(v > 1000000000000 ? v : v * 1000);
  }

  String _summarize(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 160 ? flat : '${flat.substring(0, 160)}…';
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _sending = true;
      _controller.clear();
    });
    try {
      final resp = await widget.proxyClient.sendRequest(
        serverId: widget.serverId,
        method: 'POST',
        path: '/api/studio/chat-run/runs',
        headers: _authHeaders(json: true),
        body: utf8.encode(jsonEncode({
          'input': text,
          'session_id': widget.sessionId,
          // Bound the wait so a slow run cannot hold the request forever
          // (sendRequest itself times out at 5 minutes).
          'timeout_ms': 120000,
        })),
      );
      final code = resp['status_code'] as int? ?? 0;
      if (code < 200 || code >= 300) {
        final detail = _summarize(_decodeBody(resp['body']));
        DebugLogger.instance.error('发送消息失败（HTTP $code）',
            'session=${widget.sessionId}${detail.isEmpty ? '' : ' :: $detail'}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(describeError('HTTP status code $code').message)),
          );
        }
        return;
      }
      await _load(quiet: true);
    } catch (e) {
      final fe = describeError(e);
      DebugLogger.instance.error('发送消息失败', fe.detail);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(fe.message)));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            _buildHeader(theme),
            const Divider(height: 1),
            Expanded(child: _buildBody(theme)),
            const Divider(height: 1),
            _buildComposer(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.title.isEmpty ? '会话' : widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
          IconButton(
            tooltip: '刷新快照',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () => _load(),
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading && _messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40, color: Colors.red),
              const SizedBox(height: 12),
              const Text('加载快照失败'),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: theme.disabledColor, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => _load(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_messages.isEmpty) {
      return Center(
        child: Text('暂无消息', style: TextStyle(color: theme.disabledColor)),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (context, i) => _buildMessage(theme, _messages[i]),
    );
  }

  Widget _buildMessage(ThemeData theme, _SessionMessage m) {
    final isUser = m.isUser;
    return Container(
      width: double.infinity,
      color: isUser
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25)
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isUser ? Icons.person : Icons.smart_toy,
                size: 14,
                color: isUser
                    ? theme.colorScheme.primary
                    : theme.colorScheme.secondary,
              ),
              const SizedBox(width: 4),
              Text(
                isUser ? '我' : (m.role.isEmpty ? '助手' : m.role),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isUser
                      ? theme.colorScheme.primary
                      : theme.colorScheme.secondary,
                ),
              ),
              if (m.timestamp != null) ...[
                const SizedBox(width: 8),
                Text(
                  _formatTime(m.timestamp!),
                  style: TextStyle(fontSize: 11, color: theme.disabledColor),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          MarkdownBody(
            data: m.content,
            selectable: true,
            softLineBreak: true,
            styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
              p: theme.textTheme.bodyMedium,
              code: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                fontFamily: 'monospace',
                fontSize: 13,
              ),
              codeblockDecoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: const InputDecoration(
                hintText: '输入消息，发送给该会话…',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _sending
              ? const SizedBox(
                  width: 40,
                  height: 40,
                  child: Padding(
                    padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.send),
                  color: theme.colorScheme.primary,
                  onPressed: _send,
                ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
