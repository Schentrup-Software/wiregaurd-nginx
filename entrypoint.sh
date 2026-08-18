#!/bin/bash
set -euo pipefail

log()  { printf '[gateway] %s\n' "$*" >&2; }
die()  { printf '[gateway] ERROR: %s\n' "$*" >&2; exit 1; }

WG_IF="${WG_INTERFACE:-wg0}"
SRC_CONF="/etc/wireguard/${WG_IF}.conf"
RUN_CONF="/run/wg/${WG_IF}.conf"
STREAM_DIR="/etc/nginx/stream.d"
GEN="${STREAM_DIR}/10-forwards.conf"

###############################################################################
# 1. WireGuard configuration
#    A mounted /etc/wireguard/<iface>.conf always wins. Otherwise one is built
#    from environment variables so the whole thing can be driven from Yacht.
###############################################################################

mkdir -p /run/wg && chmod 700 /run/wg

if [[ -f "$SRC_CONF" ]]; then
    log "using mounted ${SRC_CONF}"
    cp "$SRC_CONF" "$RUN_CONF"        # copy so a :ro mount can still be edited below
else
    [[ -n "${WG_PRIVATE_KEY:-}"     ]] || die "no ${SRC_CONF} mounted, and WG_PRIVATE_KEY is unset"
    [[ -n "${WG_ADDRESS:-}"         ]] || die "WG_ADDRESS is required"
    [[ -n "${WG_PEER_PUBLIC_KEY:-}" ]] || die "WG_PEER_PUBLIC_KEY is required"
    [[ -n "${WG_ENDPOINT:-}"        ]] || die "WG_ENDPOINT is required"
    [[ -n "${WG_ALLOWED_IPS:-}"     ]] || die "WG_ALLOWED_IPS is required"

    log "generating ${WG_IF} config from environment"
    {
        echo "[Interface]"
        echo "Address = ${WG_ADDRESS}"
        echo "PrivateKey = ${WG_PRIVATE_KEY}"
        echo "MTU = ${WG_MTU:-1380}"
        echo
        echo "[Peer]"
        echo "PublicKey = ${WG_PEER_PUBLIC_KEY}"
        if [[ -n "${WG_PRESHARED_KEY:-}" ]]; then
            echo "PresharedKey = ${WG_PRESHARED_KEY}"
        fi
        echo "Endpoint = ${WG_ENDPOINT}"
        echo "AllowedIPs = ${WG_ALLOWED_IPS}"
        echo "PersistentKeepalive = ${WG_KEEPALIVE:-25}"
    } > "$RUN_CONF"
fi

chmod 600 "$RUN_CONF"

# `DNS =` makes wg-quick rewrite /etc/resolv.conf, destroying Docker's embedded
# resolver at 127.0.0.11. nginx resolves upstream names at config load, so the
# symptom is nginx refusing to start rather than a per-upstream failure.
if grep -qiE '^[[:space:]]*DNS[[:space:]]*=' "$RUN_CONF"; then
    log "stripping 'DNS =' — it would clobber Docker's resolver at 127.0.0.11"
    sed -i -E '/^[[:space:]]*DNS[[:space:]]*=/d' "$RUN_CONF"
fi

if grep -qE '^[[:space:]]*AllowedIPs.*(0\.0\.0\.0/0|::/0)' "$RUN_CONF"; then
    log "WARNING: AllowedIPs contains a default route."
    log "         wg-quick will install policy routing that sends replies to"
    log "         externally-originated connections down the tunnel, so any"
    log "         published port on this container will stop answering."
    log "         Narrow AllowedIPs to the subnets you actually need."
fi

###############################################################################
# 2. Stream forwards
#    FORWARD_<n>=LISTEN:UPSTREAM_HOST:UPSTREAM_PORT   (TCP)
#    UDP_FORWARD_<n>=LISTEN:UPSTREAM_HOST:UPSTREAM_PORT
#    FORWARDS=a,b,c  — same syntax, comma separated, TCP
###############################################################################

ALLOW_BLOCK=""
if [[ -n "${ALLOW_FROM:-}" ]]; then
    IFS=',' read -ra _cidrs <<< "$ALLOW_FROM"
    for _c in "${_cidrs[@]}"; do
        _c="${_c//[[:space:]]/}"
        [[ -n "$_c" ]] && ALLOW_BLOCK+="    allow ${_c};"$'\n'
    done
    ALLOW_BLOCK+="    deny all;"$'\n'
fi

emit() {
    local proto="$1" spec="$2"
    local listen rest uhost uport

    listen="${spec%%:*}"
    rest="${spec#*:}"
    [[ "$rest" != "$spec" ]] || die "bad forward '${spec}' — expected LISTEN:HOST:PORT"
    uport="${rest##*:}"
    uhost="${rest%:*}"

    [[ "$listen" =~ ^[0-9]+$ ]] || die "bad listen port in '${spec}'"
    [[ "$uport"  =~ ^[0-9]+$ ]] || die "bad upstream port in '${spec}'"
    [[ -n "$uhost" ]]           || die "missing upstream host in '${spec}'"

    log "forward ${proto^^} :${listen} -> ${uhost}:${uport}"

    {
        echo "server {"
        if [[ "$proto" == "udp" ]]; then
            echo "    listen ${listen} udp;"
        else
            echo "    listen ${listen};"
        fi
        printf '%s' "$ALLOW_BLOCK"
        echo "    proxy_pass ${uhost}:${uport};"
        echo "    proxy_connect_timeout ${PROXY_CONNECT_TIMEOUT:-10s};"
        echo "    proxy_timeout ${PROXY_TIMEOUT:-1h};"
        if [[ "$proto" != "udp" ]]; then
            echo "    proxy_socket_keepalive on;"
        fi
        echo "}"
        echo
    } >> "$GEN"
}

: > "$GEN"
found=0

while IFS= read -r line; do
    emit tcp "${line#*=}"; found=1
done < <(env | grep -E '^FORWARD_[0-9]+=' | sort -V)

while IFS= read -r line; do
    emit udp "${line#*=}"; found=1
done < <(env | grep -E '^UDP_FORWARD_[0-9]+=' | sort -V)

if [[ -n "${FORWARDS:-}" ]]; then
    IFS=',' read -ra _specs <<< "$FORWARDS"
    for _s in "${_specs[@]}"; do
        _s="${_s//[[:space:]]/}"
        [[ -n "$_s" ]] && { emit tcp "$_s"; found=1; }
    done
fi

if [[ "$found" -eq 0 ]] && ! compgen -G "${STREAM_DIR}/*.conf" > /dev/null; then
    die "no forwards defined — set FORWARD_1=LISTEN:HOST:PORT or mount ${STREAM_DIR}/*.conf"
fi

###############################################################################
# 3. Bring up the tunnel, then nginx
###############################################################################

log "bringing up ${WG_IF}"
wg-quick up "$RUN_CONF"

shutdown() {
    log "shutting down"
    [[ -n "${NGINX_PID:-}" ]] && kill -QUIT "$NGINX_PID" 2>/dev/null || true
    wg-quick down "$RUN_CONF" >/dev/null 2>&1 || true
    exit 0
}
trap shutdown INT TERM

nginx -t
nginx -g 'daemon off;' &
NGINX_PID=$!
log "nginx started (pid ${NGINX_PID})"

# Optional watchdog: WireGuard will not re-resolve a DNS endpoint on its own, so
# a home connection on a dynamic IP can stay dead indefinitely after a WAN
# change. Re-up the interface when handshakes go stale.
if [[ "${WG_WATCHDOG:-true}" == "true" ]]; then
    (
        max_age="${WG_HANDSHAKE_MAX_AGE:-300}"
        sleep 60
        while sleep 60; do
            hs="$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')" || continue
            [[ -n "$hs" ]] || continue
            if [[ "$hs" -eq 0 ]] || (( $(date +%s) - hs > max_age )); then
                log "watchdog: no handshake in >${max_age}s, restarting ${WG_IF}"
                wg-quick down "$RUN_CONF" >/dev/null 2>&1 || true
                wg-quick up   "$RUN_CONF" >/dev/null 2>&1 || log "watchdog: bring-up failed"
            fi
        done
    ) &
fi

wait "$NGINX_PID"
