# ChangeLog

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
