# AGENTS.md

本文件是给所有 AI Agent（Codex、Claude Code、Cursor、Antigravity 等）的统一指令。
本项目是面向 macOS / Windows 的 Git 自动同步工具包。默认 README 使用简体中文，英文版为 `README.en.md`；变更公开行为时保持两份说明一致。

这些约定面向本仓库维护者及其 Agent。工具使用者应只同步自己的项目和远程仓库，不要向上游工具仓库推送业务代码。

## 开始工作前
1. 先运行 `git pull`（或 `bash scripts/autosync.sh`），确保是最新版本。

## 工作中
- 小步提交：每完成一个有意义的改动就 `git commit`，提交信息写清楚做了什么。
- 若已安装定时任务，默认大约每 10 分钟运行一次。不要长时间保留大量未提交的半成品改动。
- 运行同步前确认目标仓库、远程白名单及工作区；不要自动更改仓库可见性或重写历史。
- 不要提交密钥：`.env`、token、证书一律不进 Git，只提交 `.env.example`。

## 跨平台约定（Mac + Windows）
- 换行符统一 LF（由 `.gitattributes` 保证），`.ps1/.bat` 除外。
- 不写死绝对路径（如 `/Users/...`、`C:\...`），使用相对路径。
- 不使用软链接（Windows 默认不支持）。
- 文件名大小写保持一致，不要出现只有大小写不同的两个文件。
- shell 脚本需兼容 Git Bash（Windows）与 macOS 自带 bash 3.2。

## 结束工作前
1. 提交并推送：`bash scripts/autosync.sh`。

## 目录结构
- `scripts/autosync.sh` — 自动提交、拉取、合并、推送（macOS 与 Git Bash 共用）
- `scripts/safety.sh` — 敏感文件名、大小和凭据的启发式检查
- `scripts/install-mac.sh` / `uninstall-mac.sh` — macOS 定时任务（launchd）
- `scripts/install-windows.ps1` / `uninstall-windows.ps1` — Windows 定时任务（任务计划程序）
- `scripts/setup-remotes.sh` — 显式配置 origin 与 github，不推送
- `scripts/mirror-github.sh` — 按仓库名把 GitHub 历史备份到目标前缀
- `tests/` — 只用临时仓库的回归测试
