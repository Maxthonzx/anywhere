# anywhere

> [!WARNING]
> **This project was written with AI by a product manager who can't code. Please use it with caution. If it helps you, that would make me very happy.**

[简体中文](README.md) | [English](README.en.md)

![How anywhere works: Mac and Windows computers commit, fetch, merge, and push to allowlisted remotes. An unreachable remote is skipped and retried later.](docs/images/how-it-works.en.png)

## Overview

anywhere uses Git to synchronize project files, and AI handoff notes stored as files (for example `AGENTS.md`), across Mac and Windows computers. It is a set of scripts, not a resident application. On a schedule or by hand it runs one pass of commit, fetch, merge, and push.

It is meant for one person moving between computers on the same branch. Every remote you explicitly list is a bidirectional replica. **This is an early version and only `origin` is enabled by default.** Each run commits every non-ignored change in the target repository. Review `.gitignore`, remote URLs, and repository visibility before enabling a schedule.

It does not synchronize AI chat transcripts, ignored files, credentials, dependencies, or runtime environments. It is not for several people automatically editing one branch, and it does not replace backups or code review.

## How it works

launchd on macOS and Task Scheduler on Windows both run `scripts/autosync.sh`. The Windows task launches Git Bash through `wscript.exe`. The script uses the target repository's current branch and the `anywhere.remotes` value in that clone's `.git/config`. The setting does not travel with the code. The default is `origin`.

```mermaid
flowchart LR
  mac["macOS launchd"] --> sync["autosync.sh"]
  win["Windows Task Scheduler"] --> sync
  sync --> local["Current branch of the target repository"]
  local --> origin["origin"]
  local --> extra["github and other allowlisted remotes"]
```

Each selected remote is fetched, merged, and pushed. There is no one-way publish mode. An unreachable remote does not stop attempts to reach the others; the process exits nonzero if any remote failed. A conflict aborts that merge and keeps the local commit. Tags are not pushed. Submodules are not entered.

A real run follows the order below. `--dry-run` stops after remote validation and prints only the branch, remote names, and `git status --short`.

```mermaid
flowchart TD
  start["Manual run or scheduled task"] --> gate{"Is the branch, remote name, and URL valid"}
  gate -->|"no"| halt["Skip or exit without changing the index"]
  gate -->|"yes"| snap["Build a candidate snapshot with a temporary index"]
  snap --> guard{"Names, size, credentials, and outgoing history"}
  guard -->|"rejected"| kept["Keep the original index and stop"]
  guard -->|"accepted"| commit["Commit every non-ignored change"]
  commit --> net["Fetch and merge each allowlisted remote in order"]
  net --> again{"Does the merged history still pass"}
  again -->|"no"| hold["Keep the local commit and do not push"]
  again -->|"yes"| push["Push the current branch to reachable remotes"]
  push --> done["Exit nonzero if any remote failed; retry next run"]
```

Details that the diagram does not spell out:

1. Detached HEAD, an existing sync lock, or `index.lock` exits 0. An in-progress merge, rebase, cherry-pick, revert, or bisect exits with an error.
2. Inspection uses a temporary index. A rejection does not replace the user's index.
3. Scheduled runs set `ANYWHERE_DAEMON=1`. The script waits two seconds and postpones the run if the snapshot changes. After it takes the index lock it compares once more and stops on a mismatch. This only reduces the chance of storing a file mid-write.
4. The automatic message is `auto: YYYY-MM-DD HH:MM:SS` and does not include the hostname. Set `ANYWHERE_INCLUDE_HOSTNAME=1` to use `auto(<short hostname>): timestamp`. The short hostname is then published in remote history.
5. Conflicts run `git merge --abort`. A signal during merge also tries to clear `MERGE_HEAD`, `index.lock`, and merge temp files.
6. When the remote does not have this branch yet, the full local history is scanned before the push creates it. History that is already on the remote is not rescanned every run.

## Install

### Requirements

- Git 2.28 or newer. macOS uses its Bash 3.2; Windows uses Git Bash from Git for Windows.
- Windows scheduling also needs Windows PowerShell 5.1 or newer, Task Scheduler, and `wscript.exe`. If VBScript is disabled, run the sync script by hand in Git Bash.
- Configure `user.name`, `user.email`, and authentication for every remote first. Use an SSH agent or the OS credential manager. Do not put tokens in repository URLs.
- Python 3.9 or newer is only for tests. Synchronization does not need Python, Node.js, or `gh`.

### Get the toolkit

```bash
git clone https://github.com/Maxthonzx/anywhere.git ~/dev/anywhere
cd ~/dev/anywhere
```

That is this project's current address. Before publishing the source in another public repository, update the repository links in both READMEs and `SECURITY.md`.

The toolkit and the repository you synchronize can live in different directories. The examples assume your project is already cloned at `~/dev/my-project` and its `origin` is a repository you can write to. **The toolkit's own `origin` is not your project's remote.**

```bash
cd ~/dev/my-project
git remote -v
git config user.name "Your Name"
git config user.email "you@example.com"
```

Review the project's `.gitignore`. Exclude `.env`, private keys, dependencies, build output, and logs. A new ignore rule does not remove a file that is already tracked.

### Install a schedule

Complete one successful manual sync from the next section before installing a schedule.

macOS:

```bash
bash scripts/install-mac.sh ~/dev/my-project       # Every 600 seconds; runs once when installed
bash scripts/install-mac.sh ~/dev/my-project 300   # Custom interval; minimum 60 seconds
```

Preflight and launchd share one PATH: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`. Git must be available in those directories. The plist escapes `&`, `<`, and `>`.

Windows, from PowerShell in the toolkit directory:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 -RepoPath D:\dev\my-project
# Custom interval: append -IntervalMinutes 5
```

The interval is in minutes, from 1 to 525600. The installer accepts local drive paths and spaces. It rejects UNC paths and shell metacharacters such as quotes and dollar signs. Each generated task is limited to 30 minutes. launchd jobs on macOS have no matching limit.

## Use

Run these from the toolkit directory. On Windows use Git Bash and substitute your paths.

```bash
cd ~/dev/anywhere
bash scripts/autosync.sh --dry-run ~/dev/my-project
bash scripts/autosync.sh ~/dev/my-project
```

The preview does not stage, scan content, commit, use the network, or write a log or lock. Safety checks run only on a real sync.

Uninstall:

```bash
bash scripts/uninstall-mac.sh ~/dev/my-project
# bash scripts/uninstall-mac.sh --all
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall-windows.ps1 -RepoPath D:\dev\my-project
# Remove every job with -All instead of -RepoPath
```

The default log is `~/.anywhere/logs/autosync.log`. On macOS, launchd stdout and stderr go to `launchd.log` in that directory. Windows hides the background window. Logs are not rotated. Network errors do not write remote URLs into this log.

Success prints `Synced <branch> (<short SHA>)`. Skips for detached HEAD, a busy sync lock, or a locked index exit 0. A failed safety check, a merge conflict, or any remote failure exits nonzero and keeps commits already created locally.

## Configuration

| Setting | Default | Purpose |
|---|---|---|
| `git config --local anywhere.remotes` | `origin` | Space-separated allowlist; merge and push in this order |
| `ANYWHERE_MAX_FILE_BYTES` | `52428800` | Positive integer byte limit for one blob |
| `ANYWHERE_LOG_DIR` | `~/.anywhere/logs` | Log directory |
| `ANYWHERE_DAEMON` | `0` | `1` enables the two-second write check; installers set it |
| `ANYWHERE_INCLUDE_HOSTNAME` | unset | `1` puts the short hostname in the commit message |

Remote names may contain only letters, digits, dots, underscores, and hyphens, and must not start with `-`. Each remote must have one URL, and the fetch and push URLs must match. These are rejected: a URL that embeds a password or token (for example `ssh://git:token@host/...`, `https://token@host/...`, or `https://user:token@host/...`), a separate pushurl, multiple URLs, and `remote.<name>.mirror=true`. `ssh://git@host/path` and `git@host:path` are accepted.

`anywhere.remotes` lives in each clone's `.git/config`. Configure it on every computer. Extra remotes are never discovered automatically.

Optional: point `origin` and `github` at two empty repositories you control. The command updates remotes and does not push.

```bash
bash scripts/setup-remotes.sh \
  https://example.com/your-team/my-project.git \
  https://github.com/YOUR_ACCOUNT/my-project.git \
  ~/dev/my-project
```

The same local settings:

```bash
cd ~/dev/my-project
git config --local anywhere.remotes 'origin github'  # Merge and push in this order
git config --local anywhere.remotes 'origin'         # Return to origin only
```

Remote URLs are read again before network access and before every push. If a URL changes during the run, the run stops rather than pushing to a different destination.

### Batch backup

`scripts/mirror-github.sh` is separate from everyday two-way sync. It requires an explicit GitHub owner, destination prefix, and repository names. After cloning, it scans all history and annotated tags. By default it does not force-overwrite the destination:

```bash
bash scripts/mirror-github.sh --dry-run YOUR_ACCOUNT https://example.com/your-team repo-a repo-b
bash scripts/mirror-github.sh YOUR_ACCOUNT https://example.com/your-team repo-a repo-b
```

Create matching repositories at the destination first. All branches and tags are pushed. Only `--force` overwrites destination history and deletes branches and tags that are no longer in the source.

## Safety limits

The checks are heuristics. They produce false positives and false negatives. There is no bypass switch. For a false positive, reorganize the file or pause the schedule and commit by hand. If a secret has already been committed, revoke it first, then clean history using your host's process.

Filenames are matched case-insensitively, using the last path segment:

- `.env`, `.env.*`, `*.env`, and `.envrc`. A file whose exact name is `.env.example` skips the filename rule; its contents are still checked.
- `*.pem`, `*.key`, `*.p12`, `*.pfx`
- `id_rsa`, `id_dsa`, `id_ed25519`, `id_ecdsa`
- `credentials.json`, `.netrc`, `.npmrc`, `.pypirc`

Text checks cover some GitHub tokens, AWS access key ids beginning with `AKIA`, common private-key headers, and `http(s)` URLs that embed a username and password. They cover the candidate snapshot, the author, committer, and message of outgoing commits, and annotated tags in the mirror flow. Matched secrets are not printed.

A submodule gitlink is rejected. That avoids reporting a missing blob as a credential, and it avoids `git add -A` turning a submodule that is not checked out into a deletion commit. Fetch, merge, and push all disable submodule recursion. A symlink is checked as an ordinary small blob. Git LFS objects themselves are outside the check.

These checks do not replace a dedicated secret scanner. Do not run the scripts in an untrusted repository: Git hooks and attribute filters execute code. `GIT_TERMINAL_PROMPT=0` does not stop GPG pinentry, so a signed commit can still stall a background run.

## FAQ

**macOS reports `Operation not permitted`?**

Prefer `~/dev` for repositories. Desktop, Documents, and Downloads can be blocked by privacy controls. The installer prints a warning when it sees those locations.

**Merge conflict?**

Uninstall that project's schedule, run `git status`, then fetch and merge by hand in allowlist order. After the conflict is committed and a manual sync succeeds, install the schedule again. Do not force-push or discard local commits just to get the schedule running.

**What happens to the existing index?**

A real sync makes one commit from every non-ignored change. It does not keep a partial staging boundary. A failed safety check leaves the original index in place. Pause the schedule while organizing commits by hand.

**It keeps saying a sync is already running, or the lock has no PID?**

The lock is the directory `.git/anywhere.lock`. If its PID is still alive, this run exits 0. The script does not delete a lock just because it is old. A recycled PID that now belongs to an unrelated process can also cause repeated skips. Remove the directory only after confirming that no sync is running.

**Upgrading from the old version?**

Older builds synchronized every remote and invented a Git identity when none was configured. Each clone now needs its own `anywhere.remotes`, `user.name`, and `user.email`. An installed job points at the toolkit directory it was given. Updating this checkout does not update other copies. If you move the toolkit, uninstall with the script in the old location, then install again.

**A Windows task stops after a while?**

Task Scheduler limits one run to 30 minutes. The first push to a new remote can exceed that while scanning a long history. macOS launchd jobs do not have this cap.

## Development

```bash
python3 -m unittest discover -s tests -v
# On Windows, use python if the python3 command is absent
```

Tests use temporary repositories and local bare remotes. They do not need production accounts. CI runs them on Linux, macOS, and Windows. Windows also parses the installer, registers a task, launches it, and uninstalls it. ShellCheck covers `scripts/*.sh`.

When behavior or parameters change, update this file and [简体中文](README.md) together. See also [contributing](CONTRIBUTING.md) and [security](SECURITY.md).

Licensed under the [MIT License](LICENSE).
