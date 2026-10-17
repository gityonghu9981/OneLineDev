import 'dart:async';

import 'package:flutter/material.dart';

import '../../bridge_client.dart';
import '../../models.dart';

/// ============ 单个后端的独立设置卡片 ============
/// 每个后端（LM Studio / llama.cpp / Strata / OpenClaw / QwenPaw …）各自一张卡，
/// 拥有独立的：状态、端口、模型选择、上下文长度、温度、一键启停。
/// 互不干扰、各自保存；新增后端无需改本卡（数据来自中转下发的 backends 列表）。
class BackendSettingsCard extends StatefulWidget {
  final Map<String, dynamic> backend;
  /// 是否显示「选择模型」列表。LM Studio 由 LmStudioCard 统一管理模型（设为当前+加载/卸载），
  /// 故传 false 避免两个模型列表重复。
  final bool showModels;
  /// 上下文/温度被用户改动时上报当前值，供父级「保存设置」按钮兜底提交（Slider onChangeEnd 可能不触发）
  final ValueChanged<int>? onContextEdited;
  final ValueChanged<double>? onTemperatureEdited;
  const BackendSettingsCard(
      {super.key,
      required this.backend,
      this.showModels = true,
      this.onContextEdited,
      this.onTemperatureEdited});

  @override
  State<BackendSettingsCard> createState() => _BackendSettingsCardState();
}

class _BackendSettingsCardState extends State<BackendSettingsCard> {
  late int _context;
  late double _temperature;
  bool _busy = false; // 启动/停止动作进行中：按键置灰并转圈
  bool? _clickRunning; // 点击时后端状态，用于判断状态是否已变化
  StreamSubscription? _statusSub;
  StreamSubscription? _backendsSub;
  Timer? _busyTimer;

  String get _id => (widget.backend['id'] ?? '').toString();
  String get _name => (widget.backend['name'] ?? _id).toString();
  String get _type => (widget.backend['type'] ?? '').toString();
  String get _status => (widget.backend['status'] ?? 'unknown').toString();
  bool get _running => _status == 'running';
  String get _port => (widget.backend['port'] ?? '').toString();
  String get _model => (widget.backend['model'] ?? '').toString();
  bool get _controllable => widget.backend['controllable'] == true;
  List<dynamic> get _models =>
      (widget.backend['models'] ?? const []) as List;

  Map<String, dynamic> get _settings =>
      (widget.backend['settings'] is Map)
          ? Map<String, dynamic>.from(widget.backend['settings'] as Map)
          : const {};

  @override
  void initState() {
    super.initState();
    _syncFromBackend();
    // 中转回传"已启动/已停止"时解除按键 loading（启动可能耗时数十秒）
    _statusSub = bridge.onBackendStatus.listen((_) {
      if (mounted) {
        _busyTimer?.cancel();
        setState(() => _busy = false);
      }
    });
    // 兜底：监听后端列表刷新，本后端 running 状态相对点击时发生变化即解除 loading
    _backendsSub = bridge.onBackends.listen((list) {
      if (!mounted) return;
      final r0 = _clickRunning;
      if (!_busy || r0 == null) return;
      for (final b in list) {
        if ((b['id'] ?? '').toString() == _id) {
          // 兼容中转下发的 running 布尔 / status 字符串两种表示
          final status = (b['status'] ?? '').toString();
          final running = (b['running'] == true) || (status == 'running');
          if (running != r0) {
            _busyTimer?.cancel();
            setState(() => _busy = false);
          }
          break;
        }
      }
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _backendsSub?.cancel();
    _busyTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BackendSettingsCard old) {
    super.didUpdateWidget(old);
    // 仅切换后端（id 变化）时才重新同步 settings；
    // 同后端时保留用户正在编辑/刚拖动的值，避免父组件重建时被旧快照弹回。
    if ((widget.backend['id'] ?? '').toString() !=
        (old.backend['id'] ?? '').toString()) {
      _syncFromBackend();
    }
  }

  void _syncFromBackend() {
    final s = _settings;
    final c = s['context'];
    if (c is num) _context = c.round();
    final t = s['temperature'];
    if (t is num) _temperature = t.toDouble();
  }

  // 启动/停止后端：先置灰转圈，直到状态变化或超时
  void _toggle() {
    if (_busy) return;
    _clickRunning = _running;
    setState(() => _busy = true);
    _busyTimer?.cancel();
    _busyTimer = Timer(const Duration(seconds: 130), () {
      if (mounted) setState(() => _busy = false);
    });
    if (_running) {
      bridge.stopBackend(_id);
    } else {
      bridge.startBackend(_id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：状态圆点 + 名称 + 运行状态
            Row(
              children: [
                Icon(Icons.circle,
                    size: 12, color: _running ? Colors.green : Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$_name 设置',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  _running ? '运行中' : '未运行',
                  style: TextStyle(
                      fontSize: 12,
                      color: _running ? Colors.green : Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_port.isNotEmpty)
              Text('端口: $_port · 类型: $_type',
                  style: const TextStyle(fontSize: 12)),
            // 模型选择（逐项分栏列出，点选即切换该后端模型）
            if (widget.showModels && _models.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('选择模型',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              ..._models.map((m) {
                final ms = m.toString();
                final selected = _model == ms;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: selected ? Colors.blue : Colors.grey,
                  ),
                  title: Text(ms,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                  selected: selected,
                  selectedTileColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  onTap: () {
                    if (_id.isNotEmpty) {
                      bridge.setBackendModel(_id, ms);
                      SettingsStore.saveString('backend_model_$_id', ms);
                    }
                  },
                );
              }),
            ] else if (_model.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('模型: $_model',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
              ),
            const SizedBox(height: 12),
            // 上下文长度
            Text('上下文长度: $_context'),
            Slider(
              value: _context.toDouble().clamp(256, 131072),
              min: 256,
              max: 131072,
              divisions: 20,
              label: '$_context',
              onChanged: _controllable ? (v) {
                setState(() => _context = v.round());
                widget.onContextEdited?.call(_context);
              } : null,
              onChangeEnd: _controllable ? (v) {
                SettingsStore.saveInt('context_$_id', v.round());
                if (_id.isNotEmpty) {
                  bridge.setBackendSetting(_id, 'context', v.round());
                }
              } : null,
            ),
            // 温度
            Text('温度: ${_temperature.toStringAsFixed(2)}'),
            Slider(
              value: _temperature.clamp(0.0, 2.0),
              min: 0.0,
              max: 2.0,
              divisions: 20,
              label: _temperature.toStringAsFixed(2),
              onChanged: _controllable ? (v) {
                setState(() => _temperature = v);
                widget.onTemperatureEdited?.call(v);
              } : null,
              onChangeEnd: _controllable ? (v) {
                if (_id.isNotEmpty) {
                  bridge.setBackendSetting(_id, 'temperature', v);
                }
              } : null,
            ),
            if (!_controllable)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('上下文/温度不可远程调整，请在软件内设置',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            // 一键启停（可控后端才显示）
            if (_controllable) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _busy
                        ? FilledButton.icon(
                            onPressed: null,
                            icon: const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white)),
                            label: Text(_running ? '停止中…' : '启动中…'))
                        : (_running
                            ? OutlinedButton.icon(
                                onPressed: _toggle,
                                icon: const Icon(Icons.stop),
                                label: const Text('停止后端'))
                            : FilledButton.icon(
                                onPressed: _toggle,
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('启动后端'))),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
