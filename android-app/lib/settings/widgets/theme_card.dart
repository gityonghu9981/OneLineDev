import 'package:flutter/material.dart';

/// ============ 外观主题 ============
/// 白底黑字 / 黑底白字 两档切换。
class ThemeCard extends StatelessWidget {
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onChanged;
  const ThemeCard({super.key, required this.themeMode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('外观主题', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    label: const Text('白底黑字'),
                    selected: themeMode == ThemeMode.light,
                    onSelected: (_) => onChanged(ThemeMode.light),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChoiceChip(
                    label: const Text('黑底白字'),
                    selected: themeMode == ThemeMode.dark,
                    onSelected: (_) => onChanged(ThemeMode.dark),
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
