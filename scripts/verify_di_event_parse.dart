// 仿真验证：proxy 实际下发的 0x3B / 0x39 payload 形状被 reader 解析逻辑正确消费。
//
// 复刻 session_provider.dart 中 _onDIEvent / _onDIAuthRequest 修复后的解析分支，
// 喂入 proxy (studio_adapter.go) 真实广播的 payload 形状，确认字段能被提取、
// 任务能被加入「待处理事项」列表。
//
// 运行: dart scripts/verify_di_event_parse.dart

import 'dart:convert';

class TaskItem {
  TaskItem({
    required this.id,
    required this.title,
    required this.description,
    required this.serverId,
    this.choices = const <String>[],
  });
  final String id;
  final String title;
  final String description;
  final String serverId;
  final List<String> choices;
}

final List<TaskItem> tasks = [];

void onDIEvent(Map<String, dynamic> event) {
  final eventName = (event['event'] ?? '').toString();
  if (eventName != 'clarify.requested') return;

  // 修复后逻辑：兼容 data 为嵌套 JSON 字符串
  dynamic data = event['data'];
  if (data is String) {
    try {
      data = jsonDecode(data);
    } catch (_) {
      print('[DI] clarify.requested data 非合法 JSON');
      return;
    }
  }
  if (data is! Map) {
    print('[DI] clarify.requested data 非 Map');
    return;
  }
  final dataMap = Map<String, dynamic>.from(data);

  final sessionId = (dataMap['session_id'] ?? '').toString();
  final clarifyId =
      (dataMap['clarify_id'] ?? dataMap['id'] ?? '').toString();
  final question =
      (dataMap['question'] ?? dataMap['text'] ?? '').toString();
  final choicesRaw = dataMap['choices'];
  final choices = choicesRaw is List
      ? choicesRaw.map((e) => e.toString()).toList()
      : <String>[];

  if (clarifyId.isEmpty) return;

  tasks.add(TaskItem(
    id: clarifyId,
    title: question.isNotEmpty ? question : '需要您确认',
    description: '来自会话 $sessionId 的确认请求',
    serverId: sessionId,
    choices: choices,
  ));
  print('[DI] clarify 已入列表: id=$clarifyId session=$sessionId '
      'question="$question" choices=$choices');
}

void onDIAuthRequest(Map<String, dynamic> req) {
  final sessionId = (req['session_id'] ?? '').toString();
  final prompt = (req['prompt'] ?? '需要您确认').toString();
  final reqId = (req['req_id'] ?? req['id'] ?? '').toString();
  final id = reqId.isNotEmpty ? reqId : '${sessionId}_${prompt.hashCode}';
  if (id.isEmpty) return;
  final choicesRaw = req['choices'];
  final choices = choicesRaw is List
      ? choicesRaw.map((e) => e.toString()).toList()
      : <String>[];

  tasks.add(TaskItem(
    id: id,
    title: prompt.length > 20 ? prompt.substring(0, 20) : prompt,
    description: prompt,
    serverId: sessionId,
    choices: choices,
  ));
  print('[DI] auth 已入列表: id=$id session=$sessionId prompt="$prompt" '
      'choices=$choices');
}

void main() {
  // 1) proxy 真实 0x3B clarify.requested: data 是嵌套 JSON 字符串
  final clarifyEvent = <String, dynamic>{
    'direction': 'down',
    'event': 'clarify.requested',
    'data': jsonEncode({
      'session_id': 'sess-abc-123',
      'clarify_id': 'cf-999',
      'question': '选择哪个方案继续执行？',
      'choices': ['方案A', '方案B'],
      'timeout_ms': 60000,
    }),
  };
  onDIEvent(clarifyEvent);

  // 2) proxy 真实 0x39 auth: 只有 session_id + prompt + choices，无 req_id
  final authReq = <String, dynamic>{
    'session_id': 'sess-abc-123',
    'prompt': 'mcu.reauth.required',
    'choices': ['确认', '取消'],
  };
  onDIAuthRequest(authReq);

  // 3) 边界: data 已是 Map（平铺，某些版本 proxy）
  final clarifyMap = <String, dynamic>{
    'event': 'clarify.requested',
    'data': {
      'session_id': 'sess-xyz',
      'clarify_id': 'cf-1000',
      'question': '确定删除？',
    },
  };
  onDIEvent(clarifyMap);

  print('\n=== 验证结果 ===');
  print('列表任务数: ${tasks.length}');
  assert(tasks.length == 3, '应有 3 条任务');
  assert(tasks.any((t) => t.id == 'cf-999'), 'clarify 字符串 data 应入列表');
  assert(tasks.any((t) => t.id.startsWith('sess-abc-123_')),
      'auth 无 req_id 应回退 id 入列表');
  assert(tasks.any((t) => t.id == 'cf-1000'), 'clarify Map data 应入列表');
  print('全部断言通过 ✅');
}
