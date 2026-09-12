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
- 自动翻页朗读：当前页读完且 `autoTurnPage` 开启时自动进入下一页
- **朗读进度记忆**：记录停在第几页、第几个字符，下次朗读从断点续读；读完自动清除
- 不支持朗读的格式（`.mobi` `.html` `.json`）按钮置灰并给出提示
- 停止朗读时对已停止的引擎异常做静默处理，不再抛出 "all TTS engines failed"
- 本机引擎对单次朗读设置 2 分钟超时，避免无 TTS 引擎的设备卡死

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
