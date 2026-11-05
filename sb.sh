#!/bin/sh

set -eu

SING_BOX_VERSION=""
SERVICE_NAME=sing-box

VLESS_PORT=60001
HY2_PORT=60002
TUIC_PORT=60003
SNELL_PORT=60004
SNELL_V6_PORT=60005

VLESS_UUID=""
REALITY_PRIVATE=""
REALITY_PUBLIC=""
REALITY_SHORT_ID=""
HY2_PASSWORD=""
SNELL_PSK=""

SNI=www.tencentcloud.com
REALITY_DEST_PORT=443

BASE_DIR="${SING_BOX_HOME:-/root/sing-box}"
BIN_PATH="$BASE_DIR/sing-box"

CONF_DIR="$BASE_DIR/conf"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/sing-box.log"
PID_FILE="$BASE_DIR/sing-box.pid"
ROTATOR_PID_FILE="$BASE_DIR/log-rotator.pid"

LOG_MAX_BYTES=$((10 * 1024 * 1024))
LOG_KEEP_BYTES=$((5 * 1024 * 1024))

CONF_FILE="$CONF_DIR/config.json"
REALITY_PUBLIC_FILE="$CONF_DIR/reality-public.key"
TLS_CERT_FILE="$CONF_DIR/tls-cert.pem"
TLS_KEY_FILE="$CONF_DIR/tls-key.pem"
CLIENT_FILES="clash-pc.yaml clash-mobile.yaml singbox-pc.json singbox-android.json singbox-ios.json egern.yaml"
# Older installs kept the client configs in this folder.
OLD_CLIENT_DIR="$BASE_DIR/client"

# Left unbounded, the Go heap and socket buffers can crowd out the page cache that
# holds sing-box's own large binary, and the kernel then thrashes and OOM-kills it.
# 4 MiB per socket carries about 250 Mbit/s on one TCP connection at 90 ms. At 8 MiB,
# a dozen busy sockets took 90 MiB and got sing-box OOM-killed in a 128 MB container.
GO_MEMORY_LIMIT=48MiB
TCP_BUFFER_MAX=4194304

SERVER=""
SERVER_IPV4=""
SERVER_IPV6=""

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_RESET=$(printf '\033[0m'); C_OK=$(printf '\033[32m')
  C_ERR=$(printf '\033[31m'); C_INFO=$(printf '\033[36m')
  C_BOLD=$(printf '\033[1m')
else
  C_RESET=''; C_OK=''; C_ERR=''; C_INFO=''; C_BOLD=''
fi

log()  { printf '%s==>%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat << 'USAGE'
sing-box installer for Alpine Linux and Debian/Ubuntu.

Installs sing-box and starts five inbounds with random credentials:
  * VLESS + REALITY (XTLS-Vision)  on 60001/tcp
  * Hysteria2                      on 60002/udp
  * TUIC v5                        on 60003/udp
  * Snell v5 (v4 compatible)       on 60004/tcp
  * Snell v6                       on 60005/tcp

Usage:
  ./sb.sh              install (or repair) and start
  ./sb.sh --show       print the share links for an existing install
  ./sb.sh --client-config
                        write Clash, sing-box and Egern client configs
  ./sb.sh --uninstall  stop and remove everything this script created

Client configs send China and LAN traffic direct and everything else through
the proxy, with 223.5.5.5 as DNS. They contain credentials and are written to
the state directory; an install rewrites them.

Always installs the latest stable sing-box release; re-running upgrades it.
REALITY, Hysteria2 and TUIC all use www.tencentcloud.com as the SNI.
Hysteria2 and TUIC use a self-signed certificate; clients skip verification.
Each install generates fresh credentials; update clients after re-running.

State lives under /root/sing-box (binary, config, logs, pids).
Set SING_BOX_HOME to put it somewhere else.

Supports both systemd (Debian/Ubuntu) and OpenRC (Alpine); falls back to a
background process when neither init is present (e.g. inside a container).
sing-box is restarted automatically if it exits or is killed (e.g. by OOM).
USAGE
}

MODE=install
case "${1:-}" in
  ""|--install)         MODE=install ;;
  --show)               MODE=show ;;
  --client-config)      MODE=client-config ;;
  --uninstall|--remove) MODE=uninstall ;;
  -h|--help)            usage; exit 0 ;;
  *) die "unknown option: $1 (try --show, --client-config or --uninstall)" ;;
esac

case "$MODE" in
  show|client-config) ;;
  *) [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0)" ;;
esac

DISTRO=unknown
if [ -r /etc/os-release ]; then
  DISTRO=$(. /etc/os-release && printf '%s' "${ID:-unknown}")
fi
case "$DISTRO" in
  alpine)                 DISTRO_FAMILY=alpine ;;
  debian|ubuntu|raspbian) DISTRO_FAMILY=debian ;;
  *)
    if command -v apk >/dev/null 2>&1; then DISTRO_FAMILY=alpine
    elif command -v apt-get >/dev/null 2>&1; then DISTRO_FAMILY=debian
    else DISTRO_FAMILY=unknown; fi
    ;;
esac

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  INIT=systemd
elif command -v rc-update >/dev/null 2>&1 && [ -d /etc/init.d ]; then
  INIT=openrc
else
  INIT=none
fi

install_deps() (
  log "installing dependencies"
  if [ "$DISTRO_FAMILY" = alpine ]; then
    apk add --no-cache ca-certificates curl openssl jq >/dev/null
  elif [ "$DISTRO_FAMILY" = debian ]; then
    export DEBIAN_FRONTEND=noninteractive
    # Compressed, isolated indexes and separate download/install steps keep
    # apt and dpkg from exceeding the memory limit of small containers.
    DEPS_TMP=$(mktemp -d /tmp/sing-box-deps.XXXXXX)
    trap 'rm -rf "$DEPS_TMP"' 0
    chmod 0755 "$DEPS_TMP"
    install -d -m 0755 "$DEPS_TMP/lists" "$DEPS_TMP/archives"
    set -- -o "Dir::State::lists=$DEPS_TMP/lists" \
      -o "Dir::Cache::archives=$DEPS_TMP/archives" \
      -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= \
      -o Acquire::Languages=none -o Acquire::GzipIndexes=true \
      -o Acquire::CompressionTypes::Order::=gz -o APT::Cache-Start=8388608
    apt-get "$@" update -qq >/dev/null
    apt-get "$@" install --download-only --no-install-recommends --no-upgrade \
      -y -qq ca-certificates curl openssl jq >/dev/null
    set -- "$DEPS_TMP"/archives/*.deb
    if [ -f "$1" ]; then
      dpkg -i "$@" >/dev/null
    fi
  else
    die "no supported package manager found; install curl, openssl and jq manually"
  fi
  ok "ca-certificates, curl, openssl, jq"
)

ensure_deps() {
  missing=0
  for c in curl openssl jq; do
    command -v "$c" >/dev/null 2>&1 || missing=1
  done
  [ -d /etc/ssl/certs ] || missing=1
  [ "$missing" -eq 1 ] && install_deps
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v openssl >/dev/null 2>&1 || die "openssl is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)        echo amd64 ;;
    aarch64|arm64)       echo arm64 ;;
    armv7l|armv7)        echo armv7 ;;
    armv6l|armv6)        echo armv6 ;;
    armv5l|armv5)        echo armv5 ;;
    i386|i486|i586|i686) echo 386 ;;
    riscv64)             echo riscv64 ;;
    loongarch64|loong64) echo loong64 ;;
    s390x)               echo s390x ;;
    ppc64le)             echo ppc64le ;;
    mips64el)            echo mips64le ;;
    mipsel)              echo mipsle ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

fetch_binary() {
  ARCH=$(detect_arch)
  BASE="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}"
  install -d -m 0755 "$BASE_DIR"
  TMP=$(mktemp -d "$BASE_DIR/dl.XXXXXX")

  if [ "$DISTRO_FAMILY" = alpine ]; then
    CANDIDATES="$ARCH-musl $ARCH"
  else
    CANDIDATES="$ARCH $ARCH-glibc $ARCH-musl"
  fi

  for variant in $CANDIDATES; do
    URL="$BASE/sing-box-${SING_BOX_VERSION}-linux-${variant}.tar.gz"
    log "downloading sing-box $SING_BOX_VERSION ($variant)"
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP/sb.tar.gz" "$URL" 2>/dev/null; then
      warn "no release asset for $variant"
      continue
    fi
    if ! tar -xzf "$TMP/sb.tar.gz" -C "$TMP" 2>/dev/null; then
      warn "could not extract $variant archive"
      continue
    fi
    CANDIDATE=$(find "$TMP" -type f -name sing-box | head -n 1)
    [ -n "$CANDIDATE" ] || { warn "no binary in $variant archive"; continue; }
    chmod +x "$CANDIDATE"
    if RUNERR=$("$CANDIDATE" version 2>&1 >/dev/null); then
      install -m 0755 "$CANDIDATE" "$BIN_PATH"
      rm -rf "$TMP"
      ok "installed $BIN_PATH ($variant)"
      return 0
    fi
    warn "$variant binary does not run on this system: $RUNERR"
  done

  rm -rf "$TMP"
  die "could not obtain a working sing-box binary for $ARCH"
}

resolve_version() {
  log "resolving latest sing-box release"
  LATEST_URL=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --retry 3 --connect-timeout 15 \
    https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null) || LATEST_URL=""
  SING_BOX_VERSION=${LATEST_URL##*/v}
  case "$SING_BOX_VERSION" in
    ''|*[!0-9.]*) SING_BOX_VERSION=""; return 1 ;;
  esac
  ok "latest sing-box is $SING_BOX_VERSION"
}

ensure_binary() {
  if ! resolve_version; then
    [ -x "$BIN_PATH" ] || die "could not resolve the latest sing-box release"
    warn "could not resolve the latest sing-box release; keeping the installed binary"
    return 0
  fi
  if [ -x "$BIN_PATH" ]; then
    CURRENT=$("$BIN_PATH" version 2>/dev/null | awk '/^sing-box version/{print $3}') || CURRENT=""
    if [ "$CURRENT" = "$SING_BOX_VERSION" ]; then
      ok "sing-box $CURRENT already installed"
      return 0
    fi
    log "replacing sing-box ${CURRENT:-unknown} with $SING_BOX_VERSION"
  fi
  fetch_binary
}

ensure_dirs() {
  install -d -m 0755 "$CONF_DIR" "$LOG_DIR"
  chmod 0755 "$BASE_DIR"
}

generate_credentials() {
  log "generating fresh credentials"
  VLESS_UUID=$("$BIN_PATH" generate uuid) || die "could not generate VLESS UUID"
  reality_keypair=$("$BIN_PATH" generate reality-keypair) || die "could not generate REALITY key pair"
  REALITY_PRIVATE=$(printf '%s\n' "$reality_keypair" | awk '/^PrivateKey:/{print $2}')
  REALITY_PUBLIC=$(printf '%s\n' "$reality_keypair" | awk '/^PublicKey:/{print $2}')
  [ -n "$VLESS_UUID" ] && [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || die "invalid generated credentials"
  REALITY_SHORT_ID=$(openssl rand -hex 8) || die "could not generate REALITY short ID"
  HY2_PASSWORD=$(openssl rand -hex 16) || die "could not generate Hysteria2 password"
  SNELL_PSK=$(openssl rand -hex 32) || die "could not generate Snell key"
}

write_config() (
  umask 077
  # Set permissions before writing, including when replacing an existing file.
  touch "$CONF_FILE" "$REALITY_PUBLIC_FILE" "$TLS_CERT_FILE" "$TLS_KEY_FILE"
  chmod 600 "$CONF_FILE" "$REALITY_PUBLIC_FILE" "$TLS_CERT_FILE" "$TLS_KEY_FILE"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$TLS_KEY_FILE" -out "$TLS_CERT_FILE" -days 3650 \
    -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1 \
    || die "could not generate the TLS certificate"
  # Generated UUIDs, hex keys and base64url keys are safe in JSON strings.
  # Feed credentials through stdin so they do not appear in process arguments.
  jq . > "$CONF_FILE" << CONFIG
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-local"
      }
    ],
    "final": "dns-local",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": 60001,
      "users": [
        {
          "name": "default",
          "uuid": "$VLESS_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SNI",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE",
          "short_id": [
            "$REALITY_SHORT_ID"
          ]
        }
      },
      "multiplex": {
        "enabled": true
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 60002,
      "users": [
        {
          "name": "default",
          "password": "$HY2_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "alpn": [
          "h3"
        ],
        "certificate_path": "$TLS_CERT_FILE",
        "key_path": "$TLS_KEY_FILE"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": 60003,
      "users": [
        {
          "name": "default",
          "uuid": "$VLESS_UUID",
          "password": "$HY2_PASSWORD"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "alpn": [
          "h3"
        ],
        "certificate_path": "$TLS_CERT_FILE",
        "key_path": "$TLS_KEY_FILE"
      }
    },
    {
      "type": "snell",
      "tag": "snell-in",
      "listen": "::",
      "listen_port": 60004,
      "version": 5,
      "psk": "$SNELL_PSK"
    },
    {
      "type": "snell",
      "tag": "snell-v6-in",
      "listen": "::",
      "listen_port": 60005,
      "version": 6,
      "psk": "$SNELL_PSK",
      "mode": "default"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct",
    "default_domain_resolver": {
      "server": "dns-local",
      "strategy": "prefer_ipv4"
    }
  }
}
CONFIG
  printf '%s\n' "$REALITY_PUBLIC" > "$REALITY_PUBLIC_FILE"
)

load_credentials() {
  command -v jq >/dev/null 2>&1 || die "jq is required to read the saved configuration"
  client_settings=$(jq -er '
    (.inbounds[] | select(.type == "vless")) as $vless |
    (.inbounds[] | select(.type == "hysteria2")) as $hy2 |
    (.inbounds[] | select(.type == "snell" and .version == 5)) as $snell |
    [$vless.users[0].uuid, $vless.tls.server_name,
     $vless.tls.reality.short_id[0], $hy2.users[0].password, $snell.psk] |
    if all(.[]; type == "string" and length > 0) then @tsv
    else error("missing client settings") end
  ' "$CONF_FILE") || die "could not read credentials from $CONF_FILE"
  [ -n "$client_settings" ] || die "no client credentials found in $CONF_FILE"
  IFS="$(printf '\t')" read -r VLESS_UUID SNI REALITY_SHORT_ID HY2_PASSWORD SNELL_PSK << SETTINGS
$client_settings
SETTINGS
  [ -s "$REALITY_PUBLIC_FILE" ] || die "missing $REALITY_PUBLIC_FILE; re-run sb.sh to generate credentials"
  REALITY_PUBLIC=$(cat "$REALITY_PUBLIC_FILE")
}

check_reality_dest() {
  log "checking REALITY destination $SNI:$REALITY_DEST_PORT"
  if command -v timeout >/dev/null 2>&1; then
    REALITY_CHECK=$(timeout 10 openssl s_client -connect "$SNI:$REALITY_DEST_PORT" \
        -servername "$SNI" -alpn h2 </dev/null 2>/dev/null || true)
  else
    REALITY_CHECK=$(openssl s_client -connect "$SNI:$REALITY_DEST_PORT" \
        -servername "$SNI" -alpn h2 </dev/null 2>/dev/null || true)
  fi
  case "$REALITY_CHECK" in
    *TLSv1.3*) ok "destination speaks TLS 1.3" ;;
    *) warn "could not confirm TLS 1.3 from $SNI -- REALITY clients may fail" ;;
  esac
}

# Runs before every start because a container restart resets these settings. Writes
# fail harmlessly where /proc/sys is read-only. Limiting unsent data drops the queue
# that builds when a fast download outruns the client, leaving data in flight alone.
# 1 MiB keeps the socket sending while a CPU quota has sing-box paused.
# The values come from cat because the kernel returns EOF to byte-wise shell reads.
TUNE_COMMAND='for f in /proc/sys/net/ipv4/tcp_rmem /proc/sys/net/ipv4/tcp_wmem; do set -- $(cat "$f" 2>/dev/null); [ "$#" -eq 3 ] && [ "$3" -gt '"$TCP_BUFFER_MAX"' ] && { echo "$1 $2 '"$TCP_BUFFER_MAX"'" > "$f"; } 2>/dev/null; done; { echo 1048576 > /proc/sys/net/ipv4/tcp_notsent_lowat; } 2>/dev/null; :'

rotate_logs() {
  [ -f "$LOG_FILE" ] || return 0
  size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
  [ "$size" -gt "$LOG_MAX_BYTES" ] || return 0
  if tail -c "$LOG_KEEP_BYTES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null; then
    cat "$LOG_FILE.tmp" > "$LOG_FILE"
  fi
  rm -f "$LOG_FILE.tmp"
}

start_rotator() {
  if [ -f "$ROTATOR_PID_FILE" ] && kill -0 "$(cat "$ROTATOR_PID_FILE")" 2>/dev/null; then
    return 0
  fi
  nohup sh -c '
    while :; do
      sleep 600
      [ -f "$1" ] || continue
      size=$(wc -c < "$1" 2>/dev/null || echo 0)
      [ "$size" -gt "$2" ] || continue
      if tail -c "$3" "$1" > "$1.tmp" 2>/dev/null; then
        cat "$1.tmp" > "$1"
      fi
      rm -f "$1.tmp"
    done
  ' log-rotator "$LOG_FILE" "$LOG_MAX_BYTES" "$LOG_KEEP_BYTES" >/dev/null 2>&1 &
  echo $! > "$ROTATOR_PID_FILE"
  rotate_logs
}

stop_rotator() {
  if [ -f "$ROTATOR_PID_FILE" ]; then
    kill "$(cat "$ROTATOR_PID_FILE")" 2>/dev/null || true
    rm -f "$ROTATOR_PID_FILE"
  fi
}

stop_existing() {
  case "$INIT" in
    systemd) systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
    openrc)  rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true ;;
  esac
  if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE")
    kill "$old_pid" 2>/dev/null || true
    i=0
    while kill -0 "$old_pid" 2>/dev/null && [ "$i" -lt 10 ]; do
      sleep 1
      i=$((i + 1))
    done
    rm -f "$PID_FILE"
  fi
  stop_rotator
}

install_service() {
  case "$INIT" in
    systemd)
      cat > "/etc/systemd/system/${SERVICE_NAME}.service" << UNIT
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=-/bin/sh -c '$(printf '%s' "$TUNE_COMMAND" | sed 's/\$/$$/g')'
ExecStart=$BIN_PATH run -c $CONF_FILE
Environment=GOMEMLIMIT=$GO_MEMORY_LIMIT
Environment=GODEBUG=disablethp=1
Restart=always
RestartSec=3s
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload
      systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
      ok "systemd unit installed"
      ;;
    openrc)
      sed -e "s|@BIN@|$BIN_PATH|g" \
          -e "s|@CONF@|$CONF_FILE|g" \
          -e "s|@LOG@|$LOG_FILE|g" \
          -e "s|@RPID@|$ROTATOR_PID_FILE|g" \
          -e "s|@RMAX@|$LOG_MAX_BYTES|g" \
          -e "s|@RKEEP@|$LOG_KEEP_BYTES|g" \
          -e "s|@TUNE@|$(printf '%s' "$TUNE_COMMAND" | sed 's/[&\\|]/\\&/g')|g" \
          -e "s|@GOMEMLIMIT@|$GO_MEMORY_LIMIT|g" > "/etc/init.d/$SERVICE_NAME" << 'INITD'
#!/sbin/openrc-run

name="sing-box"
description="sing-box proxy server"

supervisor="supervise-daemon"
command="@BIN@"
command_args="run -c @CONF@"
output_log="@LOG@"
error_log="@LOG@"
respawn_delay=3
respawn_max=0

export GOMEMLIMIT="@GOMEMLIMIT@"
export GODEBUG="disablethp=1"

rotator_pid="@RPID@"

start_pre() {
  @TUNE@
  if [ -f "$rotator_pid" ] && kill -0 "$(cat "$rotator_pid")" 2>/dev/null; then
    return 0
  fi
  nohup sh -c '
    while :; do
      sleep 600
      [ -f "$1" ] || continue
      size=$(wc -c < "$1" 2>/dev/null || echo 0)
      [ "$size" -gt "$2" ] || continue
      if tail -c "$3" "$1" > "$1.tmp" 2>/dev/null; then
        cat "$1.tmp" > "$1"
      fi
      rm -f "$1.tmp"
    done
  ' log-rotator "@LOG@" @RMAX@ @RKEEP@ >/dev/null 2>&1 &
  echo $! > "$rotator_pid"
  return 0
}

stop_post() {
  if [ -f "$rotator_pid" ]; then
    kill "$(cat "$rotator_pid")" 2>/dev/null
    rm -f "$rotator_pid"
  fi
  return 0
}

depend() {
  need net
  after firewall
}
INITD
      chmod 0755 "/etc/init.d/$SERVICE_NAME"
      rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
      ok "openrc service installed"
      ;;
    none)
      warn "no init system found; sing-box will run as a background process"
      ;;
  esac
}

start_service() {
  case "$INIT" in
    systemd) systemctl start "$SERVICE_NAME" ;;
    openrc)  rc-service "$SERVICE_NAME" start >/dev/null 2>&1 ;;
    none)
      sh -c "$TUNE_COMMAND" || :
      GOMEMLIMIT="$GO_MEMORY_LIMIT" GODEBUG=disablethp=1 nohup sh -c '
        trap "kill \$child 2>/dev/null; wait \$child; exit 0" TERM
        while :; do
          "$1" run -c "$2" >>"$3" 2>&1 &
          child=$!
          wait "$child"
          sleep 3
        done
      ' sing-box-supervisor "$BIN_PATH" "$CONF_FILE" "$LOG_FILE" >/dev/null 2>&1 &
      echo $! > "$PID_FILE"
      start_rotator
      ;;
  esac
}

verify_listening() {
  sleep 2
  failed=0
  for p in "$VLESS_PORT/tcp" "$HY2_PORT/udp" "$TUIC_PORT/udp" "$SNELL_PORT/tcp" "$SNELL_V6_PORT/tcp"; do
    port=${p%/*}
    proto=${p#*/}
    if command -v ss >/dev/null 2>&1; then
      if [ "$proto" = tcp ]; then ss_flags=-lnt; else ss_flags=-lnu; fi
      ss "$ss_flags" 2>/dev/null | grep -qE "[:.]$port[[:space:]]" || failed=1
    elif command -v netstat >/dev/null 2>&1; then
      netstat -an 2>/dev/null | grep -qE "^$proto.*[:.]$port[[:space:]]" || failed=1
    elif command -v lsof >/dev/null 2>&1; then
      if [ "$proto" = tcp ]; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || failed=1
      else
        lsof -nP -iUDP:"$port" >/dev/null 2>&1 || failed=1
      fi
    fi
  done
  if [ "$failed" -eq 1 ]; then
    warn "one or more ports are not listening -- check the logs:"
    if [ "$INIT" = systemd ]; then
      printf '  journalctl -u %s -n 50 --no-pager\n' "$SERVICE_NAME"
    else
      printf '  tail -n 50 %s\n' "$LOG_FILE"
    fi
    exit 1
  fi
  ok "listening on $VLESS_PORT/tcp, $HY2_PORT/udp, $TUIC_PORT/udp, $SNELL_PORT/tcp and $SNELL_V6_PORT/tcp"
}

public_ip() {
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4 -fsS --connect-timeout 8 "$url" 2>/dev/null | tr -d '[:space:]') || ip=""
    case "$ip" in
      *[!0-9a-fA-F:.]*|"") continue ;;
      *) printf '%s' "$ip"; return 0 ;;
    esac
  done
  return 1
}

public_ipv6() {
  for url in https://api6.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip6=$(curl -6 -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') || ip6=""
    case "$ip6" in
      *[!0-9a-fA-F:]*|"") continue ;;
      *:*) printf '%s' "$ip6"; return 0 ;;
    esac
  done
  return 1
}

print_section() {
  section_head="-- $1  $2 "
  section_fill=$((56 - ${#section_head}))
  section_rule=$(printf '%s' '--------------------------------------------------------' | cut -c1-"$section_fill")
  printf '\n%s%s%s%s\n' "$C_BOLD" "$section_head" "$section_rule" "$C_RESET"
}

detect_server() {
  [ -z "$SERVER" ] || return 0
  SERVER_IPV4=$(public_ip) || SERVER_IPV4=""
  SERVER_IPV6=$(public_ipv6) || SERVER_IPV6=""
  SERVER="${SERVER_IPV4:-${SERVER_IPV6:-<your-server-ip>}}"
}

show_links() {
  load_credentials
  detect_server
  URI_SERVER=$SERVER
  case "$URI_SERVER" in
    *:*) URI_SERVER="[$URI_SERVER]" ;;
  esac
  printf '\n%s========================================================%s\n' "$C_BOLD" "$C_RESET"
  printf '%s  sing-box is running%s\n' "$C_BOLD" "$C_RESET"
  printf '%s========================================================%s\n' "$C_BOLD" "$C_RESET"
  if [ -n "$SERVER_IPV4" ]; then
    printf '  ipv4        %s\n' "$SERVER_IPV4"
  fi
  if [ -n "$SERVER_IPV6" ]; then
    printf '  ipv6        %s\n' "$SERVER_IPV6"
  fi

  print_section "VLESS + REALITY" "$VLESS_PORT/tcp"
  printf '  vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#reality\n' \
    "$VLESS_UUID" "$URI_SERVER" "$VLESS_PORT" "$SNI" "$REALITY_PUBLIC" "$REALITY_SHORT_ID"
  printf '  uuid        %s\n' "$VLESS_UUID"
  printf '  public key  %s\n' "$REALITY_PUBLIC"
  printf '  short id    %s\n' "$REALITY_SHORT_ID"
  printf '  sni         %s\n' "$SNI"

  print_section "Hysteria2" "$HY2_PORT/udp"
  printf '  hysteria2://%s@%s:%s?sni=%s&alpn=h3&insecure=1#hysteria2\n' \
    "$HY2_PASSWORD" "$URI_SERVER" "$HY2_PORT" "$SNI"
  printf '  password    %s\n' "$HY2_PASSWORD"
  printf '  sni         %s\n' "$SNI"

  print_section "TUIC v5" "$TUIC_PORT/udp"
  printf '  tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#tuic\n' \
    "$VLESS_UUID" "$HY2_PASSWORD" "$URI_SERVER" "$TUIC_PORT" "$SNI"
  printf '  uuid        %s\n' "$VLESS_UUID"
  printf '  password    %s\n' "$HY2_PASSWORD"
  printf '  sni         %s\n' "$SNI"

  print_section "Snell v5" "$SNELL_PORT/tcp"
  printf '  snell-v5 = snell, %s, %s, psk=%s, version=4, reuse=true\n' \
    "$SERVER" "$SNELL_PORT" "$SNELL_PSK"
  printf '  psk         %s\n' "$SNELL_PSK"

  print_section "Snell v6" "$SNELL_V6_PORT/tcp"
  printf '  snell-v6 = snell, %s, %s, psk=%s, version=6, reuse=true\n' \
    "$SERVER" "$SNELL_V6_PORT" "$SNELL_PSK"
  printf '  psk         %s\n' "$SNELL_PSK"

  printf '\n%s========================================================%s\n\n' "$C_BOLD" "$C_RESET"
}

# Real IPs for China and LAN answers from 223.5.5.5, fake IPs for everything else,
# so proxied traffic keeps its domain and is resolved on the server. A route
# "resolve" action cannot do this: it hands the proxy the possibly poisoned IP.
# An empty AAAA answer is returned as is, or an IPv4-only China site would get a
# fake IPv6 address and could end up on the proxy. $1 adds platform differences.
singbox_client_config() {
  jq "$1" << CONFIG
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-ali",
        "server": "223.5.5.5"
      },
      {
        "type": "local",
        "tag": "dns-local"
      },
      {
        "type": "fakeip",
        "tag": "dns-fake",
        "inet4_range": "198.18.0.0/15",
        "inet6_range": "fc00::/18"
      }
    ],
    "rules": [
      {
        "domain_suffix": ["lan", "local", "home.arpa"],
        "server": "dns-local"
      },
      {
        "query_type": ["HTTPS", "SVCB"],
        "action": "predefined"
      },
      {
        "query_type": ["A", "AAAA"],
        "action": "evaluate",
        "server": "dns-ali"
      },
      {
        "match_response": true,
        "rule_set": "geoip-cn",
        "action": "respond"
      },
      {
        "match_response": true,
        "ip_is_private": true,
        "action": "respond"
      },
      {
        "type": "logical",
        "mode": "and",
        "rules": [
          {
            "query_type": "AAAA"
          },
          {
            "match_response": true,
            "response_rcode": "NOERROR"
          },
          {
            "match_response": true,
            "ip_accept_any": true,
            "invert": true
          }
        ],
        "action": "respond"
      },
      {
        "query_type": ["A", "AAAA"],
        "server": "dns-fake"
      }
    ],
    "final": "dns-ali"
  },
  "http_clients": [
    {
      "tag": "via-proxy",
      "detour": "PROXY"
    }
  ],
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "PROXY",
      "outbounds": ["reality", "hysteria2", "tuic", "snell-v5", "snell-v6"],
      "default": "reality"
    },
    {
      "type": "vless",
      "tag": "reality",
      "server": "$SERVER",
      "server_port": $VLESS_PORT,
      "uuid": "$VLESS_UUID",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "$REALITY_PUBLIC",
          "short_id": "$REALITY_SHORT_ID"
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "server": "$SERVER",
      "server_port": $HY2_PORT,
      "password": "$HY2_PASSWORD",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "insecure": true,
        "alpn": ["h3"]
      }
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "server": "$SERVER",
      "server_port": $TUIC_PORT,
      "uuid": "$VLESS_UUID",
      "password": "$HY2_PASSWORD",
      "congestion_control": "bbr",
      "udp_relay_mode": "native",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "insecure": true,
        "alpn": ["h3"]
      }
    },
    {
      "type": "snell",
      "tag": "snell-v5",
      "server": "$SERVER",
      "server_port": $SNELL_PORT,
      "version": 4,
      "psk": "$SNELL_PSK",
      "reuse": true
    },
    {
      "type": "snell",
      "tag": "snell-v6",
      "server": "$SERVER",
      "server_port": $SNELL_V6_PORT,
      "version": 6,
      "psk": "$SNELL_PSK",
      "reuse": true
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "rule_set": "geoip-cn",
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "type": "remote",
        "tag": "geoip-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
      }
    ],
    "final": "PROXY",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-ali",
    "default_http_client": "via-proxy"
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "store_fakeip": true
    }
  }
}
CONFIG
}

# Sends LAN traffic around the TUN so devices on the LAN can reach this one.
# 172.19.0.0/16 stays routed because it holds the TUN's own address.
SINGBOX_LAN_ROUTES='.inbounds[0].route_exclude_address = [
  "10.0.0.0/8", "169.254.0.0/16", "172.16.0.0/15", "172.18.0.0/16",
  "172.20.0.0/14", "172.24.0.0/13", "192.168.0.0/16"
]'

singbox_client_pc() {
  singbox_client_config "$SINGBOX_LAN_ROUTES | .inbounds[0].strict_route = true"
}

singbox_client_android() {
  singbox_client_config "$SINGBOX_LAN_ROUTES"
}

singbox_client_ios() {
  singbox_client_config .
}

# mihomo has no Snell v6 client, so that node is left out.
clash_client_common() {
  cat << CONFIG
# Written by sb.sh. Contains credentials, so keep this file private.
mode: rule
log-level: warning
ipv6: true
profile:
  store-selected: true
  store-fake-ip: true
geo-auto-update: true
geo-update-interval: 168
geox-url:
  mmdb: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country-lite.mmdb"
dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "+.home.arpa"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
  default-nameserver:
    - 223.5.5.5
  nameserver:
    - 223.5.5.5
  nameserver-policy:
    "+.lan": system
    "+.local": system
    "+.home.arpa": system
proxies:
  - name: reality
    type: vless
    server: "$SERVER"
    port: $VLESS_PORT
    uuid: "$VLESS_UUID"
    flow: xtls-rprx-vision
    packet-encoding: xudp
    udp: true
    tls: true
    servername: "$SNI"
    client-fingerprint: chrome
    reality-opts:
      public-key: "$REALITY_PUBLIC"
      short-id: "$REALITY_SHORT_ID"
  - name: hysteria2
    type: hysteria2
    server: "$SERVER"
    port: $HY2_PORT
    password: "$HY2_PASSWORD"
    sni: "$SNI"
    skip-cert-verify: true
    alpn:
      - h3
  - name: tuic
    type: tuic
    server: "$SERVER"
    port: $TUIC_PORT
    uuid: "$VLESS_UUID"
    password: "$HY2_PASSWORD"
    congestion-controller: bbr
    udp-relay-mode: native
    sni: "$SNI"
    skip-cert-verify: true
    alpn:
      - h3
  - name: snell-v5
    type: snell
    server: "$SERVER"
    port: $SNELL_PORT
    psk: "$SNELL_PSK"
    version: 4
    udp: true
    reuse: true
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - reality
      - hysteria2
      - tuic
      - snell-v5
rules:
  - IP-CIDR,10.0.0.0/8,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,169.254.0.0/16,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR6,::1/128,DIRECT
  - IP-CIDR6,fc00::/7,DIRECT
  - IP-CIDR6,fe80::/10,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
CONFIG
}

clash_client_pc() {
  clash_client_common
  cat << 'CONFIG'
mixed-port: 7890
tun:
  enable: true
  auto-route: true
  auto-detect-interface: true
  strict-route: true
  dns-hijack:
    - any:53
    - tcp://any:53
  route-exclude-address:
    - 10.0.0.0/8
    - 169.254.0.0/16
    - 172.16.0.0/12
    - 192.168.0.0/16
CONFIG
}

# No local proxy port: other apps on a phone could find and use it.
clash_client_mobile() {
  clash_client_common
  cat << 'CONFIG'
find-process-mode: "off"
tun:
  enable: true
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
    - tcp://any:53
CONFIG
}

# Egern has no Snell v6 client, and is only available on Apple devices.
egern_client() {
  cat << CONFIG
# Written by sb.sh. Contains credentials, so keep this file private.
ipv6: true
hijack_dns:
  - "*"
real_ip_domains:
  - "*.lan"
  - "*.local"
  - "*.home.arpa"
dns:
  bootstrap:
    - 223.5.5.5
  forward:
    - domain_suffix:
        match: lan
        value: system
    - domain_suffix:
        match: local
        value: system
    - domain_suffix:
        match: home.arpa
        value: system
proxies:
  - vless:
      name: reality
      server: "$SERVER"
      port: $VLESS_PORT
      user_id: "$VLESS_UUID"
      flow: xtls-rprx-vision
      udp_relay: true
      transport:
        tls:
          sni: "$SNI"
          reality:
            public_key: "$REALITY_PUBLIC"
            short_id: "$REALITY_SHORT_ID"
  - hysteria2:
      name: hysteria2
      server: "$SERVER"
      port: $HY2_PORT
      auth: "$HY2_PASSWORD"
      sni: "$SNI"
      skip_tls_verify: true
  - tuic:
      name: tuic
      server: "$SERVER"
      port: $TUIC_PORT
      uuid: "$VLESS_UUID"
      password: "$HY2_PASSWORD"
      udp_relay_mode: native
      alpn:
        - h3
      sni: "$SNI"
      skip_tls_verify: true
  - snell:
      name: snell-v5
      server: "$SERVER"
      port: $SNELL_PORT
      psk: "$SNELL_PSK"
      version: 4
      udp_relay: true
      reuse: true
policy_groups:
  - select:
      name: PROXY
      policies:
        - reality
        - hysteria2
        - tuic
        - snell-v5
rules:
  - ip_cidr:
      match: 10.0.0.0/8
      policy: DIRECT
  - ip_cidr:
      match: 127.0.0.0/8
      policy: DIRECT
  - ip_cidr:
      match: 169.254.0.0/16
      policy: DIRECT
  - ip_cidr:
      match: 172.16.0.0/12
      policy: DIRECT
  - ip_cidr:
      match: 192.168.0.0/16
      policy: DIRECT
  - ip_cidr6:
      match: "::1/128"
      policy: DIRECT
  - ip_cidr6:
      match: "fc00::/7"
      policy: DIRECT
  - ip_cidr6:
      match: "fe80::/10"
      policy: DIRECT
  - geoip:
      match: CN
      policy: DIRECT
  - default:
      policy: PROXY
CONFIG
}

write_client_file() {
  client_file="$BASE_DIR/$1"
  touch "$client_file" && chmod 600 "$client_file" || die "could not create $client_file"
  "$2" > "$client_file" || die "could not write $client_file"
}

write_client_configs() {
  load_credentials
  detect_server
  if [ "$SERVER" = "<your-server-ip>" ]; then
    warn "could not detect this server's public IP; client configs were not written"
    return 1
  fi
  (
    umask 077
    write_client_file clash-pc.yaml clash_client_pc
    write_client_file clash-mobile.yaml clash_client_mobile
    write_client_file singbox-pc.json singbox_client_pc
    write_client_file singbox-android.json singbox_client_android
    write_client_file singbox-ios.json singbox_client_ios
    write_client_file egern.yaml egern_client
    rm -rf "$OLD_CLIENT_DIR"
  ) || return 1

  printf '%s========================================================%s\n' "$C_BOLD" "$C_RESET"
  printf '%s  Config files%s\n' "$C_BOLD" "$C_RESET"
  printf '%s========================================================%s\n' "$C_BOLD" "$C_RESET"
  printf '  %s\n\n' "$BASE_DIR"
  printf '  Clash (PC/Mac)       clash-pc.yaml\n'
  printf '  Clash (Android/iOS)  clash-mobile.yaml\n'
  printf '  sing-box (PC/Mac)    singbox-pc.json\n'
  printf '  sing-box (Android)   singbox-android.json\n'
  printf '  sing-box (iOS)       singbox-ios.json\n'
  printf '  Egern (Apple)        egern.yaml\n\n'
}

uninstall() {
  log "stopping and removing sing-box"
  case "$INIT" in
    systemd)
      systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
      systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
      rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/$SERVICE_NAME"
      ;;
  esac
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  stop_rotator
  rm -rf "$CONF_DIR" "$OLD_CLIENT_DIR" "$LOG_DIR" "$BIN_PATH" "$PID_FILE" "$ROTATOR_PID_FILE" "$BASE_DIR"/dl.*
  for client_file in $CLIENT_FILES; do
    rm -f "$BASE_DIR/$client_file"
  done
  rmdir "$BASE_DIR" 2>/dev/null || true
  ok "removed sing-box, its configuration, and its service"
}

do_install() {
  log "distribution: $DISTRO ($DISTRO_FAMILY), init: $INIT"
  if [ "$DISTRO_FAMILY" = unknown ] && [ "$INIT" = none ]; then
    warn "unrecognised platform; continuing with manual dependency handling"
  fi

  ensure_deps
  ensure_binary
  ensure_dirs
  generate_credentials

  log "writing configuration to $CONF_FILE"
  write_config

  if ! "$BIN_PATH" check -c "$CONF_FILE" >/dev/null 2>&1; then
    "$BIN_PATH" check -c "$CONF_FILE" || true
    die "generated configuration failed validation"
  fi
  ok "configuration validated"

  check_reality_dest
  rm -f "$CONF_DIR/tune.sh"

  stop_existing
  install_service
  log "starting sing-box"
  start_service
  verify_listening
  show_links
  write_client_configs || warn "client configs were not written; try: $0 --client-config"
}

case "$MODE" in
  install)   do_install ;;
  show)
    [ -f "$CONF_FILE" ] || die "no installation found at $CONF_FILE"
    show_links
    ;;
  client-config)
    [ -f "$CONF_FILE" ] || die "no installation found at $CONF_FILE"
    write_client_configs || exit 1
    ;;
  uninstall) uninstall ;;
esac
