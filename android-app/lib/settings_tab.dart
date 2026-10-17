import 'dart:async';

import 'package:flutter/material.dart';

import 'bridge_client.dart';
import 'models.dart';
import 'theme.dart';
import 'settings/widgets/theme_card.dart';
import 'settings/widgets/connection_card.dart';
import 'settings/widgets/context_compress_card.dart';
import 'settings/widgets/voice_card.dart';
import 'settings/widgets/save_button.dart';
import 'settings/widgets/help_card.dart';
import 'settings/pages/backend_list_page.dart';

/// ============ 设置页（主编排） ============
/// 本页只负责：持有共享状态、订阅后端事件、按从上到下的固定顺序组装各独立模块。
/// 各模块（主题/连接/后端选择/单后端设置/压缩/LM Studio/声线/保存/说明）分别拆在
/// `settings/widgets/*`，每个功能一个文件，新增功能只需加一个 widget 并在这里挂载，
/// 不需要改动其它模块。
/// 版本号：每次发布在 pubspec.yaml 与这里同步递增。
const String kAppVersion = 'v2.0.1';
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});
  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  // ---- 连接 ----
  final TextEditingController _hostCtrl = TextEditingController();
  final TextEditingController _portCtrl = TextEditingController();

  // ---- 后端 ----
  List<Map<String, dynamic>> _backends = [];
  String _activeBackendId = '';

  // ---- 声线 / 模型 ----
  List<Map<String, String>> _voices = [];
  String? _curModel;
  String? _curVoice;

  // ---- 全局上下文压缩 ----
  bool _compressEnabled = true;
  double _compressRatio = 0.7;
  int _compressBatch = 10;

  bool _connecting = false; // 连接动作进行中
  bool _saving = false;     // 保存设置进行中

  // ---- 主题 ----
  ThemeMode _themeMode = ThemeMode.light;

  // ---- 订阅 ----
  StreamSubscription? _modelsSub;
  StreamSubscription? _voicesSub;
  StreamSubscription? _settingsSub;
  StreamSubscription? _errSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _settingsSavedSub;
  StreamSubscription? _backendsSub;
  StreamSubscription? _backendStatusSub;

  Map<String, dynamic>? get _curBackend {
    if (_activeBackendId.isEmpty) return null;
    for (final b in _backends) {
      if (b['id'] == _activeBackendId) return b;
    }
    return null;
  }

  String get _activeBackendName {
    final b = _curBackend;
    return b == null ? '' : (b['name'] ?? _activeBackendId).toString();
  }

  @override
  void initState() {
    super.initState();
    _loadSaved();

    _modelsSub = bridge.onModels.listen((list) {
      setState(() {
        final cur = _curBackend;
        if (cur != null) cur['models'] = List<String>.from(list);
      });
    });
    _voicesSub = bridge.onVoices.listen((list) {
      setState(() => _voices = list);
    });
    _settingsSub = bridge.onSettings.listen((s) {
      setState(() {
        final m = (s['model'] ?? '').toString();
        if (m.isNotEmpty) _curModel = m;
        final v = (s['voice'] ?? '').toString();
        if (v.isNotEmpty) _curVoice = v;
        if (s['compress_enabled'] is bool) {
          _compressEnabled = s['compress_enabled'] as bool;
        }
        final cr = s['compress_ratio'];
        if (cr is num) _compressRatio = cr.toDouble();
        final cb = s['compress_batch'];
        if (cb is num) _compressBatch = cb.round();
      });
    });
    _errSub = bridge.onError.listen((e) {
      // 任何报错都解除进行中的 busy 状态，避免按钮卡死
      if (mounted) {
        setState(() {
          _saving = false;
          _connecting = false;
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    });
    _statusSub = bridge.onStatus.listen((ok) {
      if (ok) {
        bridge.listModels();
        bridge.listVoices();
        bridge.getSettings();
        bridge.listBackends();
        bridge.lmListLocal();
      }
    });
    _backendsSub = bridge.onBackends.listen((list) {
      setState(() {
        _backends = list;
        _activeBackendId = bridge.activeBackendId;
      });
    });
    _backendStatusSub = bridge.onBackendStatus.listen((msg) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
      // 启动/停止后立即刷新状态
      bridge.listBackends();
    });
    _settingsSavedSub = bridge.onSettingsSaved.listen((s) {
      if (mounted) setState(() => _saving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ 设置已保存'),
              duration: Duration(seconds: 2)),
        );
      }
    });

    if (bridge.connected) {
      bridge.listModels();
      bridge.listVoices();
      bridge.getSettings();
      bridge.listBackends();
    }
  }

  Future<void> _loadSaved() async {
    final s = await SettingsStore.load();
    if (!mounted) return;
    setState(() {
      _hostCtrl.text = s['host'] ?? '';
      _portCtrl.text = (s['port'] ?? 8765).toString();
      final v = (s['voice'] ?? '').toString();
      if (v.isNotEmpty) _curVoice = v;
      final bid = (s['backend_id'] ?? '').toString();
      if (bid.isNotEmpty) _activeBackendId = bid;
      _themeMode = (s['theme'] == 'dark') ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  void dispose() {
    _modelsSub?.cancel();
    _voicesSub?.cancel();
    _settingsSub?.cancel();
    _errSub?.cancel();
    _statusSub?.cancel();
    _settingsSavedSub?.cancel();
    _backendsSub?.cancel();
    _backendStatusSub?.cancel();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  // ---- 动作 ----
  Future<void> _connect() async {
    if (_connecting) return;
    final h = _hostCtrl.text.trim();
    final p = int.tryParse(_portCtrl.text.trim()) ?? 8765;
    SettingsStore.saveString('host', h);
    SettingsStore.saveInt('port', p);
    setState(() => _connecting = true);
    await bridge.connect(h, p);
    if (mounted) setState(() => _connecting = false);
  }

  void _setTheme(ThemeMode mode) {
    setState(() => _themeMode = mode);
    themeModeNotifier.value = mode;
    SettingsStore.saveString('theme', mode == ThemeMode.dark ? 'dark' : 'light');
  }

  void _selectBackend(String v) {
    setState(() => _activeBackendId = v);
    SettingsStore.saveString('backend_id', v);
    bridge.setBackend(v);
    bridge.listModels(); // 拉取该后端的模型列表
  }

  void _saveSettings() {
    if (!bridge.connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠ 未连接，无法保存到电脑')),
      );
      return;
    }
    if (_saving) return;
    int ctx = 4096;
    final cur = _curBackend;
    if (cur != null) {
      final s = (cur['settings'] is Map) ? cur['settings'] as Map : const {};
      final c = s['context'];
      if (c is num) ctx = c.round();
    }
    setState(() => _saving = true);
    bridge.saveSettings(
        model: _curModel ?? '',
        context: ctx,
        voice: _curVoice ?? '',
        compressEnabled: _compressEnabled,
        compressRatio: _compressRatio,
        compressBatch: _compressBatch);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 1. 外观主题
        ThemeCard(themeMode: _themeMode, onChanged: _setTheme),
        const SizedBox(height: 12),
        // 2. 连接管理
        ConnectionCard(
          hostCtrl: _hostCtrl,
          portCtrl: _portCtrl,
          connecting: _connecting,
          connected: bridge.connected,
          onConnect: _connect,
          onDisconnect: () => bridge.disconnect(),
        ),
        const SizedBox(height: 12),
        // 3. 各后端设置入口（点进去：先选择当前后端，再点某后端进入它的独立设置页）
        Card(
          child: ListTile(
            leading: const Icon(Icons.settings_suggest),
            title: const Text('各后端设置',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              _backends.isEmpty
                  ? '连接电脑后自动加载后端列表，可分别设置每个后端的模型 / 上下文 / 温度 / 启停'
                  : '共 ${_backends.length} 个后端 · 当前 ${_activeBackendName}，点击进入选择与单独设置',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => BackendListPage(
                  activeBackendId: _activeBackendId,
                  onSelect: _selectBackend,
                ),
              ),
            ),
          ),
        ),
        // 4. 智能上下文压缩（全局）
        ContextCompressCard(
          enabled: _compressEnabled,
          ratio: _compressRatio,
          batch: _compressBatch,
          onEnabled: (v) => setState(() => _compressEnabled = v),
          onRatio: (v) => setState(() => _compressRatio = v),
          onBatch: (v) => setState(() => _compressBatch = v),
        ),
        const SizedBox(height: 12),
        // 7. 声线选择
        VoiceCard(
          voices: _voices,
          curVoice: _curVoice,
          onRefresh: () => bridge.listVoices(),
          onSelect: (v) {
            SettingsStore.saveString('voice', v);
            setState(() => _curVoice = v);
          },
        ),
        const SizedBox(height: 12),
        // 8. 保存设置
        SaveButton(onSave: _saveSettings, saving: _saving),
        const SizedBox(height: 12),
        // 9. 使用说明
        const HelpCard(),
        const SizedBox(height: 12),
        // 10. 版本号
        Center(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '版本 $kAppVersion',
              style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                  decoration: TextDecoration.none),
            ),
          ),
        ),
      ],
    );
  }
}
