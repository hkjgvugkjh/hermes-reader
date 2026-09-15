# hermes-reader

小方盒管理 + 电子阅读器 + 语音对话终端。Flutter 客户端，通过 hermes-proxy
（或直接连接）访问服务器工作区 `library/` 目录下的书籍，支持离线缓存、断点续读
与语音朗读。

---

## 功能

### 连接

- **双模式接入**：代理模式（经 hermes-proxy 管理多台服务器）/ 独立模式（手动增删服务器直连）
- **扫码接入**：扫描配置二维码写入 proxy 地址与 token；也支持手动编辑
- **自动重连**：启动时若存在已保存配置，自动完成连接并拉取服务器列表
- **安全传输**：与服务器之间的文件/会话通道经 X25519 + AES-GCM 加密

### 会话与待办

- **会话清单**：按服务器分组显示会话状态（running / stopped / pending），轮询刷新
- **会话详情**：点击会话弹出对话框，展示会话快照（历史消息，Markdown 渲染），
  底部输入框可继续对话并自动刷新快照
- **状态变更提醒**：会话结束或等待输入时通过本地通知与 Snackbar 提示
- **待办事项**：展示服务器端任务列表

### 书架

- 列出服务器 `library/` 下的可读文件，显示大小与是否已缓存
- 支持下拉刷新，刷新后重新探测本地缓存状态
- 下载到本地私有目录（不落外部存储），可删除本地副本
- 沙箱约束：仅允许读取 `library/` 内文件，单文件上限 20 MB，单次传输上限 50 MB，
  目录递归深度上限 3

### 阅读

- 纯文本分页渲染，字号四档可调（0.85 / 1.0 / 1.2 / 1.5）
- **三区分页配置**（`TapZoneMode`）：
  - `thirds` 左中右三区：左右翻页，中间切换控制栏
  - `halves` 左右两区：仅翻页
  - `edges` 仅边缘响应：两侧 10% 翻页，中间切换控制栏
  - `leftZoneForward` 可反转左右区方向
- 左右滑动翻页（阈值 ±300 px/s）与点击分区并存
- **阅读位置记忆**：按书籍 id 持久化页码与进度到 `SharedPreferences`，
  打开时自动恢复，退出阅读页时保存
- 底部进度条与 `当前页 / 总页数` 显示
- 阅读设置面板：分区模式、左右方向、朗读自动翻页、每页字数，设置随本地配置持久化
- 书架显示每本书的已读百分比，并提供"从头开始"入口

### 语音朗读

- **双引擎**：服务端合成优先，失败或离线自动降级到本机 `flutter_tts`
  （`TtsMode.auto` / `server` / `local`）
- 降级时在顶部横幅说明原因，不中断朗读
- 自动翻页朗读：当前页读完且 `autoTurnPage` 开启时自动进入下一页，翻页同时更新朗读进度
- **朗读进度记忆**：记录停在第几页、第几个字符，下次朗读从断点续读；读完自动清除
- **历史播放点选择**：再次点击朗读时若存在其他页的播放点，弹出「继续朗读 / 朗读本页」选择；
  弹窗期间即在后台预热引擎（加载模型），选定后起播更快
- 分句流式合成：按标点切分并预取下一句音频，翻页等待显著降低
- 不支持朗读的格式（`.mobi` `.html` `.json`）按钮置灰并给出提示
- 停止朗读时对已停止的引擎异常做静默处理，不再抛出 "all TTS engines failed"
- 本机引擎对单次朗读设置 2 分钟超时，避免无 TTS 引擎的设备卡死

### 离线 TTS 模型（内置朗读）

本机朗读依赖 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 的 Piper 中文模型，
**模型文件不入库**（体积约 60 MB），构建/发版时直接放入 `assets/tts/` 即可被打包。

`assets/tts/` 需要的文件：

| 文件                | 说明                              |
|---------------------|-----------------------------------|
| `model.onnx`        | 中文 TTS 语音模型（Piper）        |
| `tokens.txt`        | 音素/token 表                     |
| `model.onnx.json`   | 模型元信息（采样率、espeak 配置） |
| `espeak-ng-data.zip`| 音素化所需 espeak-ng 数据         |

**自动下载**（联网环境）：

```bash
scripts/fetch_tts_model.sh assets/tts
```

脚本从 sherpa-onnx 官方 release 拉取 `piper-zh_CN-huayan-x_low` 并归一化为上述文件名。
`espeak-ng-data.zip` 由同一模型包提供，需一并放入 `assets/tts/`。

**手动放置**（离线/CI 环境）：把上述四个文件拷入 `assets/tts/`，无需联网。
`assets/tts/README.txt` 与 `pubspec.yaml` 的 `assets:` 声明已就绪，重新构建即可生效。

> 缺少模型文件时，内置朗读会回退到系统 `flutter_tts`（无系统引擎则提示不可用）。

### 错误提示与日志

- **人性化错误提示**：网络切换、断连、超时、DNS 失败、服务器 4xx/5xx 等统一映射为
  中文友好文案（如「连接被中断（网络可能已切换），请重试」），不再把
  `SocketException` / `WebSocketChannelException` 原始堆栈直接展示给用户
- 提示采用浮动 SnackBar + 分类图标，可选「重试」动作
- **日志落盘**：日志同时写入用户存储 `<documents>/hermes_logs/hermes-YYYY-MM-DD.log`，
  按天分文件、追加写入、自动保留最近 7 天；原始技术细节进日志，界面只显示摘要。
  方便网络异常后回溯诊断。

---

## 支持的文件格式

| 格式 | 书架可见 | 翻阅 | 语音朗读 |
|------|:--------:|:----:|:--------:|
| `.txt` `.md` | ✅ | ✅ | ✅ |
| `.pdf` | ✅ | ✅ | ✅ |
| `.epub` | ✅ | ✅ | ✅ |
| `.mobi` `.html` `.htm` `.json` | ✅ | ✅ | — |

识别由 `FileTypeDetector` 按扩展名完成，未识别的扩展名不会出现在书架上。
`.pdf` 与 `.epub` 由 `BookTextExtractor` 提取文本后按原始页码 / 章节分页；
`.html`、`.mobi` 去标签后作为文本；`.json` 重新缩进后展示。

**PDF 提取的限制**：为保持纯 Dart、避免构建时下载 PDFium（约 10 MB，受限网络下会失败），
PDF 文本由内置的轻量提取器读取内容流得到，覆盖普通字符串与 UTF-16BE 十六进制字符串。
使用外部 ToUnicode CMap 映射字形（部分中文 PDF）时会得到乱码，扫描件则无文本可提。

> **二进制传输说明**：`files/read` 以 JSON 信封 `{"content": "..."}` 返回，服务端会把
> 二进制当 UTF-8 解码，>= 0x80 的字节变成 U+FFFD（体积膨胀约 2.5 倍）。客户端会剥掉信封、
> 检测污染并尝试 `encoding=base64` 重取；服务端若不支持，二进制内容仍会损坏。
> 文本格式不受影响。彻底解决需要服务端提供二进制安全端点。

---

## 目录结构

```
lib/
  main.dart                    应用入口、provider 装配、启动自检
  reader/
    models/                    Book / ReaderConfig / 全局配置
    providers/                 书架、阅读、会话、任务、服务器状态
    services/                  传输、沙箱、TTS、分页、进度持久化等
    screens/                   书架、阅读、会话、待办
```

---

## 构建与运行

需要 Flutter 3.44+ / Dart 3.12+，以及 Android SDK 与 JDK 17。

```bash
export PATH=<flutter-sdk>/bin:$PATH
export ANDROID_HOME=<android-sdk>
export JAVA_HOME=<jdk-17>

flutter pub get
flutter test                     # 43 个单元测试
flutter analyze
```

日常开发用 debug 变体，构建与安装都明显快于 release：

```bash
flutter build apk --debug        # build/app/outputs/flutter-apk/app-debug.apk
adb install -r build/app/outputs/flutter-apk/app-debug.apk
flutter run -d <device-id>       # 或一步到位
```

发版时再出 release：`flutter build apk --release`（约需数分钟）。

调试桌面上可直接 `flutter run -d linux`。

---

## 更新说明

### 2026-09 迭代

**会话**

- 新增会话详情对话框：展示会话快照（历史消息，Markdown 渲染，代码块等宽灰底），
  底部输入框可续聊并自动刷新。
- 修复读取会话快照 `HTTP 401 未授权`：请求未携带 `Authorization`。现优先使用
  代理下发的后端 JWT（`ProxyClient.backendJWT`），缺失时回退到服务器 `authToken`。

**语音朗读**

- 修复内置引擎无声根因：WAV 头写入时 `RIFF/WAVE/fmt/data` 标签互相覆盖，文件头被写坏，
  播放器报 `UnrecognizedInputFormatException`。
- 播放改为等待播放完成（监听 `ProcessingState.completed`），不再用固定延时打断；
  分句流式合成（首块 50 字、块长 1.7 倍递增），翻页起播延迟由数十秒降至约 1 秒。
- 新增历史播放点选择（继续朗读 / 朗读本页），弹窗期间后台预热引擎。
- 自动翻页时同步更新播放点，中途退出也能从最新页续读。
- 修复退出阅读页后仍在朗读的问题（`dispose` 前清除朗读状态）。
- 推理线程数 `1 → 4`，提升合成速度。

**界面**

- 底部菜单正中间新增「本地文库」入口。

**健壮性**

- 新增统一错误映射与提示组件，各类网络/服务器异常以人性化中文文案呈现。
- 日志落盘到用户存储（`<documents>/hermes_logs/`，按天分文件，保留 7 天）。

**服务端（hermes-proxy / hermes-shared，配套改动）**

- hermes-proxy 内嵌 sherpa-onnx 引擎，作为「自建 TTS」直接提供
  `/api/hermes/tts/{synthesize,voices,settings}`，无需下游后端；
  通过保留 serverID `__tts__` 路由，模型置于 `models/tts/`。
- hermes-shared 对称封装上述能力：导出 `localTtsServerId`（`__tts__`），
  `HermesTtsClient` 对下游 studio 与代理自建引擎使用同一套 API。
- 端到端实机测试：`hermes-shared/test/tts_e2e_live_test.dart`（`PROXY_E2E=1 flutter test`）。

