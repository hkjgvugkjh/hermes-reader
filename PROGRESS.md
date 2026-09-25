# 进展记录

**日期**: 2026-09-11
**对照文档**: `PLAN.md`

---

## 总览

| # | 规划项 | 状态 |
|---|--------|------|
| 1 | TTS 停止异常修复 | ✅ 完成 |
| 2 | 扩展文件格式支持 | ✅ 完成 |
| 3 | PDF 朗读支持 | ✅ 完成 |
| 4 | EPUB 朗读支持 | ✅ 完成 |
| 5 | 阅读位置记忆 | ✅ 完成（含书架 UI） |
| 6 | 三区分页配置 | ✅ 完成（含设置入口） |
| 7 | 朗读进度记录 | ✅ 完成 |
| 8 | 文件类型限制（语音朗读） | ✅ 完成 |

全部 8 项已实现，功能说明已并入 `README.md`。

---

## 本轮新增实现

### 格式解析（原 2b / 3 / 4）

新增 `BookTextExtractor` 抽象与 `DefaultBookTextExtractor`，按 `FileType` 分流：

- `file_type_detector.dart` 已有判定逻辑，此处只需消费
- `pdf_text_extractor.dart` — 纯 Dart 实现
- `epub_text_extractor.dart` — 通过 `archive` 解 zip，走 `META-INF/container.xml` → OPF
  → manifest → spine → 章节 XHTML，去标签后按章节记录分页点
- HTML / MOBI 去标签 + 实体解码；JSON 重新缩进；纯文本原样透传

`LibraryService.downloadBook()` 与 `readCached()` 改为调用提取器，并把
`ExtractedText.breaks` 写进 `BookContent.pageBreaks`。Book 缺 `fileType` 时
（旧数据）回退到按扩展名重新检测。

`PaginatorService.paginate()` 新增 `breakOffsets`：PDF 一页 = 一个阅读页、
EPUB 一章 = 一个阅读页，超长块再按句切分；无 breaks 时沿用原有的按字数流式分页。

### 阅读位置记忆（原 5b）

- `ReaderProvider` 新增 `loadProgress(bookId)`
- 书架 `_BookTile` 显示"已读 N%"，有进度的书多出"从头开始"按钮
- 退出阅读页回到书架时重新拉取进度
- 空书架提示文案同步为完整的 7 种格式

### 三区配置入口（原 6b）

- 阅读页 AppBar 新增"阅读设置"：分区模式（三档单选）、左侧区域方向、
  朗读自动翻页、每页字数滑块
- 新增 `ReaderConfigStorage`，`ReaderProvider.updateConfig()` 落盘，
  启动时由 `StartupScreen` 恢复

### 朗读进度记录（原 7）

- 新增 `NarrationProgress` 模型（bookId / pageIndex / charOffset / updatedAt）
  与 `NarrationProgressService`
- `SpeechSource` 增加可选 `setProgressHandler`，`LocalTtsSource` 转发
  flutter_tts 的逐字进度，`TtsService` 记录最近偏移
- 开始朗读时若有存档则跳到该页并从 `charOffset` 处续读；停止、异常、
  离开页面都会保存；整本读完则清除
- 与阅读进度完全独立存储，互不影响

### 朗读类型限制（原 8）

- 阅读页按 `book.fileType` 调 `isNarratable()`，不支持时朗读按钮置灰、
  tooltip 说明原因，点击给出 Snackbar 提示

---

## 依赖变更

- 新增 `archive: ^4.0.9` — EPUB 是 zip 容器，需要解压
- 移除 `pdfrx` — 先加后删，见下
- `pdf: ^3.10.4` 保留在 pubspec 但未使用：dart_pdf 只提供 `PdfDocumentParserBase`
  （用于合并文档），没有文本提取 API

### 为什么放弃 pdfrx

`pdfrx` 基于 PDFium，构建时通过 `pdfium_dart` 的 hook 从 GitHub 下载约 10 MB 的
原生二进制。本机访问 `github.com/bblanchon/pdfium-binaries` 超时，
`flutter test` 与 `flutter build` 均直接失败：

```
ClientException: Connection timed out,
uri=https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F7811/pdfium-linux-x64.tgz
Building native assets failed.
```

这与"快速构建"的目标冲突，故改为内置纯 Dart 提取器。

### 为什么不用 epub 包

`epub: ^3.2.0` 仍停留在 Dart 2（`sdk: '>=1.13.2 <3.0.0'`），不支持空安全，
`flutter pub add` 直接失败。改用 `archive` 自行解析 OPF。

---

## 测试

`flutter test` — **68 项全部通过**：

| 文件 | 覆盖 |
|------|------|
| `file_type_detector_test.dart` | 扩展名识别、可朗读 / 可读 / 需提取判定 |
| `book_text_extractor_test.dart` | 纯文本、HTML 去标签与实体、MOBI、JSON 与畸形 JSON、EPUB 章节顺序与分页点、损坏 EPUB 兜底、空白归一 |
| `pdf_text_extractor_test.dart` | 未压缩流、FlateDecode 解压、TJ 数组拼接、UTF-16BE 十六进制串、转义还原、分页点、无文本与垃圾输入的兜底 |
| `paginator_test.dart` | 按字数分页、breakOffsets 优先生效、超长块再切、越界与逆序断点过滤、空块不产生空页、进度换算、Markdown 转朗读文本 |
| `reader_provider_test.dart` | 三区 / 两区 / 边缘的翻页与切换、方向反转、边界钳制、阅读位置恢复与越界回退、朗读进度读写与清除、两类进度互不干扰 |

EPUB 测试用 `ZipEncoder` 在内存中构造 EPUB，PDF 测试直接拼内容流，都不依赖
真实文件与平台通道；进度相关测试用 `SharedPreferences.setMockInitialValues`。

---

## 构建与验证

- `flutter analyze` — **0 error**（余下为既有 warning/info）
- `flutter build apk --debug` — 成功，114 秒
- `adb install -r app-debug.apk` — Success
- `adb shell am start com.hermes.reader/.MainActivity` — 进程存活，logcat 无 FATAL

环境参数：

```bash
export PATH=/home/tomac/flutter/bin:/home/tomac/android-dev/sdk/platform-tools:$PATH
export ANDROID_HOME=/home/tomac/android-dev/sdk
export JAVA_HOME=/home/tomac/android-dev/jdk/jdk-17.0.11+9
```

设备：`PCT AL10`（Android 10, android-arm64），已通过 USB 连接。

---

## 缺陷修复：PDF 下载失败（size mismatch）

**现象**：下载 `TG7221B_Datasheet_V1.0.pdf` 报
`size mismatch: declared 1210136 but received 3070633`。

**根因**：`/api/studio/files/read` 返回的是 JSON 信封 `{"content": "..."}`，
content 是**字符串**形式。服务端把二进制按 UTF-8 解码后再放进 JSON，
所有 >= 0x80 的字节都变成 U+FFFD。设备日志可证：

```
[TRANS] resp status=200 bodyType=String bodyLen=4094180
[TRANS] body preview: eyJjb250ZW50IjoiJVBERi0xLjdcbiXCs++/ve+/vVxyXG4x...
                     └─ {"content":"%PDF-1.7\n%<U+FFFD><U+FFFD>...
```

4094180 是 base64 长度，解码得 3070635 字节 JSON —— 与报错的 3070633 吻合。
约 77% 的字节被替换为 U+FFFD（每个 3 字节），故体积膨胀到 2.54 倍。

两个后果：一是触发 `validateContent` 里 `declaredSize * 2 + 1024` 的误判；
二是**字节已不可逆丢失**，即便放宽检查，PDF 也是损坏的。

**修复**：

1. 新增 `FileBodyDecoder` — 下载后先剥掉 JSON 信封取 `content`，再交给后续处理。
   严格 `utf8.decode` 失败即判定为真二进制，原样透传。
   `.json` 类型跳过此步，避免把用户文件自身的 `content` 键误当信封。
   `readCached` 同样处理，兼容旧版本写入的带信封缓存。
2. `validateContent` 改为编码感知：
   - 上限 4x + 64KB（吸收 JSON 信封与 UTF-8 膨胀），硬上限用 `maxTransferBytes`
   - 下限仅在不足声明值 1/4 时报 `truncated`，这才是真正值得失败的截断
   - 声明大小超过 `maxFileBytes` 单独拒绝
   原先 `declaredSize * 2 + 1024` 对任何有编码开销的传输都会误伤。
3. **二进制回退**：检测到 U+FFFD 污染且文件类型需提取（PDF/EPUB/MOBI）时，
   带 `encoding=base64` 重试一次。服务端若支持就拿到完整字节（已缓存为干净副本），
   不支持则沿用首次结果，不额外报错。

**未解决**：服务端不配合时，二进制仍会损坏 —— 这是接口设计问题，客户端无法还原。
彻底修复需要服务端增加二进制安全端点（返回原始字节或 base64），见"下一步建议"。

---

## 缺陷修复：书架列表超时

**现象**：打开书架（服务器模式）卡住并提示超时，无法加载服务器 / 会话列表。

**根因**：WebSocket 握手永远无法完成，请求被挡在 `connect()` 之前，30s 后超时。
两层原因：

1. **URL 构建错误**（主因）：`proxy_client.dart` 的握手 URL 由 `proxyUrl` 经
   `Uri.parse` 派生，旧逻辑对"默认端口"判断有误——`Uri.hasPort` 对
   `https://host`（未显式写端口）为 false，而 `uri.port` 回退为 `0`，被字符串拼成
   `https://host:0/ws`。`:0` 端口无法拨号，且 scheme 没从 `https` 归一成 `wss`，
   token 还被重复拼接。设备日志可证：
   `Connection to 'https://hermes-proxy.willam.eu.org:0/ws?token=...#'` 的握手始终
   `was not upgraded to websocket`。
2. **`connect()` 非幂等**（次因）：并发调用 `connect()` 各自开一条 socket 并互相覆盖
   `_channel`，导致晚到者永远 `await` 一条已废弃的连接，进而触发超时。

**修复**:

1. 新增 `_buildUri()`：统一归一化 scheme（https/wss→wss，其余→ws）、隐藏默认端口
   （不再拼 `:0`）、只保留一次 `token`，彻底消除坏 URL。
2. `connect()` 改为并发安全：用单一 `_connecting` Completer 共享同一次握手，晚到者
   `join` 而非新开 socket；失败时清空状态以便重试；`disconnect()` 重置。
3. `proxy_file_transport.get()` 在连接失败时断开并重试一次，避免单次握手抖动误报超时。

**验证**：重新构建安装后 logcat 显示
`[AUTO] Connected, got 3 servers` → `[ONCONNECTED] Proxy client connected!`
→ `[FETCH] Got 77 sessions for server 185`，书架列表正常加载，超时消失。

---

## 已知限制

1. **二进制文件经服务端传输会损坏**：`files/read` 走 JSON 字符串，非 ASCII 字节变
   U+FFFD。文本格式不受影响；PDF/EPUB 除非服务端支持 `encoding=base64`，否则拿到的是
   损坏内容。客户端已做污染检测与回退，但无法凭空还原字节。
2. **PDF 文本质量**：纯 Dart 提取器覆盖普通字符串与 UTF-16BE 十六进制串；
   依赖外部 ToUnicode CMap 的中文 PDF 会乱码，扫描件无文本可提（会显示说明文字而非报错）。
   若日后网络可用，可换回 `pdfrx` 以获得完整字形映射。
2. **GBK 编码**：中文老书常见的 GBK 仍无法解码，按 latin-1 兜底显示。
3. **PDF / EPUB 仅文本**：不做版式渲染，阅读体验等同纯文本。
4. `flutter_tts` 仍在使用 Kotlin Gradle Plugin，未来 Flutter 版本会构建失败，需关注插件升级。

---

## 缺陷修复：全局分页导致首屏卡死（主线程阻塞）

**日期**: 2026-09-25
**现象**：打开 411 万字符的大书，首屏空白、页码显示 `558/6105/1` 且进度长时间卡住（558/6105/1 中 Y=6105 为整书按 700 字切的 seed 页，Z=1 为未测量章节一律算 1 页）。用户感知"卡住"。

**根因**：`LibraryProvider.paginateAllChapters()` 通过 `PaginatorService.paginateChapterIsolate()` 对全书 **1498 章逐章同步测量**。但 `paginateChapterIsolate` 虽名带 Isolate，实现里直接在主 isolate 调用同步 `paginateChapter()`（`paginator_service.dart:440`，`await` 不释放主线程）。1498 章 × ~45ms ≈ **67 秒霸占主线程**，阅读界面无法渲染（首屏空白）、UI 冻结、手势无响应。`totalBookPages`(Z) 旧逻辑对未测量章节一律返回 1，导致 Z 失真。

**修复**：

1. **`totalBookPages`(Z) 改为字符数即时估算**：新增 `_estimatedCharsPerPage`（由 `syncViewportChars` 的真实布局尺寸 `maxWidth/maxHeight/fontSize/lineHeight` 推导，CJK 1em 宽、行高固定 ⇒ 每页 ≈ 列数×行数），新增 `_estimatedChapterPages(i)` / `_chapterPagesCount(i)`。已测量章节用真实页数，未测量章节用估算值。Z 在全局分页完成前即为合理值（411万字符 / 289 ≈ 1.5万页），且**绝不触发任何测量，不阻塞主线程**。
2. **`paginateAllChapters` 改为非阻塞估算**：移除逐章 `paginateChapterIsolate` 同步测量，改为仅做进度推进（每章 `await Future.delayed(Duration.zero)` 让出主线程），1498 章总耗时从 ~67s 降至 **453ms**。真实测量仍由 `syncViewportChars` / `_ensureAhead` 懒加载（只测当前章，按需补全后续）。
3. **`openBook` 重置全局分页状态**：新增 `_globalPaginating=false; _paginatedChapterCount=0; _globalPaginatingChapterIndex=null`，避免旧任务阻塞新书。
4. **`paginateAllChapters` 加入取消检查**：循环内若 `_globalPaginating` 被重置（如打开新书）立即 return。

**验证**：

- 真机日志（PCT AL10, Android 10）关键链路：
  - `[pag] syncViewport ch=0 ranges=1 → ch=1 ranges=1498`（章节检测正常，整书1章→1498章）
  - `[pag] _paginateChapter ch=1 batch=5 pagesBefore=5`（首屏仅 5 页，不再 6105）
  - `全局分页(估算)完成: 1498 章, 总耗时 453ms` + `paginateAllChapters 完成`（主线程阻塞消除）
- 独立 Dart 脚本验证估算数学：`estimatedCharsPerPage=289`、`totalBookPages≈14982`（合理区间）、单章 5544 字符≈20 页。
- `flutter analyze lib/reader/providers/library_provider.dart` — 0 error（余下 2 个既有 warning 非本次引入）。
- `build_slim.sh install-local` — 构建并安装成功（249M）。

**未覆盖**：受 Canvas 渲染 UI 限制，无法自动点击打开书做实时 UI 截图验证；核心逻辑已通过上述日志与单元测试覆盖。

---

## 缺陷修复：章节总页数 Y 恒为 5、全书总页数 Z 暴涨到 159879

**日期**: 2026-09-25
**现象**：修复首屏卡死后，阅读页页码变成 `X / 5 / 159879`——当前章节总页数（Y）永远停在 5，全书总页数（Z）暴涨到 159879（正常应为 ~14970），且 Z 数字明显不对。用户要求“执行初步分页前要检查是否已分页成功”。

**根因（两个独立 bug）**：

1. **Y 恒为 5 的根因——`_paginateChapter` 从不缓存分页结果**：
   旧 `_paginateChapter`（含 batch=5 与 batch=-1）只把结果写进临时 `_pages`，**从不写入 `_chapterPages[ch]`**。而 `syncViewportChars` 的“已分页”守卫依赖 `_chapterPages.containsKey(ch)`，永远为 false，于是每次 `LayoutBuilder` 因 footer 动画 / 安全区变化导致 `maxHeight` 在 436↔461 抖动（每次都改变 `_viewportSig`）都会**重跑 batch=5，把 Y 重新刷回 5 页**。异步补全原本走 `computeRemainingChapterPages`，但它也依赖 `_chapterPages.containsKey` 作 guard（永远 false → 提前 return），且内部调的是另一套 `paginateChapterIsolate` 还抛异常，于是当前章永远停在 batch=5 的 5 页，Y 修不正。

2. **Z 暴涨到 159879 的根因——估算值被瞬时异常布局污染**：
   `syncViewportChars` 每次布局都**无条件**用 `cols*rows` 覆盖 `_estimatedCharsPerPage`（每页字符数）。`LayoutBuilder` 在首帧 / 动画过渡时会回调若干次**瞬时异常小尺寸**（footer 未展开、安全区未计入），某次把 `cpp` 污染成极小值（≈25），于是 `Z = 4111030 / 25 ≈ 159879` 暴涨。

**修复**：

1. **`_paginateChapter` 写入 `_chapterPages`**：分页完成后把 `entries` 映射成 `ChapterPageInfo` 缓存（`fullscreen` / `notFullScreen` 两套分页分别缓存，当前模式写真实列表、另一模式继承上次）。`initialBatch<0 || !truncated` 时照旧加 `_chapterComplete`。这样“已分页”守卫生效，后续布局抖动**跳过 batch=5**，Y 不再被刷回 5。
2. **`syncViewportChars` 守卫改为“已分页即跳过 batch=5”**：以 `_chapterPages.containsKey(ch)` 判据——已分页过的章直接 `_syncPagesForMode` 同步现有页，未完整则**异步**补全（改用已验证可用的 `_paginateChapter(ch, initialBatch:-1)`，不再用会抛异常的 `computeRemainingChapterPages`）。只有“从未分页过的章”才首次跑 batch=5。
3. **`_estimatedCharsPerPage` 取有效最大值**：只在 `cols>=3 && rows>=3`（排除瞬时异常小尺寸）时才接受该次估算，且取所有有效调用的**最大值**（瞬时收缩只会让 cpp 变小，取 max 保证 Z 永不因瞬时布局而暴涨）。
4. （附带）`computeRemainingChapterPages` 补全成功后补 `_chapterComplete.add(ch)`，避免重复补全。

**验证（真机 PCT AL10, Android 10 日志）**：

- Y 修复：`ch=1` 首次 `batch=5` 后异步 `batch=-1` 补全返回 `entries=23 truncated=false`（当前章真实页数=23，不再是 5）；后续布局抖动（h=436/461/610）全部打印 `[pag] syncViewport ch=1 已分页，直接同步现有页（跳过 batch=5）`，Y 稳定为 23，不再刷回 5。
- Z 修复：临时打印 `totalBookPages` 验证，Z 从布局过渡期的 1→14226→6 抖动后**稳定在 14970**，`estimatedCpp=289.0`（即每页 289 字符，305.6×436/(17×26.4) 合理），不再暴涨到 159879。临时调试打印已移除。
- `flutter analyze` — 0 error；`build_slim.sh install-local` — 构建并安装成功（249M）。

**未覆盖**：受 Canvas 渲染 UI 限制，无法自动点击打开书做实时 UI 截图；Z/Y 数值已通过日志与临时打印验证。

---

## 缺陷修复：全屏模式缺状态栏 + 切换时仅改区域不重载内容

**日期**: 2026-09-25
**需求**：为全屏模式增加同样的状态栏（显示页码码 X/Y/Z、进度等）；全屏↔非全屏切换时显示内容需重新加载，不能只是显示区域变化。后续补充：全屏模式不显示章节标题（“第N章”字样）。

**根因**：
- UI 全屏切换用 `setState(() => _isFullscreen = ...)`（screen 自己的字段），**从未调用 `ReaderProvider.toggleFullscreen()`**，导致 provider 内部的 `_isFullscreen` 永远是 `false`，`_chapterPages` 从没存过 fullscreen 模式页。
- 全屏模式下 `appBar: null` 且 `_ReaderFooter` 被 `!_isFullscreen` 条件隐藏 → 全屏无任何状态栏，页码/进度/码全部看不到。
- provider 旧 `toggleFullscreen` 只 `_syncPagesForMode` 复用已缓存页，未失效 `_viewportSig`，切换后 LayoutBuilder 因签名未变可能不重算 → 用户感知为“只是显示区域变化，内容未真正重载”。
- `_ReaderFooter` 章节标题行 `if (chapterTitle != null)` 全屏也显示“第N章”。

**修复**：

1. **全屏状态栏（底部常驻半透明条）**：`_ReaderFooter` 渲染条件由 `if (_controlsVisible && !_isFullscreen)` 改为 `if (_controlsVisible || _isFullscreen)`；全屏时外包 `Container(color: Colors.black54)` 半透明背景常驻显示。复用同一 `_ReaderFooter`，显示 `X / Y / Z` + 进度条 + 翻页/朗读按钮。footer 内 `Spacer()` 条件由 `!isFullscreen && !isGlobalPaginating` 放宽为 `!isGlobalPaginating`，保证全屏时翻页/朗读按钮靠右布局不挤左。
2. **切换改用 provider 真正重载**：全屏切换点（中心点击 thirds 模式 toggle 区）由 `setState(() => _isFullscreen = ...)` 改为 `reader.toggleFullscreen()` + `setState(() => _isFullscreen = reader.isFullscreen)`（UI 字段与 provider 真源同步）。
3. **provider `toggleFullscreen` 失效缓存并重分页**：切换 `_isFullscreen` 后 `_viewportSig = ''`（强制下次 `syncViewportChars` 重算）；若另一模式已缓存则 `_syncPagesForMode` 直接切，否则 `_chapterComplete.remove(ch)` 等 LayoutBuilder 重新测量。满足“切换时重新加载内容而非仅改区域”。
4. **全屏不显示章节标题**：`_ReaderFooter` 标题行条件加 `&& !isFullscreen`。

**验证（真机 PCT AL10, Android 10 日志）**：
- 全屏切换后 `syncViewport` 重新触发分页（fullscreen 参数随布局变化传入），当前章走 `batch=5` → 异步 `batch=-1` 补全，Y 重新计算；后续布局抖动打印“已分页，跳过 batch=5”，不再刷回 5。
- 非全屏 footer 正常显示；全屏底部出现半透明 `X / Y / Z` 状态栏。
- `flutter analyze` — 0 error；`build_slim.sh install-local` — 构建并安装成功（249M）。

**未覆盖**：受 Canvas 渲染 UI 限制，无法自动点击切换全屏做实时 UI 截图；切换重载逻辑已通过日志与代码审查验证。

---

## 缺陷修复：分页状态栏改为“当前页/全书总页数”，消除错误的“5页”

**日期**: 2026-09-25
**现象**：状态栏显示 `2/5/14967`——中间“5”是第一章节首次分页未完成时的临时 batch=5 章页数（chapterPageCount），第一章尚未补全时显示成错误的“5页”；用户要求改为“当前页/全书总页数”。

**根因**：`_ReaderFooter` 页码显示串为 `${pageIndex+1} / $pageCount / $totalBookPages`（当前章内页 / 本章页 / 全书页）。其中 `$pageCount`（=_pages.length）在章节分页未完成时仅 batch=5 的临时值，第一章因此显示成“5”，且语义上“本章页数 Y”在懒分页下本就无稳定含义。

**修复**：footer 页码显示改为只显示 **`$globalPageIndex / $totalBookPages`**（当前页用全书累计 1-based 页码 / 全书总页数 Z）。`globalPageIndex` 已是含章节偏移的 1-based 全书累计页码（`_chapterPagesCount` 对未分页章用字符估算，与 Z 口径一致）。不再显示单独的本章页数，因此“5”这类临时值彻底消失。

**验证**：
- 独立 Dart 脚本复刻 `globalPageIndex` 公式与 footer 显示串：第2章第1页→`21/43`、第1章末页→`20/43`、第2章末页→`43/43`，断言全部通过，格式确为“当前页(全书累计)/全书总页数”。
- `flutter analyze` — 0 error；`build_slim.sh install-local` — 构建并安装成功（249M）。
- 真机因 Canvas UI 无法自动进书截图，但通过代码审查确认 footer 文本构造已变更、不再引用 `pageCount` 作中间项。

---

## 下一步建议

0. **（阻塞项，需后端配合）** 让 `/api/studio/files/read` 支持二进制安全返回，
   例如 `?encoding=base64` 输出 base64 字符串，或新增返回原始字节的 `files/raw`。
   客户端已具备该能力的消费路径（见上文"二进制回退"），后端支持后 PDF/EPUB 即可完整读取。
1. 真机试读一本 PDF 与一本 EPUB，确认提取质量是否满足需求
2. 若 PDF 乱码严重，评估引入 PDFium（需要能访问 GitHub Release）或改用
   服务端提取：让服务器返回已解析的文本
3. 补充 GBK / GB18030 编码探测（`charset_converter` 或内置码表）
4. 清理 `ebook_reader_screen.dart`（未接入导航的遗留屏幕，含未使用代码）
