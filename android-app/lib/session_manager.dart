import 'package:flutter/foundation.dart';

import 'models.dart';

/// ============ 会话（多对话）全局管理单例 ============
/// 供聊天页 + 左侧抽屉共用同一份会话状态；改动会 notifyListeners 触发 UI 刷新。
class SessionManager extends ChangeNotifier {
  SessionManager._();
  static final SessionManager instance = SessionManager._();

  final List<Conversation> _conversations = [];
  String? _currentId;
  bool _loaded = false;

  List<Conversation> get conversations => List.unmodifiable(_conversations);
  String? get currentId => _currentId;

  Conversation? get current {
    if (_currentId == null) return null;
    for (final c in _conversations) {
      if (c.id == _currentId) return c;
    }
    return null;
  }

  /// 按会话 id 查找：回复/错误路由到"来源会话"，而不是此刻打开的会话
  Conversation? byId(String id) {
    for (final c in _conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 启动时加载本地保存的会话（只加载一次）
  Future<void> load() async {
    if (_loaded) return;
    final list = await ConversationStore.loadAll();
    _conversations
      ..clear()
      ..addAll(list);
    if (_conversations.isNotEmpty) _currentId = _conversations.first.id;
    _loaded = true;
    notifyListeners();
  }

  /// 确保存在当前会话（无则自动新建一个），返回当前会话
  Conversation ensureCurrent() {
    if (current != null) return current!;
    final c = Conversation(
        id: '${DateTime.now().microsecondsSinceEpoch}', title: '新对话');
    _conversations.insert(0, c);
    _currentId = c.id;
    persist();
    notifyListeners();
    return c;
  }

  Conversation newConversation() {
    final c = Conversation(
        id: '${DateTime.now().microsecondsSinceEpoch}', title: '新对话');
    _conversations.insert(0, c);
    _currentId = c.id;
    persist();
    notifyListeners();
    return c;
  }

  void delete(String id) {
    _conversations.removeWhere((c) => c.id == id);
    if (_currentId == id) {
      _currentId = _conversations.isNotEmpty ? _conversations.first.id : null;
    }
    persist();
    notifyListeners();
  }

  void switchTo(String id) {
    if (_conversations.any((c) => c.id == id)) {
      _currentId = id;
      notifyListeners();
    }
  }

  void updateTitle(String title) {
    final cur = current;
    if (cur != null) {
      cur.title = title;
      persist();
      notifyListeners();
    }
  }

  Future<void> persist() async {
    await ConversationStore.saveAll(_conversations);
  }
}
