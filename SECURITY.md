# 安全说明 / Security

同步脚本会提交并推送目标仓库文件。启用之前，请检查忽略规则、所有选定远程的实际 fetch / push URL 和仓库可见性。仅在可信项目中运行，Git hooks 和属性过滤器也可能执行代码。

内置检查只覆盖部分敏感文件名和凭据格式，不保证发现所有秘密。文件名比较不区分大小写。匹配发生在完整候选快照，以及待推送提交的文件、作者、提交者和说明上；`.env.example` 只豁免文件名规则，不豁免内容检查。子模块 gitlink 会被拒绝，子模块内容不在检查范围内。普通公开配置可能误报，请人工判断，不要为了通过检查而伪装真实秘密。

如果秘密已泄露，应先撤销或轮换，再按照仓库托管方流程清理历史和副本。不要把实际秘密粘贴到公开 Issue。

报告漏洞前，请查看 [GitHub 仓库的 Security 页面](https://github.com/Maxthonzx/anywhere/security)，确认是否有可用的私密报告入口。若没有，不要公开可利用细节或凭据；先通过普通 Issue 仅请求维护者提供私密渠道。维护者目前不承诺固定响应时限。

## English

This toolkit commits and pushes files from a target repository. Before enabling it, inspect ignore rules, actual fetch / push URLs for every selected remote, and repository visibility. Only run it in trusted projects: Git hooks and attribute filters may execute code.

Built-in guards cover only some sensitive filenames and credential formats, not every secret. Filename comparison is case-insensitive. Checks inspect the complete candidate snapshot and, for outgoing commits, the files plus author, committer, and message. `.env.example` is exempt only from the filename rule, not content checks. Submodule gitlinks are rejected; submodule contents are not scanned. Public configuration may trigger false positives; review it manually instead of disguising real secrets to bypass detection.

If a secret is exposed, revoke or rotate it first, then follow your hosting provider's history and replica cleanup process. Never paste secrets into public Issues.

Check the [repository Security page](https://github.com/Maxthonzx/anywhere/security) for an available private reporting channel. If none is available, do not publish exploitable details or credentials; open a minimal Issue asking for a private channel. No fixed response-time commitment is currently provided.
