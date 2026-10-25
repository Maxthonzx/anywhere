#!/usr/bin/env bash
# Explicit repository backup. Never enumerate an entire account by default.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/safety.sh
. "$SCRIPT_DIR/safety.sh"
FORCE=0; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) break ;;
  esac
done
if [ $# -lt 3 ]; then
  echo 'Usage: mirror-github.sh [--dry-run] [--force] <github-owner> <destination-prefix> <repo> [repo...]' >&2
  exit 2
fi
GH_USER="$1"; DEST="${2%/}"; shift 2
case "$GH_USER" in ''|-*|*[!A-Za-z0-9_-]*) echo 'Invalid GitHub owner' >&2; exit 2 ;; esac
if url_embeds_credentials "$DEST"; then echo 'Invalid destination or embedded credentials' >&2; exit 2; fi
for repo in "$@"; do
  case "$repo" in ''|.|..|-*|*[!A-Za-z0-9_.-]*) echo 'Invalid repository name' >&2; exit 2 ;; esac
done
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY RUN: owner=%s, force=%s, repositories:\n' "$GH_USER" "$FORCE"
  printf '  %s\n' "$@"
  echo 'No credentials scanned, network accessed or files written.'
  exit 0
fi
MAX_BYTES="${ANYWHERE_MAX_FILE_BYTES:-52428800}"
case "$MAX_BYTES" in ''|*[!0-9]*) exit 2 ;; esac
[ "$MAX_BYTES" -gt 0 ] || exit 2
export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=Never
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ConnectTimeout=10 -o BatchMode=yes}"
NET=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15)
TMP="$(mktemp -d "${TMPDIR:-/tmp}/anywhere-mirror.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PUSH_ARGS=('refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*')
if [ "$FORCE" -eq 1 ]; then
  echo 'WARNING: --force overwrites destination branches/tags and deletes absent refs.' >&2
  PUSH_ARGS=(--prune '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*')
fi
failed=0
for repo in "$@"; do
  # A temporary clone avoids stale or concurrently updated cache repositories.
  dir="$TMP/$repo.git"
  if ! git "${NET[@]}" clone -q --mirror "https://github.com/$GH_USER/$repo.git" "$dir" >"$TMP/network" 2>&1; then
    echo "Clone failed: $repo" >&2; failed=1; continue
  fi
  # Process-substitution exit statuses are not propagated by set -e.
  if ! git -C "$dir" rev-list --all > "$TMP/commits" 2>"$TMP/network"; then
    echo "History enumeration failed: $repo" >&2; failed=1; continue
  fi
  if ! git -C "$dir" for-each-ref --format='%(refname)' refs/tags > "$TMP/tags" 2>"$TMP/network"; then
    echo "Tag enumeration failed: $repo" >&2; failed=1; continue
  fi
  safe=1
  while IFS= read -r commit; do
    (cd "$dir" && check_commit "$commit") || { safe=0; break; }
  done < "$TMP/commits"
  # Also inspect tags pointing directly to trees/blobs, which rev-list may omit.
  while IFS= read -r ref; do
    if [ "$(git -C "$dir" cat-file -t "$ref")" = tag ]; then
      git -C "$dir" cat-file tag "$ref" | check_text || safe=0
    fi
    kind="$(git -C "$dir" cat-file -t "$ref^{}")"
    case "$kind" in
      commit) ;;
      tree) (cd "$dir" && check_tree "$ref^{}") || safe=0 ;;
      *) echo "Unsupported non-commit/tree tag: $repo" >&2; safe=0 ;;
    esac
  done < "$TMP/tags"
  if [ "$safe" -ne 1 ]; then echo "Safety check blocked: $repo" >&2; failed=1; continue; fi
  if git -C "$dir" -c push.recurseSubmodules=no "${NET[@]}" push -q "$DEST/$repo.git" "${PUSH_ARGS[@]}" >"$TMP/network" 2>&1; then
    echo "Mirrored: $repo"
  else
    echo "Push failed: $repo" >&2; failed=1
  fi
done
exit "$failed"
