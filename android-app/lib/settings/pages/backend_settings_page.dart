import 'dart:async';

import 'package:flutter/material.dart';

import '../../bridge_client.dart';
import '../../models.dart';
import '../widgets/backend_settings_card.dart';
import '../widgets/lm_studio_card.dart';

/// ============ 单后端设置详情页 ============
/// 点某个后端进入的独立设置页面（如「llama.cpp 35B 设置」）。
/// 只处理这一个后端：状态、端口、模型、上下文、温度、一键启停。
/// LM Studio 额外显示 GPU 显存/分流（复用 LmGpuCard）。
/// 数据实时来自中转（订阅 onBackends 刷新），进入时自动拉取最新状态。
class BackendSettingsPage extends StatefulWidget {
  final String backendId;
  const BackendSettingsPage({super.key, required this.backendId});

  @override
  State<BackendSettingsPage> createState() => _BackendSettingsPageState();
}

class _BackendSettingsPageState extends State<BackendSettingsPage> {
  StreamSubscription? _backendsSub;
  StreamSubscription? _lmModelsSub;
  StreamSubscription? _lmResultSub;
  StreamSubscription? _statusSub;
  List<Map<String, dynamic>> _backends = [];

  // LM Studio 本地模型与加载参数（仅该后端为 lm_studio 时使用）
  List<Map<String, dynamic>> _lmModels = [];
  Map<String, dynamic> _lmGpu = {};
  double _lmGpuRatio = 0.7;
  int _lmContext = 8192;
  bool _lmBusy = false;
  // 用户改动的上下文/温度（供「保存设置」按钮兜底提交）
  int? _editedContext;
  double? _editedTemperature;

  Map<String, dynamic>? get _cur {
    for (final b in _backends) {
      if ((b['id'] ?? '').toString() == widget.backendId) return b;
    }
    return null;
  }

  String get _title {
    final b = _cur;
    if (b != null) return '${(b['name'] ?? widget.backendId).toString()} 设置';
    return '${widget.backendId} 设置';
  }

  bool get _isLmStudio => widget.backendId == 'lm_studio';

  /// 当前后端对话模型（用于 LmStudioCard 高亮「设为当前」）
  String get _curModel {
    final b = _cur;
    return (b?['model'] ?? '').toString();
  }

  /// 设为当前对话模型
  void _selectLmModel(String model) {
    if (_id.isNotEmpty) {
      bridge.setBackendModel(widget.backendId, model);
      SettingsStore.saveString('backend_model_${widget.backendId}', model);
    }
  }

  /// 读取本地持久化的 LM Studio 加载参数（GPU 分流 + 上下文），避免切换恢复
  Future<void> _loadLmParams() async {
    final s = await SettingsStore.load();
    if (!mounted) return;
    setState(() {
      final lgr = s['lm_gpu_ratio'];
      if (lgr is num) _lmGpuRatio = lgr.toDouble();
      final lc = s['lm_context'];
      if (lc is num) _lmContext = lc.round();
    });
  }

  /// 保存按钮：持久化当前后端的设置（含 LM Studio GPU/上下文），并给用户明确反馈
  void _saveCurrent() {
    // 兜底提交：把用户当前拖动的上下文/温度发给中转（Slider onChangeEnd 可能未触发，保存必须可靠生效）
    if (_editedContext != null && _id.isNotEmpty) {
      bridge.setBackendSetting(widget.backendId, 'context', _editedContext!);
    }
    if (_editedTemperature != null && _id.isNotEmpty) {
      bridge.setBackendSetting(
          widget.backendId, 'temperature', _editedTemperature!);
    }
    // LM Studio：持久化加载参数（GPU 分流 + 加载上下文），用于下次 lm_load
    if (_isLmStudio) {
      SettingsStore.saveDouble('lm_gpu_ratio', _lmGpuRatio);
      SettingsStore.saveInt('lm_context', _lmContext);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✅ 设置已保存'), duration: Duration(seconds: 2)),
    );
  }

  String get _id => widget.backendId;

  void _lmLoad(String model, String gpu, int context) {
    if (_lmBusy) return;
    setState(() => _lmBusy = true);
    bridge.lmLoad(model, gpu: gpu, context: context);
  }

  void _lmUnload(String model) {
    if (_lmBusy) return;
    setState(() => _lmBusy = true);
    bridge.lmUnload(model);
  }

  @override
  void initState() {
    super.initState();
    _loadLmParams();
    // 直接用 bridge 已缓存的最新后端列表初始化，再订阅增量刷新
    _backends = List<Map<String, dynamic>>.from(bridge.backends);
    _backendsSub = bridge.onBackends.listen((list) {
      if (!mounted) return;
      setState(() => _backends = list);
    });
    // 收到"已启动/已停止"事件后重拉后端列表，刷新卡片 running 状态
    _statusSub = bridge.onBackendStatus.listen((_) {
      if (!mounted) return;
      bridge.listBackends();
    });
    bridge.listBackends();
    // LM Studio 详情页：实时拉取 GPU 显存占用
    if (_isLmStudio) {
      _lmModelsSub = bridge.onLmModels.listen((m) {
        if (!mounted) return;
        setState(() {
          _lmModels = List<Map<String, dynamic>>.from(m['models'] ?? const []);
          _lmGpu = (m['gpu'] is Map)
              ? Map<String, dynamic>.from(m['gpu'] as Map)
              : {};
        });
      });
      _lmResultSub = bridge.onLmResult.listen((m) {
        if (!mounted) return;
        setState(() => _lmBusy = false);
        final ok = m['ok'] == true;
        final model = (m['model'] ?? '').toString();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${ok ? '✅' : '⚠'} ${model} ${ok ? '操作成功' : '操作失败'}: ${m['message'] ?? ''}'),
          duration: const Duration(seconds: 4),
        ));
        bridge.lmListLocal();
      });
      bridge.lmListLocal();
    }
  }

  @override
  void dispose() {
    _backendsSub?.cancel();
    _lmModelsSub?.cancel();
    _lmResultSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = _cur;
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: b == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('该后端不存在或尚未加载，请稍候或重新连接',
                    style: TextStyle(color: Colors.grey)),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                BackendSettingsCard(
                    backend: b,
                    showModels: !_isLmStudio,
                    onContextEdited: (v) => _editedContext = v,
                    onTemperatureEdited: (v) => _editedTemperature = v),
                if (_isLmStudio) ...[
                  const SizedBox(height: 12),
                  LmStudioCard(
                    models: _lmModels,
                    gpu: _lmGpu,
                    gpuRatio: _lmGpuRatio,
                    context: _lmContext,
                    busy: _lmBusy,
                    curModel: _curModel,
                    onSelectModel: _selectLmModel,
                    onLoad: _lmLoad,
                    onUnload: _lmUnload,
                    onRatioChanged: (v) => setState(() => _lmGpuRatio = v),
                    onContextChanged: (v) => setState(() => _lmContext = v),
                    // 松手即持久化；加载上下文仅用于下次 lm_load，不改对话上下文
                    onRatioEnd: (v) {
                      setState(() => _lmGpuRatio = v);
                      SettingsStore.saveDouble('lm_gpu_ratio', v);
                    },
                    onContextEnd: (v) {
                      setState(() => _lmContext = v);
                      SettingsStore.saveInt('lm_context', v);
                    },
                  ),
                ],
                const SizedBox(height: 12),
                // 保存设置按钮（每个子页都有，点击后持久化并反馈）
                FilledButton.icon(
                  onPressed: _saveCurrent,
                  icon: const Icon(Icons.save),
                  label: const Text('保存设置'),
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ],
            ),
    );
  }
}
