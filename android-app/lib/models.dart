import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ============ 消息模型 ============
class ChatMsg {
  final String role; // user / assistant / system
  String text;
  // 统计/思考扩展字段（assistant 消息才有）
  String? reasoning; // 思考内容（可折叠显示）
  Map<String, dynamic>? usage; // {prompt, completion, total, cached}
  int? durationMs; // 生成耗时
  int? chars; // 数据量（字符数）
  String? model; // 使用的模型
  String? backend; // 使用的后端
  ChatMsg(this.role, this.text,
      {this.reasoning,
      this.usage,
      this.durationMs,
      this.chars,
      this.model,
      this.backend});

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        if (reasoning != null && reasoning!.isNotEmpty) 'reasoning': reasoning,
        if (usage != null) 'usage': usage,
        if (durationMs != null) 'duration_ms': durationMs,
        if (chars != null) 'chars': chars,
        if (model != null && model!.isNotEmpty) 'model': model,
        if (backend != null && backend!.isNotEmpty) 'backend': backend,
      };

  factory ChatMsg.fromJson(Map<String, dynamic> j) => ChatMsg(
        (j['role'] ?? '').toString(),
        (j['text'] ?? '').toString(),
        reasoning: (j['reasoning'] ?? '').toString(),
        usage: j['usage'] is Map
            ? Map<String, dynamic>.from(j['usage'] as Map)
            : null,
        durationMs: j['duration_ms'] is int ? j['duration_ms'] as int : null,
        chars: j['chars'] is int ? j['chars'] as int : null,
        model: (j['model'] ?? '').toString(),
        backend: (j['backend'] ?? '').toString(),
      );
}

/// ============ 会话（对话）模型 ============
class Conversation {
  String id;
  String title;
  String backendId; // 关联的后端
  String model; // 关联的模型
  // 服务端压缩偏移：被压成摘要的旧非 system 消息条数，
  // 用于把前端"第 N 条非 system 消息"换算成服务端历史序号
  int compressShift;
  final List<ChatMsg> messages;
  DateTime createdAt;
  Conversation({
    required this.id,
    required this.title,
    this.backendId = '',
    this.model = '',
    this.compressShift = 0,
    List<ChatMsg>? messages,
    DateTime? createdAt,
  })  : messages = messages ?? [],
        createdAt = createdAt ?? DateTime.now();

  String get displayTitle =>
      title.isNotEmpty ? title : (messages.isNotEmpty ? messages.first.text : '新对话');

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'backend_id': backendId,
        'model': model,
        'compress_shift': compressShift,
        'messages': messages.map((m) => m.toJson()).toList(),
        'created_at': createdAt.toIso8601String(),
      };

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: (j['id'] ?? DateTime.now().millisecondsSinceEpoch.toString()).toString(),
        title: (j['title'] ?? '').toString(),
        backendId: (j['backend_id'] ?? '').toString(),
        model: (j['model'] ?? '').toString(),
        compressShift: (j['compress_shift'] is int) ? j['compress_shift'] as int : 0,
        messages: (j['messages'] is List)
            ? ((j['messages'] as List)
                    .map((m) =>
                        ChatMsg.fromJson(Map<String, dynamic>.from(m as Map)))
                    .toList())
            : [],
        createdAt: j['created_at'] != null
            ? (DateTime.tryParse(j['created_at'].toString()) ?? DateTime.now())
            : DateTime.now(),
      );
}

/// ============ 会话本地持久化（存 JSON 文件） ============
class ConversationStore {
  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/conversations.json');
  }

  static Future<List<Conversation>> loadAll() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final data = await f.readAsString();
      final list = jsonDecode(data) as List;
      return list
          .map((c) => Conversation.fromJson(Map<String, dynamic>.from(c as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveAll(List<Conversation> list) async {
    try {
      final f = await _file();
      await f.writeAsString(
          jsonEncode(list.map((c) => c.toJson()).toList()),
          flush: true);
    } catch (_) {}
  }
}

/// ============ 设置持久化（本地 shared_preferences） ============
class SettingsStore {
  static const _host = 'host';
  static const _port = 'port';
  static const _model = 'model';
  static const _context = 'context';
  static const _voice = 'voice';
  static const _voiceEnabled = 'voice_enabled';
  static const _backendId = 'backend_id';
  static const _theme = 'theme';
  static const _lmGpuRatio = 'lm_gpu_ratio';
  static const _lmContext = 'lm_context';

  static Future<Map<String, dynamic>> load() async {
    final p = await SharedPreferences.getInstance();
    return {
      'host': p.getString(_host) ?? '',
      'port': p.getInt(_port) ?? 8765,
      'model': p.getString(_model) ?? '',
      'context': p.getInt(_context) ?? 4096,
      'voice': p.getString(_voice) ?? '',
      'voice_enabled': p.getBool(_voiceEnabled) ?? true,
      'backend_id': p.getString(_backendId) ?? '',
      'theme': p.getString(_theme) ?? 'light',
      'lm_gpu_ratio': p.getDouble(_lmGpuRatio) ?? 0.7,
      'lm_context': p.getInt(_lmContext) ?? 8192,
    };
  }

  static Future<void> saveString(String key, String value) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, value);
  }

  static Future<void> saveInt(String key, int value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(key, value);
  }

  static Future<void> saveDouble(String key, double value) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(key, value);
  }

  static Future<void> saveBool(String key, bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(key, value);
  }
}
