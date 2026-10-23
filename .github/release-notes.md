## 中文

- 设置新增默认关闭的“自动重置试验（仅日志）”。开启后，对已保存账号的 banked reset 在到期前 10、5、1 分钟进行只读检查并记录模拟操作，绝不消费 reset。
- 本地日志保留计划与实际检查时间、额度、reset 到期信息及查询错误；重启不重复记录已完成的检查，错过的检查会明确标记。
- 设置提供日志文件夹入口，macOS 唤醒后立即刷新额度。应用需保持运行才能按时记录。

## English

- Add an off-by-default Auto-reset experiment (log only) setting. It performs read-only checks for saved accounts at 10, 5 and 1 minute before banked resets expire. It never consumes a reset.
- Keep local logs of planned and actual check times, usage, reset expiry details and read errors. Completed checkpoints remain deduplicated across restarts, and missed checkpoints are recorded explicitly.
- Add a log-folder shortcut and refresh usage when macOS wakes. Keep the app running to record checkpoints on time.
