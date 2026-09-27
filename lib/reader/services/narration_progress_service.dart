import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';

/// Persists where read-aloud stopped, so a book can be resumed mid-page.
///
/// Separate from [ReadingProgress] on purpose: the eye and the ear are usually
/// at different places, and conflating them would make "continue reading" jump
/// to wherever narration happened to stop.
class NarrationProgressService {
  static const String _prefix = 'narration_progress_';

  final Future<SharedPreferences> Function() _prefs;

  NarrationProgressService({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? (() => SharedPreferences.getInstance());

  String _key(String bookId) => '$_prefix$bookId';

  Future<NarrationProgress?> load(String bookId) async {
    final prefs = await _prefs();
    final raw = prefs.getString(_key(bookId));
    if (raw == null) return null;
    try {
      return NarrationProgress.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(NarrationProgress progress) async {
    final prefs = await _prefs();
    await prefs.setString(
      _key(progress.bookId),
      jsonEncode(progress.toJson()),
    );
  }

  Future<void> clear(String bookId) async {
    final prefs = await _prefs();
    await prefs.remove(_key(bookId));
  }
}
