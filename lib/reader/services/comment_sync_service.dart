import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/reader_annotations.dart';

/// Transport-agnostic shared-comment layer.
///
/// Implementations push/pull [SharedComment]s for a book. The default
/// [ServerCommentSync] stores them as a JSON file on the hermes server
/// (`library/.hermes-notes/<bookId>.json`) via the existing studio file API.
///
/// A real peer-to-peer flavour (BitTorrent / magnet-distributed comment
/// bundles) can be dropped in here later without touching the UI: implement
/// this same interface and swap the provider. Torrent is overkill for the
/// small payloads here, so it is intentionally NOT the default.
abstract class CommentSync {
  /// Returns all known shared comments for [bookId] (may be empty).
  Future<List<SharedComment>> pull(String bookId);

  /// Publishes a single comment (upsert by [SharedComment.globalKey]).
  Future<bool> push(SharedComment comment);
}

class ServerCommentSync implements CommentSync {
  ServerCommentSync(this._api);

  final dynamic _api; // HermesApiClient

  String _path(String bookId) => 'library/.hermes-notes/$bookId.json';

  List<SharedComment> _parse(String body) {
    if (body.isEmpty) return const [];
    try {
      final data = jsonDecode(body);
      final list = (data is List ? data : data['comments'] as List? ?? []) as List;
      return list.map((e) => SharedComment.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<SharedComment>> pull(String bookId) async {
    try {
      final body = await _api.readFile(_path(bookId));
      return _parse(body);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<bool> push(SharedComment comment) async {
    try {
      final existing = _parse(await _api.readFile(_path(comment.bookId)));
      final merged = <SharedComment>[];
      var replaced = false;
      for (final c in existing) {
        if (c.globalKey == comment.globalKey) {
          merged.add(comment);
          replaced = true;
        } else {
          merged.add(c);
        }
      }
      if (!replaced) merged.add(comment);
      merged.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final payload = jsonEncode(merged.map((e) => e.toJson()).toList());
      return await _api.writeFile(_path(comment.bookId), payload);
    } catch (_) {
      return false;
    }
  }
}

/// Torrent / P2P channel (reserved).
///
/// The real transport (magnet / BitTorrent-distributed comment bundles) is not
/// wired up yet, so for now comments are cached locally via SharedPreferences.
/// This keeps the dual-channel architecture testable: swap the storage here for
/// the actual P2P transport without touching the UI or the provider.
class TorrentCommentSync implements CommentSync {
  TorrentCommentSync();

  static const String _keyPrefix = 'hermes_torrent_notes:';

  @override
  Future<List<SharedComment>> pull(String bookId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyPrefix + bookId);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => SharedComment.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<bool> push(SharedComment comment) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await pull(comment.bookId);
    final merged = <SharedComment>[];
    var replaced = false;
    for (final c in existing) {
      if (c.globalKey == comment.globalKey) {
        merged.add(comment);
        replaced = true;
      } else {
        merged.add(c);
      }
    }
    if (!replaced) merged.add(comment);
    merged.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return prefs.setString(
        _keyPrefix + comment.bookId, jsonEncode(merged.map((e) => e.toJson()).toList()));
  }
}

/// Fans a single [CommentSync.push] out to every channel and merges the
/// [CommentSync.pull] results from all of them (deduplicated by globalKey).
class CompositeCommentSync implements CommentSync {
  CompositeCommentSync(this._channels);

  final List<CommentSync> _channels;

  @override
  Future<List<SharedComment>> pull(String bookId) async {
    final lists = await Future.wait(_channels.map((c) => c.pull(bookId)));
    final byKey = <String, SharedComment>{};
    for (final list in lists) {
      for (final c in list) byKey[c.globalKey] = c;
    }
    final result = byKey.values.toList();
    result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return result;
  }

  @override
  Future<bool> push(SharedComment comment) async {
    var ok = true;
    for (final c in _channels) {
      ok = (await c.push(comment)) && ok;
    }
    return ok;
  }
}
