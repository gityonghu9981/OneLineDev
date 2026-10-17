import 'package:flutter/material.dart';

/// ============ 连接管理 ============
/// 电脑局域网 IP + 端口 + 连接/断开。
class ConnectionCard extends StatelessWidget {
  final TextEditingController hostCtrl;
  final TextEditingController portCtrl;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final bool connecting; // 连接动作进行中：按键置灰并转圈
  final bool connected;  // 已连接：断开可点
  const ConnectionCard({
    super.key,
    required this.hostCtrl,
    required this.portCtrl,
    required this.onConnect,
    required this.onDisconnect,
    this.connecting = false,
    this.connected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('连接管理', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: hostCtrl,
              decoration: const InputDecoration(
                labelText: '电脑局域网 IP',
                hintText: '例如 192.168.1.100',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '端口',
                hintText: '8765',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: connecting ? null : onConnect,
                    icon: connecting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.link),
                    label: Text(connecting ? '连接中…' : '连接'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (connecting || !connected) ? null : onDisconnect,
                    icon: const Icon(Icons.link_off),
                    label: const Text('断开'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
