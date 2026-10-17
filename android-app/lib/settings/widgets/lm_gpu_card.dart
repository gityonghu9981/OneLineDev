import 'package:flutter/material.dart';

/// ============ LM Studio GPU 加载参数卡（可复用） ============
/// 显示 GPU 显存占用 + GPU 分流比例 + 上下文长度。
/// 主页「本地模型管理」和 LM Studio 后端详情页共用。
class LmGpuCard extends StatefulWidget {
  final Map<String, dynamic> gpu;
  final double gpuRatio;
  final int context;
  final ValueChanged<double> onRatioChanged;
  final ValueChanged<int> onContextChanged;
  // 松手（onChangeEnd）时回调，用于持久化保存，避免切换页面恢复
  final ValueChanged<double>? onRatioEnd;
  final ValueChanged<int>? onContextEnd;
  const LmGpuCard({
    super.key,
    required this.gpu,
    required this.gpuRatio,
    required this.context,
    required this.onRatioChanged,
    required this.onContextChanged,
    this.onRatioEnd,
    this.onContextEnd,
  });

  @override
  State<LmGpuCard> createState() => _LmGpuCardState();
}

class _LmGpuCardState extends State<LmGpuCard> {
  @override
  Widget build(BuildContext context) {
    final total = (widget.gpu['total'] ?? 0) as num;
    final used = (widget.gpu['used'] ?? 0) as num;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.gpu.isNotEmpty) ...[
          Text(
            'GPU ${widget.gpu['name'] ?? ''} · 已用 ${(used / 1024).toStringAsFixed(1)}G / ${(total / 1024).toStringAsFixed(1)}G',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: total > 0 ? (used / total).clamp(0.0, 1.0) : 0,
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
            '加载参数 · GPU分流: ${widget.gpuRatio >= 1 ? 'max' : '${(widget.gpuRatio * 100).round()}%'}'),
        Slider(
          value: widget.gpuRatio.clamp(0.0, 1.0),
          min: 0.0,
          max: 1.0,
          divisions: 10,
          label: widget.gpuRatio >= 1
              ? 'max'
              : '${(widget.gpuRatio * 100).round()}%',
          onChanged: widget.onRatioChanged,
          onChangeEnd: widget.onRatioEnd,
        ),
        Text('上下文: ${widget.context}'),
        const Text(
            '加载参数在「重新加载模型」时生效：改完请点对应模型的「加载」，聊天才会用新上下文/GPU分流',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
        Slider(
          value: widget.context.toDouble().clamp(512, 32768),
          min: 512,
          max: 32768,
          divisions: 20,
          label: '${widget.context}',
          onChanged: (v) => widget.onContextChanged(v.round()),
          onChangeEnd: (v) => widget.onContextEnd?.call(v.round()),
        ),
      ],
    );
  }
}
