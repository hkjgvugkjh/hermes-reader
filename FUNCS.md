# hermes-reader Dart 源码功能索引

> 自动生成于 2026-09-23。共 61 个 `lib/**/*.dart` + 9 个 `test/*.dart`。
> 分层：`models`（数据模型）→ `services`（IO / 算法 / 传输）→ `providers`（ChangeNotifier 状态）→ `screens`+`widgets`+`utils`（UI）。

## 目录结构总览

| 目录 | 职责 |
| --- | --- |
| `lib/main.dart` | 应用入口、Provider 注册、启动自检、会话监控首页 |
| `lib/reader/models/` | 纯数据模型与序列化（书、页、进度、配置、会话/服务器模型） |
| `lib/reader/services/` | 无 UI 的能力层：书库传输、文本提取、解码、分页、TTS、会话监控、通知、持久化 |
| `lib/reader/providers/` | Provider 状态容器与调试日志 |
| `lib/reader/screens/` | 页面 |
| `lib/reader/widgets/` | 可复用交互组件 |
| `lib/reader/utils/` | 错误文案映射、SnackBar 反馈 |

---

## 1. 应用入口

### `lib/main.dart`
应用入口与总控。`main()` 初始化 `DebugLogger.instance`、`NotificationService` 后运行 `HermesReaderApp`；`HermesReaderApp` 用 `MultiProvider` 注册 `LibraryService`、`LibraryProvider`、`ReaderProvider`、`TaskProvider`、`SessionProvider`、`GlobalConfigProvider`、`ServerProvider`、`TtsService`。`StartupScreen`（`_checkConfig()`）逐项执行启动自检：读取本地配置 → HTTP `/health` 探测 → WebSocket 连接 → `fetchServersDI()` 拉取服务器列表，再按结果 `_navigateToLocal()` / `_navigateToOnline()` 进入 `HomeScreen`。`HomeScreen` 内含会话清单页 `_SessionMonitorTab`（`_fetchAllSessions()`、`_detectChanges()`）、二维码扫码接入（`_scanQR()` / `_onConnected()`）、服务器切换（`_switchServer()` / `_attachServer()`），以及进入电子书库 `_openEbook()` 与本地文库 `_openLocalLibrary()` 的入口。

---

## 2. `lib/reader/models/`（数据模型）

### `lib/reader/models/book.dart`
阅读器核心数据模型。定义格式枚举 `FileType`（unknown/plainText/pdf/epub/mobi/html/json）、书籍实体 `Book`（`id = serverId::relativePath`，含 `downloaded`、`fileType`、`sizeLabel`、`copyWith()`、`toJson()`/`fromJson()`）、分页单元 `BookPage`（携带 `startOffset`，即以字符偏移而非页码作为权威位置）、阅读进度 `ReadingProgress`（`offset` 为续读锚点）、解码后的正文 `BookContent`（`pageBreaks`、`images`、`hasPageBreaks`、`byteLength`）和朗读进度 `NarrationProgress`（`pageIndex` + `charOffset`）。

### `lib/reader/models/chapter_page_info.dart`
章节分页缓存模型。`PageEntry` 记录单页 `pageIndex` 与全书文本中的 `startOffset`；`ChapterPageInfo` 以 `chapterIndex`/`chapterTitle`/`startOffset` 为锚，同时保存 `fullScreenPages` 与 `notFullScreenPages` 两套页表，使全屏/非全屏切换无需重新测量，并用 `hasInitialBatch` 标记前 5 页是否已算、`copyWith()` 只更新单侧页表。

### `lib/reader/models/global_config.dart`
全局连接配置模型。枚举 `ConnectionMode`（`hermesProxy`/`standalone`）配合 `GlobalConfig` 保存 `proxyUrl`、`proxyAuthToken`、`proxyWsPort`、`proxyAdminPort`；getter `proxyWsUrl` 优先原样返回 ws/wss 地址、否则由 https→wss 推导，`proxyAdminUrl` 生成管理端基址；`toJson()`/`fromJson()`/`copyWith()` 供 `GlobalConfigProvider` 持久化。

### `lib/reader/models/hive_models.dart`
服务端/代理侧通用模型集合：枚举 `ProxyType`（none/hermesProxy/httpProxy/httpsProxy/socks5Proxy）与 `ProxyConfig`（`wsUrl`、`isHermesProxy`、`displayAddress`）、`ServerConfig`（id 由 `Uuid().v4()` 生成，含 username/password/profile/isOnline、`baseUrl`）、`ChatMessage`、`HermesSession`（兼容 `session_id`/`last_active` 两种字段名，`SessionStatus` 枚举）、`HealthStatus`、`ModelInfo` 与 `ModelGroup`（模型下拉分组）。

### `lib/reader/models/reader_annotations.dart`
阅读标注三层模型：`Bookmark` 以 `bookId`+`offset` 定位（`pageIndex`、`label` 可选）；`Note` 用 `startOffset`/`endOffset` 锚定区间，携带 `quotedText`、可选 `comment` 与高亮 `color`（默认 `0xFFFFEB3B`）；`SharedComment` 是发布到共享层的 Note，增加 `deviceId`/`author` 与全局去重键 `globalKey`（`$deviceId/$id`）。三者均支持 JSON 序列化。

### `lib/reader/models/reader_config.dart`
阅读器行为与安全配置。定义枚举 `TapZoneMode`（thirds/halves/edges/whole）、`TtsMode`（auto/server/local/builtin/sano）、`CommentSyncMode`（server/torrent/both），以及 `ReaderConfig`：既有静态安全阈值（`libraryRoot`、`maxFileBytes`、`maxTransferBytes`、`maxListDepth`、`allowedExtensions`），也有 `ttsMode`、`monitorInterval`、`sessionIdleThreshold`、`speechRate`、`charsPerPage`、`fontScale`、`lineHeightFactor`、`autoTurnPage`、`tapZoneMode`、`leftZoneForward`、`commentSyncMode` 等可调项，配合 `ReaderConfigStorage` 持久化。

---

## 3. `lib/reader/providers/`（状态管理）

### `lib/reader/providers/debug_logger.dart`
内存 + 文件日志。定义 `LogLevel`（info/warn/error/success）、`DebugLogEntry` 与单例 `DebugLogger extends ChangeNotifier`：保留最近 `_maxLogs` 条（`logs`/`maxLogs`/`isVisible`），提供 `log()`/`info()`/`warn()`/`error()`/`success()`/`logError()`，并按天持久化到 `<文档目录>/hermes_logs/hermes-YYYY-MM-DD.log`（`ensureInitialized()`、`tail()`、`logFilePaths()`、`flush()`、`clear()`，保留 7 天），驱动「调试日志」面板。

### `lib/reader/providers/global_config_provider.dart`
`GlobalConfigProvider extends ChangeNotifier`，管理连接模式与代理参数。持有 `GlobalConfig _config`，通过 `load()`/`updateConfig()`/`setMode()`/`setProxyUrl()`/`setProxyAuthToken()` 持久化到 `GlobalConfigStorage`；对外暴露 `config`、`isLoading`、`error`、`isProxyMode`/`isStandaloneMode`，并提供 `fetchServersFromProxy()`（经 `ProxyClient` 拉取服务器列表）与 `testProxyConnection()`。

### `lib/reader/providers/library_provider.dart`
本项目最核心的状态文件，含两个 Provider：
- `LibraryProvider`（书架）：委托 `LibraryService` 做 `refresh()` 列书、`download()` 下载（`progressFor()`/`downloadStatsFor()` 进度）、`open()`/`readCached()` 读正文、`remove()` 删缓存、`isCached()`/`isDownloading()` 状态查询。
- `ReaderProvider`（当前打开的书）：`openBook()` 开卷、`pages`/`currentPage`/`pageIndex` 取页、`nextPage()`/`previousPage()`/`goToPage()`/`goToChapter()` 导航、`syncViewportChars()` 按视口做像素级精确分页、`updateConfig()` 改设置（字号/行距/每页字数）、`savePosition()`/`loadProgress()`/`loadNarration()` 进度存取、`toggleBookmark()`/`saveNote()`/`publishComment()` 等标注能力、`handleTap()` 点击分区翻页。
- 另定义分包接缝 `PaginatorLike` 与兜底实现 `defaultPaginate()`。

### `lib/reader/providers/local_library_provider.dart`
`LocalLibraryProvider extends ChangeNotifier`，基于设备私有 `library` 目录（`LocalFileSystemTransport`）复用内部 `LibraryProvider shelf`，提供 `refresh()`/`open()`/`download()`/`removeLocal()`/`readCached()` 与代理属性 `books`/`loading`/`error`/`isCached()`/`progressFor()`；另有本地文件 `upload()`/`deleteRemote()`/`renameRemote()`、缓存索引相关 `bookFromCache()`/`cachedFilesByServer()`/`setEncoding()`/`encodingLabelOf()`，以及唯一走网络的 `forward()`（经 `LocalLibraryClient` 上传到远端）。

### `lib/reader/providers/server_provider.dart`
`ServerProvider extends ChangeNotifier`，管理直连/代理两种模式下的服务器列表 `_servers` 与 `_activeServer`，通过 `load()`/`addServer()`/`updateServer()`/`removeServer()`/`setActiveServer()`/`setServers()` 读写 `ServerStorage`；提供 `getClient()`（`HermesApiClient`）与 `getProxyClient()`（`ProxyClient`）带缓存的客户端工厂、`checkAllServers()`/`checkServerHealth()` 健康检查、`loginServer()` 登录、`setServerOnline()` 在线标记，并附 `IterableExtension.firstOrNull` 扩展。

### `lib/reader/providers/session_provider.dart`
`SessionProvider extends ChangeNotifier`，持有 `SessionMonitorService` 并转发其状态（`currentSessions`、`recentChanges`、`isMonitoring`、`targetForServer()`、`pollNow()`/`start()`/`stop()`/`addServer()`/`removeServer()`/`setToken()`）。绑定代理后（`setProxyClient()`）订阅 DI 会话更新、`authRequests`(0x39) 与 `diEvents`(0x3B)，转成 `TaskItem` 或广播为全局 `ClarifyRequest`（同文件定义模型）。核心对外能力是 `sendCommandToSession()`（代理走 Socket.IO `/chat-run` 或直连 HTTP）与 `sendVoiceTurnViaProxy()`（语音转写 `/api/hermes/mcu/voice-turn`）。

### `lib/reader/providers/task_provider.dart`
待办模型与容器：定义 `TaskItem`（含 `TaskPriority`、`choices`、`isExpired`/`remainingSeconds` 超时判断）与轻量 `TaskProvider extends ChangeNotifier`，维护倒序列表 `tasks` 及派生 `unresolved`，只有 `addTask()`、`resolve()`、`remove()`、`clear()` 四个变更方法，供会话监控把授权/澄清请求呈现到「待处理事项」。

---

## 4. `lib/reader/screens/`（页面）

### `lib/reader/screens/book_reader_screen.dart`
全屏阅读器主界面。`BookReaderScreen`（StatefulWidget）通过 `Consumer<ReaderProvider>` 渲染分页正文，`LayoutBuilder` 在布局阶段调用 `syncViewportChars` 触发按真实画布测量的精确分页。交互：点击分区（`handleTap`）/左右滑动翻页、AppBar 字号菜单（小/标准/大/特大）、UTF-8/GBK 编码切换、书籍书签 `toggleBookmark`、批注模式（切换 `SelectableText` 后由 `FloatingActionButton.extended` 弹出笔记编辑 `showModalBottomSheet`）；底部 `_ReaderFooter` 提供上一页/下一页、朗读开关与进度条（点击可跳页或跳章）。朗读入口 `_toggleNarration` 先读取上次进度并询问「继续朗读/朗读本页」，自动翻页时降级到本机 TTS 会显示 `_FallbackBanner`；`dispose` 保存阅读位置与朗读进度。

### `lib/reader/screens/local_library_screen.dart`
本地文库浏览页。`LocalLibraryScreen` 按 `LocalLibrarySection` 分组（「本地文库」+ 各远程服务器已缓存书籍），用 `GridView.builder` 九宫格展示 `_BookCard`；卡片点击 `onOpen` 打开并跳转 `BookReaderScreen`，本地条目支持重命名、删除、转发到远程库，缓存条目支持「删除下载」，文本类电子书另有编码切换。AppBar 提供刷新与 `FilePicker` 多选上传，页面外层 `GestureDetector` 支持右滑返回。

### `lib/reader/screens/reader_home_screen.dart`
单个服务器的书架列表页。`ReaderHomeScreen` 用 `Consumer<LibraryProvider>` 监听服务器 `library/` 目录，以 `ListView.separated` 渲染 `_BookTile`，显示已读百分比/已下载/下载中状态，支持下载、删除本地副本、从头重读；`RefreshIndicator` 下拉刷新，错误态 `_ErrorView`（带重试），空态 `_EmptyShelf` 提示支持的格式。开书时先弹「正在打开…」长时 SnackBar，`LibraryProvider.open` 拿到 `BookContent` 后交给 `ReaderProvider.openBook` 并 push `BookReaderScreen`，返回后 `_loadProgress` 刷新进度。

### `lib/reader/screens/session_monitor_screen.dart`
Hermes 会话监控页。`SessionMonitorScreen` 用 `Consumer<SessionProvider>` 拉取各服务器会话快照与变更事件，顶部 `SegmentedButton<int>` 切换「会话/事件」视图，配 `DropdownButton<String?>` 按服务器过滤。会话项 `_SessionTile`（状态 Chip 由 `_stateColor` 上色）与事件项 `_ChangeTile` 均弹出 `_SessionSnapshotSheet`：展示待处理操作、可展开的 `JsonEncoder` 原始快照，并内嵌 `VoiceCommandButton` 下发语音命令（识别文本经 `sendCommandToSession` 发送后展示回复或错误）。AppBar 提供 `pollNow` 刷新与 `clearHistory` 清空事件。

### `lib/reader/screens/task_list_screen.dart`
待办列表页。`TaskListScreen`（StatelessWidget）通过 `context.watch<TaskProvider>` 渲染 `_TaskTile`，按优先级着色（紧急红/高橙/普通蓝/低灰），显示标题、描述、优先级、超时倒计时与服务器 ID；已超时标红加粗，已解决显示删除线并可删除。点击未解决项 `_openHandler` 弹出 `_TaskResolveDialog`，选择「确认/拒绝」后经 `ProxyClient.sendAuthResponse` 或 `sendClarifyResponse` 回传代理，成功后 `TaskProvider.resolve` 关闭弹窗；AppBar 可 `clear` 清空全部。

---

## 5. `lib/reader/widgets/`（组件）

### `lib/reader/widgets/robot_reading_animation.dart`
纯绘制的「机器人翻书」加载动画。`RobotReadingAnimation` 用 `AnimationController`（2200ms 无限 repeat）驱动 `AnimatedBuilder` 内的 `CustomPaint`；`_RobotPainter` 无图片资源地用 Canvas 画出摊开的书页、绕书脊旋转（+72°→-4°）的翻页闪光，以及带眨眼/微笑/胸灯的小机器人和轻微浮动。纯展示无交互，通过 `size` 参数适配尺寸，`shouldRepaint` 仅在 progress/brand 变化时重绘。

### `lib/reader/widgets/session_detail_dialog.dart`
会话详情对话框。`SessionDetailDialog` 经 `ProxyClient.sendRequest` 拉取 `GET /api/studio/sessions/{id}/context` 快照，用 `ListView` + `flutter_markdown` 的 `MarkdownBody` 渲染每条消息（区分我/助手、带时间戳、代码块样式）；顶部 `_buildHeader` 提供刷新与关闭，底部 `_buildComposer` 是多行 `TextField`，回车或发送按钮走 `POST /api/studio/chat-run/runs` 携带 `session_id` 续写会话。鉴权由 `_authHeaders` 优先取代理缓存的 backend JWT、缺失时回退 `fallbackToken`，失败文案统一经 `describeError` 转换。

### `lib/reader/widgets/voice_command_button.dart`
按住说话的语音命令按钮。`VoiceCommandButton` 用 `GestureDetector` 的 onTapDown/onTapUp/onTapCancel 实现「按下开始录音、松开发送」；录音由 `VoiceCommandService` 完成，发送优先走 `proxySender`（代理通道），否则 `sendTurn` 直连 `baseUrl`。UI 为 80 高的 `AnimatedContainer`（录音时变红），`_buildInner` 在麦克风图标、「正在录音…松开发送」、「识别中…」与上一次识别结果间切换，成功后回调 `onResult` 把转写文本交给上层。

---

## 6. `lib/reader/utils/`（工具类）

### `lib/reader/utils/error_messages.dart`
异常 → 中文友好文案的纯函数工具（无 Widget）。`describeError(Object)` 先按 `TimeoutException`/`SocketException`/`HttpException`/`HandshakeException` 类型判定，再回退匹配 "connection refused"、"connection reset"、"timed out"、TLS 等字符串片段，并用正则提取 HTTP 状态码给出 401/404/5xx 对应提示；返回含 `message`、`detail`（去噪后的日志原文）与 `ErrorKind`（network/disconnected/server/timeout/unknown）的 `FriendlyError`。

### `lib/reader/utils/ui_feedback.dart`
统一 UI 反馈工具 `UiFeedback`（私有构造 + 静态方法，无 Widget）。`showError(BuildContext, Object)` 调用 `describeError` 生成友好文案、用 `DebugLogger` 记录技术细节，再以 floating `SnackBar` 展示按 `ErrorKind` 选取的图标（wifi_off/link_off/cloud_off/hourglass_empty/error_outline）与可选 `SnackBarAction`（如「重试」），并返回 `FriendlyError` 供调用方分支处理；`showInfo` 展示 3 秒普通提示。两者都先 `clearSnackBars`。

---

## 7. `lib/reader/services/`（能力层）

### 7.1 书库与传输

#### `lib/reader/services/library_service.dart`
书库核心。定义 `FileTransport`/`TransportResponse`/`DownloadProgress` 抽象；`LibraryService.listBooks()` 列出服务端书籍并把路径交给 sandbox 校验，`downloadBook()` 按 1MiB 分块下载并以滑动窗口算速率回调进度，二进制损坏时回退 base64 重试，`_extractOffThread` 用 Isolate 做文本抽取，`readCached()` 对文本类即时重解码、PDF/EPUB 复用 `.meta`；`BookStorage` 负责落盘到 `hermes-reader/books` 并维护带版本号校验的 `.meta` 缓存。

#### `lib/reader/services/library_sandbox.dart`
路径与传输安全闸门。`LibrarySandbox.resolve()`/`resolveDir()` 拒绝绝对路径、盘符、NUL、URL 编码穿越、`..` 段并限制目录深度与扩展名白名单；`sizeAllowed`/`checkTransfer`/`validateContent` 按 `ReaderConfig` 的容量上限校验大小与截断，`localFileName()` 生成扁平化缓存名；违规统一抛带中文说明的 `LibrarySandboxError`。

#### `lib/reader/services/library_cache_index.dart`
下载缓存的 JSON 侧车索引 `.hermes-index.json`。`LibraryCacheIndex.recordDownload()` 保存远端真实标题与相对路径（因为本地文件名被 `LibrarySandbox.localFileName` 扁平化去除了非 ASCII），`setEncoding()`/`encodingOf()` 记住用户手动选择的编码以修复乱码，`titleOf`/`relativePathOf` 供书架还原原名；所有 IO 失败静默忽略。

#### `lib/reader/services/direct_file_transport.dart`
`DirectFileTransport implements FileTransport`，standalone 模式直连 hermes-hive 服务器：`ensureLoggedIn()` 自动探测鉴权并用账号密码换 JWT，`get()` 带上 profile 与 Bearer 头，因 Studio API 不支持 Range，`getRange()` 通过整文件拉取再切片模拟分段下载。

#### `lib/reader/services/proxy_file_transport.dart`
`ProxyFileTransport implements FileTransport`，让 `LibraryService` 经 hermes-proxy 取远端文件：首次请求 `proxyClient.connectServer()` 挂载服务（serverId 必须是 proxy 配置里的 ID），自动补 `Authorization: Bearer` JWT，`getRange()` 支持按 offset/limit 分片，并带自适应 `_requestTimeout()` 与断线自动重连一次。

#### `lib/reader/services/local_library_transport.dart`
纯本机文件系统的 `FileTransport` 实现。`LocalFileSystemTransport` 用 `dart:io` 直接响应 `list`/`read` 两类 studio 路径（`_localRel` 去掉 `library/` 前缀），并用 `RandomAccessFile.setPosition/read` 原生实现 `getRange()` 返回 `X-Hermes-Total`，从而让本地书架复用 `LibraryService` 的沙箱、下载进度与缓存逻辑。

#### `lib/reader/services/hermes_api_client.dart`
Hermes Web UI 服务器的 HTTP 客户端。`HermesApiClient` 处理自动鉴权（`ensureLoggedIn`、`checkServerAuthEnabled`、`login` 取 JWT）后提供 `checkHealth`、`getConfig`、会话增删改查、双向 slim、`runChat`、`fetchModelGroups`，以及 studio 文件 API（`listFiles`/`readFile`/`writeFile`/`mkdir`/`deleteFile`/`renameFile`）；配套 `FileNode`、`ChatResult` 数据类并输出 `DebugLogger`。

#### `lib/reader/services/proxy_client.dart`
纯转发文件，向 reader 模块 re-export `hermes_shared` 包中的 `ProxyClient`、`ProxyTunnel`、`ProxyTunnelException`、`KeyExchangeException`、`ConnectionClosedException`（X25519 握手 + ChaCha20-Poly1305 加密隧道的唯一实现）。

#### `lib/reader/services/socket_io_client.dart`
极简 Socket.IO（Engine.IO）客户端，跑在任意 `Stream<String>`/`send` 双工通道（如 `ProxyTunnel`）之上：实现握手 open 包、`2/3` ping-pong、命名空间连接 `connectNamespace(auth)`、`emit()` 与事件流 `events`（`SocketIoEvent`），当前仅供 `/chat-run` 命名空间使用。

#### `lib/reader/services/external_library_dir.dart`
解析设备上的用户可见 `hermes-reader` 目录（Android 上绕过 `Android/data` 到共享存储根，以便卸载后保留）：`ExternalLibraryDir.ensure()` 处理 MANAGE_EXTERNAL_STORAGE 权限并创建 root，提供 `library`/`books` 子目录与 `configFile`；`LocalLibraryConfig` 读写根目录里便携的 `config.json` 中的 `ReaderConfig`。

### 7.2 文本提取与编码

#### `lib/reader/services/book_text_extractor.dart`
把图书原始字节转成可读文本的核心。抽象类 `BookTextExtractor` 与实现 `DefaultBookTextExtractor.extract()` 按 `FileType` 分派给 PDF/EPUB 提取器；另有静态工具 `decodeText`（BOM→UTF-8→GBK→latin-1 自动探测）、`stripHtml`、`cleanText`、`decodeEntities`；输出携带分页偏移 `breaks` 与图片列表的 `ExtractedText`。

#### `lib/reader/services/pdf_text_extractor.dart`
纯 Dart 的 PDF 文本/图片提取器（不依赖 PDFium）。`PdfTextExtractor.extract()` 返回带分页 `breaks` 和 `images` 的 `ExtractedText`；内部 `_PdfDocument` 用正则/字典（`_DictParser`）解析、展开对象流 `_resolveObjectStreams()`、解码 Flate/ASCII85/Hex/LZW（`_applyFilter`），并靠 ToUnicode CMap 与 WinAnsi 映射避免乱码。

#### `lib/reader/services/pdf_image_decoder.dart`
PDF 图片解码辅助：定义可在正文中留位的可渲染对象 `PdfImage`，并实现 `\u0000IMG<n>\u0000` 占位符协议（`imageMarker()`/`imageMarkerRegex`/`stripImageMarkers()`）；`encodePngRgba()` 手写地把 RGBA 像素打包成 PNG（含 `_writeChunk` CRC 计算），供 `Image.memory` 显示。

#### `lib/reader/services/epub_text_extractor.dart`
`EpubTextExtractor` 手工解析 EPUB：`ZipDecoder` 解压后由 `META-INF/container.xml` 找 OPF，用正则取 `<item>`/`<itemref>` 组成 manifest 与 spine 顺序（spine 缺失则退化为排序后的 HTML 文件），逐章 `stripHtml`+`cleanText` 拼接并记录每章字符偏移作为 `breaks`。

#### `lib/reader/services/gbk_decoder.dart`
高性能 GBK 解码器。`decodeGbk()` 复用 gbk_codec 的映射表但改用单次 `StringBuffer` 遍历（包自带解码是 O(n²)，5MB 小说要跑几分钟）：低于 0x80 按 ASCII，否则合并两字节查表，未知或孤立前导字节原样保留。

#### `lib/reader/services/file_body_decoder.dart`
剥离服务端文件读取返回的 JSON 信封：`FileBodyDecoder.decode()` 仅在严格 UTF-8 解码成功且以 `{` 开头时取出 `content` 字段（`FileType.json` 除外），失败即原样返回；静态方法 `looksBinaryDamaged()` 通过 U+FFFD 替换符密度判断二进制是否被字符串往返损坏。

#### `lib/reader/services/file_type_detector.dart`
按扩展名判定书籍格式：`FileTypeDetector.detect()` 映射到 `FileType`（plainText/pdf/epub/mobi/html/json/unknown），并提供 `isReadable`、`isNarratable`（txt/pdf/epub）、`needsExtraction` 三种能力查询。

#### `lib/reader/services/chapter_detector.dart`
纯文本章节识别。`ChapterDetector.detect()` 用一组保守正则（第 N 章/回/卷、Chapter N、数字编号、序/楔子/后记等）逐行匹配，要求行长短于 60 字，返回带字符偏移的 `ChapterMark` 列表，并用去重 map 让靠后的真实章节覆盖前面的目录项。

### 7.3 分页

#### `lib/reader/services/paginator_service.dart`
分页核心。`PaginatorService.paginate()` 按字数/`breakOffsets` 切页；另有基于 `TextPainter` 实测的 `paginateWithLayout()`、`paginateChapter()`、`paginateBookExact()`（二分搜索每屏最大不溢出的字符偏移，填满到像素、段落从行尾削减跨页延续）与 `scanChapters()`；辅助方法 `_splitSentences`、`_splitLongParagraphByHeight`、`_safeCut`、`toSpeechText` 负责按句断行、超长段按句/按字高切分、不切断图片标记、以及朗读前剥离 Markdown。

### 7.4 配置与持久化

#### `lib/reader/services/app_config_service.dart`
统一配置服务 `AppConfigService`：把 `GlobalConfig`/`ServerConfig[]`/`activeServerId`/`ReaderConfig` 打包成 `AppConfigBundle` 单文件 `hermes_reader/config.json`；`load()` 会自动修复损坏文件并迁移旧的分散文件，`AppConfigBundle` 还封装 `addServer`/`updateServer`/`removeServer` 等服务器管理逻辑。

#### `lib/reader/services/global_config_storage.dart`
旧版全局配置存储的兼容层（`@deprecated`）：`GlobalConfigStorage.load()/save()` 现在直接委派 `AppConfigService`（读写 bundle 中的 `globalConfig`），仅在统一配置不可用时才回退读遗留的 `hermes_reader_config.json`。

#### `lib/reader/services/server_storage.dart`
已废弃的服务器配置存储（保留兼容）：`loadServers()/saveServers()/getActiveServerId()/setActiveServerId()` 均委托 `AppConfigService`，仅在统一配置为空时才回退读旧的 `servers.json`/`active_server.txt`。

#### `lib/reader/services/reader_config_storage.dart`
极简的阅读设置持久化：`ReaderConfigStorage.load()/save()` 存取 `ReaderConfig.toJson()` 的同一份 JSON 到 key `reader_config`，解析失败回退默认 `ReaderConfig()`。

#### `lib/reader/services/annotation_store.dart`
本地书签与笔记仓库 `AnnotationStore`：按 `bookId` 以 `bookmarks_`/`notes_` 前缀存入 SharedPreferences，提供 `loadBookmarks`、`addBookmark`（按 offset 去重）、`removeBookmarkAt`、`saveNote`、`removeNote`，重新读取时按 offset 排序。

#### `lib/reader/services/reading_progress_service.dart`
`ReadingProgressService` 用 SharedPreferences 按 `reading_progress_<bookId>` 保存/加载/清除每本书的阅读位置 `ReadingProgress`，使 app 重启后能回到上次位置。

#### `lib/reader/services/narration_progress_service.dart`
`NarrationProgressService` 按 `narration_progress_<bookId>` 键持久化朗读进度（`NarrationProgress` 的 load/save/clear），与阅读位置刻意分开存放，避免「继续阅读」跳到朗读停下的地方。

#### `lib/reader/services/comment_sync_service.dart`
传输无关的共享评论层：接口 `CommentSync`（`pull`/`push`）；`ServerCommentSync` 经服务端文件 API 读写 `library/.hermes-notes/<bookId>.json`（按 `globalKey` 覆盖合并），`TorrentCommentSync` 暂用 SharedPreferences 兜底，`CompositeCommentSync` 把多通道拉取结果去重合并、推送则广播到所有通道。

### 7.5 朗读（TTS）

#### `lib/reader/services/tts_service.dart`
朗读引擎抽象与调度中心。定义 `SpeechSource` 接口、`SpeechEngine` 枚举、`SpeakResult`、`NarrationProgressHandler`；`TtsService` 按 `TtsMode` 在 local→builtin→sano→server 之间选择，`_speakAuto()` 逐级静默降级并用 `stateStream`（`TtsState`）驱动 UI。

#### `lib/reader/services/local_tts_source.dart`
`LocalTtsSource implements SpeechSource`，用 flutter_tts 走系统 TTS 作为离线/兜底引擎：`_ensureInit()` 校验设备是否安装 TTS 引擎并给出中文提示，`_speakOnce()` 处理冷启动 "not bound" 的一次重试，用 `_stopRequested` 区分主动 stop 与引擎失败。

#### `lib/reader/services/builtin_tts_source.dart`
离线语音源 `BuiltinTtsSource`（实现 `SpeechSource`）：`_ensureModel()` 从 assets 解包 `model.onnx`、`tokens.txt` 与 espeak-ng 数据，`_splitForSpeech` 把文本切成渐进增大（首块仅 50 字）的分块并在后台预合成下一块以实现边播边算，`AudioPlayerPort`/`_JustAudioPort` 负责实际播放。

#### `lib/reader/services/builtin_tts_sherpa.dart`
sherpa-onnx 真机实现 `SherpaOnnxImplFactory`：因加载约 60MB 模型会卡住 UI，把 `OfflineTts` 引擎放进独立 Isolate（`_sherpaIsolateEntry`）通过消息-chunk 通信，`create/generate/dispose` 跨 isolate 发送命令，`_encodeWav` 把浮点采样封装成标准 PCM WAV。

#### `lib/reader/services/sano_tts_source.dart`
`SanoTtsSource implements SpeechSource`，通过 `sanotts_flutter` 在端上运行 SanoTTS 小模型：`_ensureInit()` 从 assets 加载 `SanoTtsVoice` 权重并准备 espeak-ng 数据（解压 `assets/sano/espeak-ng-data.zip`），`speak()` 先由 `MisakiPhonemizer` 做 G2P 再合成 PCM/WAV 并用 just_audio 播到底。

#### `lib/reader/services/server_tts_source.dart`
`ServerTtsSource implements SpeechSource`，服务端合成：有 proxy 时用 `HermesTtsClient.proxy()` 打 `/api/hermes/tts/synthesize`，否则 `_speakDirect()` 直接 HTTP POST 后端；音频经 `_play()` 喂给 just_audio 并 `waitForPlaybackEnd`，`setProxyClient()/setServerId()` 支持会话重连后原地替换通道。

#### `lib/reader/services/playback_wait.dart`
提供 `waitForPlaybackEnd(AudioPlayer)`：因为 just_audio 的 `play()` 只是发出请求，这里分两阶段监听 `playerStateStream`（先等到真正开始播放，再等到 completed 或 stop），替换掉原先固定 sleep 600ms 导致整页朗读被截断的写法。

#### `lib/reader/services/voice_command_service.dart`
`VoiceCommandService` 用 `record` 录音到临时 wav，再 `sendTurn()` POST 到 `$baseUrl/api/hermes/mcu/voice-turn`（Bearer token，30s 超时）拿到识别文本，返回 `VoiceTurnResult`；`recordAndSend()` 一条龙完成录音、上传与清理。

### 7.6 会话监控与通知

#### `lib/reader/services/session_monitor_service.dart`
会话监控轮询服务。`SessionMonitorService` 按 `MonitorTarget` 定时拉取（代理 DI 或直连 HTTP `/api/hermes/sessions`），用 `_detectChanges()` 对比快照产出 started/stopped/needsInput/resumed/authRequired/serverError 的 `SessionChange` 广播流；`SessionSnapshot.fromJson()` 负责从多种字段名推断 `SessionState` 与时间。

#### `lib/reader/services/notification_service.dart`
`NotificationService` 封装 `flutter_local_notifications`：`init()` 做初始化与 Android 权限申请，`handleChange(SessionChange)` 把会话启动/停止/待处理/恢复/授权失效/服务器异常映射为本地通知，payload 为 `serverId:sessionId` 便于点击跳转。

---

## 8. `test/`（测试）

- `test/book_text_extractor_test.dart` — 覆盖 `DefaultBookTextExtractor` 对纯文本/HTML/MOBI/JSON 的抽取与内存 EPUB 按 spine 顺序成章，异常 EPUB 不抛异常、空白归一、GBK 自动识别与 UTF-8/BOM 优先级。
- `test/chapter_detector_test.dart` — 覆盖 `ChapterDetector.detect` 对中文章节标题的识别与偏移正确性、目录与正文重复标题的折叠、误报过滤（含「第…规定」的散文）、少于两个标题时返回空，以及英文/数字/序等多形态标题。
- `test/file_type_detector_test.dart` — 覆盖 `FileTypeDetector` 的扩展名识别、未知/畸形文件名回退，以及 `isNarratable`/`isReadable`/`needsExtraction` 三类能力判定。
- `test/paginator_test.dart` — 覆盖 `PaginatorService.paginate` 的字符预算切页、breakOffsets 优先、超长块再切分、非法/降序 break 丢弃、空块不产生空页、`progressFor` 进度计算与 `toSpeechText` 去 Markdown。
- `test/proxy_client_test.dart` — 覆盖 `ProxyClient.connect()` 的并发去重（三次并发只握手一次）、已连接短路、握手失败不粘滞、共享失败与新连接、`disconnect()` 后重连。
- `test/proxy_url_test.dart` — 覆盖 `ProxyClient.buildUri()`：https→wss/http→ws 默认端口不拼 `:443/:80`、非默认端口保留、ws/wss 直通、token 只设置一次（替换而非重复拼接）及缺路径回退 `/ws`。
- `test/pdf_text_extractor_test.dart` — 覆盖 `PdfTextExtractor` 对未压缩/Flate/LZW 内容流、TJ 数组、UTF-16BE 十六进制串、转义字符的解码，ObjStm 内嵌对象、每流一页、无文本与垃圾输入的兜底提示，以及 XObject 图片提取（PNG 编码 + `IMG0` 标记、DCTDecode 保留 JPEG）。
- `test/library_service_test.dart` — 覆盖 `LibraryService.downloadBook` 的分片下载与进度回传、JSON envelope 解包、PDF 损坏时改请求 base64 重试、缓存读取，以及 `DownloadProgress` 文案、`FileBodyDecoder` 二进制判定与 `LibrarySandbox.validateContent` 大小校验。
- `test/reader_provider_test.dart` — 覆盖 `ReaderProvider` 的首次开卷分页、四种点击翻页区域（三分区/半分/边缘/左前进/中间切控件）、边界钳制、阅读进度与朗读进度各自独立存取与越界回退、改字号重排夹取，以及后台目录检测与跳章。

---

## 9. 一次开卷的完整数据流

```text
ReaderHomeScreen 长按/点击书
  └─ LibraryProvider.open(book)          → LibraryService.downloadBook / readCached
        └─ DefaultBookTextExtractor      → PDF/EPUB/GBK 解码 → BookContent(text, pageBreaks)
              └─ ReaderProvider.openBook(book, content)
                    ├─ _scanChapters()      用 pageBreaks 建立初始 chapter ranges
                    ├─ _rebuildPages()      字符级兜底分页（保证立刻有页可读）
                    ├─ _detectChapters()    后台 Isolate 识别「第N章」→ 重建 ranges
                    └─ notifyListeners()
                          └─ push BookReaderScreen
                                └─ LayoutBuilder → ReaderProvider.syncViewportChars(...)
                                      └─ PaginatorService.paginateBookExact  ← TextPainter 实量
                                            └─ 替换 _pages → 每帧显示真实的一屏文本
```
