import 'dart:async';

import 'package:flutter/material.dart';

import '../../bridge_client.dart';
import '../../models.dart';
import '../widgets/backend_settings_card.dart';
import '../widgets/lm_studio_card.dart';

/// ============ 单后端设置详情页 ============
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

  List<Map<String, dynamic>> _lmModels = [];
  Map<String, dynamic> _lmGpu = {};
  double _lmGpuRatio = 0.7;
  int _lmContext = 8192;
  bool _lmBusy = false;
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

  String get _curModel {
    final b = _cur;
    return (b?['model'] ?? '').toString();
  }

  void _selectLmModel(String model) {
    if (_id.isNotEmpty) {
      bridge.setBackendModel(widget.backendId, model);
      SettingsStore.saveString('backend_model_${widget.backendId}', model);
    }
  }

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

  void _saveCurrent() {
    if (_editedContext != null && _id.isNotEmpty) {
      bridge.setBackendSetting(widget.backendId, 'context', _editedContext!);
    }
    if (_editedTemperature != null && _id.isNotEmpty) {
      bridge.setBackendSetting(
          widget.backendId, 'temperature', _editedTemperature!);
    }
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
    _backends = List<Map<String, dynamic>>.from(bridge.backends);
    _backendsSub = bridge.onBackends.listen((list) {
      if (!mounted) return;
      setState(() => _backends = list);
    });
    _statusSub = bridge.onBackendStatus.listen((_) {
      if (!mounted) return;
      bridge.listBackends();
    });
    bridge.listBackends();
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
