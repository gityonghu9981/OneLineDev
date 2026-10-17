import 'package:flutter/material.dart';

/// ============ 全局主题模式（明暗切换） ============
/// 供设置页切换、全局应用。新增主题只需在此扩展枚举或 ValueNotifier 逻辑。
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.light);
