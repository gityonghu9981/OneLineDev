import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:audioplayers/audioplayers.dart';

/// 一条模型回复的结构化结果（文本 + 思考 + token用量 + 耗时 + 数据量 + 模型信息 + 会话id）
class ChatResult {
  final String text;
  final String reasoning;
  final Map<String, dynamic> usage;
  final int durationMs;
  final int chars;
  final String model;
  final String backend;
  final String conversationId;
  ChatResult({
    required this.text,
    this.reasoning = '',
    Map<String, dynamic>? usage,
    this.durationMs = 0,
    this.chars = 0,
    this.model = '',
    this.backend = '',
    this.conversationId = '',
  }) : usage = usage ?? {};
}

/// 流式增量块（P1-5）：模型边生成边推送，前端逐块追加渲染
class DeltaChunk {
  final String text;      // 文本增量
  final String reasoning; // 思考增量（reasoning_delta）
  final String conversationId;
  DeltaChunk({this.text = '', this.reasoning = '', this.conversationId = ''});
}

/// 上下文压缩事件：后端自动/手动把最旧对话压成概要后推送给前端
class CompressInfo {
  final int rounds;        // 被压缩的轮数（0 表示本轮未压缩/历史不足）
  final int nsRemoved;     // 被压掉的"非 system"消息条数（前端维护下标偏移用）
  final int remaining;     // 压缩后的消息条数
  final String conversationId;
  CompressInfo({this.rounds = 0, this.nsRemoved = 0, this.remaining = 0, this.conversationId = ''});
}

/// 结构化错误：携带来源会话与后端，前端按会话路由错误提示，避免串对话
class BridgeError {
  final String message;
  final String conversationId;
  final String backendId;
  final bool recoverable; // 模型调用类可恢复错误（用户消息保留，可重发）
  BridgeError(this.message,
      {this.conversationId = '',
      this.backendId = '',
      this.recoverable = false});
  @override
  String toString() => message;
}

/// ============ 桥接客户端：管理与本地电脑中转服务的 WebSocket 连接 ============
/// 统一入口：全局单例 `bridge`。所有手机<->电脑的协议收发都在这里。
/// 新增协议：加一个 StreamController + 对应 sendXxx() 方法 + _handleMessage 的 case。
class BridgeClient {
  WebSocketChannel? _channel;
  final _textCtrl = StreamController<ChatResult>.broadcast();
  final _modelsCtrl = StreamController<List<String>>.broadcast();
  final _voicesCtrl = StreamController<List<Map<String, String>>>.broadcast();
  final _settingsCtrl = StreamController<Map<String, dynamic>>.broadcast();
  final _errorCtrl = StreamController<BridgeError>.broadcast();
  final _statusCtrl = StreamController<bool>.broadcast();
  final _audioCtrl = StreamController<Uint8List>.broadcast();
  final _sttResultCtrl = StreamController<String>.broadcast();
  final _settingsSavedCtrl = StreamController<Map<String, dynamic>>.broadcast();
  final _backendsCtrl = StreamController<List<Map<String, dynamic>>>.broadcast();
  final _backendActiveCtrl = StreamController<String>.broadcast();
  final _backendStatusCtrl = StreamController<String>.broadcast();
  final _deltaCtrl = StreamController<DeltaChunk>.broadcast();
  final _compressedCtrl = StreamController<CompressInfo>.broadcast();
  final _lmModelsCtrl = StreamController<Map<String, dynamic>>.broadcast();
  final _lmResultCtrl = StreamController<Map<String, dynamic>>.broadcast();

  bool connected = false;
  String host = '';
  int port = 8765;
  List<Uint8List> _audioBuf = [];
  List<Map<String, dynamic>> backends = [];
  String activeBackendId = '';

  // ---- P0-1 心跳 + 自动重连状态 ----
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  DateTime? _lastPong;
  bool _connecting = false;
  bool _manualDisconnect = false;
  // 是否有正在等待的模型回复（慢推理期间不触发心跳超时误判）
  bool _hasPending = false;

  Stream<ChatResult> get onText => _textCtrl.stream;
  Stream<List<String>> get onModels => _modelsCtrl.stream;
  Stream<List<Map<String, String>>> get onVoices => _voicesCtrl.stream;
  Stream<Map<String, dynamic>> get onSettings => _settingsCtrl.stream;
  Stream<BridgeError> get onError => _errorCtrl.stream;
  Stream<bool> get onStatus => _statusCtrl.stream;
  Stream<Uint8List> get onAudio => _audioCtrl.stream;
  Stream<String> get onSttResult => _sttResultCtrl.stream;
  Stream<Map<String, dynamic>> get onSettingsSaved => _settingsSavedCtrl.stream;
  Stream<List<Map<String, dynamic>>> get onBackends => _backendsCtrl.stream;
  Stream<String> get onBackendActive => _backendActiveCtrl.stream;
  Stream<String> get onBackendStatus => _backendStatusCtrl.stream;
  Stream<DeltaChunk> get onDelta => _deltaCtrl.stream;
  Stream<CompressInfo> get onCompressed => _compressedCtrl.stream;
  Stream<Map<String, dynamic>> get onLmModels => _lmModelsCtrl.stream;
  Stream<Map<String, dynamic>> get onLmResult => _lmResultCtrl.stream;

  String wsUrl() => 'ws://$host:$port/ws';

  Future<void> connect(String h, int p) async {
    host = h;
    port = p;
    _manualDisconnect = false;
    _reconnectAttempt = 0;
    await _teardownChannel();
    await _doConnect();
  }

  // 真正的连接动作（供初次连接与自动重连共用）
  Future<void> _doConnect() async {
    if (_connecting) return;
    _connecting = true;
    if (host.trim().isEmpty) host = '192.168.1.6';
    if (port <= 0) port = 8765;
    print('L_BRIDGE doConnect target=${wsUrl()} host=$host port=$port reconnect=$_reconnectAttempt');
    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl()));
      await _channel!.ready;
      connected = true;
      _reconnectAttempt = 0;
      _hasPending = false;
      _statusCtrl.add(true);
      _listen();
      _startPing();
      listModels();
      listVoices();
      getSettings();
      listBackends();
    } catch (e) {
      connected = false;
      _statusCtrl.add(false);
      print('L_BRIDGE doConnect FAIL: $e (host=$host port=$port)');
      _errorCtrl.add(BridgeError('连接失败: $e'));
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  // 只关闭当前通道，不触发手动断开标记（供 connect 与重连复用）
  Future<void> _teardownChannel() async {
    _pingTimer?.cancel();
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    connected = false;
  }

  // 指数退避重连：1s→2s→4s→8s→16s→30s 封顶
  void _scheduleReconnect() {
    if (_manualDisconnect) return;
    _reconnectTimer?.cancel();
    final sec = 1 << (_reconnectAttempt > 6 ? 6 : _reconnectAttempt);
    if (_reconnectAttempt < 6) _reconnectAttempt++;
    final delay = Duration(seconds: sec.clamp(1, 30));
    _reconnectTimer = Timer(delay, _doConnect);
  }

  // 应用层心跳：每 15s ping 一次；超过 90s 无 pong 判定连接已死，主动重连（放宽防误判）
  void _startPing() {
    _pingTimer?.cancel();
    _lastPong = DateTime.now();
    _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!connected) return;
      if (_hasPending) {
        _lastPong = DateTime.now();
        return;
      }
      try {
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {}
      if (_lastPong != null &&
          DateTime.now().difference(_lastPong!) >
              const Duration(seconds: 90)) {
        _errorCtrl.add(BridgeError('连接超时，自动重连…'));
        _reconnectAttempt = 0;
        _scheduleReconnect();
        try {
          _channel?.sink.close();
        } catch (_) {}
      }
    });
  }

  void _listen() {
    _channel!.stream.listen((data) {
      if (data is String) {
        _handleMessage(data);
      } else if (data is List<int>) {
        _audioBuf.add(Uint8List.fromList(data));
      }
    }, onError: (e) {
      connected = false;
      _pingTimer?.cancel();
      _statusCtrl.add(false);
      _errorCtrl.add(BridgeError('连接中断: $e'));
      _scheduleReconnect();
    }, onDone: () {
      connected = false;
      _pingTimer?.cancel();
      _statusCtrl.add(false);
      _scheduleReconnect();
    });
  }

  void _handleMessage(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      switch (m['type']) {
        case 'pong':
          _lastPong = DateTime.now();
          break;
        case 'text':
          _hasPending = false;
          _textCtrl.add(ChatResult(
            text: (m['text'] ?? '').toString(),
            reasoning: (m['reasoning'] ?? '').toString(),
            usage: (m['usage'] is Map)
                ? Map<String, dynamic>.from(m['usage'] as Map)
                : {},
            durationMs: _toInt(m['duration_ms']),
            chars: _toInt(m['chars']),
            model: (m['model'] ?? '').toString(),
            backend: (m['backend'] ?? '').toString(),
            conversationId: (m['conversation_id'] ?? '').toString(),
          ));
          break;
        case 'text_delta':
          _deltaCtrl.add(DeltaChunk(
            text: (m['delta'] ?? '').toString(),
            conversationId: (m['conversation_id'] ?? '').toString(),
          ));
          break;
        case 'reasoning_delta':
          _deltaCtrl.add(DeltaChunk(
            reasoning: (m['delta'] ?? '').toString(),
            conversationId: (m['conversation_id'] ?? '').toString(),
          ));
          break;
        case 'audio_start':
          _audioBuf = [];
          break;
        case 'audio_end':
          _flushAudio();
          break;
        case 'models':
          _modelsCtrl.add(List<String>.from(m['models'] ?? const []));
          break;
        case 'voices':
          final list = (m['voices'] ?? const []) as List;
          _voicesCtrl.add(list.map((v) {
            final mm = v as Map;
            return {
              'name': (mm['name'] ?? '').toString(),
              'label': (mm['label'] ?? '').toString(),
              'ref': (mm['ref'] ?? '').toString(),
            };
          }).toList());
          break;
        case 'settings':
        case 'settings_ok':
          _settingsCtrl.add(m);
          break;
        case 'settings_saved':
          _settingsSavedCtrl.add(m);
          break;
        case 'backends':
          final list = (m['backends'] ?? const []) as List;
          backends = list.map((b) => Map<String, dynamic>.from(b as Map)).toList();
          _backendsCtrl.add(backends);
          final act = (m['active'] ?? '').toString();
          if (act.isNotEmpty) {
            activeBackendId = act;
            _backendActiveCtrl.add(act);
          }
          break;
        case 'backend_changed':
          final changed = (m['backend'] ?? '').toString();
          if (changed.isNotEmpty) {
            activeBackendId = changed;
            _backendActiveCtrl.add(changed);
          }
          break;
        case 'backend_status':
          final bid = (m['backend_id'] ?? '').toString();
          final st = (m['status'] ?? '').toString();
          final msg = (m['message'] ?? '').toString();
          _backendStatusCtrl.add('$bid：$st${msg.isNotEmpty ? '（$msg）' : ''}');
          Future.delayed(const Duration(seconds: 8), () {
            if (connected) listBackends();
          });
          break;
        case 'agent_result':
          _textCtrl.add(ChatResult(text: '[Agent] ${m['message']}'));
          break;
        case 'stt_result':
          _sttResultCtrl.add((m['text'] ?? '').toString());
          break;
        case 'context_compressed':
          _compressedCtrl.add(CompressInfo(
            rounds: _toInt(m['rounds']),
            nsRemoved: _toInt(m['ns_removed']),
            remaining: _toInt(m['remaining']),
            conversationId: (m['conversation_id'] ?? '').toString(),
          ));
          break;
        case 'lm_local_models':
          _lmModelsCtrl.add(Map<String, dynamic>.from(m));
          break;
        case 'lm_load_result':
        case 'lm_unload_result':
          _lmResultCtrl.add(Map<String, dynamic>.from(m));
          break;
        case 'llama_models':
        case 'llama_status':
        case 'llama_load_result':
        case 'llama_unload_result':
          _llamaResultCtrl.add(Map<String, dynamic>.from(m));
          break;
        case 'strata_models':
        case 'strata_status':
        case 'strata_load_result':
        case 'strata_unload_result':
          _strataResultCtrl.add(Map<String, dynamic>.from(m));
          break;
        case 'error':
          _hasPending = false;
          _errorCtrl.add(BridgeError(
            (m['message'] ?? '未知错误').toString(),
            conversationId: (m['conversation_id'] ?? '').toString(),
            backendId: (m['backend_id'] ?? '').toString(),
            recoverable: m['recoverable'] == true,
          ));
          break;
      }
    } catch (_) {}
  }

  void _flushAudio() {
    if (_audioBuf.isEmpty) return;
    final len = _audioBuf.fold<int>(0, (a, b) => a + b.length);
    final merged = Uint8List(len);
    int off = 0;
    for (final b in _audioBuf) {
      merged.setRange(off, off + b.length, b);
      off += b.length;
    }
    _audioBuf = [];
    _audioCtrl.add(merged);
  }

  void sendChat(String text,
      {bool voice = true,
      String? conversationId,
      String? backendId,
      bool resend = false,
      List<Map<String, dynamic>>? attachments}) {
    _hasPending = true;
    _channel?.sink.add(jsonEncode({
      'type': 'chat',
      'text': text,
      'voice': voice,
      'conversation_id': ?conversationId,
      'backend_id': ?backendId,
      if (resend) 'resend': true,
      if (attachments != null && attachments.isNotEmpty)
        'attachments': attachments,
    }));
  }

  void listModels() => _channel?.sink.add(jsonEncode({'type': 'list_models'}));
  void listVoices() => _channel?.sink.add(jsonEncode({'type': 'list_voices'}));
  void getSettings() => _channel?.sink.add(jsonEncode({'type': 'get_settings'}));
  void setModel(String model) =>
      _channel?.sink.add(jsonEncode({'type': 'set_model', 'model': model}));
  void setContext(int ctx) =>
      _channel?.sink.add(jsonEncode({'type': 'set_context', 'context': ctx}));
  void setVoice(String voice) =>
      _channel?.sink.add(jsonEncode({'type': 'set_voice', 'voice': voice}));

  void sendTtsSpeak(String text) =>
      _channel?.sink.add(jsonEncode({'type': 'tts_speak', 'text': text}));

  void sendSttStart() => _channel?.sink.add(jsonEncode({'type': 'stt_start'}));
  void sendSttData(Uint8List data) => _channel?.sink.add(data);
  void sendSttEnd() => _channel?.sink.add(jsonEncode({'type': 'stt_end'}));

  void clearHistory({String? conversationId, String? backendId}) =>
      _channel?.sink.add(jsonEncode({
        'type': 'clear_history',
        'conversation_id': ?conversationId,
        'backend_id': ?backendId,
      }));
  void deleteConversation(String conversationId) =>
      _channel?.sink.add(jsonEncode({
        'type': 'delete_conversation',
        'conversation_id': conversationId,
      }));
  void syncHistory(List<Map<String, String>> messages,
      {String? conversationId, String? backendId}) =>
      _channel?.sink.add(jsonEncode({
        'type': 'sync_history',
        'messages': messages,
        'conversation_id': ?conversationId,
        'backend_id': ?backendId,
      }));
  void truncateHistory(int keep, {String? conversationId, String? backendId}) =>
      _channel?.sink.add(jsonEncode({
        'type': 'truncate_history',
        'keep': keep,
        'conversation_id': ?conversationId,
        'backend_id': ?backendId,
      }));
  void deleteMessage(int index, {String? conversationId, String? backendId}) =>
      _channel?.sink.add(jsonEncode({
        'type': 'delete_message',
        'index': index,
        'conversation_id': ?conversationId,
        'backend_id': ?backendId,
      }));
  void regenerate({bool voice = true, String? conversationId, String? backendId}) {
    _hasPending = true;
    _channel?.sink.add(jsonEncode({
      'type': 'regenerate',
      'voice': voice,
      'conversation_id': ?conversationId,
      'backend_id': ?backendId,
    }));
  }
  void compressContext({String? conversationId, String? backendId}) =>
      _channel?.sink.add(jsonEncode({
        'type': 'compress_context',
        'conversation_id': ?conversationId,
        'backend_id': ?backendId,
      }));
  void lmListLocal() =>
      _channel?.sink.add(jsonEncode({'type': 'lm_list_local'}));
  void lmLoad(String model, {String gpu = 'max', int context = 8192}) =>
      _channel?.sink.add(jsonEncode({
        'type': 'lm_load', 'model': model, 'gpu': gpu, 'context': context,
      }));
  void lmUnload(String model) =>
      _channel?.sink.add(jsonEncode({'type': 'lm_unload', 'model': model}));

  // ---- 统一 llama.cpp 管理器（模型库随便切） ----
  final StreamController<Map<String, dynamic>> _llamaResultCtrl =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get llamaResults => _llamaResultCtrl.stream;

  void llamaListModels() =>
      _channel?.sink.add(jsonEncode({'type': 'llama_list_models'}));
  void llamaStatus() =>
      _channel?.sink.add(jsonEncode({'type': 'llama_status'}));
  void llamaLoad(String model,
          {int port = 8090, int context = 8192, int gpuLayers = 99,
          int threads = 16, String ctk = 'q8_0', String ctv = 'q8_0'}) =>
      _channel?.sink.add(jsonEncode({
        'type': 'llama_load', 'model': model, 'port': port,
        'context': context, 'gpu_layers': gpuLayers, 'threads': threads,
        'ctk': ctk, 'ctv': ctv,
      }));
  void llamaUnload({int port = 8090}) =>
      _channel?.sink.add(jsonEncode({'type': 'llama_unload', 'port': port}));

  // ---- Strata 统一管理器（orca 专用，显存控制） ----
  final StreamController<Map<String, dynamic>> _strataResultCtrl =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get strataResults => _strataResultCtrl.stream;

  void strataListModels() =>
      _channel?.sink.add(jsonEncode({'type': 'strata_list_models'}));
  void strataStatus() =>
      _channel?.sink.add(jsonEncode({'type': 'strata_status'}));
  void strataLoad(String model,
          {int port = 8080, int maxContext = 32768, String kv = 'int8',
          int expertCache = 0, bool lowVram = false}) =>
      _channel?.sink.add(jsonEncode({
        'type': 'strata_load', 'model': model, 'port': port,
        'max_context': maxContext, 'kv': kv,
        'expert_cache': expertCache, 'low_vram': lowVram,
      }));
  void strataUnload({int port = 8080}) =>
      _channel?.sink.add(jsonEncode({'type': 'strata_unload', 'port': port}));

  void saveSettings({String? model, int? context, String? voice,
      bool? compressEnabled, double? compressRatio, int? compressBatch}) =>
      _channel?.sink.add(jsonEncode({
        'type': 'save_settings',
        'model': model ?? '',
        'context': context ?? 4096,
        'voice': voice ?? '',
        if (compressEnabled != null) 'compress_enabled': compressEnabled,
        if (compressRatio != null) 'compress_ratio': compressRatio,
        if (compressBatch != null) 'compress_batch': compressBatch,
      }));

  void listBackends() => _channel?.sink.add(jsonEncode({'type': 'list_backends'}));
  void setBackend(String backendId) =>
      _channel?.sink.add(jsonEncode({'type': 'set_backend', 'backend_id': backendId}));
  void setBackendModel(String backendId, String model) =>
      _channel?.sink.add(jsonEncode({
        'type': 'set_backend_model',
        'backend_id': backendId,
        'model': model,
      }));
  void setBackendSetting(String backendId, String key, num value) =>
      _channel?.sink.add(jsonEncode({
        'type': 'set_backend_setting',
        'backend_id': backendId,
        'key': key,
        'value': value,
      }));
  void startBackend(String backendId) =>
      _channel?.sink.add(jsonEncode({'type': 'start_backend', 'backend_id': backendId}));
  void stopBackend(String backendId) =>
      _channel?.sink.add(jsonEncode({'type': 'stop_backend', 'backend_id': backendId}));

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    await _teardownChannel();
    _statusCtrl.add(false);
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse((v ?? '0').toString()) ?? 0;
  }
}

/// 全局桥接客户端单例
final BridgeClient bridge = BridgeClient();
/// 全局音频播放器（播放 TTS 返回的音频字节）
final AudioPlayer audioPlayer = AudioPlayer();
