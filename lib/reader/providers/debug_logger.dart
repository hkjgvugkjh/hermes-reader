import 'package:flutter/foundation.dart';
import 'dart:collection';

/// Debug log level
enum LogLevel { info, warn, error, success }

/// A single debug log entry
class DebugLogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final String? detail;

  DebugLogEntry({
    required this.level,
    required this.message,
    this.detail,
  }) : timestamp = DateTime.now();

  String get timeStr =>
      '${timestamp.hour.toString().padLeft(2, '0')}:'
      '${timestamp.minute.toString().padLeft(2, '0')}:'
      '${timestamp.second.toString().padLeft(2, '0')}.'
      '${timestamp.millisecond.toString().padLeft(3, '0')}';

  String get prefix {
    switch (level) {
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warn:
        return 'WARN';
      case LogLevel.error:
        return 'ERR ';
      case LogLevel.success:
        return 'OK  ';
    }
  }
}

/// Global debug logger that stores recent log entries
class DebugLogger extends ChangeNotifier {
  static final DebugLogger instance = DebugLogger._();
  DebugLogger._();

  final Queue<DebugLogEntry> _logs = Queue<DebugLogEntry>();
  int _maxLogs = 500;
  bool _isVisible = false;

  List<DebugLogEntry> get logs => _logs.toList();
  bool get isVisible => _isVisible;
  int get maxLogs => _maxLogs;

  set isVisible(bool v) {
    _isVisible = v;
    notifyListeners();
  }

  void setMaxLogs(int n) {
    _maxLogs = n;
    while (_logs.length > _maxLogs) {
      _logs.removeFirst();
    }
    notifyListeners();
  }

  void log(LogLevel level, String message, [String? detail]) {
    final entry = DebugLogEntry(level: level, message: message, detail: detail);
    _logs.add(entry);
    while (_logs.length > _maxLogs) {
      _logs.removeFirst();
    }
    notifyListeners();
    // Also print to console
    if (kDebugMode) {
      print('[${entry.prefix}] $message${detail != null ? ' | $detail' : ''}');
    }
  }

  void info(String msg, [String? detail]) => log(LogLevel.info, msg, detail);
  void warn(String msg, [String? detail]) => log(LogLevel.warn, msg, detail);
  void error(String msg, [String? detail]) => log(LogLevel.error, msg, detail);
  void success(String msg, [String? detail]) => log(LogLevel.success, msg, detail);

  void clear() {
    _logs.clear();
    notifyListeners();
  }
}
