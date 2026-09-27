import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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
      '${timestamp.year.toString().padLeft(4, '0')}-'
      '${timestamp.month.toString().padLeft(2, '0')}-'
      '${timestamp.day.toString().padLeft(2, '0')} '
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

  /// One log-file line, e.g. `2026-09-15 10:20:30.123 [ERR ] message | detail`.
  String toFileLine() =>
      '$timeStr [$prefix] $message${detail != null && detail!.isNotEmpty ? ' | $detail' : ''}';
}

/// Global logger that keeps recent entries in memory and mirrors them to a
/// per-day log file under the app documents directory, so users can retrieve
/// diagnostics even after the app is restarted.
///
/// File layout: `<documents>/hermes_logs/hermes-YYYY-MM-DD.log`.
/// Writes are best-effort and serialized; a logging failure never crashes the
/// app or throws into callers.
class DebugLogger extends ChangeNotifier {
  static final DebugLogger instance = DebugLogger._();
  DebugLogger._();

  static const String _dirName = 'hermes_logs';
  static const int _retainDays = 7;

  final Queue<DebugLogEntry> _logs = Queue<DebugLogEntry>();
  int _maxLogs = 500;
  bool _isVisible = false;

  Directory? _logDir;
  bool _dirReady = false;
  Future<void>? _writeChain;

  List<DebugLogEntry> get logs => _logs.toList();
  bool get isVisible => _isVisible;
  int get maxLogs => _maxLogs;

  /// Absolute path of the log directory once resolved (null before init).
  String? get logDirectoryPath => _logDir?.path;

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

  /// Resolves the log directory (documents/hermes_logs), creating it if needed
  /// and pruning files older than [_retainDays]. Safe to call multiple times.
  Future<void> ensureInitialized() async {
    if (_dirReady) return;
    _dirReady = true; // set first so concurrent callers don't duplicate work
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$_dirName');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _logDir = dir;
      await _pruneOldLogs(dir);
    } catch (_) {
      // No file logging available (e.g. unsupported platform). Memory only.
      _logDir = null;
    }
  }

  void log(LogLevel level, String message, [String? detail]) {
    final entry = DebugLogEntry(level: level, message: message, detail: detail);
    _logs.add(entry);
    while (_logs.length > _maxLogs) {
      _logs.removeFirst();
    }
    notifyListeners();

    if (kDebugMode) {
      debugPrint('[${entry.prefix}] $message${detail != null ? ' | $detail' : ''}');
    }
    _appendToFile(entry);
  }

  void info(String msg, [String? detail]) => log(LogLevel.info, msg, detail);
  void warn(String msg, [String? detail]) => log(LogLevel.warn, msg, detail);
  void error(String msg, [String? detail]) => log(LogLevel.error, msg, detail);
  void success(String msg, [String? detail]) => log(LogLevel.success, msg, detail);

  /// Convenience: log a caught error with both a friendly summary and the raw
  /// detail, so UI can show the summary while the file keeps the stack.
  void logError(String summary, Object err, [StackTrace? stack]) {
    final detail = stack != null ? '$err\n$stack' : '$err';
    error(summary, detail);
  }

  void clear() {
    _logs.clear();
    notifyListeners();
  }

  // --- file persistence -----------------------------------------------------

  void _appendToFile(DebugLogEntry entry) {
    // Serialize writes so interleaved logs don't corrupt the file.
    _writeChain = (_writeChain ?? Future<void>.value()).then((_) async {
      try {
        await ensureInitialized();
        final dir = _logDir;
        if (dir == null) return;
        final day = _dayKey(entry.timestamp);
        final file = File('${dir.path}/hermes-$day.log');
        await file.writeAsString(
          '${entry.toFileLine()}\n',
          mode: FileMode.append,
          flush: false,
        );
      } catch (_) {
        // Never let logging crash the app.
      }
    });
  }

  /// Flushes any pending async writes (used on shutdown / tests).
  Future<void> flush() async {
    await _writeChain;
  }

  /// All current log file paths, newest first (for a "share logs" action).
  Future<List<String>> logFilePaths() async {
    await ensureInitialized();
    final dir = _logDir;
    if (dir == null) return const [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.log'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return files.map((f) => f.path).toList();
  }

  /// Reads the tail of the current day's log (last [lines] lines).
  Future<String> tail({int lines = 200}) async {
    await flush();
    final dir = _logDir;
    if (dir == null) return '';
    final file = File('${dir.path}/hermes-${_dayKey(DateTime.now())}.log');
    if (!await file.exists()) return '';
    final content = await file.readAsString();
    final all = content.split('\n');
    if (all.length <= lines) return content;
    return all.sublist(all.length - lines).join('\n');
  }

  Future<void> _pruneOldLogs(Directory dir) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: _retainDays));
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (!name.startsWith('hermes-') || !name.endsWith('.log')) continue;
        try {
          final stat = await f.stat();
          if (stat.modified.isBefore(cutoff)) {
            await f.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  String _dayKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}
