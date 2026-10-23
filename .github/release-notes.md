## 中文

- Tibo 预测直接展示网站返回的 24h、48h 百分比，移除时间戳、两项数值排序和额外响应限制，避免有效数值被隐藏。
- “登记当前登录账号”与启动、刷新共用本地凭据同步，移除多余的身份接口请求和重复解码，保留账号匹配检查。
- 移除重复的版本号传递、过期版本兜底及限制账号管理控件类型的断言，清理过时设计说明。
- 自动重置试验仍然只记录日志，不消费 reset。

## English

- Display the site's 24h and 48h forecast percentages without timestamp, ordering or extra response gates that hide valid values.
- Register Current Account now uses the same local credential synchronization as startup and refresh, removing the extra identity RPC and duplicate decoding while preserving account matching.
- Remove redundant version forwarding, the stale version fallback and an assertion banning text boxes in account management. Correct outdated design notes.
- The reset expiry experiment remains log-only and never consumes a reset.
