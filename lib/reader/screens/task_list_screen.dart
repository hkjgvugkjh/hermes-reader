import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/task_provider.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: Icon(
          task.resolved ? Icons.check_circle : Icons.pending,
          color: task.resolved ? Colors.green : _priorityColor(),
        ),
        title: Text(
          task.title,
          style: TextStyle(
            decoration: task.resolved ? TextDecoration.lineThrough : null,
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
                Text(
                  task.serverId,
                  style: TextStyle(fontSize: 11, color: theme.disabledColor),
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
                icon: const Icon(Icons.check, size: 20),
                onPressed: () => context.read<TaskProvider>().resolve(task.id),
              ),
      ),
    );
  }
}
