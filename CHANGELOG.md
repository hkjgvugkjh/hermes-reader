# ChangeLog

## 2026-09-17
- 修复分片下载（`library_service._fetchChunked`）未拼接 `/api/studio/files/read?path=` 前缀的问题。此前分片请求直接以相对路径（`library/书名.txt?offset=&limit=`）发出，proxy 无法识别为文件下载、将其转发给 studio 后返回 HTML 错误页，导致书籍（如《元尊》）下载内容为 HTML。现已与一次性下载（`_fetchBytes`）使用一致的端点，下载恢复正常，proxy 侧以原始字节（terminal hexdump）整文件缓存后再分片下发，中文 GBK 文件内容正确无乱码。
