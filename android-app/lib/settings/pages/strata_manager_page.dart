import 'dart:async';

import 'package:flutter/material.dart';

import '../../bridge_client.dart';

/// ============ Strata 管理器 ============
/// Strata 是 orca 专用引擎（pack 绑定模型架构），加载 YOUR_STRATA_MODEL_DIR 目录下模型。
/// 显存控制：上下文(max_context) + KV 量化(kv) + GPU 专家驻留数(expert_cache)。
/// 层数由模型固定（48 层），不可调；显存吃紧可开低显存模式(low_vram)。
class StrataManagerPage extends StatefulWidget {
  const StrataManagerPage({super.key});
  @override
  State<StrataManagerPage> createState() => _StrataManagerPageState();
}

class _StrataManagerPageState extends State<StrataManagerPage> {
  StreamSubscription? _sub;
  List<Map<String, dynamic>> _models = [];
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _gpu;
  int _maxContext = 32768;
  String _kv = 'int8';
  int _expertCache = 0;
  bool _lowVram = false;
  bool _loading = false;
  String? _msg;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _connected = bridge.connected;
    _sub = bridge.strataResults.listen(_onMsg);
    bridge.onStatus.listen((c) {
      if (!mounted) return;
      setState(() => _connected = c);
      if (c) _refresh();
    });
    if (_connected) _refresh();
  }

  void _onMsg(Map<String, dynamic> m) {
    if (!mounted) return;
    setState(() {
      final t = (m['type'] ?? '').toString();
      if (t == 'strata_models') {
        _models = List<Map<String, dynamic>>.from(m['models'] ?? []);
      } else if (t == 'strata_status') {
        _status = (m['server'] is Map)
            ? Map<String, dynamic>.from(m['server'] as Map)
            : null;
        _gpu = (_status?['gpu'] is Map)
            ? Map<String, dynamic>.from(_status!['gpu'] as Map)
            : null;
      } else if (t == 'strata_load_result') {
        _loading = false;
        final ga = m['gpu_after'];
        final gpuTxt = (ga is Map && (ga['used'] ?? 0) != 0)
            ? '  显存 ${ga['used']} / ${ga['total']} MiB'
            : '';
        _msg = (m['message'] ?? '加载完成').toString() + gpuTxt;
        _refresh();
      } else if (t == 'strata_unload_result') {
        _loading = false;
        _msg = '已卸载端口 ${m['port']}';
        _refresh();
      } else if (t == 'error') {
        _loading = false;
        _msg = (m['message'] ?? '出错').toString();
      }
    });
  }

  void _refresh() {
    bridge.strataListModels();
    bridge.strataStatus();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: const Text('Strata 管理器')),
      body: _connected
          ? RefreshIndicator(
              onRefresh: () async => _refresh(),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _statusCard(primary),
                  const SizedBox(height: 12),
                  _paramsCard(),
                  const SizedBox(height: 12),
                  Text('模型库（共 ${_models.length} 个，点加载即切换）',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  ..._models.map((m) => _modelTile(m, primary)),
                  const SizedBox(height: 12),
                  if (_msg != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_msg!,
                          style: const TextStyle(color: Colors.grey)),
                    ),
                ],
              ),
            )
          : const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('未连接电脑中转，先回设置页连接后再进入',
                    style: TextStyle(color: Colors.grey)),
              ),
            ),
    );
  }

  Widget _statusCard(Color primary) {
    final running = _status?['running'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('运行状态', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('刷新'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.circle,
                    size: 10, color: running ? Colors.green : Colors.grey),
                const SizedBox(width: 6),
                Text(running ? '端口 8080 运行中' : '端口 8080 未运行',
                    style: const TextStyle(fontSize: 13)),
              ],
            ),
            if (_gpu != null) ...[
              const Divider(height: 16),
              Text(
                  'GPU 显存：${_gpu!['name']}  已用 ${_gpu!['used']} / 总 ${_gpu!['total']} MiB（剩 ${_gpu!['free']} MiB）',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _paramsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('加载参数（显存控制）',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('上下文长度: $_maxContext（越大越占显存）',
                style: const TextStyle(fontSize: 13)),
            Slider(
              value: _maxContext.toDouble().clamp(4096, 131072),
              max: 131072,
              divisions: 32,
              label: '$_maxContext',
              onChanged: (v) => setState(() => _maxContext = v.round()),
            ),
            Text('KV 量化: $_kv（int8 省一半显存，q4_0 更省）',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              value: _kv,
              isDense: true,
              decoration: const InputDecoration(
                  isDense: true, border: OutlineInputBorder()),
              items: ['int8', 'q4_0', 'f16']
                  .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                  .toList(),
              onChanged: (v) => setState(() => _kv = v ?? 'int8'),
            ),
            const SizedBox(height: 8),
            Text('GPU 专家驻留数: $_expertCache（0=默认全驻留；调小省显存）',
                style: const TextStyle(fontSize: 13)),
            Slider(
              value: _expertCache.toDouble().clamp(0, 32),
              max: 32,
              divisions: 32,
              label: '$_expertCache',
              onChanged: (v) => setState(() => _expertCache = v.round()),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('低显存模式（resident-experts）',
                  style: TextStyle(fontSize: 13)),
              value: _lowVram,
              onChanged: (v) => setState(() => _lowVram = v),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  bridge.strataUnload();
                  setState(() {
                    _loading = true;
                    _msg = '正在卸载 ...';
                  });
                },
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('卸载'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelTile(Map<String, dynamic> m, Color primary) {
    final name = (m['name'] ?? '').toString();
    final size = (m['size_gb'] ?? 0).toString();
    final shards = (m['shards'] is List) ? (m['shards'] as List).length : 0;
    final busy = _loading;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.storage),
        title: Text(name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13)),
        subtitle: Text('$size GB · $shards 分片'),
        trailing: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: primary, foregroundColor: Colors.white),
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _msg = '正在加载 $name ...（模型较大需等待）';
                  });
                  bridge.strataLoad(name,
                      maxContext: _maxContext,
                      kv: _kv,
                      expertCache: _expertCache,
                      lowVram: _lowVram);
                },
                child: const Text('加载', style: TextStyle(fontSize: 13)),
              ),
      ),
    );
  }
}
