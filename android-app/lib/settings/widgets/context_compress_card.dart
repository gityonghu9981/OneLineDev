import 'package:flutter/material.dart';

/// ============ 智能上下文压缩 ============
/// 对话历史接近模型上下文上限时，自动把最旧对话压成概要。
class ContextCompressCard extends StatelessWidget {
  final bool enabled;
  final double ratio;
  final int batch;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<double> onRatio;
  final ValueChanged<int> onBatch;
  const ContextCompressCard({
    super.key,
    required this.enabled,
    required this.ratio,
    required this.batch,
    required this.onEnabled,
    required this.onRatio,
    required this.onBatch,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('智能上下文压缩', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(
                  child: Text('启用压缩',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                Switch(value: enabled, onChanged: onEnabled),
              ],
            ),
            Text(
              '当对话历史接近模型上下文上限时，自动把最旧对话压成概要（不删除历史要点）',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Text('触发阈值: ${(ratio * 100).round()}%'),
            Slider(
              value: ratio.clamp(0.3, 0.95),
              min: 0.3,
              max: 0.95,
              divisions: 13,
              label: '${(ratio * 100).round()}%',
              onChanged: onRatio,
            ),
            Text('单次压缩条数: $batch'),
            Slider(
              value: batch.toDouble().clamp(4, 50),
              min: 4,
              max: 50,
              divisions: 23,
              label: '$batch',
              onChanged: (v) => onBatch(v.round()),
            ),
          ],
        ),
      ),
    );
  }
}
