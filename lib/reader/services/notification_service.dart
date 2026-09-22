import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'session_monitor_service.dart';

/// Shows local notifications when monitored sessions change.
///
/// Usage:
///   final svc = NotificationService();
///   await svc.init();
///   svc.handleChange(change);
class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _inited = false;
  int _nextId = 0;

  /// Callback invoked when a notification is tapped. Set by the app to
  /// navigate to the relevant session.
  void Function(String? payload)? onNotificationTap;

  Future<void> init() async {
    if (_inited) return;
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        // Handle notification tap
        onNotificationTap?.call(response.payload);
      },
    );
    if (Platform.isAndroid) {
      await _requestPermission();
    }
    _inited = true;
  }

  Future<void> _requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /// Display a notification for a session change, if applicable.
  void handleChange(SessionChange change) {
    if (!_inited) return;
    switch (change.kind) {
      case SessionChangeKind.sessionStarted:
        notifyWithSession(
          '新会话启动',
          change.after?.title ?? '未知会话',
          change.serverId,
          change.after?.id ?? '',
        );
        break;
      case SessionChangeKind.sessionStopped:
        notifyWithSession(
          '会话已停止',
          change.before?.title ?? change.after?.title ?? '未知会话',
          change.serverId,
          change.after?.id ?? change.before?.id ?? '',
        );
        break;
      case SessionChangeKind.sessionNeedsInput:
        notifyWithSession(
          '会话需要处理',
          change.after?.title ?? '未知会话',
          change.serverId,
          change.after?.id ?? '',
        );
        break;
      case SessionChangeKind.sessionResumed:
        notifyWithSession(
          '会话已恢复',
          change.after?.title ?? '未知会话',
          change.serverId,
          change.after?.id ?? '',
        );
        break;
      case SessionChangeKind.authRequired:
        _notify(
          '授权失效',
          '服务器 ${change.serverId} 需要重新登录',
          '请打开应用输入凭据',
        );
        break;
      case SessionChangeKind.serverError:
        _notify(
          '服务器异常',
          '服务器 ${change.serverId} 连接失败',
          '请检查网络或服务器状态',
        );
        break;
    }
  }

  void _notify(String title, String body, String payload) {
    const androidDetails = AndroidNotificationDetails(
      'hermes_sessions',
      '会话监控',
      channelDescription: '监控 Hermes 服务器会话状态变更',
      importance: Importance.high,
      priority: Priority.high,
    );
    _plugin.show(
      _nextId++,
      title,
      body,
      const NotificationDetails(android: androidDetails),
      payload: payload,
    );
  }

  /// Display a notification with session info encoded in payload.
  ///
  /// The payload format is `serverId:sessionId` so the app can navigate to
  /// the correct session when the notification is tapped.
  void notifyWithSession(String title, String body, String serverId, String sessionId) {
    _notify(title, body, '$serverId:$sessionId');
  }

  void dispose() {
    if (_inited) {
      _plugin.cancelAll();
    }
  }
}
