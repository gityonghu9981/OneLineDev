# 一句话开发（OneLineDev / LocalAI-App）

> 一个"手机当窗口、电脑当大脑"的本地大模型控制端：手机 Android APP 通过局域网连到 Windows 电脑上的本地中转服务，把你电脑上的本地模型（LM Studio / llama.cpp / Strata / OpenClaw / QwenPaw）都变成可以在手机上随意切换、设置、对话、语音互动的"窗口"。

---

## ⚠️ 安全警告（请务必先读）

- 本系统（手机 APP ↔ 电脑中转 ↔ 各模型后端）全部通过 **明文 WS/HTTP 通信，没有加密**。
- 请**只在可信的家庭/办公局域网内使用**，手机连接的是你自己电脑的局域网 IP。
- **严禁**把中转端口（默认 8765）暴露到公网或用内网穿透映射到互联网——任何人连上都能读取你的对话内容、看到你的后端配置（含模型路径与令牌）。
- 中转配置里的 OpenClaw 令牌、后端程序路径都是明文，只保存在本机。
- 建议：在防火墙里仅允许局域网网段访问 8765 端口；手机端连接地址务必是电脑的局域网 IP，而非公网 IP。

---

## 致谢

本项目由 **AI 助手「豆包」** 协助完成**代码实现与测试实施**。

## 免责声明

本仓库为**独立开源项目**，非字节跳动/豆包官方发布，与官方产品无关，**无官方背书、无官方支持**；文中涉及的第三方软件与商标归各自权利人所有。

## 欢迎大家完善补充

这是一个个人驱动的开源项目，欢迎任何形式的贡献：提 Issue、提 PR、补充文档、翻译、测试、建议新功能。一起把它做得更好。

---

## 架构总览

```
┌─────────────┐  WS(明文,局域网)  ┌──────────────────┐  按后端协议  ┌───────────────────┐
│ 手机 Android│ ────────────────→ │ Windows 中转服务  │ ───────────→ │ 本地模型后端       │
│  窗口 APP    │ ←─────────────── │ bridge/server.py │ ←─────────── │ LM Studio / llama  │
└─────────────┘                   │  (默认端口 8765)  │             │ / Strata / OpenClaw│
                                 │    + TTS/STT     │             │ / QwenPaw          │
                                 └──────────────────┘             └───────────────────┘
```

- **手机端**：Flutter 写的 Android APP，纯"窗口"，所有算力都在电脑。
- **电脑端中转**：Python 服务（`bridge/server.py`），统一对接多个后端、下发命令、桥接 TTS（语音播放）与 STT（按住说话转文字）。
- **后端**：电脑上各自的本地模型程序，通过各自端口供中转调用。

## 各后端默认端口

| 后端 | 类型 | 端口 | 可控 |
|------|------|------|------|
| LM Studio | openai | 1234 | 否（软件内设置） |
| OpenClaw | openclaw | 18789 | 是 |
| QwenPaw | qwenpaw | 8088 | 是 |
| llama.cpp 统一管理器 | openai | 8090 | 是 |
| Strata 统一管理器 | openai | 8080 | 是 |

> llama.cpp / Strata 采用"统一管理器"：一个端口，可在手机 APP 里随意选模型、调参数、加载/卸载。

---

## 第三方依赖（只索引，不打包）

| 用途 | 项目 | 说明 |
|------|------|------|
| 本地模型 | [LM Studio](https://lmstudio.ai/) | 闭源，官方下载，可在 APP 加载/卸载模型 |
| llama 引擎 | [llama.cpp](https://github.com/ggerganov/llama.cpp) | MIT，`llama-server` 由 APP 统一管理 |
| Strata 引擎 | Strata | 私有引擎，serve 层由中转桥接 |
| 智能体网关 | OpenClaw | 开源，独立端口设置 |
| 智能体网关 | QwenPaw | 独立端口设置 |
| TTS 语音 | [GPT-SoVITS](https://github.com/RVC-Boss/GPT-SoVITS) | MIT，独立程序，中转桥接 |
| STT 语音 | [faster-whisper](https://github.com/SYSTRAN/faster-whisper) | MIT，按住说话转文字 |
| APP 框架 | [Flutter](https://flutter.dev/) | 构建手机 APP |

以上均为各自项目的独立程序，本仓库**不打包任何模型文件、不打包上述程序**，请在 README/各项目官网自行获取。

---

## 快速开始

### 1. 电脑端中转

```bash
cd bridge
pip install -r requirements.txt
cp config.example.json config.json   # 然后按你的环境填写占位符
python server.py
```

- 中转默认监听 `0.0.0.0:8765`，WS 地址 `ws://<电脑局域网IP>:8765/ws`。
- 必须按你的环境填 `config.json`：各后端的 `executable`/`cwd`/`args` 路径、OpenClaw 的 `token`、TTS 参考音频 `tts_ref_audio`、默认模型名等。

### 2. 手机 APP 构建（Android）

```bash
cd android-app
flutter pub get
flutter build apk --release
```

- 产物：`android-app/build/app/outputs/flutter-apk/app-release.apk`。
- 或直接 `flutter run` 在已连 adb 的设备/模拟器上调试。

### 3. 连接手机

1. 电脑与手机连**同一局域网**。
2. APP 设置页「连接管理」填电脑局域网 IP + 端口 8765。
3. 点「连接」，APP 显示"已连接本地电脑"即成功。

### 4. 启动后端的顺序

- 中转启动后，**不会自动拉起任何模型**（`active_backend: null`）。
- 在 APP 里手动选择后端并加载模型（llama/Strata 用统一管理器加载），电脑端才回应。
- 各独立后端（OpenClaw/QwenPaw/LM Studio）需先在电脑端启动对应软件。

---

## 测试用的小模型示例

- **llama.cpp**：可用 `Ternary-Bonsai-27B-Q2_g64.gguf`（约 7.6GB，4 秒就绪）等小量化模型快速验证加载与对话。
- **LM Studio**：官方市场选小参数量模型即可。
- **Strata**：用 Strata 自带 pack 或小模型测试。

> 本仓库**不提供任何模型文件**，请从合法渠道（各模型官网 / HuggingFace / 模型社区）自行下载符合你机器显存与许可要求的模型。

---

## 目录结构

```
LocalAI-App/
├── bridge/            # 电脑端中转服务（自研）
│   ├── server.py          # 中转主服务
│   ├── backends_llama.py  # llama.cpp 统一管理器
│   ├── backends_strata.py # Strata 统一管理器
│   ├── config.example.json# 配置模板（脱敏）
│   └── requirements.txt   # Python 依赖
├── android-app/       # 手机 APP（自研，Flutter）
│   └── lib/               # Dart 源码
├── docs/              # 文档
└── LICENSE            # Apache-2.0
```

## 发布版说明（重要）

- 本仓库是**脱敏发布版**：`bridge/server.py`、`backends_llama.py`、`backends_strata.py` 中涉及本机的**默认路径、OpenClaw 令牌、模型名**均已替换为 `YOUR_XXX` 占位符。
- **使用前**请对照代码中的 `YOUR_XXX` 提示与 `config.example.json`，填你自己的环境：模型库路径、各后端可执行文件路径、OpenClaw 令牌、TTS 参考音频、默认模型名等。
- 发布版与本机运行版**相互独立**，迭代互不影响；本仓库**不包含任何模型文件与第三方程序**。
- 用到的第三方（LM Studio、llama.cpp、GPT-SoVITS、faster-whisper 等）请按上方索引自行获取，并遵守各自 License。

## License

Apache License 2.0。见 [LICENSE](LICENSE)。

**注意**：第三方依赖（LM Studio、llama.cpp、GPT-SoVITS 等）各有自己的 License，请在使用/分发前遵守其相应条款。
