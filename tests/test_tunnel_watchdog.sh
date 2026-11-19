#!/bin/bash
# Tests for vpn-tunnel-watchdog, with nmcli/ping/vpn-reset replaced by stubs that
# read and write little state files.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${1:-$HERE/../vpn-tunnel-watchdog}"
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0

# start <name> <reset: fix = new working tunnel, same = nothing changes, fail = exit 1> [cooldown]
start() {
  D="$T/$1"; mkdir -p "$D"
  echo "ProtonVPN US-BB#16|proton0" > "$D/tunnel"; echo 1 > "$D/alive"; echo 1 > "$D/outside"
  echo 1000 > "$D/rx"; echo "192.0.2.2 198.51.100.2" > "$D/landmarks"
  cat > "$D/stubs" <<EOF
tunnel()    { cat "$D/tunnel"; }
rx_bytes()  { cat "$D/rx"; }
dns_of()    { echo 10.2.0.1; }
ping_via()  { echo "\$1 \$2" >> "$D/pings"
              if [ "\$1" = proton0 ]; then [ "\$(cat "$D/alive")" = 1 ]; else [ "\$(cat "$D/outside")" = 1 ]; fi; }
landmarks() { cat "$D/landmarks"; }
reset_vpn() { echo "\$1" >> "$D/calls"
              case "$2" in
                fix)  echo "ProtonVPN US-CC#26|proton0" > "$D/tunnel"; echo 1 > "$D/alive" ;;
                fail) return 1 ;;
              esac; return 0; }
EOF
  VPN_TUNNEL_STUBS="$D/stubs" VPN_TUNNEL_WIFI_DEV=wlan0 VPN_TUNNEL_INTERVAL=0.2 VPN_TUNNEL_FAILS=3 \
  VPN_TUNNEL_COOLDOWN="${3:-60}" "$SUT" > "$D/out" 2>&1 &
  PID=$!
  sleep 0.5
}
set_()  { echo "$2" > "$D/$1"; }
calls() { [ -f "$D/calls" ] && wc -l < "$D/calls" || echo 0; }
stop()  { kill $PID 2>/dev/null; wait $PID 2>/dev/null; }
expect() {  # expect <name> <wanted resets>
  local got; got=$(calls)
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); echo "PASS $1"
  else FAIL=$((FAIL+1)); echo "FAIL $1: vpn-reset called $got times, wanted $2"; sed 's/^/    | /' "$D/out"; fi
  stop
}
check() {  # check <name> <command...>
  if "${@:2}"; then PASS=$((PASS+1)); echo "PASS $1"
  else FAIL=$((FAIL+1)); echo "FAIL $1"; sed 's/^/    | /' "$D/out"; fi
}

# 1. Healthy tunnel -> nothing happens.
start t1 fix; sleep 1.5
expect "healthy tunnel -> no reset" 0

# 2. Tunnel stops passing traffic, internet outside it works -> one reset,
#    told to skip the server that died.
start t2 fix; set_ alive 0; sleep 1.5
check "skip names the dead server" grep -qx 'US-BB#16' "$D/calls"
expect "silent tunnel -> reset" 1

# 3. Ping fails but data keeps arriving -> still alive.
start t3 fix; set_ alive 0
for i in 1 2 3 4 5 6 7 8; do set_ rx $((1000 + i * 500)); sleep 0.2; done
expect "data still arriving -> no reset" 0

# 4. Wi-Fi/upstream down (nothing answers outside the tunnel either) -> wait;
#    reset only once the outside comes back while the tunnel stays dead.
start t4 fix; set_ alive 0; set_ outside 0; sleep 1.5
check "outside down -> says so" grep -q 'internet outside' "$D/out"
check "outside down -> no reset yet" [ "$(calls)" = 0 ]
set_ outside 1; sleep 1
expect "outside back, tunnel still dead -> reset" 1

# 5. VPN off (no WireGuard connection) -> nothing to judge.
start t5 fix; set_ tunnel ""; set_ alive 0; sleep 1.5
expect "no tunnel -> no reset" 0

# 6. Proton reconnects by itself (new server) -> count starts over.
start t6 fix; set_ alive 0; sleep 0.25; set_ tunnel "ProtonVPN US-DD#23|proton0"; set_ alive 1; sleep 1.2
expect "Proton reconnected itself -> no reset" 0

# 7. Reset leaves it dead: no second reset within the cooldown...
start t7 same 60; set_ alive 0; sleep 2
expect "still dead within cooldown -> one reset" 1
# ...but another after it (a tunnel that never worked is judged too).
start t7b same 1.5; set_ alive 0; sleep 3
expect "still dead after cooldown -> second reset" 2

# 8. A failed reset doubles the cooldown: 1.5 s -> 3 s.
start t8 fail 1.5; set_ alive 0; sleep 3
expect "failed reset backs off (no 2nd reset at 3 s)" 1

# 9. No server list to test the outside with -> reset anyway (vpn-reset copes).
start t9 fix; set_ landmarks ""; set_ alive 0; sleep 1.5
expect "no landmarks -> reset" 1

# 10. Probes go through the tunnel's own interface, the outside check through Wi-Fi.
start t10 fix; set_ alive 0; sleep 1.5
check "pings DNS through proton0" grep -q '^proton0 10.2.0.1$' "$D/pings"
check "outside check via wlan0" grep -q '^wlan0 192.0.2.2$' "$D/pings"
check "log names the server" grep -q 'US-BB#16' "$D/out"
stop

echo "---"; echo "$PASS passed, $FAIL failed"
[ $FAIL = 0 ]
