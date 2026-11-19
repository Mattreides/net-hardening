#!/bin/bash
# Installs the untrusted-wifi NetworkManager dispatcher. Needs root.
#   sudo bash ./install.sh               install / update
#   sudo bash ./install.sh --uninstall   remove the dispatcher and its nft table
# Settings: /etc/net-hardening/untrusted-wifi.conf. On the first run it is created from
# examples/untrusted-wifi.conf.example and the install stops -- edit it, then run again.
set -euo pipefail
D=/etc/NetworkManager/dispatcher.d
CONF_DIR=/etc/net-hardening
CONF=$CONF_DIR/untrusted-wifi.conf
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "--uninstall" ]; then
  rm -f $D/10-untrusted-wifi $D/pre-up.d/10-untrusted-wifi
  nft delete table inet untrusted_wifi 2>/dev/null || true
  echo "untrusted-wifi removed (ufw/NM changes and $CONF left in place)"; exit 0
fi
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0"; exit 1; }
command -v nft >/dev/null || { echo "nft missing: install the nftables package"; exit 1; }

if [ ! -f "$CONF" ]; then
  install -d -m 755 -o root -g root $CONF_DIR
  install -m 644 -o root -g root "$HERE/examples/untrusted-wifi.conf.example" "$CONF"
  echo "created $CONF from the example -- edit it (Wi-Fi interface, trusted networks,"
  echo "Proton server list), then run this again"
  exit 1
fi
# The dispatcher only reads the file if root owns it and nobody else can write to it.
chown root:root "$CONF"; chmod go-w "$CONF"
WIFI_IFACE=""; TRUSTED_IDS=(); PROTON_SERVERLIST=""
KDECONNECT_LAN=""; KDECONNECT_REVOKE=(); NO_DHCP_HOSTNAME_IDS=()
. "$CONF"
[ -n "$WIFI_IFACE" ] && [ -e "/sys/class/net/$WIFI_IFACE" ] \
  || { echo "$CONF: WIFI_IFACE='$WIFI_IFACE' is not a network interface on this machine"; exit 1; }
[ -r "$PROTON_SERVERLIST" ] \
  || echo "WARNING: $CONF: PROTON_SERVERLIST '$PROTON_SERVERLIST' is not readable -- the lock will allow Proton's VPN ports instead of only its server IPs"
[ ${#TRUSTED_IDS[@]} -gt 0 ] || echo "NOTE: $CONF: no TRUSTED_IDS -- every Wi-Fi network gets the lock"

# Optional: KDE Connect (port 1716) only from the home LAN, not from any network you join.
if [ -n "$KDECONNECT_LAN" ]; then
  command -v ufw >/dev/null || { echo "KDECONNECT_LAN is set but ufw is missing"; exit 1; }
  for net in "${KDECONNECT_REVOKE[@]}"; do
    ufw delete allow from "$net" to any port 1716 >/dev/null 2>&1 || true
  done
  ufw allow from "$KDECONNECT_LAN" to any port 1716 comment 'KDE Connect: home LAN only'
fi
# Optional: don't announce this machine's hostname to these networks' DHCP servers.
for id in "${NO_DHCP_HOSTNAME_IDS[@]}"; do
  nmcli connection modify "$id" ipv4.dhcp-send-hostname no ipv6.dhcp-send-hostname no
done

# Strict egress on any untrusted Wi-Fi (blocks mDNS/KDE Connect broadcasts, DNS + VPN-down leaks)
install -m 755 -o root -g root "$HERE/untrusted-wifi" $D/10-untrusted-wifi
mkdir -p $D/pre-up.d && ln -sf $D/10-untrusted-wifi $D/pre-up.d/10-untrusted-wifi
systemctl enable --now NetworkManager-dispatcher.service >/dev/null 2>&1 || true

echo "--- verify"
if [ -n "$KDECONNECT_LAN" ]; then ufw status | grep 1716 || true; fi
for id in "${NO_DHCP_HOSTNAME_IDS[@]}"; do
  printf '%s dhcp-send-hostname: %s\n' "$id" "$(nmcli -g ipv4.dhcp-send-hostname connection show "$id")"
done
ls -l $D/10-untrusted-wifi $D/pre-up.d/10-untrusted-wifi
C=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev="$WIFI_IFACE" '$2==dev{print $1}')
echo "current Wi-Fi: $C"
CONNECTION_ID="$C" $D/10-untrusted-wifi "$WIFI_IFACE" up
nft list tables | grep -q untrusted_wifi && echo "strict table: ACTIVE" || echo "strict table: not active (trusted network)"
echo "done."
