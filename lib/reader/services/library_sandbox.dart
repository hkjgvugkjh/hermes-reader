import 'dart:typed_data';

import '../models/reader_config.dart';

/// Thrown when a requested path falls outside the library sandbox, or breaks
/// any of the other limits. Carries a reason suitable for showing the user.
class LibrarySandboxError implements Exception {
  final String message;
  const LibrarySandboxError(this.message);

  @override
  String toString() => 'LibrarySandboxError: $message';
}

/// Guards every path that leaves the device toward a server workspace.
///
/// The server side enforces its own rules; this is the client-side half, so a
/// mistyped config or a malicious server listing can never make the app read
/// (or appear to read) outside the designated library directory.
class LibrarySandbox {
  const LibrarySandbox();

  /// Validates a user/server-supplied path and returns it as a clean relative
  /// path under the library root, e.g. 'library/novel.txt'.
  ///
  /// Throws [LibrarySandboxError] for anything suspicious.
  String resolve(String input) {
    if (input.isEmpty) {
      throw const LibrarySandboxError('empty path');
    }

    // Reject absolute paths and anything with a drive qualifier or UNC form.
    if (input.startsWith('/') ||
        input.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(input)) {
      throw LibrarySandboxError('absolute paths are not allowed: $input');
    }

    // Reject NUL and control characters — classic parser-confusion vector.
    if (input.contains('\u0000')) {
      throw const LibrarySandboxError('path contains a NUL byte');
    }

    // Reject URL-encoded traversal before it gets decoded anywhere downstream.
    final lowered = input.toLowerCase();
    for (final enc in const ['%2e', '%2f', '%5c', '..%', '%00']) {
      if (lowered.contains(enc)) {
        throw LibrarySandboxError('encoded traversal sequence in: $input');
      }
    }

    // Normalise separators, then walk the segments.
    final normalized = input.replaceAll('\\', '/');
    final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();

    // Reject traversal segments outright.
    if (segments.any((s) => s == '..' || s == '.')) {
      throw LibrarySandboxError('path traversal rejected: $input');
    }

    // Depth limit: library/<book> is depth 1 beyond the root; allow a little
    // nesting for sub-folders but not unbounded recursion.
    if (segments.length > ReaderConfig.maxListDepth + 1) {
      throw LibrarySandboxError(
          'path too deep (${segments.length} segments): $input');
    }

    // Extension allow-list.
    final last = segments.last;
    final dot = last.lastIndexOf('.');
    if (dot <= 0) {
      throw LibrarySandboxError('file has no extension: $input');
    }
    final ext = last.substring(dot).toLowerCase();
    if (!ReaderConfig.allowedExtensions.contains(ext)) {
      throw LibrarySandboxError(
          'extension $ext is not allowed (${ReaderConfig.allowedExtensions.join(", ")})');
    }

    // Rebuild the path so it is always rooted at the library directory.
    // Strip a leading 'library' segment first so resolve() is idempotent —
    // callers may hand us an already-rooted path from a persisted Book.
    var parts = List<String>.from(segments);
    while (parts.isNotEmpty && parts.first == ReaderConfig.libraryRoot) {
      parts.removeAt(0);
    }
    if (parts.isEmpty) {
      throw const LibrarySandboxError('path has no file below the library root');
    }

    final relative = parts.join('/');
    return '${ReaderConfig.libraryRoot}/$relative';
  }

  /// Validates a directory path (no extension check), used for listing.
  String resolveDir(String input) {
    if (input.isEmpty || input == '.') {
      return ReaderConfig.libraryRoot;
    }
    final normalized = input.replaceAll('\\', '/');
    final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.any((s) => s == '..')) {
      throw LibrarySandboxError('path traversal rejected: $input');
    }
    final meaningful = segments
        .where((s) => s != ReaderConfig.libraryRoot)
        .toList(growable: false);
    if (meaningful.length > ReaderConfig.maxListDepth) {
      throw LibrarySandboxError('directory too deep: $input');
    }
    return [ReaderConfig.libraryRoot, ...meaningful].join('/');
  }

  /// True when [size] is within the per-file cap.
  bool sizeAllowed(int size) =>
      size > 0 && size <= ReaderConfig.maxFileBytes;

  /// Guards a download against a lying Content-Length: if the stream exceeds
  /// the cap, abort rather than buffering it all into memory.
  void checkTransfer(int totalBytes) {
    if (totalBytes > ReaderConfig.maxTransferBytes) {
      throw LibrarySandboxError(
          'transfer of $totalBytes bytes exceeds the ${ReaderConfig.maxTransferBytes} byte cap');
    }
  }

  /// Filename for local storage. Flattened so nested paths cannot collide with
  /// the app's own files, and stripped of separators.
  String localFileName(String serverId, String relativePath) {
    final safe = relativePath
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return '${serverId}_$safe';
  }

  /// Sanity check on decoded content before it is written to disk.
  Uint8List validateContent(Uint8List bytes, {required int declaredSize}) {
    if (bytes.isEmpty) {
      throw const LibrarySandboxError('server returned an empty file');
    }
    if (bytes.length > ReaderConfig.maxFileBytes) {
      throw LibrarySandboxError(
          'file is ${bytes.length} bytes, cap is ${ReaderConfig.maxFileBytes}');
    }
    if (declaredSize > 0 && bytes.length > declaredSize * 2 + 1024) {
      throw LibrarySandboxError(
          'size mismatch: declared $declaredSize but received ${bytes.length}');
    }
    return bytes;
  }
}
