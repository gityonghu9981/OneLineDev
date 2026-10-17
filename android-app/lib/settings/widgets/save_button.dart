import 'package:flutter/material.dart';

/// ============ 保存设置 ============
/// 一键把当前设置（声线、上下文、压缩等）保存到电脑。
class SaveButton extends StatelessWidget {
  final VoidCallback onSave;
  final bool saving;
  const SaveButton({super.key, required this.onSave, this.saving = false});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: saving ? null : onSave,
      icon: saving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.save),
      label: Text(saving ? '保存中…' : '保存设置'),
      style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14)),
    );
  }
}
