import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/server_provider.dart';
import '../providers/session_provider.dart';
import '../services/notification_service.dart';
import '../services/session_monitor_service.dart';

/// Full-screen session monitoring UI.
class SessionMonitorScreen extends StatefulWidget {
  const SessionMonitorScreen({super.key});

  @override
  State<SessionMonitorScreen> createState() => _SessionMonitorScreenState();
}

class _SessionMonitorScreenState extends State<SessionMonitorScreen> {
  final _notificationSvc = NotificationService();

  @override
  void initState() {
    super.initState();
    _notificationSvc.init();
  }

  @override
  void dispose() {
    _notificationSvc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionProvider = context.watch<SessionProvider>();
    final serverProvider = context.watch<ServerProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('会话监控'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '立即刷新',
            onPressed: () async {
              for (final target in sessionProvider.monitor.targets) {
                await sessionProvider.pollNow(target.serverId);
              }
            },
          ),
          IconButton(
            icon: sessionProvider.isMonitoring
                ? const Icon(Icons.pause)
                : const Icon(Icons.play_arrow),
            tooltip: sessionProvider.isMonitoring ? '暂停' : '开始',
            onPressed: () async {
              if (sessionProvider.isMonitoring) {
                await sessionProvider.stop();
              } else {
                await sessionProvider.start();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: '清空历史',
            onPressed: sessionProvider.clearHistory,
          ),
        ],
      ),
      body: Column(
        children: [
          if (serverProvider.servers.isNotEmpty)
            _ServerToggleList(
              servers: serverProvider.servers,
              monitor: sessionProvider.monitor,
              onToggle: (serverId, enabled) {
                if (enabled) {
                  final server = serverProvider.servers
                      .firstWhere((s) => s.id == serverId);
                  sessionProvider.addServer(MonitorTarget(
                    serverId: serverId,
                    baseUrl: server.baseUrl,
                    authToken: server.authToken,
                  ));
                } else {
                  sessionProvider.removeServer(serverId);
                }
              },
            ),
          const Divider(height: 1),
          Expanded(
            child: sessionProvider.recentChanges.isEmpty
                ? Center(
                    child: Text(
                      '暂无变更事件',
                      style: TextStyle(color: theme.disabledColor),
                    ),
                  )
                : ListView.builder(
                    itemCount: sessionProvider.recentChanges.length,
                    itemBuilder: (context, index) {
                      final change = sessionProvider.recentChanges[index];
                      return _ChangeTile(change: change);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ServerToggleList extends StatelessWidget {
  final List servers;
  final SessionMonitorService monitor;
  final void Function(String serverId, bool enabled) onToggle;

  const _ServerToggleList({
    required this.servers,
    required this.monitor,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          for (final server in servers)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(server.name, style: const TextStyle(fontSize: 12)),
                selected: monitor.targets
                    .any((t) => t.serverId == server.id),
                onSelected: (v) => onToggle(server.id, v),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChangeTile extends StatelessWidget {
  final SessionChange change;

  const _ChangeTile({required this.change});

  IconData get _icon {
    switch (change.kind) {
      case SessionChangeKind.sessionStarted:
        return Icons.play_circle;
      case SessionChangeKind.sessionStopped:
        return Icons.stop_circle;
      case SessionChangeKind.sessionNeedsInput:
        return Icons.help_outline;
      case SessionChangeKind.sessionResumed:
        return Icons.replay_circle_filled;
      case SessionChangeKind.authRequired:
        return Icons.lock;
      case SessionChangeKind.serverError:
        return Icons.error;
    }
  }

  Color _color(ThemeData theme) {
    switch (change.kind) {
      case SessionChangeKind.sessionStarted:
        return Colors.green;
      case SessionChangeKind.sessionStopped:
        return theme.disabledColor;
      case SessionChangeKind.sessionNeedsInput:
        return Colors.orange;
      case SessionChangeKind.sessionResumed:
        return Colors.blue;
      case SessionChangeKind.authRequired:
        return Colors.red;
      case SessionChangeKind.serverError:
        return Colors.red;
    }
  }

  String get _title {
    switch (change.kind) {
      case SessionChangeKind.sessionStarted:
        return '会话启动';
      case SessionChangeKind.sessionStopped:
        return '会话停止';
      case SessionChangeKind.sessionNeedsInput:
        return '需要处理';
      case SessionChangeKind.sessionResumed:
        return '会话恢复';
      case SessionChangeKind.authRequired:
        return '授权失效';
      case SessionChangeKind.serverError:
        return '服务器异常';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = change.after?.title ?? change.before?.title ?? '未知会话';
    final body = '${change.serverId} · $_title';

    return ListTile(
      leading: Icon(_icon, color: _color(theme)),
      title: Text(title),
      subtitle: Text(body),
      trailing: Text(
        _formatTime(change.detectedAt),
        style: TextStyle(color: theme.disabledColor, fontSize: 11),
      ),
    );
  }

  static String _formatTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    return '${diff.inDays}天前';
  }
}
