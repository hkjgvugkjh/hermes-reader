// 确定性验证：待处理事项弹层的"会话内容"数据链路。
//
// 不依赖 Flutter/真机 UI：起一个本地 mock HTTP server，把【真实185后端】
// 的 session context 响应（/tmp/ctx185.json，经隧道 curl 取得）原样返回，
// 再用与 HermesApiClient.getSessionMessages 完全相同的解析逻辑
// （hermes_api_client.dart:185-218）转成 ChatMessage 列表并断言。
//
// 目的：确证"会话内容"折叠区拿到的数据能正确解析（role/content/timestamp）。
// 真机端到端点开验证受限于当前待办 serverId 为空，故用此离线链路闭环。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

// —— 复制自 lib/reader/models/hive_models.dart ChatMessage 的最小构造 ——
class ChatMessage {
  final String role;
  final String content;
  final DateTime timestamp;
  ChatMessage(
      {required this.role, required this.content, required this.timestamp});
}

// —— 复制自 hermes_api_client.dart:185 getSessionMessages 的解析内核 ——
Future<List<ChatMessage>> parseSessionMessages(String body) async {
  final data = jsonDecode(body) as Map<String, dynamic>;
  final msgs = data['messages'] as List? ?? [];
  final messages = <ChatMessage>[];
  for (final m in msgs) {
    final mm = m as Map<String, dynamic>;
    messages.add(ChatMessage(
      role: mm['role'] as String? ?? 'unknown',
      content: mm['content'] as String? ?? '',
      timestamp: mm['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (mm['timestamp'] as num).toInt() * 1000)
          : DateTime.now(),
    ));
  }
  return messages;
}

void main() async {
  // 读取真实185 context 响应
  final realJson = File('/tmp/ctx185.json').readAsStringSync();
  final realMap = jsonDecode(realJson) as Map<String, dynamic>;
  final expectedCount = realMap['message_count'] as int;

  // 起 mock server 返回真实响应
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(realJson);
    await req.response.close();
  });
  final port = server.port;

  // 模拟 dialog 调用 client.getSessionMessages(sessionId)
  final req = await HttpClient()
      .get('127.0.0.1', port, '/api/hermes/sessions/test-session/context');
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  final messages = await parseSessionMessages(body);

  // 断言
  final errors = <String>[];
  if (messages.length != expectedCount) {
    errors.add('消息数不符: 期望 $expectedCount, 实际 ${messages.length}');
  }
  if (messages.isEmpty) errors.add('消息列表为空');
  if (messages.first.role != 'user') {
    errors.add('首条 role 应为 user, 实际 ${messages.first.role}');
  }
  final ts = messages.first.timestamp;
  if (ts.year < 2000) errors.add('首条 timestamp 解析异常: $ts');

  // 找一条非空 content 的消息（真实对话里多数 assistant content 为空，验证 user 侧有内容）
  final withContent = messages.where((m) => m.content.trim().isNotEmpty).toList();
  if (withContent.isEmpty) errors.add('无任何非空 content 消息');

  await server.close();

  if (errors.isNotEmpty) {
    print('FAIL:');
    for (final e in errors) print('  - $e');
    exit(1);
  }
  print('PASS: 会话内容数据链路验证通过');
  print('  消息总数 = $expectedCount');
  print('  首条 role=${messages.first.role} timestamp=${messages.first.timestamp}');
  print('  非空内容消息数 = ${withContent.length} (示例: "${withContent.first.content.substring(0, (withContent.first.content.length).clamp(0, 30))}")');
}
