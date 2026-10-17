import 'package:flutter/material.dart';

/// ============ 声线选择 ============
/// 选择电脑本地 GPT-SoVITS 已训练的声线，无需手动填路径。
class VoiceCard extends StatelessWidget {
  final List<Map<String, String>> voices;
  final String? curVoice;
  final VoidCallback onRefresh;
  final ValueChanged<String> onSelect;
  const VoiceCard({
    super.key,
    required this.voices,
    required this.curVoice,
    required this.onRefresh,
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
            Text('声线选择', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('选择电脑本地 GPT-SoVITS 已训练的声线，无需手动填路径',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            if (voices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('暂无声线，点下方"刷新声线"加载',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              )
            else
              ...voices.map((v) {
                final ref = (v['ref'] ?? '').toString();
                final label = (v['label'] ?? ref).toString();
                final selected = curVoice == ref;
                return RadioListTile<String>(
                  value: ref,
                  groupValue: curVoice,
                  onChanged: (_) => onSelect(ref),
                  title: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                );
              }),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新声线'),
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
