import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/reader_annotations.dart';

/// Local store for bookmarks and notes, mirrored after [ReadingProgressService].
/// Per-book lists are kept under a stable SharedPreferences key so they survive
/// app restarts and (via [CommentSync]) can be lifted into the shared layer.
class AnnotationStore {
  static const String _bmPrefix = 'bookmarks_';
  static const String _notePrefix = 'notes_';

  final Future<SharedPreferences> Function() _prefs;

  AnnotationStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? (() => SharedPreferences.getInstance());

  String _bmKey(String bookId) => '$_bmPrefix$bookId';
  String _noteKey(String bookId) => '$_notePrefix$bookId';

  // ---- Bookmarks ----

  Future<List<Bookmark>> loadBookmarks(String bookId) async {
    final prefs = await _prefs();
    final raw = prefs.getString(_bmKey(bookId));
    if (raw == null) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final items = list.map(Bookmark.fromJson).toList();
      items.sort((a, b) => a.offset.compareTo(b.offset));
      return items;
    } catch (_) {
      return const [];
    }
  }

  Future<void> addBookmark(Bookmark bm) async {
    final items = await loadBookmarks(bm.bookId);
    if (items.any((b) => b.offset == bm.offset)) return; // de-dup by offset
    items.add(bm);
    await _saveBookmarks(items);
  }

  Future<void> removeBookmarkAt(String bookId, int offset) async {
    final items = await loadBookmarks(bookId);
    items.removeWhere((b) => b.offset == offset);
    await _saveBookmarks(items);
  }

  Future<bool> hasBookmarkAt(String bookId, int offset) async {
    final items = await loadBookmarks(bookId);
    return items.any((b) => b.offset == offset);
  }

  Future<void> _saveBookmarks(List<Bookmark> items) async {
    final prefs = await _prefs();
    items.sort((a, b) => a.offset.compareTo(b.offset));
    await prefs.setString(
      _bmKey(items.first.bookId),
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  // ---- Notes ----

  Future<List<Note>> loadNotes(String bookId) async {
    final prefs = await _prefs();
    final raw = prefs.getString(_noteKey(bookId));
    if (raw == null) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final items = list.map(Note.fromJson).toList();
      items.sort((a, b) => a.startOffset.compareTo(b.startOffset));
      return items;
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveNote(Note note) async {
    final items = await loadNotes(note.bookId);
    final idx = items.indexWhere((n) => n.id == note.id);
    if (idx >= 0) {
      items[idx] = note;
    } else {
      items.add(note);
    }
    await _saveNotes(items);
  }

  Future<void> removeNote(String bookId, String id) async {
    final items = await loadNotes(bookId);
    items.removeWhere((n) => n.id == id);
    await _saveNotes(items);
  }

  Future<void> _saveNotes(List<Note> items) async {
    final prefs = await _prefs();
    items.sort((a, b) => a.startOffset.compareTo(b.startOffset));
    await prefs.setString(
      _noteKey(items.first.bookId),
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }
}
