import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/task_provider.dart';
import '../providers/session_provider.dart';

/// Shows pending tasks surfaced by session monitoring.
class TaskListScreen extends StatelessWidget {
  const TaskListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final taskProvider = context.watch<TaskProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('待处理事项'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: '清空',
            onPressed: () async {
              final ok = await _confirmDelete(
                context,
                '清空待处理事项',
                '确定要清空全部 ${taskProvider.tasks.length} 项待处理事项吗？此操作不可撤销。',
              );
              if (ok && context.mounted) taskProvider.clear();
            },
          ),
        ],
      ),
      body: taskProvider.tasks.isEmpty
          ? Center(
              child: Text(
                '暂无待处理事项',
                style: TextStyle(color: theme.disabledColor),
              ),
            )
          : ListView.builder(
              itemCount: taskProvider.tasks.length,
              itemBuilder: (context, index) {
                final task = taskProvider.tasks[index];
                return _TaskTile(task: task);
              },
            ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  final TaskItem task;

  const _TaskTile({required this.task});

  Color _priorityColor() {
    if (task.isExpired) return Colors.red.shade800;
    switch (task.priority) {
      case TaskPriority.urgent:
        return Colors.red;
      case TaskPriority.high:
        return Colors.orange;
      case TaskPriority.normal:
        return Colors.blue;
      case TaskPriority.low:
        return Colors.grey;
    }
  }

  String _priorityLabel() {
    if (task.isExpired) return '已超时';
    switch (task.priority) {
      case TaskPriority.urgent:
        return '紧急';
      case TaskPriority.high:
        return '高';
      case TaskPriority.normal:
        return '普通';
      case TaskPriority.low:
        return '低';
    }
  }

  String _timeoutLabel() {
    if (task.timeoutAt == null) return '';
    final secs = task.remainingSeconds;
    if (secs < 0) return '已超时 ${-secs}s';
    if (secs < 60) return '剩 $secs s';
    return '剩 ${(secs / 60).floor()}m ${secs % 60}s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: task.isExpired ? Colors.red.shade50 : null,
      child: ListTile(
        leading: Icon(
          task.resolved ? Icons.check_circle : Icons.pending,
          color: task.resolved ? Colors.green : _priorityColor(),
        ),
        title: Text(
          task.title,
          style: TextStyle(
            decoration: task.resolved ? TextDecoration.lineThrough : null,
            color: task.isExpired && !task.resolved ? Colors.red.shade800 : null,
            fontWeight: task.isExpired && !task.resolved ? FontWeight.bold : null,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(task.description),
            const SizedBox(height: 4),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _priorityColor().withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _priorityLabel(),
                    style: TextStyle(
                      fontSize: 10,
                      color: _priorityColor(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (task.timeoutAt != null)
                  Text(
                    _timeoutLabel(),
                    style: const TextStyle(fontSize: 11, color: Colors.red),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    task.serverId,
                    style: TextStyle(fontSize: 11, color: theme.disabledColor),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
        trailing: task.resolved
            ? IconButton(
                icon: const Icon(Icons.delete, size: 20),
                tooltip: '删除',
                onPressed: () async {
                  final ok = await _confirmDelete(
                    context,
                    '删除事项',
                    '确定要删除「${task.title}」吗？此操作不可撤销。',
                  );
                  if (ok && context.mounted) {
                    context.read<TaskProvider>().remove(task.id);
                  }
                },
              )
            : IconButton(
                icon: const Icon(Icons.open_in_new, size: 20),
                tooltip: '处理',
                onPressed: () => _openHandler(context, task),
              ),
        onTap: task.resolved ? null : () => _openHandler(context, task),
      ),
    );
  }

  void _openHandler(BuildContext context, TaskItem task) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _TaskResolveDialog(task: task),
    );
  }
}

/// Dialog that asks the user to resolve a pending task.
///
/// - clarify tasks send the choice back via [ProxyClient.sendClarifyResponse]
///   (DI 0x3B, session_id + clarify_id).
/// - auth tasks send it back via [ProxyClient.sendAuthResponse] (DI 0x3A).
/// When the backend provides no preset choices the user may type a free-form
/// reply, which is sent verbatim to the proxy.
class _TaskResolveDialog extends StatefulWidget {
  final TaskItem task;

  const _TaskResolveDialog({required this.task});

  @override
  State<_TaskResolveDialog> createState() => _TaskResolveDialogState();
}

class _TaskResolveDialogState extends State<_TaskResolveDialog> {
  bool _sending = false;
  bool _showDetail = false;
  final TextEditingController _controller = TextEditingController();

  Future<void> _submit(String choice) async {
    final session = context.read<SessionProvider>();
    final proxyClient = session.proxyClient;
    if (proxyClient == null || !proxyClient.isConnected) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('代理未连接，无法提交')),
      );
      return;
    }
    setState(() => _sending = true);
    try {
      // 按任务类型回传：clarify 用 session_id + clarify_id；auth 用 req_id + server_id。
      final task = widget.task;
      final details = task.details ?? <String, dynamic>{};
      if (task.kind == TaskKind.clarify) {
        final sessionId = task.serverId.isNotEmpty
            ? task.serverId
            : (details['session_id'] ?? '').toString();
        await proxyClient.sendClarifyResponse(
          sessionId: sessionId,
          clarifyId: task.id,
          response: choice,
        );
      } else {
        await proxyClient.sendAuthResponse(
          reqId: task.id,
          serverId: task.serverId,
          result: {
            'choice': choice,
            'confirmed': choice != '拒绝' && choice != '取消',
          },
        );
      }
      if (!mounted) return;
      // 标记已处理并关闭对话框。
      context.read<TaskProvider>().resolve(task.id);
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('提交失败：$e')),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final expired = task.isExpired;
    final hasChoices = task.choices.isNotEmpty;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.pending_actions,
              color: expired ? Colors.red : Colors.orange),
          const SizedBox(width: 8),
          Expanded(child: Text(task.title)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 命令/请求细节：明确呈现给用户的核心信息。
            Text(task.description),
            if (expired)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '该事项已超时，操作可能不再生效',
                  style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                ),
              ),
            const SizedBox(height: 10),
            // 可折叠的原始命令详情，方便用户查看完整上下文。
            if (task.details != null && task.details!.isNotEmpty)
              TextButton.icon(
                onPressed: () => setState(() => _showDetail = !_showDetail),
                icon: Icon(
                  _showDetail ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
                label: const Text('命令详情', style: TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            if (_showDetail && task.details != null)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(task.details),
                    style: const TextStyle(
                        fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
              ),
            // 无预设选项时，提供自由文本输入框让用户直接回复。
            if (!hasChoices) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  labelText: '直接输入回复',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                maxLines: 2,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending
              ? null
              : () {
                  context.read<TaskProvider>().resolve(task.id);
                  Navigator.of(context).pop();
                },
          child: const Text('稍后处理'),
        ),
        if (hasChoices)
          ...task.choices.map(
            (c) => FilledButton(
              onPressed: _sending ? null : () => _submit(c),
              child: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(c),
            ),
          )
        else
          FilledButton(
            onPressed: _sending
                ? null
                : () => _submit(_controller.text.trim().isEmpty
                    ? '已阅'
                    : _controller.text.trim()),
            child: const Text('提交'),
          ),
      ],
    );
  }
}

/// Asks the user to confirm an irreversible delete action.
/// Returns true only when the user taps 删除.
Future<bool> _confirmDelete(
  BuildContext context,
  String title,
  String content,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(content),
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
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return result == true;
}
