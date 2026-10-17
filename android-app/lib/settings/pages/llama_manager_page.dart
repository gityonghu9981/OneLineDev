import 'dart:async';

import 'package:flutter/material.dart';

import '../../bridge_client.dart';

/// ============ llama.cpp 管理器 ============
/// 统一管理模型库（YOUR_MODEL_ROOT，拷 .gguf 即自动进库）：
/// 列出全部模型 → 选一个 + 调参数(上下文/GPU层/线程/端口) → 加载(停旧起新，一次一个)
/// → 随时切换 / 卸载。状态探测 8081-8084/8090 各端口。
class LlamaManagerPage extends StatefulWidget {
  const LlamaManagerPage({super.key});
  @override
  State<LlamaManagerPage> createState() => _LlamaManagerPageState();
}

class _LlamaManagerPageState extends State<LlamaManagerPage> {
  StreamSubscription? _sub;
  List<Map<String, dynamic>> _models = [];
  List<Map<String, dynamic>> _servers = [];
  int _port = 8090;
  int _context = 8192;
  int _gpuLayers = 99;
  int _threads = 16;
  bool _loading = false;
  String? _msg;
  bool _connected = false;
  Map<String, dynamic>? _gpu;

  @override
  void initState() {
    super.initState();
    _connected = bridge.connected;
    _sub = bridge.llamaResults.listen(_onMsg);
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
      if (t == 'llama_models') {
        _models = List<Map<String, dynamic>>.from(m['models'] ?? []);
      } else if (t == 'llama_status') {
        final s = m['server'];
        if (s is Map) {
          _servers = [Map<String, dynamic>.from(s)];
          _gpu = (s['gpu'] is Map)
              ? Map<String, dynamic>.from(s['gpu'] as Map)
              : null;
        } else {
          _servers = List<Map<String, dynamic>>.from(m['servers'] ?? []);
          _gpu = null;
        }
      } else if (t == 'llama_load_result') {
        _loading = false;
        final ga = m['gpu_after'];
        final gpuTxt = (ga is Map && (ga['used'] ?? 0) != 0)
            ? '  显存 ${ga['used']} / ${ga['total']} MiB'
            : '';
        _msg = (m['message'] ?? '加载完成').toString() + gpuTxt;
        _refresh();
      } else if (t == 'llama_unload_result') {
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
    bridge.llamaListModels();
    bridge.llamaStatus();
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
      appBar: AppBar(title: const Text('llama.cpp 管理器')),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('运行状态',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('刷新'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('管理器端口 $portHint · 当前加载模型：',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            ..._servers.map((s) {
              final port = (s['port'] ?? '').toString();
              final running = s['running'] == true;
              final model = (s['model'] ?? '').toString();
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.circle,
                        size: 10,
                        color: running ? Colors.green : Colors.grey),
                    const SizedBox(width: 6),
                    Text('$port',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(model.isEmpty
                          ? (running ? '运行中(未知模型)' : '未运行')
                          : model,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              );
            }),
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

  String get portHint => '$_port';

  Widget _paramsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('加载参数', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _portField(),
            const SizedBox(height: 4),
            Text('上下文长度: $_context',
                style: const TextStyle(fontSize: 13)),
            Slider(
              value: _context.toDouble().clamp(256, 131072),
              max: 131072,
              divisions: 64,
              label: '$_context',
              onChanged: (v) => setState(() => _context = v.round()),
            ),
            Text('GPU 层数: $_gpuLayers（-1=全部下放 GPU，0=纯 CPU）',
                style: const TextStyle(fontSize: 13)),
            Slider(
              value: _gpuLayers.toDouble().clamp(-1, 99),
              max: 99,
              min: -1,
              divisions: 100,
              label: '$_gpuLayers',
              onChanged: (v) => setState(() => _gpuLayers = v.round()),
            ),
            Text('线程数: $_threads', style: const TextStyle(fontSize: 13)),
            Slider(
              value: _threads.toDouble().clamp(1, 64),
              max: 64,
              min: 1,
              divisions: 63,
              label: '$_threads',
              onChanged: (v) => setState(() => _threads = v.round()),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  bridge.llamaUnload(port: _port);
                  setState(() {
                    _loading = true;
                    _msg = '正在卸载端口 $_port ...';
                  });
                },
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('卸载当前端口'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _portField() {
    return TextField(
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: '加载端口（默认 8090，勿与现有 8081-8084 冲突）',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      onChanged: (v) => _port = int.tryParse(v) ?? 8090,
    );
  }

  Widget _modelTile(Map<String, dynamic> m, Color primary) {
    final name = (m['name'] ?? '').toString();
    final size = (m['size_gb'] ?? 0).toString();
    final busy = _loading;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.memory),
        title: Text(name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13)),
        subtitle: Text('$size GB'),
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
                    _msg = '正在加载 $name ...（大模型需等待）';
                  });
                  bridge.llamaLoad(name,
                      port: _port,
                      context: _context,
                      gpuLayers: _gpuLayers,
                      threads: _threads);
                },
                child: const Text('加载', style: TextStyle(fontSize: 13)),
              ),
      ),
    );
  }
}
