import 'package:flutter/material.dart';

/// ============ 使用说明 ============
class HelpCard extends StatelessWidget {
  const HelpCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '使用说明\n\n'
          '1. 电脑端需运行「LocalAI Bridge」（YOUR_PROJECT_DIR\\bridge\\start_server.ps1，或用桌面启动脚本）\n'
          '2. 手机和电脑连同一个 WiFi\n'
          '3. 在手机设置里填入电脑的局域网 IP（电脑上运行 ipconfig 查看）\n'
          '4. 点击「连接」，选后端和模型，即可聊天并播放语音\n'
          '5. 每个后端都有独立设置卡，可单独调上下文/温度、一键启停\n'
          '6. 每条消息下有操作按钮：播放 / 重置 / 删除；自己的消息可重发、修改\n'
          '7. 底部可切换「键盘」或「语音」输入（按住说话）\n'
          '8. 语音由电脑本地 GPT-SoVITS 合成',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
      ),
    );
  }
}
