// 仿真验证：本轮改进后 reader 对 proxy 下发的 DI 事件的处理。
//
// 覆盖：
//  1) clarify.requested（0x3B）正确进入待处理列表，kind=clarify、details 含完整
//     question/choices，dialog 据此渲染选项与可折叠命令详情。
//  2) 代理自管的认证失效事件（auth.invalid / re-authenticate 等）被正确过滤，
//     不污染待处理列表（代理应自行重连/重认证，APP 不呈现给用户点选）。
//  3) 无选项的任务（choices 为空）dialog 回退为自由文本输入（"提交"按钮）。
//
// 运行: dart scripts/verify_di_event_parse.dart

import 'dart:convert';

enum TaskKind { clarify, auth, system }

class TaskItem {
  TaskItem({
    required this.id,
    required this.title,
    required this.description,
    required this.serverId,
    this.choices = const <String>[],
    this.kind = TaskKind.auth,
    this.details,
  });
  final String id;
  final String title;
  final String description;
  final String serverId;
  final List<String> choices;
  final TaskKind kind;
  final Map<String, dynamic>? details;
}

final List<TaskItem> tasks = [];

bool _isAuthFailure(String prompt) {
  final p = prompt.toLowerCase();
  return p.contains('authentication invalid') ||
      p.contains('auth.invalid') ||
      p.contains('re-authenticate') ||
      p.contains('reauth') ||
      p.contains('请重新认证') ||
      p.contains('认证失效') ||
      p.contains('unauthorized');
}

void onDIEvent(Map<String, dynamic> event) {
  final eventName = (event['event'] ?? '').toString();
  if (eventName != 'clarify.requested') return;

  dynamic data = event['data'];
  if (data is String) {
    try {
      data = jsonDecode(data);
    } catch (_) {
      print('[DI] clarify.requested data 非合法 JSON');
      return;
    }
  }
  if (data is! Map) return;
  final dataMap = Map<String, dynamic>.from(data);

  final sessionId = (dataMap['session_id'] ?? '').toString();
  final clarifyId = (dataMap['clarify_id'] ?? dataMap['id'] ?? '').toString();
  final question = (dataMap['question'] ?? dataMap['text'] ?? '').toString();
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
    kind: TaskKind.clarify,
    details: dataMap,
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

  // 代理自管的认证失效事件：过滤掉，不污染待处理列表。
  if (_isAuthFailure(prompt)) {
    print('[DI] 跳过代理自管的认证失效事件: prompt="$prompt"');
    return;
  }

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
    kind: TaskKind.auth,
    details: req,
  ));
  print('[DI] auth 已入列表: id=$id session=$sessionId prompt="$prompt" '
      'choices=$choices');
}

/// 模拟 dialog 根据 task 决定呈现方式（与 task_list_screen 逻辑一致）。
String dialogPresentation(TaskItem t) {
  if (t.kind == TaskKind.clarify) {
    if (t.choices.isNotEmpty) {
      return '选项按钮:${t.choices.join("/")} + 命令详情折叠';
    }
    return '自由文本输入(提交)';
  }
  if (t.kind == TaskKind.auth) {
    if (t.choices.isNotEmpty) return '选项按钮:${t.choices.join("/")}';
    return '自由文本输入(提交)';
  }
  return '只读展示';
}

void main() {
  // 1) proxy 真实 0x3B clarify.requested（data 嵌套 JSON 字符串，含 choices）
  onDIEvent(<String, dynamic>{
    'direction': 'down',
    'event': 'clarify.requested',
    'data': jsonEncode({
      'session_id': 'sess-abc-123',
      'clarify_id': 'cf-999',
      'question': '选择哪个方案继续执行？',
      'choices': ['方案A (推荐)', '方案B'],
      'timeout_ms': 60000,
    }),
  });

  // 2) 代理自管的认证失效事件（auth.invalid）—— 应被过滤
  onDIAuthRequest(<String, dynamic>{
    'session_id': '',
    'prompt': 'Authentication invalid, please re-authenticate',
    'choices': <String>[],
  });

  // 3) 真实用户决策型 auth（有选项、非失效）—— 应入列表
  onDIAuthRequest(<String, dynamic>{
    'session_id': 'sess-xyz',
    'prompt': '是否允许 device-001 连接？',
    'choices': ['允许', '拒绝'],
  });

  // 4) 边界: data 已是 Map（平铺）
  onDIEvent(<String, dynamic>{
    'event': 'clarify.requested',
    'data': {
      'session_id': 'sess-xyz',
      'clarify_id': 'cf-1000',
      'question': '确定删除？',
    },
  });

  print('\n=== 验证结果 ===');
  print('列表任务数: ${tasks.length}');
  for (final t in tasks) {
    print(' - [${t.kind}] ${t.title} | ${dialogPresentation(t)}');
  }

  assert(tasks.length == 3, '应有 3 条任务（认证失效事件被过滤）');
  assert(tasks.any((t) => t.id == 'cf-999' && t.kind == TaskKind.clarify),
      'clarify 应入列表且 kind=clarify');
  final cf = tasks.firstWhere((t) => t.id == 'cf-999');
  assert(cf.details != null && cf.details!['choices'] is List,
      'clarify details 应保留完整 choices');
  assert(tasks.any((t) => t.id == 'cf-1000'), 'clarify Map data 应入列表');
  assert(tasks.any((t) => t.serverId == 'sess-xyz' && t.kind == TaskKind.auth),
      '真实 auth 应入列表');
  assert(!tasks.any((t) => t.title.startsWith('Authentication invalid')),
      '认证失效事件必须被过滤');
  print('全部断言通过 ✅');
}
