import 'package:flutter/material.dart';

import 'home_page.dart';
import 'theme.dart';

/// ============ 入口 ============
/// 本文件只负责启动与主题外壳。各功能模块见：
///   bridge_client.dart  通信协议  models.dart  数据模型  theme.dart  主题
///   home_page.dart      底部导航    chat_tab.dart 聊天页  settings_tab.dart 设置页
/// 追加新功能：先改对应模块文件，不要动本文件以外无关内容；新增页面/能力按模块新建文件。
void main() {
  runApp(const LocalAiApp());
}

class LocalAiApp extends StatelessWidget {
  const LocalAiApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (_, mode, _) {
        return MaterialApp(
          title: '本地AI窗口',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.indigo, brightness: Brightness.light),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.indigo, brightness: Brightness.dark),
            useMaterial3: true,
          ),
          themeMode: mode,
          home: const HomePage(),
        );
      },
    );
  }
}
