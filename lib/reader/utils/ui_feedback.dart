import 'package:flutter/material.dart';

import '../providers/debug_logger.dart';
import 'error_messages.dart';

/// Central place for surfacing errors and messages to the user.
///
/// Errors are converted with [describeError] so the user sees a friendly
/// Chinese sentence, while the full technical detail is written to the log
/// file (see [DebugLogger]).
class UiFeedback {
  UiFeedback._();

  /// Shows a friendly error SnackBar and logs the technical detail.
  ///
  /// Returns the [FriendlyError] so callers can branch on [ErrorKind]
  /// (e.g. offer a retry action for [ErrorKind.network]).
  static FriendlyError showError(
    BuildContext context,
    Object error, {
    String? context_, // e.g. "加载会话" — prefixed for the log only
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final fe = describeError(error);
    DebugLogger.instance.error(
      context_ != null ? '$context_失败' : '操作失败',
      fe.detail.isEmpty ? fe.message : '${fe.message} :: ${fe.detail}',
    );

    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.clearSnackBars();
    messenger?.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(_iconFor(fe.kind), color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(fe.message)),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: (actionLabel != null && onAction != null)
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
      ),
    );
    return fe;
  }

  /// Shows a neutral informational message (no error styling).
  static void showInfo(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.clearSnackBars();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  static IconData _iconFor(ErrorKind kind) {
    switch (kind) {
      case ErrorKind.network:
        return Icons.wifi_off;
      case ErrorKind.disconnected:
        return Icons.link_off;
      case ErrorKind.server:
        return Icons.cloud_off;
      case ErrorKind.timeout:
        return Icons.hourglass_empty;
      case ErrorKind.unknown:
        return Icons.error_outline;
    }
  }
}
