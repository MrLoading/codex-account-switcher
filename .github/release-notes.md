## 中文

- macOS 仅保留菜单栏入口和弹出面板，移除手动启动或重开应用时出现的独立账号窗口。
- 修复预测请求失败后，重新打开菜单仍需等待 15 分钟才能再次获取的问题。失败后打开菜单可立即重新请求；关闭菜单不会取消进行中的预测请求。
- 预测不可用时，提示和日志保留具体的 HTTP 状态或网络错误。

## English

- Keep the macOS interface in the menu-bar popover and remove the separate account window shown on launch or reopen.
- Fix failed forecast requests blocking the next menu opening for 15 minutes. Reopening after failure can fetch again immediately, and closing the popover no longer cancels an active forecast request.
- Include the specific HTTP status or network error in unavailable-forecast tooltips and logs.
