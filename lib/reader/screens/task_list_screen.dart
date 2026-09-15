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
            onPressed: taskProvider.clear,
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
                onPressed: () => context.read<TaskProvider>().remove(task.id),
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

/// Dialog that asks the user to resolve a pending authorization task. After the
/// user confirms a choice the result is sent back to the proxy (DI 0x3A) and the
/// dialog dismisses, returning to the previous screen.
class _TaskResolveDialog extends StatefulWidget {
  final TaskItem task;

  const _TaskResolveDialog({required this.task});

  @override
  State<_TaskResolveDialog> createState() => _TaskResolveDialogState();
}

class _TaskResolveDialogState extends State<_TaskResolveDialog> {
  bool _sending = false;

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
      await proxyClient.sendAuthResponse(
        reqId: widget.task.id,
        serverId: widget.task.serverId,
        result: {
          'choice': choice,
          'confirmed': choice != '拒绝' && choice != '取消',
        },
      );
      if (!mounted) return;
      // Mark resolved and return to the previous screen.
      context.read<TaskProvider>().resolve(widget.task.id);
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
  Widget build(BuildContext context) {
    final task = widget.task;
    final expired = task.isExpired;
    final choices = task.choices.isNotEmpty
        ? task.choices
        : const ['确认', '拒绝'];

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.pending_actions,
              color: expired ? Colors.red : Colors.orange),
          const SizedBox(width: 8),
          Expanded(child: Text(task.title)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(task.description),
          if (expired)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '该事项已超时，操作可能不再生效',
                style: TextStyle(color: Colors.red.shade700, fontSize: 12),
              ),
            ),
        ],
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
        ...choices.map(
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
        ),
      ],
    );
  }
}
