import 'package:flutter/foundation.dart';

/// Type of pending task, so the UI knows how to present and respond to it.
enum TaskKind {
  /// A clarification question from a backend session; user must pick an option
  /// or type a free-form reply. Needs user interaction.
  clarify,
  /// An authorization / decision request surfaced by the proxy. Needs user interaction.
  auth,
  /// A system notification (e.g. proxy re-auth required). The proxy owns the
  /// actual handling; the APP only shows it for awareness and never needs the
  /// user to pick an option here.
  system,
}

/// A pending task surfaced by session monitoring.
class TaskItem {
  final String id;
  final String title;
  final String description;
  final String serverId;
  final DateTime createdAt;
  final DateTime? timeoutAt; // null = never expires
  final TaskPriority priority;
  final List<String> choices; // options offered to the user (DI 0x39)
  final TaskKind kind; // how to present / respond to this task
  final Map<String, dynamic>? details; // raw payload for full-context display
  bool resolved;

  TaskItem({
    required this.id,
    required this.title,
    required this.description,
    required this.serverId,
    required this.createdAt,
    this.timeoutAt,
    this.priority = TaskPriority.normal,
    this.choices = const [],
    this.kind = TaskKind.auth,
    this.details,
    this.resolved = false,
  });

  /// Whether this task has passed its timeout deadline.
  bool get isExpired {
    if (timeoutAt == null) return false;
    return DateTime.now().isAfter(timeoutAt!);
  }

  /// Remaining seconds until timeout; negative if already expired; -1 if none.
  int get remainingSeconds {
    if (timeoutAt == null) return -1;
    return timeoutAt!.difference(DateTime.now()).inSeconds;
  }
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
