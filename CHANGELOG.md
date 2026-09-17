# ChangeLog

## 2026-09-17
- 修复分片下载（`library_service._fetchChunked`）未拼接 `/api/studio/files/read?path=` 前缀的问题。此前分片请求直接以相对路径（`library/书名.txt?offset=&limit=`）发出，proxy 无法识别为文件下载、将其转发给 studio 后返回 HTML 错误页，导致书籍（如《元尊》）下载内容为 HTML。现已与一次性下载（`_fetchBytes`）使用一致的端点，下载恢复正常，proxy 侧以原始字节（terminal hexdump）整文件缓存后再分片下发，中文 GBK 文件内容正确无乱码。
- 修复会话停止通知重复推送问题。`SessionProvider._onChange` 此前对每个 `sessionStopped` 事件都插入 `_recentChanges`，导致同一会话的停止事件在列表中重复出现、通知多次弹出。现已对 `sessionStopped` 去重：若 `_recentChanges` 中已存在相同会话 ID 的停止事件，则不再重复插入。
