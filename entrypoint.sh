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
# resolver at 127.0.0.11. nginx needs that resolver to look up upstream names,
# so the symptom is nginx refusing to start rather than a per-upstream failure.
if grep -qiE '^[[:space:]]*DNS[[:space:]]*=' "$RUN_CONF"; then
    log "stripping 'DNS =' — it would clobber Docker's resolver at 127.0.0.11"
    sed -i -E '/^[[:space:]]*DNS[[:space:]]*=/d' "$RUN_CONF"
fi

# WireGuard only rehandshakes when it has traffic to send. Without
# PersistentKeepalive an idle tunnel's last handshake ages past
# WG_HANDSHAKE_MAX_AGE, which makes the healthcheck report unhealthy and makes
# the watchdog below tear down a perfectly good interface every 60 seconds.
# Configs generated above already carry it; mounted ones frequently do not.
_ka="${WG_KEEPALIVE:-25}"
if [[ "$_ka" != "0" && "$_ka" != "off" ]]; then
    _tmp="$(mktemp "/run/wg/${WG_IF}.XXXXXX")"
    awk -v ka="$_ka" '
        /^[[:space:]]*\[/ {
            if (in_peer && !has_ka) print "PersistentKeepalive = " ka
            in_peer = (tolower($0) ~ /^[[:space:]]*\[peer\]/)
            has_ka = 0
            print
            next
        }
        in_peer && tolower($0) ~ /^[[:space:]]*persistentkeepalive[[:space:]]*=/ { has_ka = 1 }
        { print }
        END { if (in_peer && !has_ka) print "PersistentKeepalive = " ka }
    ' "$RUN_CONF" > "$_tmp"
    if ! cmp -s "$RUN_CONF" "$_tmp"; then
        log "adding 'PersistentKeepalive = ${_ka}' — without it an idle tunnel's"
        log "         handshake goes stale and the watchdog restarts it for nothing"
    fi
    cat "$_tmp" > "$RUN_CONF"
    rm -f "$_tmp"
fi

_default_route=0
if grep -qE '^[[:space:]]*AllowedIPs.*(0\.0\.0\.0/0|::/0)' "$RUN_CONF"; then
    _default_route=1
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

# Listeners bind 0.0.0.0, which includes wg0. Without an access rule the far
# side of the tunnel can dial back in and be proxied straight into the private
# network. An explicit ALLOW_FROM wins; otherwise deny exactly the ranges the
# tunnel routes and leave the Docker networks open.
ALLOW_BLOCK=""
if [[ -n "${ALLOW_FROM:-}" ]]; then
    IFS=',' read -ra _cidrs <<< "$ALLOW_FROM"
    for _c in "${_cidrs[@]}"; do
        _c="${_c//[[:space:]]/}"
        [[ -n "$_c" ]] && ALLOW_BLOCK+="    allow ${_c};"$'\n'
    done
    ALLOW_BLOCK+="    deny all;"$'\n'
elif [[ "${DENY_FROM_TUNNEL:-true}" == "true" ]]; then
    if [[ "$_default_route" -eq 1 ]]; then
        log "WARNING: not auto-denying tunnel sources — AllowedIPs is a default"
        log "         route, so the deny list would match everything. Set ALLOW_FROM."
    else
        _denied=""
        while IFS= read -r _c; do
            [[ -n "$_c" ]] || continue
            ALLOW_BLOCK+="    deny ${_c};"$'\n'
            _denied+=" ${_c}"
        done < <(grep -iE '^[[:space:]]*AllowedIPs[[:space:]]*=' "$RUN_CONF" \
                 | cut -d= -f2- | tr ',' '\n' | tr -d ' \t\r' | grep -v '^$' | sort -u)
        if [[ -n "$ALLOW_BLOCK" ]]; then
            ALLOW_BLOCK+="    allow all;"$'\n'
            log "denying new connections from tunnel-routed ranges:${_denied}"
            log "         (DENY_FROM_TUNNEL=false to disable, or set ALLOW_FROM to be explicit)"
        fi
    fi
fi

srv_id=0

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
    # Also decides literal-vs-name below, and keeps the value from carrying
    # nginx syntax into the generated file.
    [[ "$uhost" =~ ^[A-Za-z0-9._-]+$ || "$uhost" =~ ^\[[0-9A-Fa-f:]+\]$ ]] \
        || die "bad upstream host '${uhost}' in '${spec}' — use a name, IPv4, or bracketed [IPv6]"

    srv_id=$((srv_id + 1))
    log "forward ${proto^^} :${listen} -> ${uhost}:${uport}"

    {
        echo "server {"
        if [[ "$proto" == "udp" ]]; then
            echo "    listen ${listen} udp;"
        else
            echo "    listen ${listen};"
        fi
        printf '%s' "$ALLOW_BLOCK"
        if [[ "$uhost" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$uhost" =~ ^\[ ]]; then
            # Literal address: resolved at config load and checked by nginx -t.
            echo "    proxy_pass ${uhost}:${uport};"
        else
            # Name: routed through a variable so nginx re-resolves it on the
            # resolver's valid= interval. A literal proxy_pass with a name is
            # resolved once at config load and then pinned for the life of the
            # container, stranding the forward if the upstream address moves.
            echo "    set \$upstream_${srv_id} ${uhost}:${uport};"
            echo "    proxy_pass \$upstream_${srv_id};"
        fi
        echo "    proxy_connect_timeout ${PROXY_CONNECT_TIMEOUT:-10s};"
        if [[ "$proto" == "udp" ]]; then
            # A datagram has no close, so proxy_timeout is how long each UDP
            # session stays pinned. The TCP default of 1h would exhaust
            # worker_connections after a few thousand DNS queries.
            echo "    proxy_timeout ${UDP_PROXY_TIMEOUT:-30s};"
            if [[ -n "${UDP_PROXY_RESPONSES:-}" ]]; then
                echo "    proxy_responses ${UDP_PROXY_RESPONSES};"
            fi
        else
            echo "    proxy_timeout ${PROXY_TIMEOUT:-1h};"
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

if [[ "$found" -eq 0 ]]; then
    # $GEN has already been created, so it has to be excluded from this probe —
    # a plain glob over the directory always matches it, which would make this
    # check dead and let a typo'd FORWARD_1 start a gateway listening on nothing.
    mounted=0
    for _f in "${STREAM_DIR}"/*.conf; do
        [[ -e "$_f" && "$_f" != "$GEN" ]] || continue
        mounted=1
        break
    done
    [[ "$mounted" -eq 1 ]] || die "no forwards defined — set FORWARD_1=LISTEN:HOST:PORT or mount ${STREAM_DIR}/*.conf"
    log "no FORWARD_* variables set — using mounted ${STREAM_DIR}/*.conf only"
    rm -f "$GEN"
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
