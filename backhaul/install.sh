#!/usr/bin/env bash
# Backhaul multi-tunnel manager
# Each tunnel has its own name, config (/etc/backhaul/<name>.toml) and service (backhaul-<name>).
# Supports 2-layer (Iran <- Foreign) and 3-layer (Iran <- Relay -> Destination) setups,
# over IPv4 or IPv6, with an optional per-tunnel watchdog that restarts hung tunnels.

BIN="/usr/local/bin/backhaul"
CONF_DIR="/etc/backhaul"
WD_BIN="/usr/local/bin/backhaul-watchdog"
SYSCTL_FILE="/etc/sysctl.d/99-backhaul.conf"

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo -i)."
  exit 1
fi

pause() { read -rp "Press Enter to return to the menu..." _; }

# ---------- look & feel ----------

C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'

ok()   { echo "${C_GREEN}✅ $*${C_RESET}"; }
err()  { echo "${C_RED}❌ $*${C_RESET}"; }
warn() { echo "${C_YELLOW}⚠️  $*${C_RESET}"; }

# Static server info, collected once at startup
gather_info() {
  OS_NAME=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
  HOST_NAME=$(hostname)
  KERNEL=$(uname -r)
  ARCH_NAME=$(uname -m)
  CPU_CORES=$(nproc)
  LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')

  PUB_IP=$(curl -4 -s -m 3 https://api.ipify.org 2>/dev/null)
  [ -z "$PUB_IP" ] && PUB_IP=$(curl -4 -s -m 3 https://ifconfig.me 2>/dev/null)
  [[ "$PUB_IP" =~ ^[0-9.]+$ ]] || PUB_IP=""

  PUB_IP6=$(curl -6 -s -m 3 https://api6.ipify.org 2>/dev/null)
  [[ "$PUB_IP6" =~ ^[0-9a-fA-F:]+$ ]] || PUB_IP6=""
  # Fallback: first global IPv6 configured on an interface
  [ -z "$PUB_IP6" ] && PUB_IP6=$(ip -6 addr show scope global 2>/dev/null \
    | awk '/inet6/ && !/temporary|deprecated/ {sub(/\/.*/, "", $2); print $2; exit}')

  COUNTRY=""
  [ -n "$PUB_IP" ] && COUNTRY=$(curl -s -m 3 "https://ipinfo.io/$PUB_IP/country" 2>/dev/null)
  [[ "$COUNTRY" =~ ^[A-Z]{2}$ ]] || COUNTRY=""
}

print_header() {
  local ram up names total active n bh_state
  ram=$(free -m | awk '/Mem:/ {printf "%d / %d MB", $3, $2}')
  up=$(uptime -p | sed 's/^up //')

  names=$(list_names)
  total=$(echo "$names" | grep -c .)
  active=0
  for n in $names; do
    [ "$(systemctl is-active "backhaul-$n" 2>/dev/null)" = "active" ] && active=$((active + 1))
  done

  if [ -x "$BIN" ]; then bh_state="${C_GREEN}installed${C_RESET}"; else bh_state="${C_RED}not installed${C_RESET}"; fi

  clear
  echo "${C_CYAN}${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo "${C_CYAN}${C_BOLD}   🚀  Backhaul Tunnel Manager${C_RESET}"
  echo "${C_CYAN}${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo " 🖥️  Host      : $HOST_NAME"
  echo " 🐧 OS        : ${OS_NAME:-?}  (${ARCH_NAME}, kernel $KERNEL)"
  echo " 🌐 Public v4 : ${PUB_IP:-unknown}${COUNTRY:+  [$COUNTRY]}"
  echo " 🌍 Public v6 : ${PUB_IP6:-${C_DIM}none${C_RESET}}"
  echo " 🔌 Local IP  : ${LOCAL_IP:-?}"
  echo " ⚙️  CPU / RAM : ${CPU_CORES} cores  /  $ram"
  echo " ⏱️  Uptime    : $up"
  echo " 📦 Backhaul  : $bh_state"
  echo " 🔗 Tunnels   : ${C_GREEN}$active active${C_RESET} / $total"
  echo "${C_DIM}──────────────────────────────────────────────────────${C_RESET}"
}

# ---------- helpers ----------

list_names() {
  ls "$CONF_DIR"/*.toml 2>/dev/null | xargs -rn1 basename | sed 's/\.toml$//'
}

# Returns the host ready to be used in "host:port".
# IPv6 addresses get wrapped in [brackets]; IPv4 / hostnames are returned as-is.
fmt_host() {
  local h="${1#[}"
  h="${h%]}"
  if [[ "$h" == *:* ]]; then echo "[$h]"; else echo "$h"; fi
}

is_ipv6() { [[ "$1" == *:* ]]; }

# Sets "key = value" in a tunnel config: replaces the line if it exists,
# otherwise inserts it right after the [server]/[client] header.
set_kv() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^$key[[:space:]]*=" "$file"; then
    sed -i -E "s|^$key[[:space:]]*=.*|$key = $value|" "$file"
  else
    sed -i "1a $key = $value" "$file"
  fi
}

# Prints "server" or "client" for a tunnel
tunnel_role() {
  if grep -q '^\[server\]' "$CONF_DIR/$1.toml"; then echo server; else echo client; fi
}

# Prints the first user (listen) port of a server tunnel, e.g. 443
first_user_port() {
  grep -m1 '^ports' "$CONF_DIR/$1.toml" | sed -nE 's/^[^"]*"([0-9]+)=.*/\1/p'
}

# Adds the recommended stability settings to a tunnel config
apply_stability_keys() {
  local file="$CONF_DIR/$1.toml" transport
  transport=$(grep -m1 '^transport' "$file" | cut -d'"' -f2)
  if [ "$transport" = "udp" ]; then
    # TCP keepalive / mux options don't apply to the UDP transport
    if [ "$(tunnel_role "$1")" = "server" ]; then
      set_kv "$file" heartbeat 20
      set_kv "$file" channel_size 2048
    else
      set_kv "$file" retry_interval 3
    fi
  elif [ "$(tunnel_role "$1")" = "server" ]; then
    set_kv "$file" heartbeat 20
    set_kv "$file" keepalive_period 20
    set_kv "$file" channel_size 2048
    [[ "$transport" == *mux ]] && set_kv "$file" mux_con 8
  else
    set_kv "$file" keepalive_period 20
    set_kv "$file" dial_timeout 10
    set_kv "$file" retry_interval 3
  fi
}

# Sets TNAME to an existing tunnel name chosen by the user
select_tunnel() {
  local names
  names=$(list_names)
  if [ -z "$names" ]; then
    warn "No tunnels have been created yet."
    return 1
  fi
  echo "Tunnels:"
  echo "$names" | sed 's/^/  - /'
  read -rp "Tunnel name: " TNAME
  if [ ! -f "$CONF_DIR/$TNAME.toml" ]; then
    err "Tunnel '$TNAME' does not exist."
    return 1
  fi
}

check_installed() {
  if [ ! -x "$BIN" ]; then
    warn "Run option 1 (Install Backhaul) first."
    return 1
  fi
}

choose_transport() {
  echo ""
  echo "Choose a transport (must be the same on both sides of the tunnel):"
  echo "  1) tcpmux   (fast, recommended to start with)"
  echo "  2) tcp      (simple, no multiplexing)"
  echo "  3) wsmux    (use if DPI causes problems)"
  echo "  4) wssmux   (WebSocket + TLS, most resistant to filtering)"
  echo "  --- UDP (e.g. WireGuard, Hysteria, OpenVPN-UDP) ---"
  echo "  5) udp            (native UDP tunnel - user ports are UDP)"
  echo "  6) tcp + UDP      (UDP over TCP - use if UDP between the servers is blocked/throttled)"
  read -rp "Choice [1]: " t
  ACCEPT_UDP=""
  case "${t:-1}" in
    2) TRANSPORT="tcp" ;;
    3) TRANSPORT="wsmux" ;;
    4) TRANSPORT="wssmux" ;;
    5) TRANSPORT="udp" ;;
    6) TRANSPORT="tcp"; ACCEPT_UDP="true" ;;
    *) TRANSPORT="tcpmux" ;;
  esac
}

# True if the tunnel carries UDP user traffic (udp transport or accept_udp)
carries_udp() {
  [ "$TRANSPORT" = "udp" ] || [ "$ACCEPT_UDP" = "true" ]
}

# Sets BIND_HOST based on the IP version the tunnel should listen on
choose_ip_version() {
  echo ""
  echo "Which IP version should the tunnel listen on?"
  echo "  1) IPv4  (0.0.0.0)"
  echo "  2) IPv6  ([::] — on most Linux systems this also accepts IPv4)"
  read -rp "Choice [1]: " v
  if [ "${v:-1}" = "2" ]; then
    if [ -z "$PUB_IP6" ]; then
      warn "No global IPv6 address was detected on this server."
      read -rp "Continue anyway? [y/N]: " r
      [[ ! "$r" =~ ^[yY]$ ]] && return 1
    fi
    BIND_HOST="[::]"
    IP_VER="6"
  else
    BIND_HOST="0.0.0.0"
    IP_VER="4"
  fi
}

# Builds PORT_LIST from input like "443,8443:443" and destination IP
# Format: PORT (same on both sides) or LISTEN_PORT:DEST_PORT
build_ports() {
  local input="${1// /}" dest_host list="" item lp dp
  local arr
  dest_host=$(fmt_host "$2")
  IFS=',' read -ra arr <<< "$input"
  for item in "${arr[@]}"; do
    if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
      lp=${BASH_REMATCH[1]}; dp=${BASH_REMATCH[2]}
    elif [[ "$item" =~ ^[0-9]+$ ]]; then
      lp=$item; dp=$item
    else
      echo "Invalid port: '$item'" >&2
      return 1
    fi
    list+="\"$lp=$dest_host:$dp\", "
  done
  PORT_LIST="[${list%, }]"
}

write_service() {
  local name="$1"
  cat > "/etc/systemd/system/backhaul-$name.service" <<EOF
[Unit]
Description=Backhaul Tunnel ($name)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN -c $CONF_DIR/$name.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "backhaul-$name"
  sleep 1
  systemctl --no-pager --lines=0 status "backhaul-$name" | head -n 5
}

# ---------- actions ----------

install_backhaul() {
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) err "Unsupported architecture: $(uname -m)"; return ;;
  esac

  URL="https://github.com/Musixal/Backhaul/releases/latest/download/backhaul_linux_${ARCH}.tar.gz"
  TMP="/tmp/backhaul.tar.gz"

  echo "Downloading from GitHub..."
  if ! curl -fL --connect-timeout 15 -o "$TMP" "$URL"; then
    echo ""
    warn "Download failed (the server may not be able to reach GitHub, e.g. in Iran)."
    echo "Copy backhaul_linux_${ARCH}.tar.gz to this server manually with scp."
    read -rp "Path to the file (empty = cancel): " LOCAL
    [ -z "$LOCAL" ] && return
    [ ! -f "$LOCAL" ] && { err "File not found."; return; }
    cp "$LOCAL" "$TMP"
  fi

  mkdir -p "$CONF_DIR"
  tar -xzf "$TMP" -C /tmp backhaul 2>/dev/null || tar -xzf "$TMP" -C /tmp
  mv /tmp/backhaul "$BIN" && chmod +x "$BIN"
  rm -f "$TMP"
  ok "Backhaul installed: $BIN"
}

create_tunnel() {
  check_installed || return

  read -rp "Tunnel name (e.g. iran1, tr-de) [lowercase letters/digits/- only]: " TNAME
  if [[ ! "$TNAME" =~ ^[a-z0-9-]+$ ]]; then
    err "Invalid name."
    return
  fi
  if [ -f "$CONF_DIR/$TNAME.toml" ]; then
    err "Tunnel '$TNAME' already exists."
    return
  fi

  echo ""
  echo "What is this server's role in the tunnel?"
  echo "  1) SERVER  (user ports are opened here, e.g. the Iran server)"
  echo "  2) CLIENT  (connects to the server, e.g. the Turkey or Germany server)"
  read -rp "Choice [1]: " ROLE
  mkdir -p "$CONF_DIR"

  if [ "${ROLE:-1}" = "2" ]; then
    create_client "$TNAME"
  else
    create_server "$TNAME"
  fi
}

create_server() {
  local name="$1"

  echo ""
  echo "Tunnel type:"
  echo "  1) 2-LAYER  (Iran <- Foreign; the client is the destination, destination = 127.0.0.1)"
  echo "  2) 3-LAYER  (Iran <- Relay -> Destination; client runs on the relay, destination is another IP)"
  read -rp "Choice [2]: " KIND
  if [ "${KIND:-2}" = "1" ]; then
    DEST_IP="127.0.0.1"
  else
    read -rp "Destination server IP, IPv4 or IPv6 (e.g. the Germany server): " DEST_IP
    [ -z "$DEST_IP" ] && { err "IP cannot be empty."; return; }
  fi

  choose_ip_version || return
  choose_transport

  read -rp "Tunnel port (the client connects to this) [3080]: " TPORT
  TPORT=${TPORT:-3080}
  local ss_flag="-tln"
  [ "$TRANSPORT" = "udp" ] && ss_flag="-uln"
  if ss $ss_flag | grep -q ":$TPORT "; then
    warn "Port $TPORT is already in use on this server!"
    read -rp "Continue? [y/N]: " r
    [[ ! "$r" =~ ^[yY]$ ]] && return
  fi

  read -rp "Token (empty = generate a random one): " TOKEN
  [ -z "$TOKEN" ] && TOKEN=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)

  echo ""
  echo "Enter user ports separated by commas."
  echo "  443        -> port 443 on this server to port 443 on the destination"
  echo "  8443:443   -> port 8443 on this server to port 443 on the destination"
  local def_ports=443
  if carries_udp; then
    def_ports=51820
    echo "  Example (WireGuard): 51820   or   51820,2408:51820"
  else
    echo "  Example: 443,1126,8443:443"
  fi
  read -rp "Ports [$def_ports]: " PORTS
  PORTS=${PORTS:-$def_ports}
  build_ports "$PORTS" "$DEST_IP" || return

  {
    echo "[server]"
    echo "bind_addr = \"$BIND_HOST:$TPORT\""
    echo "transport = \"$TRANSPORT\""
    echo "token = \"$TOKEN\""
    echo "log_level = \"info\""
    [ "$TRANSPORT" != "udp" ] && echo "nodelay = true"
    [ "$ACCEPT_UDP" = "true" ] && echo "accept_udp = true"
    echo "ports = $PORT_LIST"
  } > "$CONF_DIR/$name.toml"

  if [ "$TRANSPORT" = "wssmux" ]; then
    echo "wssmux needs a certificate. Generating a self-signed one..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$CONF_DIR/$name.key" -out "$CONF_DIR/$name.crt" \
      -subj "/CN=localhost" 2>/dev/null
    {
      echo "tls_cert = \"$CONF_DIR/$name.crt\""
      echo "tls_key = \"$CONF_DIR/$name.key\""
    } >> "$CONF_DIR/$name.toml"
  fi

  apply_stability_keys "$name"

  local client_addr
  if [ "$IP_VER" = "6" ]; then client_addr="${PUB_IP6:-<this server's IPv6>}"; else client_addr="${PUB_IP:-<this server's IPv4>}"; fi

  write_service "$name"
  echo ""
  echo "======================================"
  echo " ✅ Tunnel '$name' (SERVER) is ready"
  echo " 🔑 Token:          $TOKEN"
  if [ "$ACCEPT_UDP" = "true" ]; then
    echo " 🚇 Transport:      tcp + UDP over TCP (choose option 6 on the client too)"
  else
    echo " 🚇 Transport:      $TRANSPORT"
  fi
  echo " 🌐 Listening on:   IPv$IP_VER ($BIND_HOST:$TPORT)"
  echo " 📍 Client connects to: $client_addr  port $TPORT"
  echo " 🎯 Destination:    $DEST_IP"
  echo " 🚪 Ports:          $PORTS"
  echo " Enter this token, transport and address on the CLIENT."
  echo " Then enable the watchdog for this tunnel (menu option 11)."
  local tproto="TCP" uproto="TCP"
  [ "$TRANSPORT" = "udp" ] && tproto="UDP"
  carries_udp && uproto="UDP"
  if [ "$IP_VER" = "6" ]; then
    echo " Firewall: open $tproto port $TPORT for IPv6 too (ip6tables / ufw with IPV6=yes),"
    echo "           plus the user ports ($PORTS, $uproto)."
  else
    echo " Firewall: $tproto port $TPORT (from the client's IP) and the user ports ($PORTS, $uproto) must be open."
  fi
  if carries_udp; then
    echo " WireGuard tip: set MTU = 1280 in the users' WireGuard configs to avoid"
    echo "                fragmentation inside the tunnel."
  fi
  echo "======================================"
}

create_client() {
  local name="$1" host

  read -rp "Server IP, IPv4 or IPv6 (the SERVER side of this tunnel, e.g. Iran): " SRV_IP
  [ -z "$SRV_IP" ] && { err "IP cannot be empty."; return; }
  host=$(fmt_host "$SRV_IP")

  if is_ipv6 "$SRV_IP" && [ -z "$PUB_IP6" ]; then
    warn "You entered an IPv6 address, but this server has no global IPv6."
    read -rp "Continue anyway? [y/N]: " r
    [[ ! "$r" =~ ^[yY]$ ]] && return
  fi

  read -rp "Tunnel port on the server [3080]: " TPORT
  TPORT=${TPORT:-3080}
  choose_transport
  read -rp "Token (same token as the server): " TOKEN
  [ -z "$TOKEN" ] && { err "Token cannot be empty."; return; }

  {
    echo "[client]"
    echo "remote_addr = \"$host:$TPORT\""
    echo "transport = \"$TRANSPORT\""
    echo "token = \"$TOKEN\""
    echo "log_level = \"info\""
    echo "connection_pool = 8"
    echo "retry_interval = 3"
    [ "$TRANSPORT" != "udp" ] && echo "nodelay = true"
  } > "$CONF_DIR/$name.toml"
  # Note: accept_udp is a server-side option; the client just uses the tcp transport.
  apply_stability_keys "$name"

  write_service "$name"
  echo ""
  ok "Tunnel '$name' (CLIENT) is ready -> $host:$TPORT"
  if carries_udp; then
    echo "Make sure the UDP service (e.g. WireGuard) is listening on the destination:"
    echo "  ss -uln | grep 51820"
  else
    echo "Check that this server can reach the destination (xray IP/port), e.g.:"
    echo "  nc -zv DEST_IP 443"
  fi
  is_ipv6 "$SRV_IP" && echo "You can test the IPv6 link to the server with menu option 6."
  echo "Tip: enable the watchdog (menu option 11) on the SERVER side of this tunnel."
}

list_tunnels() {
  local names n role target state icon wd
  names=$(list_names)
  if [ -z "$names" ]; then
    warn "No tunnels have been created yet."
    return
  fi
  printf "${C_BOLD}%-14s %-8s %-4s %-42s %-12s %-4s %s${C_RESET}\n" "NAME" "ROLE" "IP" "ADDRESS" "STATE" "WD" "PORTS"
  for n in $names; do
    if grep -q '^\[server\]' "$CONF_DIR/$n.toml"; then
      role="server"
      target=$(grep -m1 '^bind_addr' "$CONF_DIR/$n.toml" | cut -d'"' -f2)
    else
      role="client"
      target=$(grep -m1 '^remote_addr' "$CONF_DIR/$n.toml" | cut -d'"' -f2)
    fi
    if [[ "$target" == \[* ]]; then ipv="v6"; else ipv="v4"; fi
    state=$(systemctl is-active "backhaul-$n" 2>/dev/null)
    if [ "$state" = "active" ]; then icon="🟢"; else icon="🔴"; fi
    if [ "$(systemctl is-active "backhaul-watchdog@$n.timer" 2>/dev/null)" = "active" ]; then wd="on"; else wd="-"; fi
    printf "%-14s %-8s %-4s %-42s %s %-9s %-4s %s\n" "$n" "$role" "$ipv" "$target" "$icon" "$state" "$wd" \
      "$(grep -m1 '^ports' "$CONF_DIR/$n.toml" | sed 's/^ports = //')"
  done
}

show_status() {
  select_tunnel || return
  systemctl --no-pager status "backhaul-$TNAME"
  echo ""
  echo "Config:"
  sed -E 's/(token = ").*(")/\1****\2/' "$CONF_DIR/$TNAME.toml"
}

show_logs() {
  select_tunnel || return
  journalctl -u "backhaul-$TNAME" -n 50 --no-pager
}

test_ipv6() {
  local addrs target port
  echo "Global IPv6 addresses on this server:"
  addrs=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print "  " $2}')
  if [ -z "$addrs" ]; then
    err "This server has no global IPv6 address. Ask your provider to enable IPv6."
    return
  fi
  echo "$addrs"
  echo ""
  read -rp "Remote IPv6 address to test (empty = cancel): " target
  [ -z "$target" ] && return
  target="${target#[}"; target="${target%]}"
  read -rp "Port to test [3080]: " port
  port=${port:-3080}

  echo ""
  echo "▶ ping -6 $target"
  if ping -6 -c 3 -W 2 "$target"; then ok "Ping OK"; else warn "Ping failed (ICMPv6 may just be blocked)."; fi

  echo ""
  echo "▶ TCP connect to [$target]:$port"
  if command -v nc >/dev/null 2>&1; then
    nc -6 -vz -w 5 "$target" "$port" && ok "Port $port is reachable over IPv6." \
      || err "Port $port is not reachable (service down or firewall/ip6tables)."
  elif timeout 5 bash -c "</dev/tcp/$target/$port" 2>/dev/null; then
    ok "Port $port is reachable over IPv6."
  else
    err "Port $port is not reachable (service down or firewall/ip6tables)."
  fi
}

restart_tunnel() {
  select_tunnel || return
  systemctl restart "backhaul-$TNAME" && ok "Restarted."
}

edit_config() {
  select_tunnel || return
  "${EDITOR:-nano}" "$CONF_DIR/$TNAME.toml"
  read -rp "Restart the service? [y/N]: " r
  [[ "$r" =~ ^[yY]$ ]] && systemctl restart "backhaul-$TNAME" && ok "Restarted."
}

remove_tunnel_files() {
  local n="$1"
  systemctl disable --now "backhaul-watchdog@$n.timer" 2>/dev/null
  systemctl disable --now "backhaul-$n" 2>/dev/null
  rm -f "/etc/systemd/system/backhaul-$n.service" \
        "$CONF_DIR/$n.toml" "$CONF_DIR/$n.crt" "$CONF_DIR/$n.key" "$CONF_DIR/$n.watchdog" \
        "/run/backhaul-watchdog/$n".*
}

delete_tunnel() {
  select_tunnel || return
  read -rp "Delete tunnel '$TNAME'? [y/N]: " r
  [[ ! "$r" =~ ^[yY]$ ]] && return
  remove_tunnel_files "$TNAME"
  systemctl daemon-reload
  ok "Tunnel '$TNAME' deleted."
}

uninstall_all() {
  read -rp "Remove ALL tunnels and Backhaul? [y/N]: " r
  [[ ! "$r" =~ ^[yY]$ ]] && return
  for n in $(list_names); do
    remove_tunnel_files "$n"
  done
  rm -f "$BIN" "$WD_BIN" "$SYSCTL_FILE" \
        /etc/systemd/system/backhaul-watchdog@.service \
        /etc/systemd/system/backhaul-watchdog@.timer
  rm -rf "$CONF_DIR" /run/backhaul-watchdog
  systemctl daemon-reload
  ok "Everything removed."
}

# ---------- watchdog ----------

# Installs the watchdog script and the systemd template units (idempotent)
install_watchdog_files() {
  cat > "$WD_BIN" <<'WDEOF'
#!/usr/bin/env bash
# backhaul-watchdog <tunnel-name> [--test]
# Restarts backhaul-<name> when the tunnel stops passing traffic.
# Settings come from /etc/backhaul/<name>.watchdog
NAME="$1"
CONF="/etc/backhaul/$NAME.toml"
WD="/etc/backhaul/$NAME.watchdog"
STATE_DIR="/run/backhaul-watchdog"
SVC="backhaul-$NAME"
[ -f "$CONF" ] && [ -f "$WD" ] || exit 0

CHECK_MODE=conn; CHECK_PORT=""; CHECK_SNI=""; MAX_FAILS=2; RESTART_EVERY_H=0; MAX_RESTARTS_PER_HOUR=6
. "$WD"

mkdir -p "$STATE_DIR"
FAILS_FILE="$STATE_DIR/$NAME.fails"
HIST_FILE="$STATE_DIR/$NAME.restarts"
log() { logger -t backhaul-watchdog "[$NAME] $*"; }

if grep -q '^\[server\]' "$CONF"; then
  ROLE=server; ADDR=$(grep -m1 '^bind_addr' "$CONF" | cut -d'"' -f2)
else
  ROLE=client; ADDR=$(grep -m1 '^remote_addr' "$CONF" | cut -d'"' -f2)
fi
TPORT="${ADDR##*:}"

check() {
  case "$CHECK_MODE" in
    tls)
      # Full TLS handshake through the tunnel -> proves traffic reaches the destination
      echo | timeout 8 openssl s_client -connect "127.0.0.1:$CHECK_PORT" \
        ${CHECK_SNI:+-servername "$CHECK_SNI"} >/dev/null 2>&1 ;;
    http)
      local code
      code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:$CHECK_PORT/")
      [ -n "$code" ] && [ "$code" != "000" ] ;;
    tcp)
      timeout 5 bash -c "</dev/tcp/127.0.0.1/$CHECK_PORT" 2>/dev/null ;;
    alive)
      # Only the service state (checked above) and scheduled restarts are used
      true ;;
    *)
      # conn: at least one established tunnel connection on the tunnel port
      local f proto=-Htn
      grep -q '^transport = "udp"' "$CONF" && proto=-Hun
      if [ "$ROLE" = server ]; then f="sport = :$TPORT"; else f="dport = :$TPORT"; fi
      [ "$(ss $proto state established "( $f )" 2>/dev/null | wc -l)" -gt 0 ] ;;
  esac
}

if [ "$2" = "--test" ]; then
  if check; then echo OK; exit 0; else echo FAIL; exit 1; fi
fi

now=$(date +%s)
restart() {
  # Safety valve: never restart more than MAX_RESTARTS_PER_HOUR times per hour
  local recent
  recent=$(awk -v t=$((now - 3600)) '$1 > t' "$HIST_FILE" 2>/dev/null | wc -l)
  if [ "$recent" -ge "$MAX_RESTARTS_PER_HOUR" ]; then
    log "would restart ($1), but already restarted $recent times in the last hour - skipping"
    return
  fi
  log "restarting: $1"
  systemctl restart "$SVC"
  echo 0 > "$FAILS_FILE"
  { awk -v t=$((now - 3600)) '$1 > t' "$HIST_FILE" 2>/dev/null; echo "$now"; } > "$HIST_FILE.tmp"
  mv "$HIST_FILE.tmp" "$HIST_FILE"
}

# 1) The service itself must be running
if [ "$(systemctl is-active "$SVC")" != "active" ]; then
  restart "service was not active"
  exit 0
fi

# Seconds since the service (re)started, based on the monotonic clock
mono=$(systemctl show "$SVC" -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
up=$(awk '{print int($1)}' /proc/uptime)
if [[ "$mono" =~ ^[0-9]+$ ]] && [ "$mono" -gt 0 ]; then
  elapsed=$(( up - mono / 1000000 ))
else
  elapsed=0
fi

# 2) Give a freshly started tunnel time to connect
[ "$elapsed" -lt 90 ] && exit 0

# 3) Optional scheduled restart
if [ "${RESTART_EVERY_H:-0}" -gt 0 ] && [ "$elapsed" -ge $((RESTART_EVERY_H * 3600)) ]; then
  restart "scheduled restart (every ${RESTART_EVERY_H}h)"
  exit 0
fi

# 4) Traffic check
if check; then
  echo 0 > "$FAILS_FILE"
else
  fails=$(( $(cat "$FAILS_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$FAILS_FILE"
  log "check '$CHECK_MODE' failed ($fails/$MAX_FAILS)"
  [ "$fails" -ge "$MAX_FAILS" ] && restart "check '$CHECK_MODE' failed $fails times in a row"
fi
WDEOF
  chmod +x "$WD_BIN"

  cat > /etc/systemd/system/backhaul-watchdog@.service <<'EOF'
[Unit]
Description=Backhaul watchdog check (%i)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backhaul-watchdog %i
EOF

  cat > /etc/systemd/system/backhaul-watchdog@.timer <<'EOF'
[Unit]
Description=Run the Backhaul watchdog for %i every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

watchdog_status() {
  local n="$1" f="$CONF_DIR/$1.watchdog"
  if [ "$(systemctl is-active "backhaul-watchdog@$n.timer" 2>/dev/null)" = "active" ] && [ -f "$f" ]; then
    echo "Watchdog for '$n': ${C_GREEN}ON${C_RESET}"
    sed 's/^/  /' "$f"
  else
    echo "Watchdog for '$n': ${C_DIM}OFF${C_RESET}"
  fi
}

watchdog_enable() {
  local n="$1" role mode port sni fails every def_port r t_transport def_every=0
  role=$(tunnel_role "$n")
  t_transport=$(grep -m1 '^transport' "$CONF_DIR/$n.toml" | cut -d'"' -f2)
  install_watchdog_files

  echo ""
  if [ "$t_transport" = "udp" ]; then
    warn "This is a native UDP tunnel. UDP has no handshake, so a real traffic check"
    echo "isn't possible. The watchdog will restart the tunnel if the service dies,"
    if [ "$role" = "client" ]; then
      echo "if it loses its tunnel connection, and optionally on a schedule."
      mode=conn
    else
      echo "and on a schedule (recommended for UDP: every 6 hours)."
      mode=alive
    fi
    def_every=6
  elif grep -q '^accept_udp = true' "$CONF_DIR/$n.toml"; then
    echo "This tunnel carries UDP over TCP. UDP user ports (e.g. WireGuard) can't be"
    echo "checked with tls/http/tcp, so 'conn' (tunnel connection exists) is used."
    echo "Add a scheduled restart for extra safety."
    mode=conn
    def_every=6
  elif [ "$role" = "server" ]; then
    echo "How should the watchdog check this tunnel?"
    echo "  1) tls   - TLS handshake through the tunnel to xray (best for TLS / Reality ports)"
    echo "  2) http  - HTTP request through the tunnel (for ws / http / non-TLS inbounds)"
    echo "  3) tcp   - only checks the user port accepts connections (weak)"
    echo "  4) conn  - checks that tunnel connections exist (weak, works with anything)"
    read -rp "Choice [1]: " m
    case "${m:-1}" in
      2) mode=http ;; 3) mode=tcp ;; 4) mode=conn ;; *) mode=tls ;;
    esac
  else
    warn "This is the CLIENT side. Only the 'conn' check works here."
    echo "For a real traffic check, enable the watchdog on the SERVER side (Iran) instead."
    mode=conn
  fi

  if [ "$mode" = "tls" ] || [ "$mode" = "http" ] || [ "$mode" = "tcp" ]; then
    def_port=$(first_user_port "$n")
    read -rp "User port to check [${def_port:-443}]: " port
    port=${port:-${def_port:-443}}
    [[ "$port" =~ ^[0-9]+$ ]] || { err "Invalid port."; return; }
  fi
  if [ "$mode" = "tls" ]; then
    read -rp "SNI of the inbound (Reality serverName / TLS domain, empty = none): " sni
    [[ "$sni" =~ ^[A-Za-z0-9.-]*$ ]] || { err "Invalid SNI."; return; }
  fi

  read -rp "Restart after how many failed checks in a row? [2]: " fails
  fails=${fails:-2}
  [[ "$fails" =~ ^[1-9][0-9]*$ ]] || { err "Invalid number."; return; }

  read -rp "Also restart on a schedule every N hours? (0 = off) [$def_every]: " every
  every=${every:-$def_every}
  [[ "$every" =~ ^[0-9]+$ ]] || { err "Invalid number."; return; }

  cat > "$CONF_DIR/$n.watchdog" <<EOF
CHECK_MODE=$mode
CHECK_PORT=$port
CHECK_SNI=$sni
MAX_FAILS=$fails
RESTART_EVERY_H=$every
MAX_RESTARTS_PER_HOUR=6
EOF

  echo ""
  echo "Running the check once now..."
  if "$WD_BIN" "$n" --test >/dev/null; then
    ok "Check '$mode' passed - the tunnel is working right now."
  else
    err "Check '$mode' FAILED right now."
    echo "If the tunnel is actually working, this check doesn't fit your inbound and the"
    echo "watchdog would keep restarting it. Try another check type (e.g. http or conn)."
    read -rp "Enable it anyway? [y/N]: " r
    if [[ ! "$r" =~ ^[yY]$ ]]; then
      rm -f "$CONF_DIR/$n.watchdog"
      return
    fi
  fi

  systemctl enable --now "backhaul-watchdog@$n.timer" >/dev/null 2>&1
  ok "Watchdog enabled for '$n' (checks every minute)."
}

watchdog_disable() {
  local n="$1"
  systemctl disable --now "backhaul-watchdog@$n.timer" 2>/dev/null
  rm -f "$CONF_DIR/$n.watchdog" "/run/backhaul-watchdog/$n".*
  ok "Watchdog disabled for '$n'."
}

watchdog_log() {
  local n="$1" out
  out=$(journalctl -t backhaul-watchdog --no-pager -n 500 2>/dev/null | grep -F "[$n]" | tail -n 30)
  if [ -z "$out" ]; then
    echo "No watchdog events for '$n' yet (no failures or restarts)."
  else
    echo "$out"
  fi
}

watchdog_menu() {
  select_tunnel || return
  echo ""
  watchdog_status "$TNAME"
  echo ""
  echo "  1) Enable / reconfigure"
  echo "  2) Disable"
  echo "  3) Show watchdog log (restarts & failures)"
  echo "  4) Run the check now"
  read -rp "Choice: " w
  case "$w" in
    1) watchdog_enable "$TNAME" ;;
    2) watchdog_disable "$TNAME" ;;
    3) watchdog_log "$TNAME" ;;
    4)
      if [ -f "$CONF_DIR/$TNAME.watchdog" ]; then
        if "$WD_BIN" "$TNAME" --test >/dev/null; then ok "Check passed."; else err "Check failed."; fi
      else
        warn "Watchdog is not configured for this tunnel."
      fi ;;
    *) echo "Invalid option." ;;
  esac
}

# ---------- stability tuning ----------

stability_tuning() {
  local n r
  echo "This will:"
  echo "  - apply TCP keepalive / conntrack / file-limit sysctl settings ($SYSCTL_FILE)"
  echo "  - add heartbeat/keepalive settings to your existing tunnel configs"
  read -rp "Continue? [Y/n]: " r
  [[ "$r" =~ ^[nN]$ ]] && return

  modprobe nf_conntrack 2>/dev/null
  cat > "$SYSCTL_FILE" <<'EOF'
# Backhaul stability tuning
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.netfilter.nf_conntrack_max = 262144
net.core.somaxconn = 4096
fs.file-max = 1048576
# Larger socket buffers - helps UDP tunnels (WireGuard etc.) under load
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
EOF
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1
  ok "sysctl settings applied."

  for n in $(list_names); do
    apply_stability_keys "$n"
    echo "  updated config: $n"
  done

  if [ -n "$(list_names)" ]; then
    read -rp "Restart all tunnels now so the new settings take effect? [y/N]: " r
    if [[ "$r" =~ ^[yY]$ ]]; then
      for n in $(list_names); do systemctl restart "backhaul-$n"; done
      ok "All tunnels restarted."
    else
      warn "New config settings apply after each tunnel's next restart."
    fi
  fi
  echo "Note: apply this on BOTH servers (Iran and foreign)."
}

# ---------- menu ----------

gather_info

while true; do
  print_header
  echo " ${C_BOLD}🔧 Install & Create${C_RESET}"
  echo "   1) 📦 Install Backhaul"
  echo "   2) ➕ Create a new tunnel (server / client, IPv4 / IPv6, TCP / UDP)"
  echo ""
  echo " ${C_BOLD}📊 Monitoring${C_RESET}"
  echo "   3) 📋 List tunnels"
  echo "   4) 🔍 Tunnel status"
  echo "   5) 📜 Show logs"
  echo "   6) 🌍 Test IPv6 connectivity"
  echo ""
  echo " ${C_BOLD}🛠️  Management${C_RESET}"
  echo "   7) 🔄 Restart a tunnel"
  echo "   8) ✏️  Edit config"
  echo "   9) 🗑️  Delete a tunnel"
  echo "  10) 💣 Uninstall everything"
  echo ""
  echo " ${C_BOLD}🛡️  Stability${C_RESET}"
  echo "  11) 🐶 Watchdog (auto-restart a hung tunnel)"
  echo "  12) 🧰 Stability tuning (keepalive / heartbeat / sysctl)"
  echo ""
  echo "   0) 🚪 Exit"
  echo "${C_DIM}──────────────────────────────────────────────────────${C_RESET}"
  read -rp " 👉 Choice: " c
  echo ""
  case "$c" in
    1) install_backhaul ;;
    2) create_tunnel ;;
    3) list_tunnels ;;
    4) show_status ;;
    5) show_logs ;;
    6) test_ipv6 ;;
    7) restart_tunnel ;;
    8) edit_config ;;
    9) delete_tunnel ;;
    10) uninstall_all ;;
    11) watchdog_menu ;;
    12) stability_tuning ;;
    0) exit 0 ;;
    *) echo "Invalid option." ;;
  esac
  echo ""
  pause
done
