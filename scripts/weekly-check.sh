#!/bin/bash
# Weekly drift check on a Mac that has the reference cleaner and real apps installed.
# Runs scripts/release-check.sh at background priority, keeps the log, and shows a notification when it fails,
# so a parity gap shows up in the middle of a normal week and not on release day.
#
# Run it by hand:        scripts/weekly-check.sh
# Run it every Monday:   scripts/weekly-check.sh --install      (adds a LaunchAgent; --uninstall removes it)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
LABEL="app.sapu2.weekly-check"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/Sapu2"

case "${1:-}" in
  --install)
    mkdir -p "$LOGDIR" "$(dirname "$PLIST")"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$ROOT/scripts/weekly-check.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
</dict></plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Installed: runs every Monday at 09:00. Log: $LOGDIR/weekly-check.log"
    exit 0 ;;
  --uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed."
    exit 0 ;;
esac

mkdir -p "$LOGDIR"
LOG="$LOGDIR/weekly-check.log"
{ echo "=== $(date '+%Y-%m-%d %H:%M') ==="; } >> "$LOG"
# The check rewrites Tests/parity-fixture.json with this week's recording; `git diff` shows what drifted.
if taskpolicy -b scripts/release-check.sh >> "$LOG" 2>&1; then
  echo "passed" >> "$LOG"
  echo "Weekly check passed. Log: $LOG"
else
  echo "FAILED" >> "$LOG"
  osascript -e 'display notification "Parity check failed. See ~/Library/Logs/Sapu2/weekly-check.log" with title "Sapu2 weekly check"' 2>/dev/null || true
  echo "Weekly check failed. Log: $LOG"
  exit 1
fi
