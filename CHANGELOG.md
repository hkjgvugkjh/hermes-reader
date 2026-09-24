# ChangeLog

## 2026-09-24（已实现 · 真机验证）
- **新增全局分页处理，显示 X/Y/Z 页码和分页进度动画**。
  - X = 当前章节内页码（1-based），Y = 当前章节总页数，Z = 全书总页数
  - Z 值为各章页数之和，未分页章节按 1 页估算
  - 章节检测完成后自动触发 `paginateAllChapters`，后台逐章计算总页数
  - 非全屏状态下显示"分页中 N%"进度动画，完成后自动清除
  - 每处理完一个章节，`notifyListeners` 触发 UI 更新 Z 值
  - 若处理完的是当前章节，同步更新当前章节页码 Y
  - 真机验证（Huawei P10）：打开《元尊》→ 页码显示 1/5/1498 → 分页中 0% 动画正常

## 2026-09-24（已实现 · 真机验证）
- **修复页内容尾部空白导致渲染溢出**。
  根因：`pageContentAtOffset` 返回的页内容未做 rtrim，尾部空白/换行符在渲染时
  占据垂直空间，导致页面底部溢出（BOTTOM OVERFLOWED BY 11 PIXELS）。
  修复：对每页内容调用 `trimRight()` 去除尾部空白，确保渲染高度不超过测量值。
  真机验证（Huawei P10）：打开《元尊》→ 无溢出提示，页码显示正常（3/5/1498）。

## 2026-09-24（已实现 · 真机验证）
- **新增分页页码显示 X/Y/Z 格式**（当前页/章节页数/全书总页数）。
  - X = 全书全局页码（前面所有章节页数之和 + 当前章节内页码 + 1）
  - Y = 当前章节总页数
  - Z = 全书总页数（各章页数之和，未分页章节按 1 页估算）
  - 进度条同步使用全局页码计算
  - 章节分页完成后自动更新 Z 值（通过 `notifyListeners` 触发）

## 2026-09-24（已实现 · 真机验证）
- **修复段首全角空格（U+3000）缩进消失问题**。
  根因：Flutter `TextAlign.justify` 会折叠每行行首的所有 `White_Space=Yes` 字符（包括
  U+3000 全角空格），导致中文段首缩进完全消失。
  调试过程：通过临时开关 `debugReplaceFullwidthSpace` 将 U+3000 替换为"口"，
  确认文本中确实包含 U+3000，排除文本提取问题。
  尝试方案（均无效）：
  1. `cleanText` 保护-恢复（`\u0001` 占位符）→ 文本保留但渲染仍折叠
  2. `WidgetSpan` + `SizedBox` 替代 U+3000 → justify 下仍被折叠
  3. 替换为普通空格 U+0020 → justify 同样折叠
  4. 替换为不换行空格 U+00A0 → 同上
  最终方案：将 `TextAlign.justify` 改为 `TextAlign.left`，确保段首 U+3000
  不被折叠，缩进正常显示。
  真机验证（Huawei P10）：打开《元尊》→ 正文各行开头均有全角空格缩进。
- **新增调试开关 `debugReplaceFullwidthSpace`**：ReaderConfig 新增布尔字段，
  设置面板中添加"[调试] 全角空格→口"开关，用于排查段首缩进显示问题。
- **新增精简编译脚本 `build_slim.sh`**：排除 TTS/sano 模型资源（~84MB），
  APK 从 350MB 降至 249MB，支持 `install`（传输到 Mac）和 `install-local`（安装到本机）。
- **修复 txt 文件换行符残留**：`cleanText` 使用保护-恢复方式处理 `\r\n`，
  避免 `\r` 残留在行首导致字符异常。
- **修复 `readerConfig` 序列化**：`toJson()`/`fromJson()` 新增
  `debugReplaceFullwidthSpace` 字段，确保调试开关状态持久化。

## 2026-09-23（已修复 · 待真机验证）
- **修复阅读页始终显示“没有可显示的内容”**。
  根因（连锁两处）：① `book_reader_screen` 用 `page == null` 作为是否渲染正文的
  开关，而 `page` 为空恰恰是分页完成前的状态 —— 触发分页的 `LayoutBuilder` 就在
  这个分支里，于是永远不会被构建、`syncViewportChars()` 永不执行、`_pages` 永远是
  空的，形成死锁；改为按 `content` 判空，`page == null` 时走 `isPaginating ||
  pages.isEmpty` 的加载态分支。② `openBook()` 不再调用 `_rebuildPages()` 播种
  字符级兜底页，一旦 ① 发生就没有任何内容可显示；现在 `openBook()` 恢复调用
  `_rebuildPages()` 先给出兜底页，视口精确分页随后覆盖。
- **修复分页行高单位错误**：传给 `syncViewportChars()` 的 `TextStyle.height` 被写成
  绝对像素值 `fontSize × lineHeightFactor`（17×1.6≈27），而 `TextStyle.height` 是
  **字号倍数**，实际行高被放大到 462dp/行 —— 每屏只能塞进 1 个字符。改为传入
  `reader.config.lineHeightFactor`，与正文渲染 `_buildPageBody` 的测量样式一致。
- 健壮性：`_paginateChapter()` 提前返回时清空 `_viewportSig`，避免 debounce 把后续
  布局帧全部吞掉而永久停在加载态；新增 `_canPaginate()`，`nextPage()/previousPage()`
  /`goToChapter()` 在无布局信息时不再“假装还有下一页”（此前 `while(nextPage())`
  会死循环），`goToChapter()` 退化为在字符级页面中跳转。
- **扩大阅读区域并修复 4.3px 布局溢出**：正文高度原来按
  `constraints.maxHeight - 100 - safePadding` 计算 —— SafeArea 已把系统 insets
  去掉一次，这里再减 100px + insets 属于重复扣除，每页浪费约 65dp 空白；改为
  `constraints.maxHeight - 16 - insets`（16px 为取整余量）。残余的偶发
  "RenderFlex overflowed by 4.3 pixels"（TextPainter 测量与真实渲染的固定微差，
  位于 Huawei P10 的满页上）已被外层 `ClipRect` 裁剪、肉眼不可见，属 debug 日志
  噪音。
- `main.dart` 的 `FlutterError.onError` 现在同时输出 widget 链
  （`details.toString()`，仅 debug 模式），便于从 logcat 直接定位布局问题。
- 目录检测 `_detectChapters()` 不再挂到 `addPostFrameCallback`（未泵帧的场景永远不
  执行，单元测试看不到目录），改为开卷即发起（本身跑在后台 Isolate，不阻塞 UI）。
- 真机验证（Huawei PCT-AL10，USB 直连）：打开 7.7MB《元尊》→ 正文正常显示、
  翻页 11/29→14/29 正常、章节完整分页 29 页约 300ms、无卡顿。
- 回归：`flutter test` 83/84 通过（唯一失败项 `chapter_detector_test` 的“少于两个
  标题”用例在改动前 HEAD 上同样失败，与本次无关）。

## 2026-09-22（已实现 · 真机验证）
- **修复阅读页正文底部溢出（BOTTOM OVERFLOWED BY 672/523 PIXELS）**。
  根因：渲染层把正文 `Column` 套进 `SizedBox(height: contentMaxHeight)`（非全屏
  ≈ 454dp / 全屏 ≈ 630dp）依赖分页结果“每页恰好一屏”，但实际 `_pages` 来自
  `openBook → _rebuildPages()` 的**估算法分页**（按固定 `charsPerPage=700` 字/页
  切页，无布局测量），每页 ~700-800 字 ≈ 41 行 × 27.2dp ≈ 1120dp ≫ 454dp →
  溢出 672px（数字精确吻合）。本应按真实屏幕分页的 `ensureChapterPages →
  paginateChapterIsolate` 从未生效：`_chapterRanges` 由 `scanChapters` 生成、
  fallback 只识别 markdown `#` 标题 → 普通 txt 全书只有 1 个 range，而章节检测
  `_chapters`（识别“第X章”）是另一套异步系统，`ensureChapterPages(chapterIdx)`
  因 `chapterIndex >= _chapterRanges.length` 直接 return。此前 3 次“修复溢出”
  的尝试（TextPainter 高度匹配等）都改在了这条死路上。
- **改用视口自适应估算分页**：阅读页 `LayoutBuilder` 内按真实可视高度换算
  每页字数（`perLine = maxWidth/fontSize`、`lines = availH/(fontSize×lineHeight)`、
  `chars = perLine × lines × 0.85` 安全系数），调用新增的
  `ReaderProvider.syncViewportChars(chars)` 重切页并以字符偏移对齐保持阅读位置。
  因 CJK 字形至多 1em 宽，实际行数只会更少，每页永不超过固定高度的正文区。
  `charsPerPage` 用户设置作为上限。`ReadingProgress` 新增 `offset` 字段，进度按
  字符偏移恢复，页大小变化不再错位。`updateConfig` 字号变化分支删除了硬编码
  尺寸的 `ensureChapterPages` 死代码调用。
- **重新设计章节跳转定位逻辑**：此前章节标题被当作普通段落累积进当前页，
  标题落在页内中下部，渲染层固定高度 `SizedBox+ClipRect` 无滚动 → 跳转后标题
  不在可见范围（“多移动了两行”）；原设计的 `_pendingChapterScrollFraction=0.1`
  页内滚动因无 `ScrollView`、`_scrollController` 无 clients 从不执行（死代码）。
  现把章节标题偏移作为 `breakOffsets` 传给分页器，`_paginateByBreaks` 重写为
  流式 `cursor` 累积偏移（修掉原 `block.indexOf(trimmed)` 在重复子串时偏移错位
  的 bug），每章标题强制成为新页页首 → `goToChapter` 跳到的页 `startOffset ==
  章节标题偏移`，标题显示在屏幕顶部。同步删除 `_pendingChapterScrollFraction`/
  `_pendingChapterPageIndex`/`_scrollController` 等死代码。
- **修复章节列表弹窗滚动定位偏移过大**：`_showChapterList` 原用硬编码
  `itemExtent=56.0` 估算 `dense ListTile` 高度，但实际更矮 → `current*56`
  滚过头，当前章被推到视口上方（如当前 39 章时第一行显示 45 章）。改为给
  `ListView.builder` 传 `itemExtent` 固定每行高度使滚动精确，并用
  `viewportDimension` 计算居中偏移 `current*extent + extent/2 - viewport/2`
  （clamp 到首尾），当前章出现在列表中段；`jumpTo` 即时定位替代动画。

## 2026-09-20（已实现）
- **新增 clarify 双向事件流**：支持后端通过 `/chat-run` 命名空间发送的 `clarify.requested` 事件，
  在待处理事项中展示选项供用户选择，并通过 `clarify.respond` 回传用户选择。
- `SessionProvider` 新增 `_diEventSub` 订阅 DI 事件流 (0x3B)，解析 `clarify.requested` 并创建 TaskItem。
- `TaskListScreen._submit` 根据任务类型分发：clarify 任务调用 `sendClarifyResponse`，auth 任务调用 `sendAuthResponse`。
- 依赖 hermes-shared 新增的 `sendClarifyResponse` 方法。

## 2026-09-18（已实现 · 已 Linux 端到端验证）
- **新增 sanoTTS 引擎 + 引擎可选（真实集成）**：为 hermes-reader 增加
  [sanoTTS](https://github.com/Ampixa/sanoTTS) 本机离线神经 TTS 引擎（微型模型，294K–2.27M
  参数，可跑在 WASM/ESP32）。`SpeechEngine` 新增 `sano`，`TtsMode` 扩展为
  `auto/server/local/builtin/sano` 五项可在阅读设置中显式选择。`TtsService` 接入 `_sano`
  并纳入 auto 回退链（local → builtin → sano → server）；同时修复 `ttsMode` 配置未同步到
  `TtsService` 的缺陷（此前选择引擎不生效）。
- 新建 Flutter FFI 插件 **`hermes-application/sanotts_flutter/`**：vendoring 上游 C 运行时
 （`native/mobile` + `native/mcu`，lineage `en_us_e13b`），通过 Dart FFI 包装
  `sanotts_open_memory`，提供 `SanoTtsVoice`（权重从 assets 加载 → 合成 Float32 PCM →
  16-bit WAV）、`MisakiPhonemizer`（忠实移植上游 62 音素词表 `DEFAULT_VOCABULARY` + `E2M`
  表，text→音素 id）与 `EspeakNgProvider`（FFI 驱动 espeak-ng 产出 IPA，复用 sherpa 已
  打包的 `libespeak-ng.so` + `espeak-ng-data`）。hermes-reader 的 `SanoTtsSource` 改用该插件
  真实合成（不再占位），并自动解包 `assets/tts/espeak-ng-data.zip` 供 espeak-ng 使用。
- **已验证（Linux x86_64）**：`text → espeak-ng IPA[həlˈoʊ fɹʌm sˈɑːnoʊ tˌiːtˌiːˈɛs] →
  62 音素 id(30, dropped="") → libsanotts_flutter.so → 59392 样本(24kHz) → WAV`。G2P 零丢符
  号，证明词表/E2M 移植逐字节正确。`bin/probe.dart` 与 `test/sano_e2e_test.dart` 留作回归。
- **✅ Android APK 已构建（2026-09-19）**：`build_reader_apk.sh` 运行成功；APK 内含自打包的
  `libespeak-ng.so`（由 vendoring 的 `sanotts_flutter/third_party/espeak-ng` 1.53.0 编出，
  三 ABI 齐全）与 `libsanotts_flutter.so`，权重 `heartnano.q8.{front,model}.bin` 已就位
  （git-ignored），`espeak-ng-data` 由 `SanoTtsSource` 优先解包 `assets/sano/espeak-ng-data.zip`，
  回退 `assets/tts/` 那份。整条链路由 Gradle/CMake 真编入包。
- **剩余（仅真机听测）**：`adb install -r` 后在「仅 SanoTTS」下验证可出声（用户已选暂不做）。
  权重 URL 见 `sanotts_flutter/lib/src/weights.dart`。详见
  `hermes-application/progress/20260918-sanoTTS.md`
  与 `sanotts_flutter/README.md`。

## 2026-09-17
- 修复分片下载（`library_service._fetchChunked`）未拼接 `/api/studio/files/read?path=` 前缀的问题。此前分片请求直接以相对路径（`library/书名.txt?offset=&limit=`）发出，proxy 无法识别为文件下载、将其转发给 studio 后返回 HTML 错误页，导致书籍（如《元尊》）下载内容为 HTML。现已与一次性下载（`_fetchBytes`）使用一致的端点，下载恢复正常，proxy 侧以原始字节（terminal hexdump）整文件缓存后再分片下发，中文 GBK 文件内容正确无乱码。
- 修复会话停止通知重复推送问题。`SessionProvider._onChange` 此前对每个 `sessionStopped` 事件都插入 `_recentChanges`，导致同一会话的停止事件在列表中重复出现、通知多次弹出。现已对 `sessionStopped` 去重：若 `_recentChanges` 中已存在相同会话 ID 的停止事件，则不再重复插入。
