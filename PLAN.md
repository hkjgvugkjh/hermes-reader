# hermes-reader 改进规划

**日期**: 2026-09-11
**状态**: 实施中

> 已完成的功能说明已迁入 `README.md`，逐项进展与遗留问题见 `PROGRESS.md`。
> 本文件保留目标与方案设计。

---

## 问题清单

1. **TTS 朗读停止时报错 "all TTS engines failed"** — 停止时异常未正确处理
2. **后端新增文件刷新后看不到** — 格式过滤只允许 .txt/.md
3. **缺少 PDF/MOBI/EPUB 支持** — 仅支持纯文本
4. **语音朗读未限制文件类型** — 非文本文件也会尝试朗读
5. **无阅读位置记忆** — 每次打开书籍从头开始
6. **主阅读区无三区分页配置** — 点击/滑动区域固定
7. **无朗读进度记录** — 无法续读

---

## 改进方案

### 1. TTS 停止异常修复

**根因**: `tts.stop()` 在引擎已处于错误状态时可能抛出异常；`_toggleNarration` 的 catch 块在停止路径上未隔离。

**修复**:
- `tts.stop()` 包裹 try-catch，忽略停止时的异常
- `_toggleNarration` 停止路径不进入外层 try-catch
- `LocalTtsSource.stop()` 增加保护

### 2. 扩展文件格式支持

**新增支持的格式**:

| 格式 | 方案 | 依赖 |
|------|------|------|
| `.txt`, `.md` | 已有，直接分页 | — |
| `.pdf` | 使用 `pdf` 包提取文本 + PDF 渲染 | `pdf: ^3.10.4` |
| `.epub` | 使用 `epub` 包提取章节文本 | `epub: ^3.2.0` |
| `.mobi` | 尝试作为文本读取（MOBI 基于 HTML） | — |
| `.html`, `.htm` | 去除 HTML 标签后作为文本 | — |
| `.json` | 作为文本读取 | — |

**过滤规则**: `allowedExtensions` 扩展为 `['.txt', '.md', '.pdf', '.epub', '.mobi', '.html', '.htm', '.json']`

**文件类型检测**: 新增 `FileType` 枚举和 `FileTypeDetector` 工具类

### 3. PDF 朗读支持

**方案**:
- 使用 `pdf` 包提取每页文本
- PDF 分页按实际 PDF 页码（非字符数）
- 朗读时使用提取的文本
- 视觉阅读时渲染 PDF 页面（使用 `pdf` + `flutter_pdf` 或 `pdfrx`）

**依赖**: `pdf: ^3.10.4`

### 4. EPUB 朗读支持

**方案**:
- 使用 `epub` 包解析 EPUB 文件
- 提取章节文本内容
- 按章节分页（而非字符数）
- 朗读时使用章节文本

**依赖**: `epub: ^3.2.0`

### 5. 阅读位置记忆

**已有模型**: `ReadingProgress` (bookId, pageIndex, percent, updatedAt)

**新增**:
- `ReadingProgressService` — 持久化阅读位置到 `SharedPreferences`
- `ReaderProvider` 集成：打开书籍时恢复位置，关闭时保存位置
- 书架界面：显示"继续阅读" vs "从头开始"

**存储格式**: `reading_progress_{bookId}.json` 或统一 JSON

### 6. 三区分页配置

**配置项** (扩展 `ReaderConfig`):
```dart
enum TapZoneMode {
  thirds,    // 左中右三区
  halves,    // 左右两区
  edges,     // 仅边缘区域
}

TapZoneMode tapZoneMode = TapZoneMode.thirds;
bool leftZoneForward = false; // 左区是否向前（默认向后）
```

**实现**:
- 阅读区域按配置划分为 2 或 3 个点击区域
- 点击左区 → 根据 `leftZoneForward` 决定向前或向后
- 点击右区 → 相反方向
- 中区点击 → 切换控制栏显示
- 滑动手势保留但可配置是否启用

### 7. 朗读进度记录

**新增**:
- `NarrationProgress` 模型 (bookId, pageIndex, positionInPage, updatedAt)
- `TtsService` 增加 `onNarrationProgress` 回调
- 朗读时实时更新进度
- 停止/暂停时保存当前朗读位置
- 续读时从保存位置开始

### 8. 文件类型限制（语音朗读）

**规则**:
- 仅 `.txt`, `.md`, `.pdf`, `.epub` 支持语音朗读
- `.mobi`, `.html`, `.json` 仅视觉阅读
- 不支持的格式在阅读界面禁用朗读按钮并提示

---

## 文件变更清单

| 文件 | 变更 |
|------|------|
| `pubspec.yaml` | 新增 `pdf`, `epub` 依赖 |
| `lib/reader/models/reader_config.dart` | 新增 `TapZoneMode` 枚举、`tapZoneMode`、`leftZoneForward` 配置项 |
| `lib/reader/models/book.dart` | 新增 `FileType` 枚举、`fileType` 字段 |
| `lib/reader/services/file_type_detector.dart` | 新增 — 文件类型检测 |
| `lib/reader/services/reading_progress_service.dart` | 新增 — 阅读位置持久化 |
| `lib/reader/services/narration_progress_service.dart` | 新增 — 朗读位置持久化 |
| `lib/reader/services/tts_service.dart` | 增加进度回调、停止保护 |
| `lib/reader/services/local_tts_source.dart` | 停止异常保护 |
| `lib/reader/services/library_service.dart` | 扩展 `allowedExtensions`、文件类型检测 |
| `lib/reader/providers/library_provider.dart` | 刷新时保留已下载文件、类型过滤 |
| `lib/reader/providers/reader_provider.dart` | 集成阅读位置记忆、三区分页配置 |
| `lib/reader/screens/book_reader_screen.dart` | 三区分页布局、朗读进度显示 |
| `lib/reader/screens/ebook_reader_screen.dart` | 三区分页布局、朗读进度显示 |
| `lib/reader/screens/reader_home_screen.dart` | 显示继续阅读选项 |
| `lib/main.dart` | 初始化新服务 |

---

## 实施顺序

1. ✅ 写入规划文档
2. ✅ TTS 停止异常修复
3. ✅ 文件类型检测 + 扩展格式支持
4. ✅ 阅读位置记忆（含书架续读 UI）
5. ✅ 三区分页配置（含设置入口）
6. ✅ 朗读进度记录
7. ✅ PDF/EPUB 解析
8. ✅ 构建测试（debug 变体，已安装到设备）