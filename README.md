# net-hardening

Bash and Python tools for a Linux desktop that uses **NetworkManager** and the
**Proton VPN** app. They do two jobs:

1. **Untrusted Wi-Fi lock.** A NetworkManager dispatcher script puts an nftables
   egress filter on the Wi-Fi interface on every network that isn't on a trusted list.
   Only DHCP, IPv6 neighbor discovery and Proton VPN entry servers are reachable
   directly. Everything else has to go through the VPN tunnel.
2. **VPN self-healing.** Watchdogs notice the ways the Proton app gets stuck and run a
   clean reset, so you don't have to reboot.

> **Warning: these scripts change firewall and network state.**
> `install.sh` must run as root. It installs a dispatcher that loads nftables rules
> and can add a ufw rule and modify NetworkManager connections. The user-level tools
> kill and relaunch the Proton VPN app, delete NetworkManager connections and
> interfaces, turn the Wi-Fi radio on, reconnect Wi-Fi, and edit Proton's
> `app-config.json`. Read the scripts before you run them. If the trusted list is
> wrong or the server list is missing, you can end up offline or less protected than
> you expect.

## Tools

| File | Runs as | What it does |
|---|---|---|
| `untrusted-wifi` | root (NetworkManager dispatcher) | Loads or removes the `inet untrusted_wifi` nftables table depending on whether the Wi-Fi connection is trusted |
| `install.sh` | root | Installs the dispatcher (plus `pre-up.d` symlink), applies the optional ufw/DHCP settings, runs the dispatcher once for the current Wi-Fi |
| `vpn-reset` | user | Stops Proton for real, removes leftover connections and interfaces, makes sure Wi-Fi is up, checks the startup server answers, relaunches Proton and reports the result |
| `vpn-pick-server` | user (Python) | Replays the Proton app's server choice and TCP-checks it. Names the fastest server that answers, honouring avoid/prefer lists and an optional pinned mode |
| `vpn-failover` | user service | Watches Proton's log and runs `vpn-reset` when the app is stuck retrying a dead server or hangs on "Connecting" |
| `vpn-tunnel-watchdog` | user service | Runs `vpn-reset` when the WireGuard tunnel goes silent while the internet outside it still works |
| `wifi-link-watchdog` | user service | Reconnects the Wi-Fi when a gateway that was answering goes silent |

## Threat model

### Untrusted Wi-Fi

On networks you don't control, anything that leaves outside the VPN can be seen by
the network, and local discovery traffic announces the machine. On every Wi-Fi network
whose NetworkManager connection name isn't in `TRUSTED_IDS`, `untrusted-wifi` loads
these rules, applied to the Wi-Fi interface only:

- **Outbound:** allows the DHCP client (UDP 68→67), ICMPv6 router and neighbor
  solicitation and neighbor advertisement, and any traffic to a Proton VPN entry IP
  taken from the app's cached server list. Everything else is counted and dropped.
  So DNS can't go to the local resolver, mDNS/KDE Connect announcements are blocked,
  and traffic not addressed to a Proton server can't leave the Wi-Fi interface outside
  the tunnel, including while the VPN is down.
- **Inbound:** allows established/related traffic, DHCP replies and ICMPv6 router
  advertisements and neighbor messages. Everything else is counted and dropped.

The rules are applied at `pre-up`, so before the connection is usable. They are also
applied on `down`/`pre-down`, and removed only when a trusted connection comes up.
Traffic through the tunnel interface and other interfaces is not filtered.

### VPN failure modes handled

| Failure | Detected by | Action |
|---|---|---|
| **Dead server.** The app retries an unreachable server forever with growing gaps while the kill switch keeps you offline | `vpn-failover`: two `VPN server NOT reachable` log lines within 120 s | `vpn-reset --skip=<server>` |
| **Server answers ping but refuses connections**, yet the app's "fastest" ranking keeps choosing it | `vpn-pick-server`: TCP connect to the server's entry IPs on 443/7770/8443 | Proton starts once on the fastest server that answers. The setting is restored afterwards |
| **Stuck "Connecting".** The app logs `Connecting`, then nothing | `vpn-failover`: no outcome after 90 s while the app process is running | `vpn-reset` (no skip, since the server isn't at fault) |
| **Stale kill-switch interface.** A `pvpnksintrf0` dummy is left behind (for example after "Disconnect" on `pvpn-killswitch` in the desktop network menu) and Proton never connects | `vpn-reset` cleanup | Deletes `ProtonVPN *` / `pvpn-*` connections and leftover `pvpnksintrf0/1`, `ipv6leakintrf0/1`, `proton0` interfaces |
| **Silently dead tunnel.** The tunnel stops passing traffic before the app notices | `vpn-tunnel-watchdog`: no received bytes and no ping reply from the tunnel's DNS server for 4 checks, 5 s apart | If Proton servers still answer over the Wi-Fi outside the tunnel: `vpn-reset --skip=<server>`. Otherwise it waits |
| **Wi-Fi link wedge.** NetworkManager still says "connected" but even the gateway is unreachable | `wifi-link-watchdog`: a gateway that answered before misses 4 pings, 5 s apart | Reconnects the same connection |

Every automatic action has a cooldown. If an action doesn't fix the problem, the
cooldown doubles each time, up to 30 minutes. None of the tools change Proton's
kill-switch setting or the untrusted-wifi lock.

### Limitations

- Trust is decided by the NetworkManager connection name alone. The access point's
  BSSID and the gateway's MAC are not checked.
- The allow-list comes from the Proton app's server cache in the desktop user's home,
  so anything that can write that file can add addresses to it. If the file can't be
  read, the lock falls back to allowing Proton's VPN ports (UDP 80, 88, 443, 500, 1194,
  1224, 4500, 4569, 5060, 51820) to any address, and UDP 443 also carries QUIC.
- `vpn-reset` deletes Proton's `pvpn-*` kill-switch connections as part of its cleanup.
  Until the relaunched app reconnects, non-VPN traffic is held back only by the
  untrusted-wifi lock. That covers untrusted Wi-Fi, but not trusted networks.
- The tools depend on the Proton app's file locations, log line format, and the names
  it gives NetworkManager connections and interfaces. A change in the app can break
  them.

## Requirements

- Linux with **NetworkManager**, including `NetworkManager-dispatcher.service`, and `nmcli`
- **nftables** (`nft`)
- bash, python3, iputils `ping`, util-linux (`flock`, `logger`), procps (`pgrep`, `pkill`), awk
- A systemd user session (`systemd-run --user`, user services)
- **Proton VPN**: the official Proton VPN GTK app for Linux, installed as
  `/usr/bin/protonvpn-app`, using the **WireGuard** protocol (the tools look for an
  active NetworkManager connection of type `wireguard`). `vpn-pick-server` imports the
  app's own Python libraries (`proton.vpn.session`) to rank servers. It reads
  `~/.config/Proton/VPN/app-config.json` and `~/.cache/Proton/VPN/serverlist.json`, and
  `vpn-failover` tails `~/.cache/Proton/VPN/logs/vpn-app.log`. `vpn-reset` needs
  "Connect at app startup" turned on in the app, because the relaunched app connects
  by itself.
  Developed against `proton-vpn-gtk-app` 4.18 and `python-proton-vpn-api-core` 5.8 on
  an Arch-based (Manjaro) KDE Plasma desktop.
- Optional: `notify-send` (desktop notifications from `vpn-reset`), `ufw` (only for the
  optional KDE Connect rule)

## Install

### 1. Untrusted Wi-Fi lock (root)

```sh
sudo bash ./install.sh
```

The first run creates `/etc/net-hardening/untrusted-wifi.conf` from
`examples/untrusted-wifi.conf.example` and stops. Edit that file to set your Wi-Fi
interface, trusted connection names and the path to Proton's server list, then run the
installer again:

```sh
sudoedit /etc/net-hardening/untrusted-wifi.conf
sudo bash ./install.sh
```

The installer checks that `WIFI_IFACE` exists. It then installs the dispatcher as
`/etc/NetworkManager/dispatcher.d/10-untrusted-wifi` with a `pre-up.d` symlink,
enables `NetworkManager-dispatcher.service`, and runs the dispatcher once for the
current Wi-Fi so you can see whether the strict table is active. The dispatcher only
reads the config if root owns it and nobody else can write to it. Otherwise it trusts
no network.

To remove the dispatcher and its nft table (ufw/NetworkManager changes and the config
file are left in place):

```sh
sudo bash ./install.sh --uninstall
```

### 2. VPN tools (user)

Link the scripts into `~/.local/bin`. The watchdogs find `vpn-reset` and
`vpn-pick-server` next to their own resolved path, so keep all five together.

```sh
mkdir -p ~/.local/bin
for t in vpn-reset vpn-pick-server vpn-failover vpn-tunnel-watchdog wifi-link-watchdog; do ln -sf "$PWD/$t" ~/.local/bin/$t; done
```

Start the three watchdogs as user services:

```sh
mkdir -p ~/.config/systemd/user
cp systemd/*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now vpn-failover vpn-tunnel-watchdog wifi-link-watchdog
```

You can also add a "VPN Reset" entry to the application menu:

```sh
sed "s|@HOME@|$HOME|" desktop/vpn-reset.desktop > ~/.local/share/applications/vpn-reset.desktop
```

## Configure

| Where | What |
|---|---|
| `/etc/net-hardening/untrusted-wifi.conf` | `WIFI_IFACE`, `TRUSTED_IDS`, `PROTON_SERVERLIST`. For `install.sh` only: `KDECONNECT_LAN`, `KDECONNECT_REVOKE`, `NO_DHCP_HOSTNAME_IDS`. See `examples/untrusted-wifi.conf.example` |
| `~/.config/net-hardening/vpn-avoid` | Cities never to start Proton on, one per line. See `examples/vpn-avoid.example` |
| `~/.config/net-hardening/vpn-prefer` | Exit-IP CIDR ranges to try first, one per line. See `examples/vpn-prefer.example` |
| `NET_HARDENING_WIFI_DEV`, `NET_HARDENING_WIRED_DEV` | Wi-Fi / Ethernet device for the user tools. When unset, the first device of that type in `nmcli device` is used, so you only need these with more than one |
| `VPN_FAILOVER_WINDOW`, `_COOLDOWN`, `_STUCK`, `_TICK`, `_LOG`, `_RESET`, `_APP_RE` | `vpn-failover` tuning (defaults 120 s, 180 s, 90 s, 5 s, Proton's log, `./vpn-reset`, the app's process pattern) |
| `VPN_TUNNEL_WIFI_DEV`, `_INTERVAL`, `_FAILS`, `_COOLDOWN` | `vpn-tunnel-watchdog` tuning (defaults: auto-detected, 5 s, 4, 120 s) |
| `WIFI_WATCHDOG_DEV`, `_INTERVAL`, `_FAILS`, `_SETTLE`, `_COOLDOWN` | `wifi-link-watchdog` tuning (defaults: auto-detected, 5 s, 4, 20 s, 60 s) |
| `VPN_RESET_WAIT` | How long `vpn-reset` waits for the VPN to connect (default 60 s) |

To set environment variables for a service, run `systemctl --user edit <service>` and
add `Environment=NAME=value` under `[Service]`.

### Using vpn-reset and vpn-pick-server

```sh
vpn-reset
vpn-reset "CafeWiFi"
vpn-reset --skip=US-BB#16
vpn-reset --dry-run
```

These, in order: reset and stay on the current Wi-Fi; switch to the named connection
first; leave out a server whose tunnel just died (plus every server on the same
machine); print what would happen and change nothing.

Pinned mode works around the app's startup setting, which accepts only a country,
`FASTEST`, or a single server. `vpn-pick-server manage US` makes `vpn-reset` keep that
setting on one working US server outside the avoided cities, and move it when that
server stops answering. `vpn-pick-server unpin` turns pinned mode off. Run
`vpn-pick-server` with no arguments for all subcommands.

Logs: `journalctl -t vpn-reset`, `journalctl -t untrusted-wifi`,
`journalctl --user -u vpn-failover` (and likewise for the other two services).

## Tests

```sh
python3 -m pytest -q -p no:cacheprovider tests/test_pick_server.py
bash tests/test_vpn_failover.sh
bash tests/test_vpn_reset.sh
bash tests/test_tunnel_watchdog.sh
bash tests/test_wifi_watchdog.sh
```

The tests don't touch the real network:

- `nmcli`, `ip`, `pgrep`, `pkill`, `systemd-run`, `logger`, `notify-send` and
  `vpn-pick-server` are replaced by PATH stubs (`vpn-reset`).
- The watchdogs source a stub file through `*_STUBS` variables in place of their
  `nmcli`, `ping` and `vpn-reset` calls.
- `vpn-failover` reads a temporary log file and calls a fake `vpn-reset`.
- `vpn-pick-server` gets fake servers and a fake TCP check.

`RealServerListTest` is the exception. It ranks servers from the locally cached Proton
server list (read-only, no connections) and is skipped if the Proton app isn't
installed. The shell tests use short real-time sleeps. `untrusted-wifi` and
`install.sh` have no automated tests, because they need root and change firewall
state.

## Layout

```
untrusted-wifi, install.sh            root: Wi-Fi egress lock
vpn-reset, vpn-pick-server            user: reset + server choice
vpn-failover, vpn-tunnel-watchdog,
wifi-link-watchdog                    user services
examples/                             config file templates
systemd/                              user service units
desktop/vpn-reset.desktop             menu entry template
tests/                                stubbed tests
```

## License

MIT. See [LICENSE](LICENSE).
