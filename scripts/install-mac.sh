#!/usr/bin/env bash
# 在 macOS 上为某个仓库安装定时自动同步（launchd）
# 用法: ./scripts/install-mac.sh [仓库路径] [间隔秒数，默认 600]
set -euo pipefail

ANYWHERE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "${1:-$ANYWHERE_DIR}" && pwd)"
INTERVAL="${2:-600}"
case "$INTERVAL" in ''|*[!0-9]*) echo 'Interval must be a positive integer' >&2; exit 2 ;; esac
[ "$INTERVAL" -ge 60 ] 2>/dev/null || { echo 'Minimum interval is 60 seconds' >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || { echo 'This installer requires macOS' >&2; exit 2; }
# Validate configuration before installing a job that runs immediately.
DAEMON_PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
PATH="$DAEMON_PATH" /bin/bash "$ANYWHERE_DIR/scripts/autosync.sh" --dry-run "$REPO"
xml_escape() {
  # Quotes are valid in XML text nodes; only &, < and > require escaping.
  printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

NAME="$(basename "$REPO" | tr -d "\n" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-')"
HASH="$(printf %s "$REPO" | shasum | cut -c1-8)"
LABEL="com.anywhere.autosync.$NAME.$HASH"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.anywhere/logs"
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
chmod +x "$ANYWHERE_DIR/scripts/autosync.sh"

SCRIPT_XML="$(xml_escape "$ANYWHERE_DIR/scripts/autosync.sh")"
REPO_XML="$(xml_escape "$REPO")"
LOG_XML="$(xml_escape "$LOG_DIR/launchd.log")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_XML</string>
    <string>$REPO_XML</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$DAEMON_PATH</string>
    <key>ANYWHERE_DAEMON</key><string>1</string>
  </dict>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_XML</string>
  <key>StandardErrorPath</key><string>$LOG_XML</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✅ 已安装: $LABEL"
echo "   仓库: $REPO"
echo "   间隔: ${INTERVAL}s"
echo "   日志: $LOG_DIR/autosync.log"
case "$REPO" in
  "$HOME/Desktop"*|"$HOME/Documents"*|"$HOME/Downloads"*)
    echo ""
    echo "⚠️  仓库位于 桌面/文稿/下载 目录，macOS 隐私保护可能阻止后台任务访问。"
    echo "   建议把项目移到 ~/dev 之类的目录，或在 系统设置 → 隐私与安全性 → 完全磁盘访问权限 中添加 /bin/bash。"
    ;;
esac
