import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';

/// Persists reading position per book so the reader can resume where it left
/// off, even across app restarts.
class ReadingProgressService {
  static const String _prefix = 'reading_progress_';

  final Future<SharedPreferences> Function() _prefs;

  ReadingProgressService({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? (() => SharedPreferences.getInstance());

  String _key(String bookId) => '$_prefix$bookId';

  /// Loads the saved position for [bookId], or null when the book has not been
  /// opened before.
  Future<ReadingProgress?> load(String bookId) async {
    final prefs = await _prefs();
    final raw = prefs.getString(_key(bookId));
    if (raw == null) return null;
    try {
      return ReadingProgress.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// Saves the position for [bookId].
  Future<void> save(ReadingProgress progress) async {
    final prefs = await _prefs();
    await prefs.setString(
      _key(progress.bookId),
      jsonEncode(progress.toJson()),
    );
  }

  /// Clears the saved position for [bookId].
  Future<void> clear(String bookId) async {
    final prefs = await _prefs();
    await prefs.remove(_key(bookId));
  }
}