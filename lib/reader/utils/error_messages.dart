import 'dart:async';
import 'dart:io';

/// Turns raw exceptions into short, friendly Chinese messages suitable for
/// showing to end users, while keeping the raw diagnostic text available for
/// the log file.
///
/// The goal: a user should never see `WebSocketChannelException: ...` or
/// `SocketException: OS Error: Connection refused, errno = 111` on screen.
/// They see "网络连接失败，请检查网络后重试"; the raw text goes to the log.
class FriendlyError {
  /// Short, human-facing message (safe to show in a SnackBar / dialog).
  final String message;

  /// Technical detail for the log file (may be empty).
  final String detail;

  /// Classifies the failure so callers can react (e.g. offer "重试").
  final ErrorKind kind;

  const FriendlyError(this.message, this.detail, this.kind);

  @override
  String toString() => message;
}

/// Coarse failure categories, used to pick icons/actions in the UI.
enum ErrorKind {
  /// No network / can't reach the host at all.
  network,

  /// The connection dropped mid-flight (network changed, server restarted).
  disconnected,

  /// The server answered, but with an error.
  server,

  /// Timed out waiting for a response.
  timeout,

  /// Something else (parsing, unexpected).
  unknown,
}

/// Maps an arbitrary [error] (exception or string) to a [FriendlyError].
FriendlyError describeError(Object error) {
  final raw = error.toString();
  final detail = _clean(raw);

  // Typed exceptions first — most reliable signal.
  if (error is TimeoutException) {
    return FriendlyError('请求超时，网络可能不稳定，请稍后重试', detail, ErrorKind.timeout);
  }
  if (error is SocketException) {
    return FriendlyError(_socketMessage(raw), detail, ErrorKind.network);
  }
  if (error is HttpException) {
    return FriendlyError('服务器响应异常，请稍后重试', detail, ErrorKind.server);
  }
  if (error is HandshakeException) {
    return FriendlyError('安全连接建立失败，请检查网络环境', detail, ErrorKind.network);
  }

  // Fall back to matching well-known fragments from lower layers
  // (web_socket_channel and the OS wrap SocketException as plain strings).
  final lower = raw.toLowerCase();
  if (lower.contains('failed host lookup') ||
      lower.contains('no address associated') ||
      lower.contains('nodename nor servname')) {
    return FriendlyError('无法解析服务器地址，请检查网络或代理设置', detail, ErrorKind.network);
  }
  if (lower.contains('connection refused')) {
    return FriendlyError('无法连接到服务器，服务可能未启动', detail, ErrorKind.network);
  }
  if (lower.contains('connection reset') ||
      lower.contains('broken pipe') ||
      lower.contains('software caused connection abort')) {
    return FriendlyError('连接被中断（网络可能已切换），请重试', detail, ErrorKind.disconnected);
  }
  if (lower.contains('connection closed') ||
      lower.contains('connection terminated') ||
      lower.contains('socket has been disconnected')) {
    return FriendlyError('与服务器的连接已断开，正在尝试恢复', detail, ErrorKind.disconnected);
  }
  if (lower.contains('timed out') || lower.contains('timeout')) {
    return FriendlyError('请求超时，网络可能不稳定，请稍后重试', detail, ErrorKind.timeout);
  }
  if (lower.contains('network is unreachable') ||
      lower.contains('network unreachable')) {
    return FriendlyError('当前网络不可用，请检查网络连接', detail, ErrorKind.network);
  }
  if (lower.contains('tls') || lower.contains('certificate')) {
    return FriendlyError('安全连接建立失败，请检查网络环境', detail, ErrorKind.network);
  }

  // Server-side HTTP errors surfaced as strings.
  final status = _httpStatus(lower);
  if (status != null) {
    return FriendlyError(_httpMessage(status), detail, ErrorKind.server);
  }

  return FriendlyError('出现错误，请重试；若持续失败可在日志中查看详情', detail, ErrorKind.unknown);
}

String _socketMessage(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('refused')) return '无法连接到服务器，服务可能未启动';
  if (lower.contains('unreachable')) return '当前网络不可用，请检查网络连接';
  if (lower.contains('reset') || lower.contains('broken pipe')) {
    return '连接被中断（网络可能已切换），请重试';
  }
  if (lower.contains('failed host lookup') || lower.contains('address')) {
    return '无法解析服务器地址，请检查网络或代理设置';
  }
  return '网络连接失败，请检查网络后重试';
}

int? _httpStatus(String lower) {
  final m = RegExp(r'(?:http|status|code)\D{0,3}(\d{3})').firstMatch(lower);
  if (m != null) return int.tryParse(m.group(1)!);
  return null;
}

String _httpMessage(int code) {
  if (code == 401 || code == 403) return '登录已失效，请重新登录';
  if (code == 404) return '请求的资源不存在';
  if (code >= 500) return '服务器暂时不可用，请稍后重试';
  return '服务器返回错误（$code），请稍后重试';
}

/// Strips noisy prefixes so the log stays readable.
String _clean(String raw) {
  var s = raw;
  for (final p in const [
    'Exception: ',
    'WebSocketChannelException: ',
    'SocketException: ',
    'HttpException: ',
    'HandshakeException: ',
  ]) {
    if (s.startsWith(p)) s = s.substring(p.length);
  }
  return s.trim();
}
