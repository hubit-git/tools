# Backhaul Tunnel Manager

**English** | [فارسی](README.fa.md)

An interactive Bash menu for installing, creating and maintaining multiple [Backhaul](https://github.com/Musixal/Backhaul) reverse tunnels on one server — with IPv6 support, a built-in watchdog that restarts hung tunnels, and stability tuning.

Built for the common Iran ⇄ foreign server setup, but works anywhere Backhaul does.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   🚀  Backhaul Tunnel Manager
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 🖥️  Host      : ir-1
 🐧 OS        : Ubuntu 22.04.4 LTS  (x86_64, kernel 5.15.0)
 🌐 Public v4 : 185.x.x.x  [IR]
 🌍 Public v6 : 2a01:xxxx::1
 📦 Backhaul  : installed
 🔗 Tunnels   : 2 active / 2
──────────────────────────────────────────────────────
```

## Features

- **Multiple tunnels per server.** Each tunnel has its own name, config and systemd service, so you can run as many as you need side by side.
- **2-layer and 3-layer setups.** `Iran ← Foreign` or `Iran ← Relay → Destination`.
- **IPv4 and IPv6.** Listen on `0.0.0.0` or `[::]`, and connect to IPv6 servers or destinations. Brackets are added automatically. Useful when a server's IPv4 is blocked but IPv6 still works.
- **Transports:** `tcpmux`, `tcp`, `wsmux`, `wssmux` (a self-signed certificate is generated automatically for `wssmux`).
- **Watchdog.** Checks each tunnel every minute and restarts it if it hangs (the process is alive but traffic no longer passes).
- **Stability tuning.** Heartbeat/keepalive settings in tunnel configs, plus TCP keepalive, conntrack and file-limit sysctl tuning.
- **Offline install.** If the server can't reach GitHub, you can point the script at a release archive you uploaded yourself.
- **Built-in tools:** status, logs, IPv6 connectivity test, config editing, and clean uninstall.

## Requirements

- Linux with systemd (Ubuntu / Debian recommended)
- Root access
- `curl`, `openssl`, `ss` (iproute2). `nc` is optional and used for the IPv6 test.
- `x86_64` or `arm64`

## Installation

Run as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hubit-git/tools/main/backhaul/install.sh)
```

Then pick option **1** to install the Backhaul binary.

To keep a local copy and run it later:

```bash
curl -fsSL -o /usr/local/bin/backhaul-manager https://raw.githubusercontent.com/hubit-git/tools/main/backhaul/install.sh
chmod +x /usr/local/bin/backhaul-manager
backhaul-manager
```

> Use `bash <(curl ...)`, not `curl ... | bash`. The menu is interactive, and piping into bash breaks keyboard input.

> **Server can't reach GitHub?** Download `backhaul_linux_amd64.tar.gz` (or `arm64`) from the [Backhaul releases](https://github.com/Musixal/Backhaul/releases) on another machine, copy it over with `scp`, and enter its path when the installer asks.

## Menu

| # | Option | What it does |
|---|--------|--------------|
| 1 | Install Backhaul | Downloads the latest release into `/usr/local/bin/backhaul` |
| 2 | Create a new tunnel | Guided setup for the server or client side, over IPv4 or IPv6 |
| 3 | List tunnels | Shows name, role, IP version, address, state, watchdog and ports |
| 4 | Tunnel status | `systemctl status` plus the config (token hidden) |
| 5 | Show logs | Last 50 log lines of a tunnel |
| 6 | Test IPv6 connectivity | Lists local IPv6 addresses, then pings and tests a TCP port on a remote IPv6 |
| 7 | Restart a tunnel | Restarts one tunnel's service |
| 8 | Edit config | Opens the config in your editor, with an optional restart afterwards |
| 9 | Delete a tunnel | Removes the service, config, certificates and watchdog |
| 10 | Uninstall everything | Removes all tunnels, the watchdog, sysctl tuning and the binary |
| 11 | Watchdog | Enable, disable, view the log of or test the watchdog for a tunnel |
| 12 | Stability tuning | Applies keepalive, heartbeat and sysctl settings |

## How it works

### Roles

Backhaul is a reverse tunnel, so the connection is opened from the **client** to the **server**:

```
 Users ──► [ SERVER: Iran ]  ◄────tunnel────  [ CLIENT: Foreign ] ──► xray / panel
           user ports open here                connects out to the server
```

- **SERVER.** Listens on the tunnel port (default `3080`) and on the user ports (e.g. `443`). This is usually the Iran server.
- **CLIENT.** Connects to the server and forwards traffic to the destination. This is usually the foreign server.

Both sides must use the same **token** and **transport**. When you create the server side, the script prints both, along with the exact address the client should use.

### 2-layer vs 3-layer

| Type | Path | Destination in config |
|------|------|-----------------------|
| 2-layer | `Iran ← Foreign` (xray runs on the client) | `127.0.0.1` |
| 3-layer | `Iran ← Relay → Destination` (client runs on the relay) | Destination IP (IPv4 or IPv6) |

### Port mapping

When asked for user ports, enter a comma-separated list:

- `443` maps port 443 on the server to port 443 on the destination.
- `8443:443` maps port 8443 on the server to port 443 on the destination.
- Example: `443,2053,8443:443`

### IPv6

When creating a server, choose **IPv6** to listen on `[::]`. When creating a client, simply enter the server's IPv6 address. The script detects IPv6 and wraps it in brackets (`[2a01:...]:3080`), which Backhaul requires.

To test the link before creating a tunnel, run option **6** from the client side against the server's IPv6 address and tunnel port.

> Both servers need working, routable IPv6. Remember to open the tunnel port in the IPv6 firewall too (`ip6tables`, or `ufw` with `IPV6=yes`).

### Files

| Path | Purpose |
|------|---------|
| `/usr/local/bin/backhaul` | Backhaul binary |
| `/etc/backhaul/<name>.toml` | Tunnel config |
| `/etc/backhaul/<name>.watchdog` | Watchdog settings for that tunnel |
| `/etc/systemd/system/backhaul-<name>.service` | Tunnel service |
| `/usr/local/bin/backhaul-watchdog` | Watchdog checker |
| `/etc/systemd/system/backhaul-watchdog@.{service,timer}` | Watchdog timer template |
| `/etc/sysctl.d/99-backhaul.conf` | Stability sysctl settings |

Services are standard systemd units, so you can also manage them directly:

```bash
systemctl status backhaul-<name>
journalctl -u backhaul-<name> -f
```

## Watchdog

Backhaul tunnels can sometimes hang: the process keeps running, but traffic stops passing until it is restarted. `Restart=always` doesn't help here, because the process never exits.

The watchdog runs every minute through a systemd timer (`backhaul-watchdog@<name>.timer`). On each run it:

1. Restarts the service if it isn't running.
2. Waits 90 seconds after any (re)start so the tunnel can reconnect.
3. Optionally restarts on a fixed schedule (every N hours).
4. Runs the configured check. After **N failures in a row** (default 2), it restarts the tunnel.

### Check types

| Check | What it tests | Best for |
|-------|---------------|----------|
| `tls` | A full TLS handshake to `127.0.0.1:<user port>`, which passes **through the tunnel** to the destination | VLESS/Trojan + TLS, Reality |
| `http` | An HTTP request through the tunnel | WS / HTTP inbounds without TLS |
| `tcp` | Only checks that the user port accepts connections | Fallback (weak) |
| `conn` | Checks that an established tunnel connection exists | Client side, or anything else (weak) |

For `tls`, enter the inbound's **SNI**: the certificate domain for TLS, or the `serverName` for Reality. If the inbound rejects unknown SNI, a wrong value will make every check fail.

### Safety measures

- When you enable it, the check runs once immediately. If it fails, you are warned before enabling, so an unsuitable check can't put a healthy tunnel into a restart loop.
- The watchdog restarts at most **6 times per hour**. If the destination itself is down, it logs the problem instead of restarting endlessly.
- Every failure and restart is logged. View them with option **11 → 3**, or with `journalctl -t backhaul-watchdog`.

### Where to enable it

Enable the watchdog **only on the SERVER side** (where user ports are open). Only that side can run a real end-to-end check, and when the server restarts, the client reconnects on its own. Running watchdogs on both sides can trigger back-to-back restarts.

## Stability tuning

Option **12** does two things:

**1. Adds settings to every tunnel config:**

| Side | Settings |
|------|----------|
| Server | `heartbeat = 20`, `keepalive_period = 20`, `channel_size = 2048`, `mux_con = 8` (mux transports only) |
| Client | `keepalive_period = 20`, `dial_timeout = 10`, `retry_interval = 3` |

Lower heartbeat and keepalive values make dead connections get noticed and rebuilt faster. New tunnels get these settings automatically.

**2. Writes `/etc/sysctl.d/99-backhaul.conf`:**

```
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.netfilter.nf_conntrack_max = 262144
net.core.somaxconn = 4096
fs.file-max = 1048576
```

Run this on **both** servers.

## Quick start: Iran ← Foreign over IPv6

**On the Iran server:**

1. Option `12` (stability tuning).
2. Option `2` → **SERVER** → **2-layer** → **IPv6** → `tcpmux` → port `3080` → empty token (a random one is generated) → ports `443`.
3. Note the printed **token**, **transport** and **IPv6 address**.

**On the foreign server:**

1. Option `12` (stability tuning).
2. Option `6` to test the Iran server's IPv6 address on port `3080`.
3. Option `2` → **CLIENT** → enter the Iran server's IPv6 → port `3080` → `tcpmux` → paste the token.

**Back on the Iran server:**

4. Option `11` → select the tunnel → **Enable** → `tls` → port `443` → your inbound's SNI.

## Troubleshooting

- **The client can't connect.** Check that the tunnel port is open on the server (both IPv4 and IPv6 firewalls), and that the token and transport are the same on both sides.
- **The tunnel is up but users can't connect.** Check that the user ports are open on the server, and from the client that the destination is reachable (`nc -zv DEST_IP 443`).
- **Frequent watchdog restarts.** Check the watchdog log (option 11 → 3). If restarts are common, try switching the transport from `tcpmux` to `tcp` or `wsmux`.
- **A config change has no effect.** Restart the tunnel (option 7). Configs are only read when the service starts.

## Credits

This project is a management wrapper around [Backhaul](https://github.com/Musixal/Backhaul) by Musixal. All tunneling is done by Backhaul itself.

## License

MIT
