#!/usr/bin/env bash
# Integration test for `browserpark proxy`: needs a logged-in macOS session, Google Chrome, agent-browser and node.
# Drives a throwaway Chrome (temp profile, port 9299, proxy on 19299).
# Only the last section takes focus, and it says so.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/browserpark"
WATCH="$ROOT/.build/focus_watch"
mkdir -p "$ROOT/.build"
swiftc -swift-version 5 "$ROOT/main.swift" "$ROOT/proxy.swift" -o "$BIN" || exit 1
swiftc -swift-version 5 "$ROOT/tests/focus_watch.swift" -o "$WATCH" || exit 1

PORT=9299
PROXY=19299
S=browserparkproxytest
TMP="$(mktemp -d)"
FAILS=0
CHROME_PID=""
PROXY_PID=""
WATCH_PID=""
export BROWSERPARK_CONFIG="$TMP/config.json"
export BROWSERPARK_PROXY_LOG="$TMP/proxy.log"
touch "$BROWSERPARK_PROXY_LOG"

cleanup() {
  agent-browser close --session $S >/dev/null 2>&1
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null
  [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null
  sleep 1
  rm -rf "$TMP"
}
trap cleanup EXIT

check() { # name, actual, expected
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILS=$((FAILS + 1)); fi
}
ab() { agent-browser "$@" --session $S 2>&1; }
vis() { ab eval 'document.visibilityState'; }
raf() { ab eval "new Promise(r=>{let t=setTimeout(()=>r('stalled'),3000);requestAnimationFrame(()=>{clearTimeout(t);r('ran')})})"; }
state() { "$BIN" status | awk -F'\t' -v p="$PORT" '$2==p{print $3}'; }
chrome_activations() { grep -c "^$CHROME_PID$" "$TMP/focus.log"; }
tabs() { ab tab | grep -o '\[t[0-9]*\]' | tr -d '[]'; }

"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --remote-debugging-port=$PORT --user-data-dir="$TMP/chrome" \
  --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling \
  --no-first-run --no-default-browser-check about:blank >/dev/null 2>&1 &
CHROME_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s "http://127.0.0.1:$PORT/json/version" >/dev/null && break; sleep 1; done
sleep 1
"$BIN" park --port $PORT

"$BIN" proxy --port $PORT >/dev/null &
PROXY_PID=$!
sleep 1

# This script's own command line contains the debugging flag when it's run through a shell wrapper.
bash -c ": --remote-debugging-port=$PORT; sleep 3" &
check "discovery: ignores a shell with the flag in its arguments" "$("$BIN" status | awk -F'\t' -v p="$PORT" '$2==p' | wc -l | tr -d ' ')" 1
check "http: WebSocket URL points at the proxy" "$(curl -s "http://127.0.0.1:$PROXY/json/version" | grep -c "127.0.0.1:$PROXY/devtools/browser")" 1
check "http: page list points at the proxy" "$(curl -s "http://127.0.0.1:$PROXY/json/list" | grep -c "127.0.0.1:$PORT")" 0
LISTEN="$(lsof -nP -iTCP:$PROXY -sTCP:LISTEN | awk 'NR==2{print $9}')"
check "security: listens on loopback only" "$LISTEN" "127.0.0.1:$PROXY"

# Chrome takes focus when it launches. Unless something else is in front first, it can't "take" focus
# again and no activation event fires, so every focus check below would pass without testing anything.
activate() { osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($1).activateWithOptions(0)" >/dev/null; }
front() { osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier"; }
activate "$(pgrep -x Finder)"
sleep 1
if [ "$(front)" = "$CHROME_PID" ]; then check "setup: Chrome is not in front" yes no; else echo "PASS setup: Chrome is not in front"; fi

"$WATCH" > "$TMP/focus.log" &
WATCH_PID=$!
sleep 0.5

ab connect $PROXY >/dev/null
ab open https://example.com >/dev/null
check "open: works through the proxy" "$(ab get url)" "https://example.com/"
check "open: no focus taken" "$(chrome_activations)" 0

ab tab new https://example.org >/dev/null
sleep 1
check "tab new: lands on the new page" "$(ab get url)" "https://example.org/"
check "tab new: no focus taken" "$(chrome_activations)" 0
check "tab new: Chrome stays parked" "$(state)" parked
check "tab new: page visible" "$(vis)" '"visible"'
check "tab new: page rendering" "$(raf)" '"ran"'
check "tab new: own window" "$(node "$ROOT/tests/windows.mjs" $PORT count)" 2
check "tab new: page keeps the normal width" "$(ab eval 'innerWidth > 800')" true

ab tab new https://example.net >/dev/null
FIRST="$(tabs | head -1)"
ab tab "$FIRST" >/dev/null
sleep 1
check "tab switch: reaches the first tab" "$(ab get url)" "https://example.com/"
check "tab switch: page visible" "$(vis)" '"visible"'
check "tab switch: no focus taken" "$(chrome_activations)" 0
check "tab switch: answered by the proxy" "$(grep -c 'answered without Chrome' "$BROWSERPARK_PROXY_LOG" | awk '{print ($1>0)}')" 1

ab click a >/dev/null
check "click: works" "$(ab get url)" "https://www.iana.org/help/example-domains"
ab screenshot "$TMP/shot.png" >/dev/null
check "screenshot: written" "$([ -s "$TMP/shot.png" ] && echo yes)" yes
check "large reply: 3 MB intact" "$(ab eval '"x".repeat(3000000)' | tr -d '"\n' | wc -c | tr -d ' ')" 3000000
LONG="$(python3 -c 'print("x"*200000)')"
check "large request: 200 KB intact" "$(ab eval "'$LONG'.length")" 200000
check "after all that: no focus taken" "$(chrome_activations)" 0

BEFORE="$(tabs | wc -l | tr -d ' ')"
ab tab close >/dev/null
check "tab close: one fewer tab" "$(tabs | wc -l | tr -d ' ')" "$((BEFORE - 1))"

kill "$PROXY_PID" 2>/dev/null; PROXY_PID=""
sleep 1
check "proxy stopped: Chrome survives" "$(kill -0 "$CHROME_PID" 2>/dev/null && echo alive)" alive

"$BIN" proxy --port $PORT >/dev/null &
PROXY_PID=$!
sleep 1
ab connect $PROXY >/dev/null
check "proxy restarted: client can reconnect" "$(ab eval '1+1')" 2

echo "--- next step takes focus on purpose"
# A hidden tab sharing a window must still become visible when selected, even though that takes focus.
HIDDEN="$(node "$ROOT/tests/windows.mjs" $PORT shared-tab)"
sleep 1
ab connect $PROXY >/dev/null
SHARED="$(ab tab | awk '/example\.edu/{print}' | grep -o '\[t[0-9]*\]' | tr -d '[]')"
ab tab "$SHARED" >/dev/null
sleep 1
check "shared tab: created hidden" "$HIDDEN" hidden
check "shared tab: visible once selected" "$(vis)" '"visible"'
# Control: proves the focus checks above can fail. Selecting a tab doesn't always activate Chrome, so do it directly.
activate "$(pgrep -x Finder)"
sleep 1
BEFORE="$(chrome_activations)"
activate "$CHROME_PID"
sleep 1
check "control: focus watcher saw Chrome activate" "$(($(chrome_activations) - BEFORE))" 1
activate "$(pgrep -x Finder)"

echo
[ "$FAILS" = 0 ] && echo "ALL PASSED" || echo "$FAILS FAILED"
exit "$FAILS"
