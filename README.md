# anywhere

> [!WARNING]
> **这个项目是一个不懂代码的产品经理用 AI 写的，请谨慎使用。如果能帮到你，我会很开心。**

[简体中文](README.md) | [English](README.en.md)

![anywhere 的工作原理：多台 Mac 和 Windows 对白名单里的远程做提交、拉取、合并和推送；连不上的远程先跳过，下次再试](docs/images/how-it-works.zh-CN.png)

## 简介

anywhere 用 Git 在多台 Mac / Windows 电脑之间同步项目文件，以及写成文件的 AI 工作交接（例如 `AGENTS.md`）。它是一组脚本，不是常驻应用：定时或手动执行同一次「提交 → 拉取 → 合并 → 推送」。

适合一个人在几台电脑上轮流改同一个分支，也可以把明确列出的多个远程都当作双向副本。**当前是早期版本，默认只同步 `origin`。** 一次运行会提交目标仓库里所有未被忽略的改动。启用定时任务前，先检查 `.gitignore`、远程地址和仓库可见性。

它不同步 AI 客户端里的聊天记录、被忽略的文件、凭据、依赖和运行环境，也不适合多人同时自动改同一分支。它不能代替备份或代码审查。

## 原理

macOS 由 launchd 调用 `scripts/autosync.sh`，Windows 由任务计划程序经 `wscript.exe` 调用 Git Bash 里的同一脚本。脚本进入目标仓库的当前分支，只使用该仓库 `.git/config` 里的 `anywhere.remotes`。这项配置不随代码同步，默认值是 `origin`。

```mermaid
flowchart LR
  mac["macOS launchd"] --> sync["autosync.sh"]
  win["Windows 任务计划程序"] --> sync
  sync --> local["目标仓库的当前分支"]
  local --> origin["origin"]
  local --> extra["github 等白名单远程"]
```

选定的每个远程都会拉取、合并、再推送。没有单独的「只发布、不拉回」模式。某个远程连不上时，其余远程仍会尝试；最后用非零状态表示有失败。冲突会中止这次合并并保留本地提交。不自动推送标签，也不进入子模块。

一次真实运行的顺序如下。`--dry-run` 在校验远程后就结束，只打印分支、远程名和 `git status --short`。

```mermaid
flowchart TD
  start["手动运行或定时任务"] --> gate{"当前分支、远程名和 URL 是否有效"}
  gate -->|"否"| halt["跳过或报错，不改暂存区"]
  gate -->|"是"| snap["用临时 index 生成候选快照"]
  snap --> guard{"文件名、大小、凭据和待推送历史"}
  guard -->|"拒绝"| kept["保留原暂存区并停止"]
  guard -->|"通过"| commit["提交全部未忽略改动"]
  commit --> net["按白名单顺序 fetch 并 merge"]
  net --> again{"合并后的历史是否仍通过检查"}
  again -->|"否"| hold["保留本地提交，不推送"]
  again -->|"是"| push["把当前分支推到可达远程"]
  push --> done["任一远程失败则非零退出，下次重试"]
```

补充细节：

1. detached HEAD、已有同步锁或 `index.lock` 时直接退出 0。未完成的合并、变基、拣选、revert 或 bisect 会报错退出。
2. 检查使用临时 index。拒绝时不替换用户原来的暂存区。
3. 后台任务会设置 `ANYWHERE_DAEMON=1`：先等 2 秒，快照变了就延后到下一轮。拿到 index 锁之后还会再比一次，不一致就停止。这只能降低截断半截文件的概率。
4. 自动提交说明默认是 `auto: YYYY-MM-DD HH:MM:SS`，不带主机名。只有设置 `ANYWHERE_INCLUDE_HOSTNAME=1` 时才变成 `auto(短主机名): 时间`。短主机名会进入远程历史。
5. 合并冲突时执行 `git merge --abort`。中途被信号打断时，也会尽量清掉 `MERGE_HEAD`、`index.lock` 和合并临时文件。
6. 远程还没有这个分支时，会在推送前扫描全部本地历史，再创建该分支。已在远程上的旧历史不会每次重扫。

## 安装

### 环境要求

- Git 2.28 或更新版本。macOS 使用自带 Bash 3.2，Windows 使用 Git for Windows 里的 Git Bash。
- Windows 定时任务还需要 Windows PowerShell 5.1 或更新版本、任务计划程序和 `wscript.exe`。系统禁用 VBScript 时，改为在 Git Bash 里手动运行同步脚本。
- 先配置 `user.name`、`user.email`，以及每个远程的认证。使用 SSH agent 或系统凭据管理器。不要把令牌写进仓库 URL。
- Python 3.9 或更新版本只用于跑测试。同步本身不需要 Python、Node.js 或 `gh`。

### 获取工具

```bash
git clone https://github.com/Maxthonzx/anywhere.git ~/dev/anywhere
cd ~/dev/anywhere
```

上面是这个项目当前的地址。把源码放进另一个公开仓库之前，先同时改掉两份 README 和 `SECURITY.md` 里的仓库链接。

工具和被同步的项目可以放在不同目录。下面假设项目已经克隆到 `~/dev/my-project`，并且它的 `origin` 指向你有写权限的仓库。**工具仓库自己的 `origin` 不是你的项目远程。**

```bash
cd ~/dev/my-project
git remote -v
git config user.name "Your Name"
git config user.email "you@example.com"
```

检查项目的 `.gitignore`，至少忽略 `.env`、私钥、依赖、构建产物和日志。已经跟踪的文件不会因为新的忽略规则而自动移出历史。

### 安装定时任务

先按下一节做一次成功的手动同步，再安装定时任务。

macOS：

```bash
bash scripts/install-mac.sh ~/dev/my-project       # 每 600 秒，安装后立即运行
bash scripts/install-mac.sh ~/dev/my-project 300   # 自定义间隔，至少 60 秒
```

预检和 launchd 使用同一条 PATH：`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`。Git 必须能在这些目录里找到。plist 会转义 `&`、`<` 和 `>`。

Windows，在工具目录打开 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 -RepoPath D:\dev\my-project
# 自定义间隔：追加 -IntervalMinutes 5
```

间隔单位是分钟，允许 1 到 525600。安装器接受本地盘路径和空格，拒绝 UNC 路径以及引号、美元符等 shell 元字符。生成的任务单次最长运行 30 分钟；macOS 的 launchd 任务没有对应上限。

## 使用

在工具目录执行。Windows 请用 Git Bash，并换成自己的路径。

```bash
cd ~/dev/anywhere
bash scripts/autosync.sh --dry-run ~/dev/my-project
bash scripts/autosync.sh ~/dev/my-project
```

预演不暂存、不扫描内容、不提交、不联网，也不写日志或锁。真实运行才会做安全检查。

卸载：

```bash
bash scripts/uninstall-mac.sh ~/dev/my-project
# bash scripts/uninstall-mac.sh --all
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall-windows.ps1 -RepoPath D:\dev\my-project
# 卸载全部：使用 -All，不要同时依赖 -RepoPath
```

日志默认在 `~/.anywhere/logs/autosync.log`。macOS 调度器的标准输出和标准错误写到同目录的 `launchd.log`。Windows 后台窗口隐藏。日志不会自动轮转。网络错误不会把远程 URL 写进这份日志。

成功时打印 `Synced <分支> (<短 SHA>)`。部分跳过（没有当前分支、锁已被占用、index 被锁）退出码为 0。安全检查失败、合并冲突或任一远程失败时退出码非零，本地已创建的提交会保留。

## 配置

| 配置 | 默认值 | 作用 |
|---|---|---|
| `git config --local anywhere.remotes` | `origin` | 空格分隔的远程白名单，按这个顺序合并和推送 |
| `ANYWHERE_MAX_FILE_BYTES` | `52428800` | 单个 blob 的字节上限，必须是正整数 |
| `ANYWHERE_LOG_DIR` | `~/.anywhere/logs` | 日志目录 |
| `ANYWHERE_DAEMON` | `0` | 设为 `1` 时启用 2 秒写入观察；安装器会设置 |
| `ANYWHERE_INCLUDE_HOSTNAME` | 未设置 | 设为 `1` 时，提交说明带短主机名 |

远程名只能包含字母、数字、点、下划线和连字符，并且不能以 `-` 开头。每个远程只能有一个 URL，fetch 与 push 地址必须相同。下面这些配置会被拒绝：带密码或令牌的 URL（例如 `ssh://git:token@host/...`、`https://token@host/...`、`https://user:token@host/...`）、单独的 pushurl、多个 URL、`remote.<name>.mirror=true`。`ssh://git@host/path` 和 `git@host:path` 可以使用。

`anywhere.remotes` 写在每个克隆自己的 `.git/config` 里。每台电脑都要单独配置。脚本不会自动发现其他远程。

可选：把两个你自己的空仓库配成 `origin` 和 `github`。命令只改远程，不推送。

```bash
bash scripts/setup-remotes.sh \
  https://example.com/your-team/my-project.git \
  https://github.com/YOUR_ACCOUNT/my-project.git \
  ~/dev/my-project
```

等价的本地配置：

```bash
cd ~/dev/my-project
git config --local anywhere.remotes 'origin github'  # 按此顺序合并和推送
git config --local anywhere.remotes 'origin'         # 恢复只同步 origin
```

联网前和每次推送前都会重新读取远程 URL。URL 在运行中被改掉时，本次停止，避免推到另一个地址。

### 批量备份

`scripts/mirror-github.sh` 不参与日常双向同步。它要求显式给出 GitHub 所有者、目标前缀和仓库名，克隆后扫描全部历史和附注标签，默认不以强制推送覆盖目标：

```bash
bash scripts/mirror-github.sh --dry-run YOUR_ACCOUNT https://example.com/your-team repo-a repo-b
bash scripts/mirror-github.sh YOUR_ACCOUNT https://example.com/your-team repo-a repo-b
```

目标端要事先建好同名仓库。默认推送全部分支和标签。只有加上 `--force` 才会覆盖目标历史，并删除来源中已经不存在的分支和标签。

## 安全边界

检查是启发式的，会误报，也会漏报。没有跳过开关。误报时请改文件组织，或暂停定时任务后手动提交和推送。秘密已经进过历史时，先撤销凭据，再按托管方的流程清理历史。

文件名按大小写不敏感匹配，只看最后一段：

- `.env`、`.env.*`、`*.env`、`.envrc`。精确名为 `.env.example` 的文件免于文件名规则，内容仍要检查。
- `*.pem`、`*.key`、`*.p12`、`*.pfx`
- `id_rsa`、`id_dsa`、`id_ed25519`、`id_ecdsa`
- `credentials.json`、`.netrc`、`.npmrc`、`.pypirc`

文本检查覆盖部分 GitHub 令牌、`AKIA` 开头的 AWS 访问密钥、常见私钥头，以及带用户名和密码的 `http(s)` URL。范围包括候选快照、待推送提交的作者、提交者和说明，以及镜像流程里的附注标签。匹配到的原文不会打印。

子模块 gitlink 会直接拒绝，避免把「读不到 blob」误报成凭据，也避免 `git add -A` 把未检出的子模块提交成删除。fetch、merge 和 push 都关闭子模块递归。符号链接按一个普通小 blob 检查。Git LFS 的实际对象不在检查范围内。

这些检查不替代专用秘密扫描。不要在不可信仓库里运行；Git hooks 和属性过滤器会执行代码。`GIT_TERMINAL_PROMPT=0` 不能阻止 GPG pinentry，签名提交仍可能在后台停下。

## 常见问题

**macOS 提示 `Operation not permitted`？**

优先把仓库放在 `~/dev`。桌面、文稿和下载目录可能受隐私权限限制。安装器发现这三类路径时会打印提醒。

**合并冲突怎么办？**

先卸载该项目的定时任务，运行 `git status`，再按白名单顺序手动 fetch 和 merge。解决冲突并提交后，手动同步成功，再重新安装。不要为了恢复自动同步而强制推送或丢弃本地提交。

**原来的暂存区会怎样？**

真实同步把全部未忽略改动打成一个提交，不保留「只暂存一部分」的边界。安全检查失败时，原来的暂存区还在。需要手工组织提交时，先停掉定时任务。

**一直提示已经在同步，或锁没有 PID？**

锁目录是 `.git/anywhere.lock`。里面的 PID 仍对应活进程时，本次退出 0。脚本不会因为锁放得久就删掉它；PID 被系统重新分配给无关进程时，也可能一直跳过。确认没有同步进程后，再手工删除这个目录。

**从旧版升级？**

旧版会同步全部远程，并在缺少身份时写入兜底的 Git 作者。现在每个克隆都要自己设置 `anywhere.remotes`、`user.name` 和 `user.email`。已安装的任务指向当时的工具目录；只更新这一份检出不会改其他副本。工具换目录时，先用旧目录里的卸载脚本卸掉任务，再重新安装。

**Windows 任务跑了一阵就停？**

任务计划程序把单次运行限制在 30 分钟。首次向新远程推送并扫描很长的历史时可能不够。macOS 侧没有这个上限。

## 开发与贡献

```bash
python3 -m unittest discover -s tests -v
# Windows 上如果没有 python3 命令，用 python
```

测试使用临时仓库和本地 bare 远程，不需要生产账号。CI 在 Linux、macOS 和 Windows 上跑这些测试；Windows 额外跑安装器解析、注册、启动和卸载。ShellCheck 检查 `scripts/*.sh`。

行为或参数变化时，同时更新本文件和 [English](README.en.md)。其他约定见 [贡献说明](CONTRIBUTING.md) 和 [安全说明](SECURITY.md)。

本项目使用 [MIT 许可证](LICENSE)。
