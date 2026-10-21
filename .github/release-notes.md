## 中文

- 修复切换账号时因 Codex app-server 的 `workspace routing discovery timed out` 报错而中断的问题。macOS 和 Windows 在保存当前凭证、核验目标账号时直接读取本地凭证中的工作区身份。
- 保留同邮箱不同工作区的身份检查。凭证缺失、损坏或工作区不匹配时仍明确报错；登录和用量查询继续通过 Codex app-server 执行。

## English

- Fix account switching interrupted by Codex app-server's `workspace routing discovery timed out` error. Both macOS and Windows now read workspace identity directly from local credentials when saving the current account and verifying the installed target.
- Preserve identity checks for workspaces sharing an email. Missing, malformed, or mismatched credentials still produce visible errors; login and usage requests continue to use Codex app-server.
