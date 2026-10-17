import 'package:flutter/material.dart';

/// ============ 后端选择 ============
/// 选择当前对话使用的模型后端（各后端聊天记录独立保留）。
/// 各后端的详细设置见下方各自的独立卡片。
class BackendSelectorCard extends StatelessWidget {
  final List<Map<String, dynamic>> backends;
  final String activeBackendId;
  final ValueChanged<String> onSelect;
  const BackendSelectorCard({
    super.key,
    required this.backends,
    required this.activeBackendId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('后端选择', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('选择对话使用的后端，选中后自动切换；各后端聊天记录独立保留',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            if (backends.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('暂无后端列表，连接成功后自动加载',
                    style: TextStyle(color: Colors.grey)),
              )
            else
              RadioGroup<String>(
                groupValue: activeBackendId.isEmpty ? null : activeBackendId,
                onChanged: (v) {
                  if (v == null) return;
                  onSelect(v);
                },
                child: Column(
                  children: backends.map((b) {
                    final id = (b['id'] ?? '').toString();
                    final name = (b['name'] ?? id).toString();
                    final type = (b['type'] ?? '').toString();
                    final status = (b['status'] ?? 'unknown').toString();
                    final running = status == 'running';
                    return RadioListTile<String>(
                      value: id,
                      title: Text(name),
                      subtitle: Text(type),
                      secondary: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle,
                              size: 12,
                              color: running ? Colors.green : Colors.grey),
                          const SizedBox(height: 2),
                          Text(running ? '运行中' : '未运行',
                              style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
