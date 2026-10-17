import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

import 'bridge_client.dart';
import 'models.dart';
import 'session_manager.dart';
import 'attachments.dart';

/// ============ 聊天页 ============
class ChatTab extends StatefulWidget {
  const ChatTab({super.key});
  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _voice = true;
  bool _sending = false;
  // 输入模式：0=键盘，1=语音（微信式切换）
  int _inputMode = 0;
  // 待发送附件（图片/文件），发送后清空
  final List<Map<String, dynamic>> _attachments = [];
  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  // 语音上滑取消（微信式）
  bool _slideToCancel = false;
  double _voiceStartY = 0;
  static const double _slideCancelThreshold = 70;
  int _contextLimit = 4096; // 当前后端上下文上限（用于顶部统计）
  StreamSubscription? _sttSub;
  StreamSubscription? _textSub;
  StreamSubscription? _errSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _backendActiveSub;
  StreamSubscription? _deltaSub;
  StreamSubscription? _compressedSub;
  // 当前流式生成中的 assistant 消息索引（null=无流式）；流式结束时用完整回复替换
  int? _streamIdx;

  List<ChatMsg> get _messages =>
      SessionManager.instance.current?.messages ?? const [];

  // 当前会话 id（用于协议按会话隔离）
  String get _curId => SessionManager.instance.current?.id ?? '';
  bool _lastConnected = false;

  // 会话↔后端绑定：与当前 active 不一致（用户切了模型/后端，或首次使用）时，
  // 重新绑定并把前端可见的非 system 历史"重放"进新后端桶——新后端立即拿到
  // 完整上下文，解决"切换模型/后端后聊天不连贯"。
  String _ensureBackend() {
    final cur = SessionManager.instance.current;
    if (cur == null) return '';
    final active = bridge.activeBackendId;
    if (active.isEmpty) return cur.backendId;
    if (cur.backendId != active) {
      cur.backendId = active;
      cur.compressShift = 0; // 重放后桶与前端可见消息一一对应
      SessionManager.instance.persist();
      _replayHistory(cur, active);
    }
    return cur.backendId;
  }

  void _replayHistory(Conversation conv, String bid) {
    final msgs = <Map<String, String>>[];
    for (final m in conv.messages) {
      if ((m.role == 'user' || m.role == 'assistant') && m.text.isNotEmpty) {
        msgs.add({'role': m.role, 'content': m.text});
      }
    }
    bridge.syncHistory(msgs, conversationId: conv.id, backendId: bid);
  }

  // 前端 messages 含 system 气泡；服务端历史只存 user/assistant，且最旧的
  // compressShift 条已被压缩成摘要移出。换算时两者都要扣除。
  int get _shift => SessionManager.instance.current?.compressShift ?? 0;

  // 保留前 keep 条（含 system）里，落在服务端可见范围的非 system 条数
  int _nsKeep(int keep) {
    final msgs = _messages;
    int n = 0;
    for (int i = 0; i < keep && i < msgs.length; i++) {
      if (msgs[i].role != 'system') n++;
    }
    n -= _shift;
    return n < 0 ? 0 : n;
  }

  // 前端第 idx 条消息对应服务端非 system 序列里的第几个（已扣压缩偏移）
  int _nsIndex(int idx) {
    final msgs = _messages;
    if (idx < 0 || idx >= msgs.length || msgs[idx].role == 'system') return -1;
    int n = 0;
    for (int i = 0; i < idx; i++) {
      if (msgs[i].role != 'system') n++;
    }
    n -= _shift;
    return n; // <0 表示该条已被压缩，服务端自动忽略
  }

  @override
  void initState() {
    super.initState();
    _loadVoicePref();
    SessionManager.instance.load();
    SessionManager.instance.addListener(_onSessionChanged);
    _contextLimit = _loadContextLimit();
    _textSub = bridge.onText.listen((r) {
      // 回复按来源会话投递：路由到 r.conversationId 对应会话，不是"此刻打开的"
      final conv = r.conversationId.isNotEmpty
          ? SessionManager.instance.byId(r.conversationId)
          : SessionManager.instance.current;
      if (conv == null) return;
      // 仅当正在查看该会话时才更新流式索引并刷新 UI
      final viewing = conv.id == _curId;
      if (viewing) {
        setState(() {
          if (_streamIdx != null && _streamIdx! < conv.messages.length) {
            conv.messages[_streamIdx!] = ChatMsg('assistant', r.text,
                reasoning: r.reasoning.isNotEmpty ? r.reasoning : null,
                usage: r.usage.isEmpty ? null : r.usage,
                durationMs: r.durationMs,
                chars: r.chars,
                model: r.model,
                backend: r.backend);
            _streamIdx = null;
          } else {
            conv.messages.add(ChatMsg('assistant', r.text,
                reasoning: r.reasoning.isNotEmpty ? r.reasoning : null,
                usage: r.usage.isEmpty ? null : r.usage,
                durationMs: r.durationMs,
                chars: r.chars,
                model: r.model,
                backend: r.backend));
          }
          _sending = false;
        });
      } else {
        // 后台会话：旧流式气泡可能已作废，直接移除占位再追加完整回复
        if (_streamIdx != null && _streamIdx! < conv.messages.length &&
            conv.messages[_streamIdx!].role == 'assistant' &&
            conv.messages[_streamIdx!].text.isEmpty) {
          conv.messages.removeAt(_streamIdx!);
        }
        conv.messages.add(ChatMsg('assistant', r.text,
            reasoning: r.reasoning.isNotEmpty ? r.reasoning : null,
            usage: r.usage.isEmpty ? null : r.usage,
            durationMs: r.durationMs,
            chars: r.chars,
            model: r.model,
            backend: r.backend));
        _sending = false;
      }
      SessionManager.instance.persist();
      if (viewing) _scrollDown();
    });
    // P1-5 流式增量：模型边生成边逐块追加渲染（仅渲染到来源会话且正在查看时）
    _deltaSub = bridge.onDelta.listen((ch) {
      final conv = ch.conversationId.isNotEmpty
          ? SessionManager.instance.byId(ch.conversationId)
          : SessionManager.instance.current;
      if (conv == null) return;
      final viewing = conv.id == _curId;
      if (viewing) {
        setState(() {
          if (_streamIdx == null || _streamIdx! >= conv.messages.length) {
            conv.messages.add(ChatMsg('assistant', ''));
            _streamIdx = conv.messages.length - 1;
          }
          final idx = _streamIdx!;
          final old = conv.messages[idx];
          conv.messages[idx] = ChatMsg('assistant',
              old.text + ch.text,
              reasoning: (old.reasoning ?? '') + ch.reasoning,
              usage: old.usage,
              durationMs: old.durationMs,
              chars: old.chars,
              model: old.model,
              backend: old.backend);
        });
        _scrollDown();
      } else if (_streamIdx == null ||
          _streamIdx! >= conv.messages.length) {
        // 后台流式：只占一次位，不刷 UI，等最终 text 事件替换
        conv.messages.add(ChatMsg('assistant', ''));
        _streamIdx = conv.messages.length - 1;
      }
    });
    _errSub = bridge.onError.listen((e) {
      // 错误按来源会话投递；无会话上下文的全局错误（连接类）投当前
      final conv = e.conversationId.isNotEmpty
          ? (SessionManager.instance.byId(e.conversationId) ??
              SessionManager.instance.ensureCurrent())
          : SessionManager.instance.ensureCurrent();
      final viewing = conv.id == _curId;
      if (viewing) {
        setState(() {
          conv.messages.add(ChatMsg('system', '⚠ ${e.message}'));
          _sending = false;
        });
      } else {
        conv.messages.add(ChatMsg('system', '⚠ ${e.message}'));
        _sending = false;
      }
      SessionManager.instance.persist();
      if (viewing) _scrollDown();
    });
    // 上下文压缩事件：后端把最旧对话压成概要后，顶部提示用户并记录偏移
    _compressedSub = bridge.onCompressed.listen((ci) {
      final conv = ci.conversationId.isNotEmpty
          ? SessionManager.instance.byId(ci.conversationId)
          : SessionManager.instance.current;
      if (conv != null && ci.rounds > 0) {
        conv.compressShift += ci.nsRemoved;
        SessionManager.instance.persist();
      }
      if (!mounted) return;
      if (ci.rounds > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已自动压缩 ${ci.rounds} 轮旧对话（剩余 ${ci.remaining} 条）'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });
    _statusSub = bridge.onStatus.listen((ok) {
      if (!mounted) return;
      setState(() {
        // 只在断开→重连成功时加一条系统提示，避免自动重连刷屏
        if (ok && !_lastConnected) {
          final cur = SessionManager.instance.ensureCurrent();
          cur.messages.add(ChatMsg('system', '已连接本地电脑'));
          SessionManager.instance.persist();
          _scrollDown();
        }
        _lastConnected = ok;
        if (!ok) _sending = false;
      });
    });
    _sttSub = bridge.onSttResult.listen((t) {
      if (t.trim().isNotEmpty) _sendText(t.trim());
    });
    _backendActiveSub = bridge.onBackendActive.listen((bid) {
      // 切换后端时更新上下文上限
      setState(() => _contextLimit = _loadContextLimit());
    });
  }

  int _loadContextLimit() {
    final bid = bridge.activeBackendId;
    for (final b in bridge.backends) {
      if (b['id'] == bid) {
        final s = (b['settings'] ?? const {}) as Map;
        final c = s['context'];
        if (c is num) return c.round();
      }
    }
    return 4096;
  }

  /// 切换会话：自动把当前后端/模型切到该会话记录的关联值
  void _onSessionChanged() {
    _streamIdx = null; // 切换会话时重置流式索引
    final cur = SessionManager.instance.current;
    if (cur != null) {
      // 接管该会话后台生成中的占位气泡（空 assistant 且无统计），避免重复占位
      if (cur.messages.isNotEmpty) {
        final last = cur.messages.last;
        if (last.role == 'assistant' &&
            last.text.isEmpty &&
            last.usage == null) {
          _streamIdx = cur.messages.length - 1;
        }
      }
      // 会话已绑定后端 → 全局 active 跟随会话；先乐观更新本地 active，
      // 避免紧随其后的 _ensureBackend 误判"用户换了后端"而错误重绑
      if (cur.backendId.isNotEmpty && cur.backendId != bridge.activeBackendId) {
        bridge.activeBackendId = cur.backendId;
        bridge.setBackend(cur.backendId);
      }
    }
    if (mounted) setState(() => _contextLimit = _loadContextLimit());
  }

  Future<void> _loadVoicePref() async {
    final s = await SettingsStore.load();
    if (mounted) setState(() => _voice = s['voice_enabled'] ?? true);
  }

  @override
  void dispose() {
    SessionManager.instance.removeListener(_onSessionChanged);
    _textSub?.cancel();
    _errSub?.cancel();
    _statusSub?.cancel();
    _sttSub?.cancel();
    _backendActiveSub?.cancel();
    _deltaSub?.cancel();
    _compressedSub?.cancel();
    _recorder.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  // ===== 普通发送 =====
  void _sendText(String text) {
    final t = text.trim();
    if (t.isEmpty && _attachments.isEmpty) return;
    if (!bridge.connected) {
      final cur = SessionManager.instance.ensureCurrent();
      setState(() => cur.messages.add(ChatMsg('system', '⚠ 未连接，请先在「设置」连接电脑')));
      SessionManager.instance.persist();
      _scrollDown();
      return;
    }
    final cur = SessionManager.instance.ensureCurrent();
    final att = List<Map<String, dynamic>>.from(_attachments);
    // 用户气泡里展示附件名，方便查看
    String display = t;
    if (att.isNotEmpty) {
      final names = att.map((a) => a['name']).join('、');
      display = t.isEmpty ? '[附件] $names' : '$t\n[附件] $names';
    }
    setState(() {
      cur.messages.add(ChatMsg('user', display));
      _sending = true;
      _input.clear();
      _attachments.clear();
    });
    SessionManager.instance.persist();
    bridge.sendChat(t,
        voice: _voice,
        conversationId: _curId,
        backendId: _ensureBackend(),
        attachments: att);
    _scrollDown();
  }

  // ===== 附件选择（图片/文件） =====
  Future<void> _pickAttachment() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('发送图片'),
              subtitle: const Text('从相册选择，模型需支持视觉才能识别'),
              onTap: () => Navigator.pop(ctx, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.description),
              title: const Text('发送文件'),
              subtitle: const Text('文本文件（txt/代码等），内容直接喂给模型'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    Map<String, dynamic>? a;
    if (choice == 'image') {
      a = await AttachmentPicker.pickImage();
    } else if (choice == 'file') {
      a = await AttachmentPicker.pickTextFile();
    }
    final picked = a;
    if (picked != null && mounted) {
      setState(() => _attachments.add(picked));
      // 有附件时切回键盘输入，方便补文字
      if (_inputMode != 0) setState(() => _inputMode = 0);
    }
  }

  void _send() => _sendText(_input.text);

  // ===== 截断重写（删除 index 及之后所有消息，前端+后端同步） =====
  void _truncateTo(int keep) {
    final nsKeep = _nsKeep(keep); // 换算：前 keep 条（含 system）里的非 system 条数
    final msgs = SessionManager.instance.ensureCurrent().messages;
    while (msgs.length > keep) {
      msgs.removeLast();
    }
    SessionManager.instance.persist();
    bridge.truncateHistory(nsKeep,
        conversationId: _curId, backendId: _ensureBackend());
  }

  // 播放
  void _play(ChatMsg m) {
    if (m.text.trim().isEmpty) return;
    if (!bridge.connected) {
      setState(() => SessionManager.instance.ensureCurrent()
          .messages.add(ChatMsg('system', '⚠ 未连接，请先在「设置」连接电脑')));
      SessionManager.instance.persist();
      _scrollDown();
      return;
    }
    bridge.sendTtsSpeak(m.text.trim());
  }

  // 重置某条 assistant：从该条截断，重新生成（原对话条目完成）
  void _regenerateAt(ChatMsg m, int index) {
    if (!bridge.connected) {
      setState(() => SessionManager.instance.ensureCurrent()
          .messages.add(ChatMsg('system', '⚠ 未连接，请先在「设置」连接电脑')));
      SessionManager.instance.persist();
      _scrollDown();
      return;
    }
    // 保留 index 条（删除该 assistant 及其后），最后一条是它前面的 user
    setState(() {
      _truncateTo(index);
      _sending = true;
    });
    bridge.regenerate(
        voice: _voice,
        conversationId: _curId,
        backendId: _ensureBackend());
  }

  // 重发一条用户消息：从该条截断，重新发送
  void _resendAt(ChatMsg m, int index) {
    if (!bridge.connected) {
      setState(() => SessionManager.instance.ensureCurrent()
          .messages.add(ChatMsg('system', '⚠ 未连接，请先在「设置」连接电脑')));
      SessionManager.instance.persist();
      _scrollDown();
      return;
    }
    setState(() {
      _truncateTo(index + 1); // 保留到该 user（前后端同步截断）
      _sending = true;
    });
    // resend=true：服务端替换同槽位的该 user（截断保留的那条），不再重复追加
    bridge.sendChat(m.text,
        voice: _voice,
        conversationId: _curId,
        backendId: _ensureBackend(),
        resend: true);
  }

  // 修改用户消息：编辑文本 → 截断 → 在原条目重发（不新建条目）
  Future<void> _editMessage(ChatMsg m, int index) async {
    final ctrl = TextEditingController(text: m.text);
    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改消息'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          decoration: const InputDecoration(hintText: '编辑内容...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (newText == null) return;
    final t = newText.trim();
    if (t.isEmpty || t == m.text) return;
    if (!bridge.connected) {
      setState(() => SessionManager.instance.ensureCurrent()
          .messages.add(ChatMsg('system', '⚠ 未连接，请先在「设置」连接电脑')));
      SessionManager.instance.persist();
      _scrollDown();
      return;
    }
    setState(() {
      _messages[index] = ChatMsg('user', t);
      _truncateTo(index + 1); // 保留到修改后的 user，删除其后
      _sending = true;
    });
    // 截断后服务端末尾是同槽位旧 user，resend 让它被新内容替换而非重复追加
    bridge.sendChat(t,
        voice: _voice,
        conversationId: _curId,
        backendId: _ensureBackend(),
        resend: true);
  }

  // 删除单条消息（只删该条，保留其余；后端同步删除对应位置）
  void _delete(ChatMsg m, int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息'),
        content: const Text('确定删除这条消息吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              final cur = SessionManager.instance.ensureCurrent();
              if (index >= 0 && index < cur.messages.length) {
                final nsIdx = _nsIndex(index); // system 气泡返回 -1，服务端自动忽略
                setState(() {
                  cur.messages.removeAt(index);
                  SessionManager.instance.persist();
                });
                bridge.deleteMessage(nsIdx,
                    conversationId: _curId, backendId: _ensureBackend());
              }
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  // 清空对话
  void _clearChat() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空对话'),
        content: const Text('确定清空当前对话内容吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _messages.clear();
                final cur = SessionManager.instance.current;
                if (cur != null) cur.compressShift = 0;
                SessionManager.instance.persist();
              });
              bridge.clearHistory(
                  conversationId: _curId, backendId: _ensureBackend());
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  // ===== 按住说话（STT 语音输入）=====
  Future<void> _startRecord() async {
    if (_recording) return;
    if (!bridge.connected) {
      setState(() => SessionManager.instance.ensureCurrent()
          .messages.add(ChatMsg('system', '⚠ 未连接，请先在「设置」连接电脑')));
      SessionManager.instance.persist();
      _scrollDown();
      return;
    }
    final perm = await _recorder.hasPermission();
    if (!perm) {
      setState(() => SessionManager.instance.ensureCurrent()
          .messages.add(ChatMsg('system', '⚠ 未获得录音权限')));
      SessionManager.instance.persist();
      _scrollDown();
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.wav),
          path: '${dir.path}/stt_${DateTime.now().millisecondsSinceEpoch}.wav');
      setState(() => _recording = true);
    } catch (e) {
      setState(() => SessionManager.instance.ensureCurrent()
          .messages.add(ChatMsg('system', '⚠ 录音启动失败: $e')));
      SessionManager.instance.persist();
      _scrollDown();
    }
  }

  Future<void> _stopRecord() async {
    if (!_recording) return;
    setState(() => _recording = false);
    try {
      final path = await _recorder.stop();
      if (path == null || path.isEmpty) return;
      final bytes = File(path).readAsBytesSync();
      if (bytes.isEmpty) return;
      bridge.sendSttStart();
      for (var i = 0; i < bytes.length; i += 65536) {
        final end = (i + 65536) > bytes.length ? bytes.length : (i + 65536);
        bridge.sendSttData(bytes.sublist(i, end));
      }
      bridge.sendSttEnd();
    } catch (e) {
      setState(() => SessionManager.instance.ensureCurrent()
          .messages.add(ChatMsg('system', '⚠ 语音识别失败: $e')));
      SessionManager.instance.persist();
      _scrollDown();
    }
  }

  // ===== 语音上滑取消（微信式）：按住说话时上滑可取消发送 =====
  void _voiceDown(PointerDownEvent e) {
    _voiceStartY = e.position.dy;
    if (_slideToCancel) setState(() => _slideToCancel = false);
    _startRecord();
  }

  void _voiceMove(PointerMoveEvent e) {
    if (!_recording) return;
    final up = (_voiceStartY - e.position.dy) > _slideCancelThreshold;
    if (up != _slideToCancel) setState(() => _slideToCancel = up);
  }

  Future<void> _voiceUp() async {
    if (!_recording) return;
    if (_slideToCancel) {
      await _cancelRecord();
    } else {
      await _stopRecord();
    }
    if (mounted && _slideToCancel) setState(() => _slideToCancel = false);
  }

  // 上滑取消：停录音、删文件，不发送
  Future<void> _cancelRecord() async {
    setState(() => _recording = false);
    try {
      final path = await _recorder.stop();
      if (path != null && path.isNotEmpty) {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      }
    } catch (_) {}
  }

  // ===== 统计 =====
  Map<String, int> _sessionStats() {
    int prompt = 0, completion = 0, cached = 0;
    for (final m in _messages) {
      if (m.usage != null) {
        prompt += (m.usage!['prompt'] ?? 0) as int;
        completion += (m.usage!['completion'] ?? 0) as int;
        cached += (m.usage!['cached'] ?? 0) as int;
      }
    }
    return {'prompt': prompt, 'completion': completion, 'cached': cached};
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _header(),
        if (_messages.isNotEmpty) _statsOverview(),
        Expanded(
          child: _messages.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('在下方输入消息，即可与本地电脑上的模型对话并播放语音',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey)),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length,
                  itemBuilder: (c, i) => _bubbleWithActions(_messages[i], i),
                ),
        ),
        _inputBar(),
      ],
    );
  }

  Widget _header() {
    final cur = SessionManager.instance.current;
    final title = cur != null && cur.title.isNotEmpty
        ? cur.title
        : (cur != null ? cur.displayTitle : '新对话');
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Builder(builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: '对话列表',
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          )),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
          StreamBuilder<bool>(
            stream: bridge.onStatus,
            initialData: bridge.connected,
            builder: (c, snap) {
              final ok = snap.data ?? false;
              return StreamBuilder<String>(
                stream: bridge.onBackendActive,
                initialData: bridge.activeBackendId,
                builder: (c, bsnap) {
                  final id = bsnap.data ?? '';
                  String name = '';
                  for (final b in bridge.backends) {
                    if (b['id'] == id) {
                      name = (b['name'] ?? '').toString();
                      break;
                    }
                  }
                  final text = ok ? (name.isEmpty ? '已连接' : name) : '未连接';
                  return Text(text,
                      style: TextStyle(
                          color: ok ? Colors.green : Colors.grey,
                          fontSize: 12,
                          fontWeight: FontWeight.w600));
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
            tooltip: '清空对话',
            onPressed: _messages.isEmpty ? null : _clearChat,
          ),
          Text('语音', style: const TextStyle(color: Colors.grey)),
          Switch(
            value: _voice,
            onChanged: (v) {
              setState(() => _voice = v);
              SettingsStore.saveBool('voice_enabled', v);
            },
          ),
        ],
      ),
    );
  }

  // 对话顶部上下文统计总览（含使用进度条 + 手动压缩按钮）
  Widget _statsOverview() {
    final st = _sessionStats();
    final used = st['prompt']! + st['completion']!;
    final color = Theme.of(context).colorScheme;
    final limit = _contextLimit <= 0 ? 4096 : _contextLimit;
    final ratio = (used / limit).clamp(0.0, 1.0);
    final over = used >= limit;
    final barColor = over
        ? Colors.redAccent
        : (ratio >= 0.8 ? Colors.orange : color.primary);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.data_usage, size: 16, color: color.primary),
              const SizedBox(width: 6),
              Text('上下文 $used/$limit', style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 10),
              Icon(Icons.storage, size: 16, color: color.primary),
              const SizedBox(width: 6),
              Text('命中 ${st["cached"]}', style: const TextStyle(fontSize: 12)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.compress, size: 18),
                tooltip: '压缩旧对话',
                visualDensity: VisualDensity.compact,
                onPressed: used == 0
                    ? null
                    : () => bridge.compressContext(
                        conversationId: _curId, backendId: _ensureBackend()),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 5,
              backgroundColor: color.surface,
              color: barColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(ChatMsg m, int index) {
    final isUser = m.role == 'user';
    final isSys = m.role == 'system';
    final color = Theme.of(context).colorScheme;
    Color bg;
    if (isSys) {
      bg = color.surfaceContainerHighest;
    } else if (isUser) {
      bg = color.primaryContainer;
    } else {
      bg = color.surfaceContainerHighest;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(top: 4, bottom: 2),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints:
                BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // 思考内容（可折叠）
                if (m.reasoning != null && m.reasoning!.isNotEmpty)
                  _thinkingBlock(m.reasoning!),
                Text(m.text),
              ],
            ),
          ),
        ),
        if (!isSys) _msgMetaLine(m, isUser),
      ],
    );
  }

  // 思考内容折叠块
  Widget _thinkingBlock(String reasoning) {
    final color = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: color.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.outlineVariant),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 10),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        leading: const Icon(Icons.psychology_outlined, size: 18),
        title: const Text('思考过程', style: TextStyle(fontSize: 12)),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(reasoning,
                style: TextStyle(fontSize: 12, color: color.outline)),
          ),
        ],
      ),
    );
  }

  // 消息统计行：耗时 + 数据量（字符/token）
  Widget _msgMetaLine(ChatMsg m, bool isUser) {
    final color = Theme.of(context).colorScheme.outline;
    final parts = <String>[];
    if (m.durationMs != null && m.durationMs! > 0) {
      parts.add('${(m.durationMs! / 1000).toStringAsFixed(1)}s');
    }
    if (m.usage != null) {
      final c = m.usage!['completion'] ?? 0;
      final p = m.usage!['prompt'] ?? 0;
      if (c is int && c > 0) parts.add('输出${c}t');
      if (p is int && p > 0) parts.add('输入${p}t');
    } else if (m.chars != null && m.chars! > 0) {
      parts.add('${m.chars}字');
    }
    if (m.model != null && m.model!.isNotEmpty) {
      parts.add(m.model!.split('/').last.split('\\').last);
    }
    if (parts.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(parts.join(' · '),
            style: TextStyle(fontSize: 10, color: color)),
      ),
    );
  }

  /// 每条消息下方的操作按钮
  List<Widget> _msgActions(ChatMsg m, int index) {
    final color = Theme.of(context).colorScheme.outline;
    final items = <Widget>[];
    items.add(_miniBtn(Icons.volume_up, '播放', color, () => _play(m)));
    if (m.role == 'assistant') {
      items.add(_miniBtn(Icons.refresh, '重置', color, () => _regenerateAt(m, index)));
    } else if (m.role == 'user') {
      items.add(_miniBtn(Icons.send, '重发', color, () => _resendAt(m, index)));
      items.add(_miniBtn(Icons.edit, '修改', color, () => _editMessage(m, index)));
    }
    items.add(_miniBtn(Icons.delete_outline, '删除', color, () => _delete(m, index)));
    return items;
  }

  Widget _miniBtn(IconData icon, String label, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 2),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }

  // 消息气泡 + 操作按钮（供 ListView 使用）
  Widget _bubbleWithActions(ChatMsg m, int index) {
    final isUser = m.role == 'user';
    final isSys = m.role == 'system';
    final bubble = _bubble(m, index);
    if (isSys) return bubble;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        bubble,
        Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: _msgActions(m, index),
            ),
          ),
        ),
      ],
    );
  }

  Widget _inputBar() {
    final theme = Theme.of(context);
    final sc = theme.colorScheme;
    final slideColor = _slideToCancel ? sc.error : sc.primary;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 待发送附件标签（可点 × 移除）
                if (_attachments.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SizedBox(
                      height: 36,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _attachments.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 6),
                        itemBuilder: (_, i) {
                          final a = _attachments[i];
                          return InputChip(
                            label: Text(a['name'].toString(),
                                overflow: TextOverflow.ellipsis),
                            avatar: Icon(
                                a['type'] == 'image'
                                    ? Icons.image
                                    : Icons.description,
                                size: 16),
                            onDeleted: () =>
                                setState(() => _attachments.removeAt(i)),
                          );
                        },
                      ),
                    ),
                  ),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(_inputMode == 0 ? Icons.keyboard : Icons.mic,
                      color: theme.colorScheme.primary),
                  tooltip: _inputMode == 0 ? '切换到语音输入' : '切换到键盘输入',
                  onPressed: () =>
                      setState(() => _inputMode = _inputMode == 0 ? 1 : 0),
                ),
                // 附件按钮（图片/文件，键盘模式可用）
                if (_inputMode == 0)
                  IconButton(
                    icon: Icon(Icons.add_circle_outline,
                        color: theme.colorScheme.primary),
                    tooltip: '添加图片或文件',
                    onPressed: _pickAttachment,
                  ),
                const SizedBox(width: 4),
                if (_inputMode == 0)
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: '输入消息...',
                        border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.all(Radius.circular(24))),
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  )
                else
                  Expanded(
                    // 用 Listener 捕获指针级事件：上滑到按钮外松开也能判定取消
                    child: Listener(
                      onPointerDown: _voiceDown,
                      onPointerMove: _voiceMove,
                      onPointerUp: (_) => _voiceUp(),
                      onPointerCancel: (_) => _voiceUp(),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _recording
                              ? (_slideToCancel
                                  ? sc.errorContainer
                                  : Colors.red.shade100)
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                              color: _slideToCancel
                                  ? sc.error
                                  : theme.colorScheme.outline),
                        ),
                        child: Text(
                          _recording
                              ? (_slideToCancel ? '松开 取消' : '上滑取消 · 松开结束')
                              : '按住 说话',
                          style: TextStyle(
                              color: _recording
                                  ? (_slideToCancel
                                      ? sc.error
                                      : Colors.red)
                                  : theme.colorScheme.onSurface),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                if (_inputMode == 0)
                  IconButton.filled(
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                    onPressed: _sending ? null : _send,
                  )
                else
                  IconButton.filled(
                    icon: const Icon(Icons.mic_none),
                    onPressed: null,
                  ),
                ],
              ),
            ],
          ),
        ),
        ),
        // 录音提示浮层（微信式：上滑取消）
        if (_recording)
          Positioned(
            bottom: 84,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: _slideToCancel
                    ? sc.error
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                    color: _slideToCancel ? sc.error : sc.outline),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _slideToCancel ? Icons.close : Icons.keyboard_arrow_up,
                    color: _slideToCancel ? sc.onError : slideColor,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _slideToCancel ? '松开手指，取消发送' : '手指上滑，取消发送',
                    style: TextStyle(
                        color: _slideToCancel
                            ? sc.onError
                            : theme.colorScheme.onSurface,
                        fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// ============ 左侧抽屉：会话列表 ============
class ConversationDrawer extends StatelessWidget {
  const ConversationDrawer({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SessionManager.instance,
      builder: (context, _) {
        final sm = SessionManager.instance;
        return Drawer(
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Text('对话列表',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          sm.newConversation();
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('新对话'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: sm.conversations.isEmpty
                      ? const Center(child: Text('暂无对话，点「新对话」开始'))
                      : ListView.builder(
                          itemCount: sm.conversations.length,
                          itemBuilder: (c, i) {
                            final conv = sm.conversations[i];
                            final selected = conv.id == sm.currentId;
                            return ListTile(
                              selected: selected,
                              title: Text(conv.displayTitle,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '${conv.backendId.isEmpty ? '默认后端' : conv.backendId} · ${conv.messages.length}条',
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline, size: 20),
                                onPressed: () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('删除对话'),
                                      content: Text(
                                          '确定删除「${conv.displayTitle}」吗？电脑上保存的该对话上下文也会一并清除。'),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, false),
                                            child: const Text('取消')),
                                        FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, true),
                                            child: const Text('删除')),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    // 先通知服务端清历史桶，再删本地（断开时仅删本地，服务端桶随会话名失效不再使用）
                                    if (bridge.connected) {
                                      bridge.deleteConversation(conv.id);
                                    }
                                    sm.delete(conv.id);
                                  }
                                },
                              ),
                              onTap: () {
                                sm.switchTo(conv.id);
                                Navigator.pop(context);
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
