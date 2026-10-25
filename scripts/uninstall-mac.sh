#!/usr/bin/env bash
# 卸载 macOS 定时同步
# 用法: ./scripts/uninstall-mac.sh [仓库路径]   卸载某个仓库的任务
#       ./scripts/uninstall-mac.sh --all        卸载全部 anywhere 任务
set -euo pipefail

ANYWHERE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"

if [ "${1:-}" = "--all" ]; then
  PLISTS=("$AGENTS"/com.anywhere.autosync.*.plist)
else
  REPO="$(cd "${1:-$ANYWHERE_DIR}" && pwd)"
  NAME="$(basename "$REPO" | tr -d "\n" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-')"
  HASH="$(printf %s "$REPO" | shasum | cut -c1-8)"
  PLISTS=("$AGENTS/com.anywhere.autosync.$NAME.$HASH.plist")
fi

for p in "${PLISTS[@]}"; do
  [ -f "$p" ] || continue
  launchctl bootout "gui/$(id -u)" "$p" 2>/dev/null || true
  rm -f "$p"
  echo "🗑  已卸载: $(basename "$p" .plist)"
done
