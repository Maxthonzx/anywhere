#!/usr/bin/env bash
# Safe automatic commit -> fetch -> merge -> push. Bash 3.2 / Git Bash.
set -u
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/safety.sh
. "$SCRIPT_DIR/safety.sh"
DRY_RUN=0
REPO=""
usage() { echo 'Usage: bash scripts/autosync.sh [--dry-run] [repository]'; }
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [ -z "$REPO" ] || { usage >&2; exit 2; }; REPO="$arg" ;;
  esac
done
REPO="${REPO:-$SCRIPT_DIR/..}"
cd "$REPO" || exit 1
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || { echo 'Not a Git working tree' >&2; exit 1; }
cd "$(git rev-parse --show-toplevel)" || exit 1
REPO="$PWD"
GIT_DIR="$(git rev-parse --absolute-git-dir)" || exit 1
BRANCH="$(git symbolic-ref --short -q HEAD)" || { echo 'detached HEAD: skipped'; exit 0; }
MAX_BYTES="${ANYWHERE_MAX_FILE_BYTES:-52428800}"
case "$MAX_BYTES" in ''|*[!0-9]*) echo 'Invalid ANYWHERE_MAX_FILE_BYTES' >&2; exit 2 ;; esac
[ "$MAX_BYTES" -gt 0 ] 2>/dev/null || { echo 'Invalid file size limit' >&2; exit 2; }
REMOTES="$(git config --local --get anywhere.remotes || true)"
REMOTES="${REMOTES:-origin}"
# Explicit names only: no option injection, globbing, URLs or implicit discovery.
REMOTE_LIST=()
read -r -a REMOTE_LIST <<< "$REMOTES"
[ "${#REMOTE_LIST[@]}" -gt 0 ] || exit 2
validate_remote() {
  local r="$1" push_url
  case "$r" in -*|*[!A-Za-z0-9_.-]*|'') echo 'Invalid remote name' >&2; return 2 ;; esac
  FETCH_URL="$(git remote get-url --all "$r")" || { echo "Remote not configured: $r" >&2; return 2; }
  push_url="$(git remote get-url --push --all "$r")" || return 2
  if url_embeds_credentials "$FETCH_URL"; then echo "Unsafe or multiple URLs: $r" >&2; return 2; fi
  [ "$FETCH_URL" = "$push_url" ] || { echo "Fetch/push URLs must be identical and singular: $r" >&2; return 2; }
  [ "$(git config --bool --get "remote.$r.mirror" || true)" != true ] || { echo "Mirror-mode remote not supported: $r" >&2; return 2; }
}
BASE_URLS=()
for r in "${REMOTE_LIST[@]}"; do
  validate_remote "$r" || exit 2
  BASE_URLS+=("$FETCH_URL")
done
verify_remotes() {
  local i
  for ((i=0; i<${#REMOTE_LIST[@]}; i++)); do
    validate_remote "${REMOTE_LIST[$i]}" || return 1
    [ "$FETCH_URL" = "${BASE_URLS[$i]}" ] || { echo 'Remote URL changed during sync' >&2; return 1; }
  done
}

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY RUN: %s\nBranch: %s\nRemotes: %s\n' "$REPO" "$BRANCH" "$REMOTES"
  GIT_OPTIONAL_LOCKS=0 git status --short || exit 1
  echo 'Preview only: no staging, credential scan, commit, network, lock or log writes.'
  exit 0
fi
# Apply before git add / commit as well as fetch. This does not stop GPG pinentry.
export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=Never
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ConnectTimeout=10 -o BatchMode=yes}"
LOG_DIR="${ANYWHERE_LOG_DIR:-$HOME/.anywhere/logs}"
mkdir -p "$LOG_DIR" || exit 1
LOG="$LOG_DIR/autosync.log"
HOST="$(hostname 2>/dev/null || echo unknown)"; HOST="${HOST%%.*}"
log() { printf '[%s] [%s] %s\n' "$(date '+%F %T')" "${REPO##*/}" "$*" >> "$LOG"; }
fail() { echo "$*" >&2; log "$*"; exit 1; }
# Never reclaim a live process's lock based solely on elapsed time.
LOCK="$GIT_DIR/anywhere.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  OLD_PID="$(cat "$LOCK/pid" 2>/dev/null || true)"
  case "$OLD_PID" in ''|*[!0-9]*) echo 'Sync lock present; inspect it before removing.'; exit 0 ;; esac
  if kill -0 "$OLD_PID" 2>/dev/null; then echo 'Sync already running'; exit 0; fi
  # Serialize stale-lock recovery, then re-read: another starter may already
  # have replaced the old directory. Never remove its new live lock.
  RECOVERY="$LOCK.recovery"
  mkdir "$RECOVERY" 2>/dev/null || { echo 'Lock recovery already in progress'; exit 0; }
  CURRENT_PID="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ "$CURRENT_PID" != "$OLD_PID" ]; then rmdir "$RECOVERY"; exit 0; fi
  rm -rf "$LOCK" || { rmdir "$RECOVERY"; exit 1; }
  mkdir "$LOCK" 2>/dev/null || { rmdir "$RECOVERY"; exit 0; }
  printf '%s\n' "$$" > "$LOCK/pid"
  rmdir "$RECOVERY"
fi
printf '%s\n' "$$" > "$LOCK/pid"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/anywhere.XXXXXX")" || { rm -rf "$LOCK"; exit 1; }
INDEX_LOCK_OWNED=0
MERGING=0
INDEX=""
cleanup() {
  local i tmp
  if [ "$MERGING" -eq 1 ]; then
    # Interruptions can land before MERGE_HEAD exists: git still holds index.lock
    # and may leave .merge_file_* temp files from the merge driver.
    i=0
    while [ "$i" -lt 25 ]; do
      if [ ! -e "$GIT_DIR/MERGE_HEAD" ] && { [ -z "$INDEX" ] || [ ! -e "$INDEX.lock" ]; }; then
        break
      fi
      git merge --abort >/dev/null 2>&1 || true
      if [ -n "$INDEX" ]; then rm -f "$INDEX.lock"; fi
      i=$((i + 1))
      sleep 0.1
    done
    for tmp in "$REPO"/.merge_file_*; do
      [ -f "$tmp" ] || continue
      rm -f "$tmp"
    done
    MERGING=0
  fi
  if [ "$INDEX_LOCK_OWNED" -eq 1 ]; then rm -f "$INDEX.lock"; fi
  rm -rf "$TMP" "$LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[ ! -f "$GIT_DIR/index.lock" ] || { echo 'Git index is locked; skipped'; exit 0; }
for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
  [ ! -e "$GIT_DIR/$state" ] || fail 'Git operation in progress; finish it manually.'
done
# Use a temporary index for inspection; never unstage the user's files on rejection.
INDEX="$(git rev-parse --git-path index)"
if [ -f "$INDEX" ]; then cp "$INDEX" "$TMP/original-index" || exit 1; fi
BASE_HEAD="$(git rev-parse --verify HEAD 2>/dev/null || true)"
candidate() {
  if [ -f "$INDEX" ]; then cp "$INDEX" "$TMP/index" || return 1; else rm -f "$TMP/index"; fi
  GIT_INDEX_FILE="$TMP/index" git add -A || return 1
  GIT_INDEX_FILE="$TMP/index" git write-tree
}
TREE="$(candidate)" || fail 'Cannot prepare candidate snapshot.'
check_tree "$TREE" || fail 'Safety check blocked sync. See the message above; the original index was kept.'
if [ "${ANYWHERE_DAEMON:-0}" = 1 ]; then
  sleep 2
  NEXT_TREE="$(candidate)" || fail 'Cannot recheck candidate snapshot.'
  if [ "$TREE" != "$NEXT_TREE" ]; then log 'Files changed during observation; postponed.'; exit 0; fi
fi
# Existing commits can contain credentials even after the file has been removed.
# Check all locally reachable history not already present in every selected remote.
check_outgoing() {
  local r ref commit commits
  for r in "${REMOTE_LIST[@]}"; do
    ref="refs/remotes/$r/$BRANCH"
    if git rev-parse --verify -q "$ref" >/dev/null; then
      commits="$(git rev-list HEAD "^$ref")" || return 1
    elif git rev-parse --verify -q HEAD >/dev/null; then
      commits="$(git rev-list HEAD)" || return 1
    else
      commits=""
    fi
    for commit in $commits; do
      check_commit "$commit" || return 1
    done
  done
}
check_outgoing || fail 'Outgoing history blocked by safety check. See the message above; nothing was pushed.'
# No synthetic identity that leaks a user/host email: require ordinary Git identity.
if [ -z "$(git config user.name || true)" ] || [ -z "$(git config user.email || true)" ]; then
  fail 'Configure git user.name and user.email first.'
fi
git var GIT_AUTHOR_IDENT >/dev/null 2>&1 || fail 'Invalid Git author identity.'
git var GIT_COMMITTER_IDENT >/dev/null 2>&1 || fail 'Invalid Git committer identity.'
# Serialize the final index transaction with ordinary Git commands. Commit using
# the private index so a rejection/failing hook never overwrites user staging.
if ! (set -C; : > "$INDEX.lock") 2>/dev/null; then
  fail 'Git index became locked; retry later.'
fi
INDEX_LOCK_OWNED=1
if [ -f "$TMP/original-index" ]; then
  cmp -s "$INDEX" "$TMP/original-index" || fail 'Git index changed during inspection; retry later.'
else
  [ ! -e "$INDEX" ] || fail 'Git index changed during inspection; retry later.'
fi
[ "$BASE_HEAD" = "$(git rev-parse --verify HEAD 2>/dev/null || true)" ] || fail 'HEAD changed during inspection; retry later.'
ACTUAL_TREE="$(candidate)" || fail 'Cannot prepare final candidate snapshot.'
[ "$ACTUAL_TREE" = "$TREE" ] || fail 'Files changed after inspection; retry when editing has stopped.'
if ! GIT_INDEX_FILE="$TMP/index" git diff --cached --quiet; then
  if [ "${ANYWHERE_INCLUDE_HOSTNAME:-}" = 1 ]; then
    COMMIT_MSG="auto($HOST): $(date '+%F %T')"
  else
    COMMIT_MSG="auto: $(date '+%F %T')"
  fi
  GIT_INDEX_FILE="$TMP/index" git commit -q -m "$COMMIT_MSG" >>"$LOG" 2>&1 || fail 'Commit failed; original index kept.'
  log 'Committed local changes.'
  # Atomic replacement while holding the real index lock.
  cp "$TMP/index" "$INDEX.lock" || fail 'Commit succeeded but index update failed; inspect git status manually.'
  mv "$INDEX.lock" "$INDEX" || fail 'Cannot replace index; inspect git status manually.'
else
  rm -f "$INDEX.lock"
fi
INDEX_LOCK_OWNED=0

NET=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15)
REACHABLE=()
FAILED=0
# Capture network errors without logging URLs/credentials returned by Git.
# Never recurse into submodules: their objects are not covered by check_tree.
for r in "${REMOTE_LIST[@]}"; do
  verify_remotes || fail 'Remote configuration changed; retry after reviewing it.'
  if git -c fetch.recurseSubmodules=no -c submodule.recurse=false "${NET[@]}" fetch -q --no-tags "$r" "+refs/heads/$BRANCH:refs/remotes/$r/$BRANCH" >"$TMP/network" 2>&1; then
    REACHABLE+=("$r")
    MERGING=1
    if ! git -c submodule.recurse=false merge -q --no-edit "refs/remotes/$r/$BRANCH" >>"$LOG" 2>&1; then
      git merge --abort >/dev/null 2>&1 || true
      MERGING=0
      fail "Merge failed with $r/$BRANCH; local commits kept. Resolve manually."
    fi
    MERGING=0
  else
    # An empty remote has no branch yet; distinguish it from an unreachable remote.
    if git -c fetch.recurseSubmodules=no -c submodule.recurse=false "${NET[@]}" ls-remote --exit-code --heads "$r" "refs/heads/$BRANCH" >"$TMP/network" 2>&1; then
      log "Fetch failed: $r"; FAILED=1
    else
      code=$?
      if [ "$code" -eq 2 ]; then
        # A changed remote URL may leave a stale tracking ref. An absent branch
        # has no trusted baseline; scan the complete history before creating it.
        git update-ref -d "refs/remotes/$r/$BRANCH" || fail 'Cannot clear stale remote tracking ref.'
        REACHABLE+=("$r")
      else
        log "Remote unavailable: $r"; FAILED=1
      fi
    fi
  fi
done
# Recheck merged content/history before any remote receives it.
check_outgoing || fail 'Merged history blocked by safety check; inspect locally before pushing.'
for r in ${REACHABLE[@]+"${REACHABLE[@]}"}; do
  verify_remotes || fail 'Remote configuration changed; refusing to push.'
  REMOTE_SHA="$(git rev-parse -q --verify "refs/remotes/$r/$BRANCH" 2>/dev/null || true)"
  [ "$(git rev-parse HEAD)" != "$REMOTE_SHA" ] || continue
  if git -c push.recurseSubmodules=no "${NET[@]}" -c push.followTags=false push -q "$r" "HEAD:refs/heads/$BRANCH" >"$TMP/network" 2>&1; then
    log "Push succeeded: $r"
  else
    log "Push failed: $r; retry next run"; FAILED=1
  fi
done
[ "$FAILED" -eq 0 ] || fail 'One or more remotes failed; local commits kept. See autosync.log.'
echo "Synced $BRANCH ($(git rev-parse --short HEAD))"
