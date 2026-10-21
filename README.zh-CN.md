# Codex Account Switcher — macOS 增强分支

[English](README.md) · 中文

本项目基于刘朝（Zhao Liu）创建的 [liuzhao1225/codex-account-switcher](https://github.com/liuzhao1225/codex-account-switcher)，主要增加 macOS 切换账号后的启动控制。这份 README 介绍本 fork 的额外功能；基础功能和完整项目说明请查看[上游 README](https://github.com/liuzhao1225/codex-account-switcher/blob/main/README.zh-CN.md)。

## 下载本 fork

**最新 macOS 开发安装包位于 [macOS Dev Artifact workflow](https://github.com/MrLoading/codex-account-switcher/actions/workflows/macos-dev-build.yml)。**

1. 打开本仓库的 **Actions → macOS Dev Artifact**，选择最近一次成功的运行。
2. 在 **Artifacts** 中下载 **Codex-Account-Switcher-macos-dev**。下载构建产物需要登录 GitHub。
3. 解压下载文件及其中的 `.app.zip`，将 **Codex Account Switcher.app** 拖入“应用程序”。

需要 macOS 14+ 和 Apple Silicon。此流水线生成临时签名（ad-hoc）的开发版应用，未经过 Apple 公证。上游 Release 和上游 npm 安装器提供的是上游版本。

应用内更新源仍指向上游。需要保留本 fork 的功能时，请通过上述 workflow 获取更新；在应用内安装上游更新会替换这些改动。

## 比上游多了什么

| 额外功能 | 行为 |
| --- | --- |
| **自动打开开关** | 控制切换账号后是否启动 Codex Desktop。默认开启，关闭后切换成功也保持桌面应用关闭。 |
| **切换后执行 Shell 脚本** | 目标账号校验并提交成功后执行可选脚本。关闭自动打开时也执行，等待脚本完成后再判断是否启动。 |
| **自定义环境变量** | 配置代理等变量，供脚本及 Switcher 启动的桌面应用使用。 |
| **源账号与目标账号信息** | 脚本通过环境变量获取双方的本地档案 ID、账号／工作区 ID、邮箱和显示名称。 |
| **第三方 provider 身份响应兼容** | app-server 明确返回 `account: null`、`requiresOpenaiAuth: false` 时，从同一档案的 `auth.json` 读取已保存的 ChatGPT 身份，保留 provider 配置。 |

新增设置界面仅面向 macOS，Windows 沿用上游界面和启动行为。上游的本地凭证校验逻辑继续保留，第三方 provider 的兼容处理用于仍通过 app-server 读取身份的流程。

## 如何配置

打开 **设置 → 桌面应用启动**。自动打开开关、环境变量和脚本集中在一个紧凑分组中。开关立即保存；环境变量和脚本通过同一个**保存**按钮保存。

环境变量每行一个 `KEY=VALUE`，不写 `export`，也不用 Shell 引号：

```text
all_proxy=http://127.0.0.1:7890
MY_SETTING=example
```

脚本框可填写 Shell 命令，也可以调用已有文件：

```sh
/bin/bash "$HOME/scripts/after-switch.sh"
```

切换顺序为：

```text
关闭桌面应用 → 保存当前凭证 → 激活并校验目标账号
→ 提交目标账号 → 执行脚本 → 按自动打开开关决定是否启动
```

选择当前账号不会执行这些操作。脚本留空则跳过；脚本失败会报告错误并停止自动启动，已切换的目标账号保持生效。

脚本通过 `/bin/zsh -c` 执行，以用户主目录为工作目录。执行前先合并 Switcher 继承的环境变量与设置页变量，再写入保留的账号变量，并将 `CODEX_HOME` 设为活动 Codex 目录。脚本中的 `export` 不会传回桌面应用，应用需要的变量应填写在环境变量框。脚本不提供交互式输入，也不显示标准输出和错误输出，需要日志时请自行重定向到文件。

## 脚本可读取的账号变量

| 源账号 | 目标账号 | 内容 |
| --- | --- | --- |
| `CODEX_SWITCHER_SOURCE_PROFILE_ID` | `CODEX_SWITCHER_TARGET_PROFILE_ID` | 本地档案的稳定 UUID。 |
| `CODEX_SWITCHER_SOURCE_ACCOUNT_ID` | `CODEX_SWITCHER_TARGET_ACCOUNT_ID` | 账号／工作区 ID，可能为空。 |
| `CODEX_SWITCHER_SOURCE_EMAIL` | `CODEX_SWITCHER_TARGET_EMAIL` | 邮箱，可能为空。 |
| `CODEX_SWITCHER_SOURCE_NAME` | `CODEX_SWITCHER_TARGET_NAME` | 显示名称。 |

源账号信息取自切换前捕获的档案，目标账号信息取自已校验并提交的账号。缺少的可选信息为空字符串；首次启用账号时，所有源账号变量均为空字符串。这些保留值覆盖设置页同名变量，并且只传给脚本。

例如，按目标邮箱执行不同操作：

```sh
case "$CODEX_SWITCHER_TARGET_EMAIL" in
  work@example.com) /bin/bash "$HOME/scripts/work-account.sh" ;;
  *) /bin/bash "$HOME/scripts/default-account.sh" ;;
esac
```

## 致谢与许可证

原始项目：[刘朝 Zhao Liu / liuzhao1225](https://github.com/liuzhao1225/codex-account-switcher)。本 fork 保留上游的 [MIT 许可证](LICENSE)及版权声明。
