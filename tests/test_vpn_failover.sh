#!/bin/bash
# Tests for vpn-failover: feed it Proton log lines (in the app's real log format)
# with a fake vpn-reset, and check when it resets.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${1:-$HERE/../vpn-failover}"
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0

NOTREACH='2026-01-01T00:00:00.000001+00:00 | proton.vpn.backend.networkmanager.core.networkmanager:81 | INFO | VPN server NOT reachable.'
START='2026-01-01T00:00:02.000001+00:00 | proton.vpn.core.vpnconnector:376 | INFO | CONN.CONNECT:START | Server: US-AA#458 / Domain: node-aa-458.example.net / IP: 192.0.2.7 / OpenVPN Ports: ProtocolPorts(udp=[80], tcp=[443, 7770, 8443])'
DISC='2026-01-01T00:00:02.000002+00:00 | proton.vpn.core.vpnconnector:479 | INFO | CONN:STATE_CHANGED | Disconnected'
CONNECTING='2026-01-01T00:00:02.000003+00:00 | proton.vpn.core.vpnconnector:479 | INFO | CONN:STATE_CHANGED | Connecting'
CONNECTED='2026-01-01T00:05:24.000001+00:00 | proton.vpn.core.vpnconnector:479 | INFO | CONN:STATE_CHANGED | Connected'
APPSTART='2026-01-01T00:05:23.000001+00:00 | proton.vpn.app.gtk.app:66 | INFO | APP:PROCESS_START | self=<app.App object>'
# The app has been seen to hang here for hours (stale kill-switch interface), logging nothing more.
START_FF='2026-01-02T00:00:00.000001+00:00 | proton.vpn.core.vpnconnector:376 | INFO | CONN.CONNECT:START | Server: US-FF#54 / Domain: node-ff-54.example.net / IP: 198.51.100.29 / OpenVPN Ports: ProtocolPorts(udp=[80, 51820, 4569, 1194, 5060], tcp=[443, 7770, 8443], tls=[])'
CONNECTING_FF='2026-01-02T00:00:00.000002+00:00 | proton.vpn.core.vpnconnector:479 | INFO | CONN:STATE_CHANGED | Connecting'
ERROR='2026-01-02T00:00:20.000001+00:00 | proton.vpn.core.vpnconnector:479 | INFO | CONN:STATE_CHANGED | Error'
REFRESH='2026-01-02T00:30:00.000001+00:00 | proton.vpn.session.session:259 | INFO | API:REQUEST | '"'"'/vpn/v1/loads'"'"' | x-pm-locale: omitted, x-pm-timezone: UTC'

# A stand-in for the running Proton app, so "is the app still running?" is answerable.
printf '#!/bin/bash\nexec -a "$0" sleep 600\n' > "$T/fake-protonvpn-app"; chmod +x "$T/fake-protonvpn-app"
"$T/fake-protonvpn-app" >/dev/null 2>&1 &   # (exec: killing the job ends it; no pipe held open)

# start <name> [reset-exit-code] [window] [cooldown] [stuck-after] [app running: 1/0]
start() {
  D="$T/$1"; mkdir -p "$D"; : > "$D/vpn-app.log"
  cat > "$D/reset" <<EOF
#!/bin/bash
echo "reset \$*" >> "$D/calls"
exit ${2:-0}
EOF
  chmod +x "$D/reset"
  local app="$T/fake-protonvpn-app"; [ "${6:-1}" = 1 ] || app="no-such-app-$$"
  VPN_FAILOVER_LOG="$D/vpn-app.log" VPN_FAILOVER_RESET="$D/reset" \
  VPN_FAILOVER_WINDOW="${3:-60}" VPN_FAILOVER_COOLDOWN="${4:-60}" \
  VPN_FAILOVER_STUCK="${5:-90}" VPN_FAILOVER_TICK=0.2 VPN_FAILOVER_APP_RE="$app" \
    "$SUT" > "$D/out" 2>&1 &
  PID=$!
  sleep 1.2   # let tail open the file
}
emit()   { printf '%s\n' "$@" >> "$D/vpn-app.log"; sleep 0.4; }
calls()  { [ -f "$D/calls" ] && wc -l < "$D/calls" || echo 0; }
stop()   { pkill -P $PID 2>/dev/null; kill $PID 2>/dev/null; wait $PID 2>/dev/null; }   # children first: once $PID dies they are re-parented
expect() {  # expect <name> <wanted calls>
  sleep 0.6; local got; got=$(calls)
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); echo "PASS $1"
  else FAIL=$((FAIL+1)); echo "FAIL $1: reset called $got times, wanted $2"; sed 's/^/    | /' "$D/out"; fi
  stop
}

# 1. The real-world loop: two failed retries of the same server -> one reset.
start t1; emit "$START" "$DISC" "$CONNECTING" "$NOTREACH" "$START" "$DISC" "$CONNECTING" "$NOTREACH"
expect "two failed retries in a row -> reset" 1

# 2. One failure, then the app connects, then one failure -> not stuck, no reset.
start t2; emit "$NOTREACH" "$CONNECTED" "$NOTREACH"
expect "connected in between -> no reset" 0

# 3. A fresh app start also clears the count.
start t3; emit "$NOTREACH" "$APPSTART" "$NOTREACH"
expect "app restart in between -> no reset" 0

# 4. Two failures further apart than the window -> no reset.
start t4 0 2 60; emit "$NOTREACH"; sleep 2.6; emit "$NOTREACH"
expect "failures outside window -> no reset" 0

# 5. A long failure streak resets once, not once per failure (cooldown).
start t5; emit "$NOTREACH" "$NOTREACH" "$NOTREACH" "$NOTREACH" "$NOTREACH" "$NOTREACH"
expect "streak -> single reset within cooldown" 1

# 6. After the cooldown, a still-stuck app gets reset again.
start t6 0 60 2; emit "$NOTREACH" "$NOTREACH"; sleep 2.5; emit "$NOTREACH" "$NOTREACH"
expect "still stuck after cooldown -> second reset" 2

# 7. A failed reset (network down) doubles the cooldown: 2 s -> 4 s.
start t7 1 60 2; emit "$NOTREACH" "$NOTREACH"; sleep 2.5; emit "$NOTREACH" "$NOTREACH"
expect "failed reset backs off (no 2nd reset at 2.5 s)" 1
start t7b 1 60 2; emit "$NOTREACH" "$NOTREACH"; sleep 4.5; emit "$NOTREACH" "$NOTREACH"
expect "failed reset backs off (2nd reset after 4 s)" 2

# 8. Proton rotates its log at 3 MB (vpn-app.log -> vpn-app.log.1); keep following.
start t8; mv "$D/vpn-app.log" "$D/vpn-app.log.1"; : > "$D/vpn-app.log"; sleep 1.5
emit "$NOTREACH" "$NOTREACH"
expect "follows log rotation" 1

# 9. User disconnects on purpose: no retries are logged -> nothing happens.
start t9; emit "$DISC"
expect "manual disconnect -> no reset" 0

# 10. Log names the stuck server.
start t10; emit "$START" "$NOTREACH" "$START" "$NOTREACH"; sleep 0.5
if grep -q 'US-AA#458' "$D/out"; then PASS=$((PASS+1)); echo "PASS log names the server"
else FAIL=$((FAIL+1)); echo "FAIL log names the server"; sed 's/^/    | /' "$D/out"; fi
stop

# --- Stuck on "Connecting": the app hangs and logs nothing more. ---
# check <name> <condition...>  (for things other than the reset count)
check() {
  local name=$1; shift
  if "$@"; then PASS=$((PASS+1)); echo "PASS $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name"; sed 's/^/    | /' "$D/out"; fi
}

# 11. The hang: Connecting, then silence past the limit -> one reset.
start t11 0 60 60 2; emit "$START_FF" "$CONNECTING_FF"; sleep 2.5
check "stuck: reset without --skip (the server isn't the problem)" eval '[ -f "$D/calls" ] && ! grep -q -- --skip "$D/calls"'
check "stuck: log says why"                                     grep -q "stuck on 'Connecting' to US-FF#54" "$D/out"
expect "stuck on Connecting -> reset" 1

# 12. Unrelated log lines (server-list refreshes) don't count as an outcome.
start t12 0 60 60 2; emit "$START_FF" "$CONNECTING_FF" "$REFRESH"; sleep 2.5
expect "refresh lines while stuck -> still reset" 1

# 13. Normal connect: Connected arrives in time -> nothing.
start t13 0 60 60 2; emit "$START_FF" "$CONNECTING_FF" "$CONNECTED"; sleep 2.5
expect "connected in time -> no reset" 0

# 14. Proton gives up by itself (Error) -> its reconnector / the NOT-reachable rule take it.
start t14 0 60 60 2; emit "$START_FF" "$CONNECTING_FF" "$ERROR"; sleep 2.5
expect "error in time -> no reset" 0

# 15. You cancel the connection (Disconnected) -> nothing.
start t15 0 60 60 2; emit "$START_FF" "$CONNECTING_FF" "$DISC"; sleep 2.5
expect "cancelled -> no reset" 0

# 16. The app is gone (quit/killed mid-connect) -> not restarted behind your back.
start t16 0 60 60 2 0; emit "$START_FF" "$CONNECTING_FF"; sleep 2.5
expect "app not running -> no reset" 0

# 17. Not yet past the limit -> nothing. (It counts whole seconds: allow 1 s of slack.)
start t17 0 60 60 4; emit "$START_FF" "$CONNECTING_FF"; sleep 1.5
expect "before the limit -> no reset" 0

# 18. Still stuck after a reset (new app hangs too) -> waits the cooldown, then again.
start t18 0 60 4 1; emit "$CONNECTING_FF"; sleep 1.2       # reset 1 at ~1 s
emit "$APPSTART" "$START_FF" "$CONNECTING_FF"; sleep 0.4      # new app hangs too
check "still stuck: no 2nd reset inside cooldown" eval '[ "$(calls)" = 1 ]'
sleep 3.5
expect "still stuck after cooldown -> second reset" 2

# 19. The NOT-reachable rule still names and skips the dead server.
start t19; emit "$START" "$NOTREACH" "$START" "$NOTREACH"; sleep 0.6
check "not-reachable reset still skips the dead server" grep -q -- '--skip=US-AA#458' "$D/calls"
stop

echo "---"; echo "$PASS passed, $FAIL failed"
[ $FAIL = 0 ]
