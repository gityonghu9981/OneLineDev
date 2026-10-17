import 'dart:async';

import 'package:flutter/material.dart';

import '../../bridge_client.dart';
import 'backend_settings_page.dart';
import 'llama_manager_page.dart';
import 'strata_manager_page.dart';

/// ============ 后端列表页 ============
class BackendListPage extends StatefulWidget {
  final String activeBackendId;
  final ValueChanged<String> onSelect;
  const BackendListPage({
    super.key,
    required this.activeBackendId,
    required this.onSelect,
  });

  @override
  State<BackendListPage> createState() => _BackendListPageState();
}

class _BackendListPageState extends State<BackendListPage> {
  StreamSubscription? _backendsSub;
  List<Map<String, dynamic>> _backends = [];

  @override
  void initState() {
    super.initState();
    _backends = List<Map<String, dynamic>>.from(bridge.backends);
    _backendsSub = bridge.onBackends.listen((list) {
      if (!mounted) return;
      setState(() => _backends = list);
    });
    bridge.listBackends();
  }

  @override
  void dispose() {
    _backendsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('后端设置')),
      body: _backends.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('暂无后端列表，连接成功后自动加载',
                    style: TextStyle(color: Colors.grey)),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('选择当前对话后端',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        const Text('选中即自动切换；点某一行可进入该后端的独立设置',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                        const SizedBox(height: 8),
                        ..._backends.map((b) {
                          final id = (b['id'] ?? '').toString();
                          final name = (b['name'] ?? id).toString();
                          final type = (b['type'] ?? '').toString();
                          final running =
                              (b['status'] ?? '').toString() == 'running';
                          final selected = id == widget.activeBackendId;
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Radio<String>(
                              value: id,
                              groupValue:
                                  widget.activeBackendId.isEmpty ? null : widget.activeBackendId,
                              onChanged: (v) {
                                if (v != null) widget.onSelect(v);
                              },
                            ),
                            title: Text(name),
                            subtitle: Text(type),
                            trailing: Icon(Icons.circle,
                                size: 12,
                                color: running ? Colors.green : Colors.grey),
                            onTap: () => widget.onSelect(id),
                            selected: selected,
                            selectedTileColor:
                                Theme.of(context).colorScheme.primaryContainer,
                          );
                        }),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text('各后端独立设置',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: Colors.grey)),
                const SizedBox(height: 4),
                ..._backends.map((b) {
                  final id = (b['id'] ?? '').toString();
                  final name = (b['name'] ?? id).toString();
                  final type = (b['type'] ?? '').toString();
                  final running = (b['status'] ?? '').toString() == 'running';
                  final port = (b['port'] ?? '').toString();
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(
                        running ? Icons.settings : Icons.settings_outlined,
                        color: running ? Colors.green : Colors.grey,
                      ),
                      title: Text('$name 设置',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          '${running ? '运行中' : '未运行'}${port.isNotEmpty ? ' · 端口 $port' : ''} · $type'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        widget.onSelect(id);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                BackendSettingsPage(backendId: id),
                          ),
                        );
                      },
                    ),
                  );
                }),
                const SizedBox(height: 4),
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  child: ListTile(
                    leading: Icon(Icons.library_books,
                        color: Theme.of(context).colorScheme.primary),
                    title: const Text('llama.cpp 管理器',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('统一模型库，随便选模型 + 调参 + 加载切换'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LlamaManagerPage(),
                      ),
                    ),
                  ),
                ),
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  child: ListTile(
                    leading: Icon(Icons.sd_storage,
                        color: Theme.of(context).colorScheme.primary),
                    title: const Text('Strata 管理器',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('orca 专用引擎，上下文/KV量化/GPU驻留显存控制'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const StrataManagerPage(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
