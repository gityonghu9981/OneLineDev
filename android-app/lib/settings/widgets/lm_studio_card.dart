import 'package:flutter/material.dart';

import '../../bridge_client.dart';
import 'lm_gpu_card.dart';

/// ============ LM Studio 本地模型管理 ============
/// 直接在手机上加载/卸载 LM Studio 里的模型、查看显存、控制加载参数。
class LmStudioCard extends StatefulWidget {
  final List<Map<String, dynamic>> models;
  final Map<String, dynamic> gpu;
  final double gpuRatio;
  final int context;
  final bool busy;
  final void Function(String model, String gpu, int context) onLoad;
  final void Function(String model) onUnload;
  final ValueChanged<double> onRatioChanged;
  final ValueChanged<int> onContextChanged;
  final ValueChanged<double>? onRatioEnd;
  final ValueChanged<int>? onContextEnd;
  /// 设为当前对话模型（合并 BackendSettingsCard 的「选择模型」，避免两个模型列表重复）
  final ValueChanged<String> onSelectModel;
  /// 当前对话模型 id，用于在列表中高亮
  final String curModel;
  const LmStudioCard({
    super.key,
    required this.models,
    required this.gpu,
    required this.gpuRatio,
    required this.context,
    required this.busy,
    required this.onLoad,
    required this.onUnload,
    required this.onRatioChanged,
    required this.onContextChanged,
    required this.onSelectModel,
    required this.curModel,
    this.onRatioEnd,
    this.onContextEnd,
  });

  @override
  State<LmStudioCard> createState() => _LmStudioCardState();
}

class _LmStudioCardState extends State<LmStudioCard> {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('本地模型管理（LM Studio）',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新',
                  onPressed: () => bridge.lmListLocal(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('直接在手机上加载/卸载 LM Studio 里的模型，无需改配置文件',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            LmGpuCard(
              gpu: widget.gpu,
              gpuRatio: widget.gpuRatio,
              context: widget.context,
              onRatioChanged: widget.onRatioChanged,
              onContextChanged: widget.onContextChanged,
              onRatioEnd: widget.onRatioEnd,
              onContextEnd: widget.onContextEnd,
            ),
            const SizedBox(height: 8),
            if (widget.models.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('暂无模型列表，点击右上角刷新',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              )
            else
              ...widget.models.map((mm) {
                final id = (mm['id'] ?? '').toString();
                final loaded = mm['loaded'] == true;
                final isCur = id == widget.curModel;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    isCur
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: isCur
                        ? Colors.blue
                        : (loaded ? Colors.green : Colors.grey),
                  ),
                  title: Text(id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                  subtitle: Text(
                      '${mm['size'] ?? ''}${loaded ? ' · 已加载' : ''}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  // 点行设为当前对话模型
                  onTap: () => widget.onSelectModel(id),
                  trailing: loaded
                      ? OutlinedButton(
                          onPressed: widget.busy
                              ? null
                              : () => widget.onUnload(id),
                          child: const Text('卸载'))
                      : FilledButton(
                          onPressed: widget.busy
                              ? null
                              : () {
                                  widget.onLoad(
                                      id,
                                      widget.gpuRatio >= 1
                                          ? 'max'
                                          : widget.gpuRatio.toString(),
                                      widget.context);
                                },
                          child: const Text('加载')),
                );
              }),
          ],
        ),
      ),
    );
  }
}
