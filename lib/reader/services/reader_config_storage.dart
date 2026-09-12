import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/reader_config.dart';

/// Persists the reader settings that survive an app restart.
///
/// Kept tiny on purpose: it stores the same JSON shape as
/// [ReaderConfig.toJson], so adding a field to the config needs no change here.
class ReaderConfigStorage {
  static const String _key = 'reader_config';

  final Future<SharedPreferences> Function() _prefs;

  ReaderConfigStorage({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? (() => SharedPreferences.getInstance());

  Future<ReaderConfig> load() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_key);
    if (raw == null) return const ReaderConfig();
    try {
      return ReaderConfig.fromJson(jsonDecode(raw));
    } catch (_) {
      return const ReaderConfig();
    }
  }

  Future<void> save(ReaderConfig config) async {
    final prefs = await _prefs();
    await prefs.setString(_key, jsonEncode(config.toJson()));
  }
}
