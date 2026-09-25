import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/session_provider.dart';
import '../services/session_monitor_service.dart';
import '../widgets/voice_command_button.dart';

/// Monitor for Hermes sessions across configured servers.
class SessionMonitorScreen extends StatefulWidget {
  final String? initialServerId;
  final String? initialSessionId;
  const SessionMonitorScreen({super.key, this.initialServerId, this.initialSessionId});

  @override
  State<SessionMonitorScreen> createState() => _SessionMonitorScreenState();
}

class _SessionMonitorScreenState extends State<SessionMonitorScreen> {
  int _view = 0; // 0 = 会话, 1 = 事件
  String? _serverFilter;

  @override
  void initState() {
    super.initState();
    // Auto-open the session that triggered the notification
    if (widget.initialServerId != null && widget.initialSessionId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final provider = context.read<SessionProvider>();
        final snap = provider.currentSessions
            .where((s) => s.id == widget.initialSessionId)
            .firstOrNull;
        if (snap != null && mounted) {
          _openSnapshot(snap, widget.initialServerId!, provider);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SessionProvider>(
      builder: (context, provider, _) {
        final sessions = provider.currentSessions.where((s) {
          if (_serverFilter == null) return true;
          return provider.serverIdForSession(s.id) == _serverFilter;
        }).toList();
        final changes = provider.recentChanges.where((c) {
          if (_serverFilter == null) return true;
          return c.serverId == _serverFilter;
        }).toList();

        return Scaffold(
          appBar: AppBar(
            title: const Text('会话监控'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: '刷新',
                onPressed: () async {
                  if (_serverFilter != null) {
                    await provider.pollNow(_serverFilter!);
                  } else {
                    for (final t in provider.monitor.targets) {
                      await provider.pollNow(t.serverId);
                    }
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_sweep),
                tooltip: '清空事件',
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('清空事件'),
                      content: Text(
                        '确定要清空全部 ${provider.recentChanges.length} 条监控事件吗？此操作不可撤销。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => Navigator.of(dialogContext).pop(true),
                          child: const Text('清空'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true && mounted) provider.clearHistory();
                },
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 0, label: Text('会话')),
                        ButtonSegment(value: 1, label: Text('事件')),
                      ],
                      selected: {_view},
                      onSelectionChanged: (s) => setState(() => _view = s.first),
                    ),
                    const Spacer(),
                    DropdownButton<String?>(
                      value: _serverFilter,
                      hint: const Text('所有服务器'),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('所有服务器'),
                        ),
                        ...provider.monitor.targets.map(
                          (t) => DropdownMenuItem(
                            value: t.serverId,
                            child: Text(t.serverId),
                          ),
                        ),
                      ],
                      onChanged: (v) => setState(() => _serverFilter = v),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _view == 0
                    ? _buildSessions(sessions, provider)
                    : _buildChanges(changes, provider),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSessions(List<SessionSnapshot> sessions, SessionProvider provider) {
    if (sessions.isEmpty) {
      return const Center(child: Text('暂无会话快照'));
    }
    return ListView.builder(
      itemCount: sessions.length,
      itemBuilder: (_, i) {
        final snap = sessions[i];
        final serverId = provider.serverIdForSession(snap.id) ?? '';
        return _SessionTile(
          snapshot: snap,
          serverId: serverId,
          onTap: () => _openSnapshot(snap, serverId, provider),
        );
      },
    );
  }

  Widget _buildChanges(List<SessionChange> changes, SessionProvider provider) {
    if (changes.isEmpty) {
      return const Center(child: Text('暂无事件'));
    }
    return ListView.builder(
      itemCount: changes.length,
      itemBuilder: (_, i) => _ChangeTile(
        change: changes[i],
        onTap: () {
          final snap = changes[i].after ?? changes[i].before;
          if (snap != null) {
            _openSnapshot(snap, changes[i].serverId, provider);
          }
        },
      ),
    );
  }

  void _openSnapshot(
    SessionSnapshot snap,
    String serverId,
    SessionProvider provider,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SessionSnapshotSheet(
        snapshot: snap,
        serverId: serverId,
        provider: provider,
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final SessionSnapshot snapshot;
  final String serverId;
  final VoidCallback onTap;

  const _SessionTile({
    required this.snapshot,
    required this.serverId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(Icons.chat_bubble_outline, color: _stateColor(snapshot.state)),
      title: Text(
        snapshot.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '服务器: $serverId  •  ${_fmtTime(snapshot.lastActivity)}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Chip(
        label: Text(_stateLabel(snapshot.state)),
        backgroundColor: _stateColor(snapshot.state).withAlpha(38),
      ),
      onTap: onTap,
    );
  }
}

/// Bottom sheet shown when a session is tapped: the latest snapshot plus a
/// voice-command box that sends the transcribed text as a chat command.
class _SessionSnapshotSheet extends StatefulWidget {
  final SessionSnapshot snapshot;
  final String serverId;
  final SessionProvider provider;

  const _SessionSnapshotSheet({
    required this.snapshot,
    required this.serverId,
    required this.provider,
  });

  @override
  State<_SessionSnapshotSheet> createState() => _SessionSnapshotSheetState();
}

class _SessionSnapshotSheetState extends State<_SessionSnapshotSheet> {
  bool _showRaw = false;
  String? _transcript;
  String? _reply;
  String? _error;
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    final snap = widget.snapshot;
    final target = widget.provider.targetForServer(widget.serverId);
    final proxy = widget.provider.proxyClient;
    final useProxy = proxy != null && proxy.isConnected;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.92,
      ),
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    snap.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  label: Text('状态: ${_stateLabel(snap.state)}'),
                  backgroundColor: _stateColor(snap.state).withAlpha(38),
                ),
                Chip(label: Text('服务器: ${widget.serverId}')),
                Chip(label: Text('更新: ${_fmtTime(snap.lastActivity)}')),
              ],
            ),
            if (snap.pendingAction != null) ...[
              const SizedBox(height: 8),
              Text(
                '待处理操作: ${snap.pendingAction!}',
                style: const TextStyle(color: Colors.orange),
              ),
            ],
            const SizedBox(height: 12),
            const Text('最后的快照', style: TextStyle(fontWeight: FontWeight.bold)),
            TextButton(
              onPressed: () => setState(() => _showRaw = !_showRaw),
              child: Text(_showRaw ? '收起' : '展开原始数据'),
            ),
            if (_showRaw && snap.raw != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  const JsonEncoder.withIndent('  ').convert(snap.raw),
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
            const SizedBox(height: 16),
            const Divider(),
            const Text('语音发送命令',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (target != null)
              VoiceCommandButton(
                baseUrl: target.baseUrl,
                authToken: target.authToken,
                proxySender: useProxy
                    ? (path) => widget.provider.sendVoiceTurnViaProxy(
                          widget.serverId,
                          path,
                          target.authToken,
                        )
                    : null,
                onResult: _send,
              )
            else
              const Text('未找到服务器配置，无法发送语音命令',
                  style: TextStyle(color: Colors.grey)),
            if (_transcript != null) ...[
              const SizedBox(height: 8),
              Text('识别: $_transcript'),
            ],
            if (_sending)
              const Padding(
                padding: EdgeInsets.all(8),
                child: LinearProgressIndicator(),
              ),
            if (_reply != null) ...[
              const SizedBox(height: 8),
              const Text('回复:', style: TextStyle(fontWeight: FontWeight.bold)),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_reply!),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('错误: $_error',
                    style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _send(String transcript) async {
    setState(() {
      _sending = true;
      _error = null;
      _reply = null;
    });
    final result =
        await widget.provider.sendCommandToSession(widget.snapshot.id, transcript);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _transcript = transcript;
      if (result.success) {
        _reply = result.content;
      } else {
        _error = result.error ?? result.content;
      }
    });
  }
}

class _ChangeTile extends StatelessWidget {
  final SessionChange change;
  final VoidCallback? onTap;

  const _ChangeTile({required this.change, this.onTap});

  String _kindLabel(SessionChangeKind kind) {
    switch (kind) {
      case SessionChangeKind.sessionStarted:
        return '开始';
      case SessionChangeKind.sessionStopped:
        return '停止';
      case SessionChangeKind.sessionNeedsInput:
        return '需要输入';
      case SessionChangeKind.sessionResumed:
        return '恢复';
      case SessionChangeKind.authRequired:
        return '需要认证';
      case SessionChangeKind.serverError:
        return '服务器错误';
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = change.after ?? change.before;
    return ListTile(
      title: Text('${_kindLabel(change.kind)} · ${snap?.title ?? change.serverId}'),
      subtitle: Text(
        '服务器: ${change.serverId}  •  ${_fmtTime(change.detectedAt)}',
      ),
      trailing: Icon(
        change.after != null ? Icons.check_circle : Icons.circle_outlined,
        color: change.after != null ? Colors.green : Colors.grey,
        size: 16,
      ),
      onTap: onTap,
    );
  }
}

Color _stateColor(SessionState state) {
  switch (state) {
    case SessionState.running:
      return Colors.green;
    case SessionState.stopped:
      return Colors.grey;
    case SessionState.pending:
      return Colors.orange;
    case SessionState.error:
      return Colors.red;
  }
}

String _stateLabel(SessionState state) {
  switch (state) {
    case SessionState.running:
      return '运行中';
    case SessionState.stopped:
      return '已停止';
    case SessionState.pending:
      return '待输入';
    case SessionState.error:
      return '错误';
  }
}

String _fmtTime(DateTime t) {
  final s = t.toLocal().toString();
  return s.length > 19 ? s.substring(0, 19) : s;
}
