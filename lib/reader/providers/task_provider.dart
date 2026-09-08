import 'package:flutter/foundation.dart';

/// A pending task surfaced by the session monitor.
class TaskItem {
  final String id;
  final String title;
  final String description;
  final String serverId;
  final DateTime createdAt;
  final TaskPriority priority;
  bool resolved;

  TaskItem({
    required this.id,
    required this.title,
    required this.description,
    required this.serverId,
    required this.createdAt,
    this.priority = TaskPriority.normal,
    this.resolved = false,
  });
}

enum TaskPriority { low, normal, high, urgent }

/// Owns the list of pending tasks surfaced by session monitoring.
class TaskProvider extends ChangeNotifier {
  final List<TaskItem> _tasks = [];

  List<TaskItem> get tasks => List.unmodifiable(_tasks);
  List<TaskItem> get unresolved => _tasks.where((t) => !t.resolved).toList();

  void addTask(TaskItem task) {
    _tasks.insert(0, task);
    notifyListeners();
  }

  void resolve(String id) {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx >= 0) {
      _tasks[idx].resolved = true;
      notifyListeners();
    }
  }

  void remove(String id) {
    _tasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  void clear() {
    _tasks.clear();
    notifyListeners();
  }
}
