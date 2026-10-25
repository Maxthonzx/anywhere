#!/usr/bin/env bash
# Explicit dual remote setup; does not push, delete remotes, or infer a mirror.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/safety.sh
. "$SCRIPT_DIR/safety.sh"
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo 'Usage: setup-remotes.sh <primary-url> <mirror-url> [repository]' >&2
  exit 2
fi
PRIMARY="$1"; MIRROR="$2"
cd "${3:-$SCRIPT_DIR/..}"
[ "$(git rev-parse --is-inside-work-tree)" = true ] || exit 1
for url in "$PRIMARY" "$MIRROR"; do
  if url_embeds_credentials "$url"; then
    echo 'Use a URL without embedded credentials. ssh://user@host/path and git@host:path are allowed.' >&2
    exit 2
  fi
done
set_remote() {
  if git remote get-url "$1" >/dev/null 2>&1; then
    git config --local --replace-all "remote.$1.url" "$2"
  else
    git remote add "$1" "$2"
  fi
  # Tracking refs must describe the actual push destination.
  git config --local --unset-all "remote.$1.pushurl" || [ "$?" -eq 5 ]
  git config --local "remote.$1.mirror" false
}
set_remote origin "$PRIMARY"
set_remote github "$MIRROR"
git config --local anywhere.remotes 'origin github'
echo 'Configured origin + github, enabled in local anywhere.remotes. No push performed.'
echo 'Review URLs and visibility locally with: git remote -v'
