#!/bin/bash
# Tests for vpn-reset's cleanup of interfaces Proton leaves behind. nmcli, ip, pgrep,
# pkill, systemd-run, logger, notify-send and vpn-pick-server are stubs that read and
# write little state files -- nothing touches the real network.
#
# The bug: "Disconnect" on pvpn-killswitch in the Plasma network menu
# left the pvpnksintrf0 dummy behind as an external device with autoconnect blocked.
# Deleting the pvpn-killswitch connection no longer removed it, and every kill switch
# Proton added afterwards never activated -- Proton sat in "Connecting" for hours.
# The stub app below behaves the same: it only connects if pvpnksintrf0 is gone.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${1:-$HERE/../vpn-reset}"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

mkdir -p "$T/bin"
cp "$SUT" "$T/bin/vpn-reset"
cat > "$T/bin/vpn-pick-server" <<'EOF'
#!/bin/bash
case "$1" in pick) echo keep ;; get-startup) echo US ;; esac
EOF
cat > "$T/bin/nmcli" <<'EOF'
#!/bin/bash
D="$STUB_DIR"; echo "nmcli $*" >> "$D/log"
case "$*" in
  "-t -f UUID,NAME connection show") cat "$D/conns" ;;
  "connection delete uuid "*)
    u=${@: -1}; name=$(grep "^$u:" "$D/conns" | cut -d: -f2-)
    grep -v "^$u:" "$D/conns" > "$D/conns.new"; mv "$D/conns.new" "$D/conns"
    # NM removes the device it created for a connection -- unless it went external.
    while IFS=$'\t' read -r c dev; do [ "$c" = "$name" ] && sed -i "/^$dev\$/d" "$D/ifaces"; done < "$D/owned" ;;
  "-t -f DEVICE,TYPE device")
    if [ -f "$D/no_wifi" ]; then printf '%s\n' eth0:ethernet lo:loopback
    else printf '%s\n' eth0:ethernet wlan0:wifi p2p-dev-wlan0:wifi-p2p lo:loopback; fi ;;
  "radio wifi") echo enabled ;;
  "-g GENERAL.STATE device show wlan0") echo "100 (connected)" ;;
  "-g GENERAL.CONNECTION device show wlan0") echo HomeNetwork ;;
  "-g GENERAL.STATE device show eth0") echo "20 (unavailable)" ;;
  "-t -f TYPE,STATE connection show --active")
    [ -f "$D/vpnup" ] && echo "wireguard:activated"; echo "802-11-wireless:activated" ;;
  "-t -f NAME,TYPE connection show --active")
    [ -f "$D/vpnup" ] && echo "ProtonVPN US-FF#54:wireguard"; echo "HomeNetwork:802-11-wireless" ;;
  "device delete "*)
    dev=${@: -1}
    [ -f "$D/delete_fails" ] && { echo "Error: not authorized" >&2; exit 4; }
    grep -qx "$dev" "$D/ifaces" || { echo "Error: Device '$dev' not found." >&2; exit 10; }
    sed -i "/^$dev\$/d" "$D/ifaces"; echo "Device '$dev' successfully removed." ;;
  *) echo "nmcli $*" >> "$D/unexpected" ;;
esac
EOF
cat > "$T/bin/ip" <<'EOF'
#!/bin/bash
D="$STUB_DIR"
[ "$*" = "-o link show" ] || { echo "ip $*" >> "$D/unexpected"; exit 1; }
n=1; while read -r dev; do echo "$n: $dev: <BROADCAST,NOARP,UP,LOWER_UP> mtu 1500 state UNKNOWN"; n=$((n+1)); done < "$D/ifaces"
EOF
cat > "$T/bin/systemd-run" <<'EOF'
#!/bin/bash
# The Proton app: hangs in "Connecting" while a stale pvpnksintrf0 is still there.
grep -qx pvpnksintrf0 "$STUB_DIR/ifaces" || touch "$STUB_DIR/vpnup"
EOF
printf '#!/bin/bash\nexit 1\n' > "$T/bin/pgrep"       # app not running
printf '#!/bin/bash\nexit 0\n' > "$T/bin/pkill"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/logger"
printf '#!/bin/bash\necho "$*" >> "$STUB_DIR/notes"\n' > "$T/bin/notify-send"
chmod +x "$T/bin/"*

# setup <name> <ifaces...>   (conns/owned/flags are written by the test afterwards)
setup() {
  D="$T/$1"; mkdir -p "$D"; shift
  : > "$D/conns"; : > "$D/owned"; : > "$D/log"
  printf '%s\n' lo wlan0 eth0 "$@" > "$D/ifaces"
}
run_reset() {
  STUB_DIR="$D" PATH="$T/bin:$PATH" XDG_RUNTIME_DIR="$D" XDG_STATE_HOME="$D/state" \
  VPN_RESET_WAIT=2 JOURNAL_STREAM= NET_HARDENING_WIFI_DEV= NET_HARDENING_WIRED_DEV= "$T/bin/vpn-reset" "$@" > "$D/out" 2>&1
  RC=$?
}
check() {  # check <name> <condition...>
  local name=$1; shift
  if "$@"; then PASS=$((PASS+1)); echo "PASS $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name"; sed 's/^/    | /' "$D/out"; fi
}
has_iface()  { grep -qx "$1" "$D/ifaces"; }
deleted()    { grep -qx "nmcli device delete $1" "$D/log"; }
said()       { grep -qF -- "$1" "$D/out"; }
no_unexpected() { [ ! -s "$D/unexpected" ]; }

# 1. The stale case: kill-switch dummy left behind, no connection owns it.
setup stale pvpnksintrf0
run_reset
check "stale pvpnksintrf0 is removed"            deleted pvpnksintrf0
check "stale pvpnksintrf0 gone afterwards"       eval '! has_iface pvpnksintrf0'
check "VPN connects once it is gone"             eval '[ $RC = 0 ] && said "OK: VPN connected"'
check "stale case: no unexpected commands"       no_unexpected

# 2. Normal leftovers: NM removes its own devices when the connections are deleted.
setup normal pvpnksintrf0 proton0
printf '%s\n' "u1:pvpn-killswitch" "u2:ProtonVPN US-FF#54" > "$D/conns"
printf '%s\t%s\n' pvpn-killswitch pvpnksintrf0 "ProtonVPN US-FF#54" proton0 > "$D/owned"
run_reset
check "normal: connections deleted"              eval 'grep -q "connection delete uuid u1" "$D/log" && grep -q "connection delete uuid u2" "$D/log"'
check "normal: no device delete needed"          eval '! grep -q "device delete" "$D/log"'
check "normal: no NOTE about leftovers"          eval '! said "could not remove"'
check "normal: VPN connects"                     eval '[ $RC = 0 ]'

# 3. Nothing left over at all.
setup clean
run_reset
check "clean: no device delete"                  eval '! grep -q "device delete" "$D/log"'
check "clean: VPN connects"                      eval '[ $RC = 0 ] && said "OK: VPN connected"'

# 4. Every Proton interface name is cleaned up; look-alikes and real NICs are not.
setup all pvpnksintrf0 pvpnksintrf1 ipv6leakintrf0 ipv6leakintrf1 proton0 proton0x mypvpnksintrf0 wg0
run_reset
check "all: pvpnksintrf1 removed"                deleted pvpnksintrf1
check "all: ipv6leakintrf0 removed"              deleted ipv6leakintrf0
check "all: ipv6leakintrf1 removed"              deleted ipv6leakintrf1
check "all: stale proton0 removed"               deleted proton0
check "all: look-alikes and NICs untouched"      eval 'for d in proton0x mypvpnksintrf0 wg0 wlan0 eth0 lo; do has_iface $d || exit 1; done'

# 5. NM refuses to delete it: say how to do it by hand, still try to connect.
setup refused pvpnksintrf0
touch "$D/delete_fails"
run_reset
check "refused: tells you the manual command"    said "sudo ip link delete pvpnksintrf0"
check "refused: still starts the app"            said "starting Proton app"
check "refused: reports failure (app hangs)"     eval '[ $RC = 1 ] && said "FAILED: Proton did not connect"'

# 6. Dry run lists the interface but deletes nothing.
setup dry pvpnksintrf0
run_reset --dry-run
check "dry-run: mentions the leftover interface" said "removing leftover interface: pvpnksintrf0"
check "dry-run: nothing deleted"                 eval '! deleted pvpnksintrf0 && has_iface pvpnksintrf0'

# 7. No Wi-Fi device at all: fail with a hint before touching anything.
setup nowifi pvpnksintrf0
touch "$D/no_wifi"
run_reset
check "no wifi: fails and says how to fix it"   eval '[ $RC = 1 ] && said "no Wi-Fi device found"'
check "no wifi: nothing deleted or started"     eval '! grep -q delete "$D/log" && ! said "starting Proton app"'

echo "$PASS passed, $FAIL failed"
[ $FAIL = 0 ]
