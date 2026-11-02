#!/usr/bin/env bash
# Build browserpark into ~/.local/bin and start its menu bar icon at login.
#   ./install.sh               build and load the LaunchAgent
#   ./install.sh --build-only  build only
#   ./install.sh --uninstall   remove the binary and the LaunchAgent
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin/browserpark"
LABEL="io.github.mitev22.browserpark"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$BIN"
  echo "Removed browserpark"
  exit 0
fi

mkdir -p "$(dirname "$BIN")"
swiftc -O -swift-version 5 "$HERE/main.swift" "$HERE/proxy.swift" -o "$BIN"
echo "Built $BIN"

[ "${1:-}" = "--build-only" ] && exit 0

# AbandonProcessGroup: a Chrome started from the menu must survive browserpark quitting or restarting.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns before the old job has gone, and bootstrap fails until it has.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && { echo "Loaded $LABEL"; exit 0; }
  sleep 1
done
echo "Could not load $LABEL" >&2
exit 1
