import 'dart:async';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';

import 'bridge_client.dart';
import 'chat_tab.dart';
import 'models.dart';
import 'settings_tab.dart';
import 'theme.dart';

/// ============ 主页面：底部导航（聊天 / 设置） ============
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  StreamSubscription? _audioSub;

  @override
  void initState() {
    super.initState();
    _loadTheme();
    _audioSub = bridge.onAudio.listen((bytes) {
      audioPlayer.play(BytesSource(bytes));
    });
    _autoConnect();
  }

  /// 启动时自动连接：读取已保存的电脑局域网 IP/端口。
  /// 有记录即自动连接；失败由 bridge 内部指数退避自动重连（1s→30s），
  /// 无需手动点「连接」，解决重启后不会自动连、频繁掉线的问题。
  Future<void> _autoConnect() async {
    final s = await SettingsStore.load();
    final h = (s['host'] ?? '').toString().trim();
    final raw = s['port'];
    final p = raw is int
        ? raw
        : int.tryParse(raw.toString()) ?? 8765;
    if (h.isNotEmpty && p > 0) {
      await bridge.connect(h, p);
    }
  }

  Future<void> _loadTheme() async {
    final s = await SettingsStore.load();
    themeModeNotifier.value =
        (s['theme'] == 'dark') ? ThemeMode.dark : ThemeMode.light;
  }

  @override
  void dispose() {
    _audioSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const ConversationDrawer(),
      body: IndexedStack(
        index: _tab,
        children: const [ChatTab(), SettingsTab()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat), label: '聊天'),
          NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}
