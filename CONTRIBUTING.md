# 贡献说明 / Contributing

欢迎通过 Issue 提交可复现的问题，通过 Pull Request 提交小范围修改。请勿附上真实凭据、完整私人仓库内容或未经脱敏的日志。

- 脚本兼容 macOS Bash 3.2 与 Windows Git Bash；运行时仅依赖 Git 和系统组件。
- 默认 README 使用简体中文，功能或参数变化必须同步更新 `README.en.md`。
- 不硬编码个人路径、账号或私有远程。配置示例使用占位地址。
- 安全默认值不能因方便而放宽；改变自动暂存、推送或历史行为时，补充临时仓库回归测试。
- 提交前运行 `python3 -m unittest discover -s tests -v`、`for file in scripts/*.sh; do bash -n "$file"; done`、`git diff --check`，查看 CI。
- shell / Markdown 使用 LF，PowerShell 使用带 BOM 的 UTF-8 和 CRLF。不提交密钥、依赖目录、日志或构建产物。

## English

Report reproducible problems in Issues and propose focused changes in Pull Requests. Never include real credentials, private repository contents or unredacted logs.

- Keep runtime scripts compatible with macOS Bash 3.2 and Git Bash. Runtime dependencies are Git and OS components only.
- Keep Simplified Chinese `README.md` and `README.en.md` aligned whenever behavior or parameters change.
- Use placeholder configuration, without personal paths, accounts or private remotes.
- Preserve safe defaults. Add isolated repository tests for staging, push and history changes.
- Run `python3 -m unittest discover -s tests -v`, `bash -n` on each shell file, and `git diff --check`; inspect CI results.
- Use LF for shell / Markdown and UTF-8 with BOM and CRLF for PowerShell. Do not commit secrets, dependencies, logs or build artifacts.
