#!/bin/bash
# Tests for wifi-link-watchdog, with nmcli/ping/reconnect replaced by stubs that
# read and write little state files.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${1:-$HERE/../wifi-link-watchdog}"
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0

# start <name> <fixes: 1 = reconnect brings the gateway back, 0 = it doesn't> [cooldown]
start() {
  D="$T/$1"; mkdir -p "$D"
  echo "HomeNetwork|192.0.2.1" > "$D/conn"; echo 1 > "$D/alive"
  cat > "$D/stubs" <<EOF
current()   { cat "$D/conn"; }
gw_alive()  { [ "\$(cat "$D/alive")" = 1 ]; }
reconnect() { echo "\$1" >> "$D/calls"; [ "$2" = 1 ] && echo 1 > "$D/alive"; return 0; }
EOF
  WIFI_WATCHDOG_STUBS="$D/stubs" WIFI_WATCHDOG_DEV=wlan0 WIFI_WATCHDOG_INTERVAL=0.2 WIFI_WATCHDOG_FAILS=3 \
  WIFI_WATCHDOG_SETTLE=1 WIFI_WATCHDOG_COOLDOWN="${3:-60}" \
    "$SUT" > "$D/out" 2>&1 &
  PID=$!
  sleep 0.5
}
set_()  { echo "$2" > "$D/$1"; }
calls() { [ -f "$D/calls" ] && wc -l < "$D/calls" || echo 0; }
stop()  { kill $PID 2>/dev/null; wait $PID 2>/dev/null; }
expect() {  # expect <name> <wanted reconnects>
  local got; got=$(calls)
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); echo "PASS $1"
  else FAIL=$((FAIL+1)); echo "FAIL $1: reconnect called $got times, wanted $2"; sed 's/^/    | /' "$D/out"; fi
  stop
}

# 1. Router answered, then the link went silent -> one reconnect, which fixes it.
start t1 1; set_ alive 0; sleep 2
expect "silent gateway -> reconnect" 1
grep -q 'HomeNetwork' "$D/calls" 2>/dev/null && { PASS=$((PASS+1)); echo "PASS reconnects the same network"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL reconnects the same network"; }

# 2. A gateway that never answered on this connection (ping blocked) is never judged.
start t2 1; set_ alive 0; set_ conn "CafeWiFi|198.51.100.1"; sleep 2
expect "never-answering gateway -> no reconnect" 0

# 3. A blip shorter than FAILS checks -> nothing.
start t3 1; set_ alive 0; sleep 0.3; set_ alive 1; sleep 1.5
expect "short blip -> no reconnect" 0

# 4. Wi-Fi not connected (no connection / no gateway) -> nothing.
start t4 1; set_ conn "|"; set_ alive 0; sleep 2
expect "no connection -> no reconnect" 0

# 5. Router really down (reconnect doesn't help): retry no sooner than 2x cooldown.
start t5 0 1; set_ alive 0; sleep 2.2
expect "router down -> backs off (one reconnect in 2.2 s)" 1
start t5b 0 1; set_ alive 0; sleep 5
expect "router down -> retries after backoff" 2

# 6. Back to normal after a fix -> a later failure is handled again.
start t6 1 1; set_ alive 0; sleep 2; set_ alive 0; sleep 2.5
expect "second failure after recovery -> second reconnect" 2

echo "---"; echo "$PASS passed, $FAIL failed"
[ $FAIL = 0 ]
