#!/usr/bin/env bash
# Integration test: needs a logged-in macOS session, Google Chrome, agent-browser and node.
# Drives a throwaway Chrome (temp profile, port 9299). It briefly takes focus and opens windows.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BROWSERPARK_BIN:-$ROOT/.build/browserpark}"
if [ -z "${BROWSERPARK_BIN:-}" ]; then
  mkdir -p "$ROOT/.build"
  swiftc -swift-version 5 "$ROOT/main.swift" "$ROOT/proxy.swift" -o "$BIN" || exit 1
fi
PORT=9299
S=browserparktest
PROFILE="$(mktemp -d)"
FAILS=0
CHROME_PID=""
MENU_PID=""
export BROWSERPARK_CONFIG="$PROFILE/config.json"

cleanup() {
  agent-browser close --session $S >/dev/null 2>&1
  [ -n "$MENU_PID" ] && kill "$MENU_PID" 2>/dev/null
  [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null
  sleep 1
  rm -rf "$PROFILE"
}
trap cleanup EXIT

check() { # name, actual, expected
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi
}
front() { osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier"; }
vis() { agent-browser eval 'document.visibilityState' --session $S; }
raf() { agent-browser eval "new Promise(r=>{let t=setTimeout(()=>r('stalled'),3000);requestAnimationFrame(()=>{clearTimeout(t);r('ran')})})" --session $S; }
state() { "$BIN" status | awk -F'\t' -v p="$PORT" '$2==p{print $3}'; }
windows() { node "$ROOT/tests/windows.mjs" $PORT "$1"; }

launch() { # extra chrome flags
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --remote-debugging-port=$PORT --user-data-dir="$PROFILE/chrome" \
    "$@" --no-first-run --no-default-browser-check about:blank >/dev/null 2>&1 &
  CHROME_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s "http://localhost:$PORT/json/version" >/dev/null && break; sleep 1; done
  sleep 1
  agent-browser connect $PORT --session $S >/dev/null 2>&1
  agent-browser open https://example.com --session $S >/dev/null 2>&1
}

stop_chrome() {
  agent-browser close --session $S >/dev/null 2>&1
  kill "$CHROME_PID" 2>/dev/null
  for _ in 1 2 3 4 5; do kill -0 "$CHROME_PID" 2>/dev/null || break; sleep 1; done
  CHROME_PID=""
}

check "nothing listed before launch" "$(state)" ""
"$BIN" park --port $PORT >/dev/null 2>&1
check "park with nothing running exits non-zero" "$?" 1

echo '[{"name":"configured-but-down","port":9298}]' > "$BROWSERPARK_CONFIG"
check "configured browser shows as down" "$("$BIN" status | awk -F'\t' '$2==9298{print $1"/"$3}')" "configured-but-down/down"
rm "$BROWSERPARK_CONFIG"

# Without the occlusion flag a parked page can go hidden (seen in some runs, not all), so status must warn about it.
launch
check "discovered without config" "$(state)" showing
check "no flag: status warns" "$("$BIN" status | awk -F'\t' -v p="$PORT" '$2==p{print $4}')" missing-occlusion-flag
"$BIN" park --port $PORT
check "no flag: parked" "$(state)" parked
stop_chrome

launch --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling
check "flags: no status warning" "$("$BIN" status | awk -F'\t' -v p="$PORT" '$2==p{print $4}')" ""
"$BIN" park --port $PORT
# Chrome updates occlusion a moment after a window moves, so don't check straight away.
sleep 3
check "park: state" "$(state)" parked
check "park: page visible" "$(vis)" '"visible"'
check "park: page rendering" "$(raf)" '"ran"'
agent-browser screenshot "$PROFILE/parked.png" --session $S >/dev/null 2>&1
check "park: screenshot written" "$([ -s "$PROFILE/parked.png" ] && echo yes)" yes
agent-browser click a --session $S >/dev/null 2>&1
check "park: click works" "$(agent-browser get url --session $S)" "https://www.iana.org/help/example-domains"

"$BIN" show --port $PORT
sleep 0.5
check "show: state" "$(state)" showing
check "show: fully on the desktop" "$(windows fully-onscreen)" yes
check "show: Chrome is frontmost" "$(front)" "$CHROME_PID"

"$BIN" toggle --port $PORT
check "toggle: parks" "$(state)" parked
"$BIN" toggle --port $PORT
check "toggle: shows" "$(state)" showing
"$BIN" park --port $PORT

# Menu bar app: a new window in a parked browser gets parked too.
"$BIN" &
MENU_PID=$!
sleep 4
node "$ROOT/tests/windows.mjs" $PORT new-window
sleep 5
check "menu app: new window gets parked" "$(state)" parked
check "menu app: instance has two windows" "$(windows count)" 2

echo
[ "$FAILS" = 0 ] && echo "ALL PASSED" || echo "$FAILS FAILED"
exit "$FAILS"
