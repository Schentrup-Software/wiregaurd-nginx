#!/usr/bin/env bats
#
# Config generation, run against the real entrypoint with wg-quick stubbed out.
# `nginx -t` is real, so every case that is expected to start also proves the
# generated stream config actually parses.

CONF=/etc/nginx/stream.d/10-forwards.conf
WGCONF=/run/wg/wg0.conf

setup() {
    rm -rf /etc/nginx/stream.d /run/wg /etc/wireguard/wg0.conf
    mkdir -p /etc/nginx/stream.d
    # Cleared per test so each one starts from a known environment.
    unset FORWARDS ALLOW_FROM DENY_FROM_TUNNEL UDP_PROXY_TIMEOUT \
          UDP_PROXY_RESPONSES PROXY_TIMEOUT WG_KEEPALIVE
    for v in $(env | grep -oE '^(UDP_)?FORWARD_[0-9]+' || true); do unset "$v"; done
    export WG_WATCHDOG=false
    export WG_PRIVATE_KEY=sNUzsCOfYmRErEyAnMNW6n4W1z+g7kT6BT2izLHjTkw=
    export WG_ADDRESS=10.13.13.2/32
    export WG_PEER_PUBLIC_KEY=oLnZj3sH8QthL2iVqwXHJ/n6sxrOnfS6dE/rQuBYRQ4=
    export WG_ENDPOINT=192.0.2.1:51820
    export WG_ALLOWED_IPS="10.13.13.0/24, 192.168.1.0/24"
}

gen() { run /usr/local/bin/entrypoint.sh; }

# --- the guard against starting with nothing to forward -----------------------

@test "no forwards at all is a hard error" {
    gen
    [ "$status" -ne 0 ]
    [[ "$output" == *"no forwards defined"* ]]
}

@test "a misspelled FORWARD_1 is a hard error, not a silent no-op" {
    # The failure this guards against: the gateway starts, listens on nothing,
    # and every consumer gets connection-refused with no explanation.
    export FOWARD_1=5432:192.168.1.20:5432
    gen
    [ "$status" -ne 0 ]
    [[ "$output" == *"no forwards defined"* ]]
}

@test "a mounted stream.d file is enough on its own" {
    echo 'server { listen 1234; proxy_pass 192.168.1.20:1234; }' \
        > /etc/nginx/stream.d/99-custom.conf
    gen
    [ "$status" -eq 0 ]
    [ ! -e "$CONF" ]        # the empty generated file is cleaned up
}

# --- forward parsing ----------------------------------------------------------

@test "FORWARD_n, UDP_FORWARD_n and FORWARDS all produce listeners" {
    export FORWARD_1=5432:192.168.1.20:5432
    export UDP_FORWARD_1=53:192.168.1.1:53
    export FORWARDS=8080:192.168.1.30:80,8081:192.168.1.31:80
    gen
    [ "$status" -eq 0 ]
    [ "$(grep -c '^server {' "$CONF")" -eq 4 ]
    grep -q 'listen 53 udp;' "$CONF"
}

@test "malformed forwards are rejected" {
    for spec in "5432" "5432:host" "5432::5432" "notaport:host:5432"; do
        setup
        export FORWARD_1="$spec"
        gen
        [ "$status" -ne 0 ] || { echo "accepted bad spec: $spec"; return 1; }
    done
}

@test "an upstream host carrying nginx syntax is rejected" {
    export FORWARD_1='5432:host;}server{listen 9999;proxy_pass evil:80;}#:5432'
    gen
    [ "$status" -ne 0 ]
    [[ "$output" == *"bad upstream host"* ]]
}

@test "IPv6 upstreams must be bracketed, and are accepted when they are" {
    export FORWARD_1=5432:fd00::1:5432
    gen
    [ "$status" -ne 0 ]

    setup
    export FORWARD_1='5432:[fd00::1]:5432'
    gen
    [ "$status" -eq 0 ]
    grep -q 'proxy_pass \[fd00::1\]:5432;' "$CONF"
}

# --- timeouts -----------------------------------------------------------------

@test "UDP listeners get a short timeout and TCP listeners keep the long one" {
    export FORWARD_1=5432:192.168.1.20:5432
    export UDP_FORWARD_1=53:192.168.1.1:53
    gen
    [ "$status" -eq 0 ]
    [[ "$(awk '/listen 5432;/,/^}/' "$CONF")" == *"proxy_timeout 1h;"* ]]
    [[ "$(awk '/listen 53 udp;/,/^}/' "$CONF")" == *"proxy_timeout 30s;"* ]]
}

@test "UDP timeout and responses are overridable" {
    export UDP_FORWARD_1=53:192.168.1.1:53
    export UDP_PROXY_TIMEOUT=5s UDP_PROXY_RESPONSES=1
    gen
    [ "$status" -eq 0 ]
    grep -q 'proxy_timeout 5s;'   "$CONF"
    grep -q 'proxy_responses 1;'  "$CONF"
}

@test "proxy_responses is omitted unless asked for" {
    export UDP_FORWARD_1=53:192.168.1.1:53
    gen
    [ "$status" -eq 0 ]
    ! grep -q 'proxy_responses' "$CONF"
}

# --- upstream resolution ------------------------------------------------------

@test "hostname upstreams go through a variable so they are re-resolved" {
    export FORWARD_1=9000:minio.home.lan:9000
    gen
    [ "$status" -eq 0 ]
    grep -q 'set \$upstream_1 minio.home.lan:9000;' "$CONF"
    grep -q 'proxy_pass \$upstream_1;' "$CONF"
}

@test "literal addresses are passed straight through" {
    export FORWARD_1=5432:192.168.1.20:5432
    gen
    [ "$status" -eq 0 ]
    grep -q 'proxy_pass 192.168.1.20:5432;' "$CONF"
    ! grep -q 'set \$upstream' "$CONF"
}

@test "an unresolvable hostname upstream still lets nginx -t pass" {
    export FORWARD_1=9000:nonexistent.invalid:9000
    gen
    [ "$status" -eq 0 ]
}

# --- access control -----------------------------------------------------------

@test "tunnel-routed ranges are denied by default" {
    export FORWARD_1=5432:192.168.1.20:5432
    gen
    [ "$status" -eq 0 ]
    grep -q 'deny 10.13.13.0/24;'  "$CONF"
    grep -q 'deny 192.168.1.0/24;' "$CONF"
    grep -q 'allow all;'           "$CONF"
}

@test "ALLOW_FROM replaces the default deny list" {
    export FORWARD_1=5432:192.168.1.20:5432
    export ALLOW_FROM=172.16.0.0/12
    gen
    [ "$status" -eq 0 ]
    grep -q 'allow 172.16.0.0/12;' "$CONF"
    grep -q 'deny all;'            "$CONF"
    ! grep -q 'deny 192.168.1.0/24;' "$CONF"
}

@test "DENY_FROM_TUNNEL=false leaves listeners open" {
    export FORWARD_1=5432:192.168.1.20:5432
    export DENY_FROM_TUNNEL=false
    gen
    [ "$status" -eq 0 ]
    ! grep -qE '^\s+(deny|allow)' "$CONF"
}

@test "a default route disables the deny list rather than denying everything" {
    export FORWARD_1=5432:192.168.1.20:5432
    export WG_ALLOWED_IPS=0.0.0.0/0
    gen
    [ "$status" -eq 0 ]
    [[ "$output" == *"not auto-denying tunnel sources"* ]]
    ! grep -q 'deny' "$CONF"
}

# --- WireGuard config handling ------------------------------------------------

@test "PersistentKeepalive is added to a mounted config that lacks it" {
    cat > /etc/wireguard/wg0.conf <<'EOF'
[Interface]
Address = 10.13.13.2/32
PrivateKey = sNUzsCOfYmRErEyAnMNW6n4W1z+g7kT6BT2izLHjTkw=

[Peer]
PublicKey = oLnZj3sH8QthL2iVqwXHJ/n6sxrOnfS6dE/rQuBYRQ4=
Endpoint = 192.0.2.1:51820
AllowedIPs = 10.13.13.0/24
EOF
    export FORWARD_1=5432:10.13.13.1:5432
    gen
    [ "$status" -eq 0 ]
    [ "$(grep -c 'PersistentKeepalive' "$WGCONF")" -eq 1 ]
    [[ "$output" == *"adding 'PersistentKeepalive"* ]]
}

@test "an existing PersistentKeepalive is left alone" {
    cat > /etc/wireguard/wg0.conf <<'EOF'
[Interface]
Address = 10.13.13.2/32
PrivateKey = sNUzsCOfYmRErEyAnMNW6n4W1z+g7kT6BT2izLHjTkw=

[Peer]
PublicKey = oLnZj3sH8QthL2iVqwXHJ/n6sxrOnfS6dE/rQuBYRQ4=
Endpoint = 192.0.2.1:51820
AllowedIPs = 10.13.13.0/24
PersistentKeepalive = 15
EOF
    export FORWARD_1=5432:10.13.13.1:5432
    gen
    [ "$status" -eq 0 ]
    [ "$(grep -c 'PersistentKeepalive' "$WGCONF")" -eq 1 ]
    grep -q 'PersistentKeepalive = 15' "$WGCONF"
}

@test "WG_KEEPALIVE=0 opts out of the injection" {
    cat > /etc/wireguard/wg0.conf <<'EOF'
[Interface]
Address = 10.13.13.2/32
PrivateKey = sNUzsCOfYmRErEyAnMNW6n4W1z+g7kT6BT2izLHjTkw=

[Peer]
PublicKey = oLnZj3sH8QthL2iVqwXHJ/n6sxrOnfS6dE/rQuBYRQ4=
Endpoint = 192.0.2.1:51820
AllowedIPs = 10.13.13.0/24
EOF
    export FORWARD_1=5432:10.13.13.1:5432 WG_KEEPALIVE=0
    gen
    [ "$status" -eq 0 ]
    ! grep -q 'PersistentKeepalive' "$WGCONF"
}

@test "a DNS line is stripped so Docker's resolver survives" {
    cat > /etc/wireguard/wg0.conf <<'EOF'
[Interface]
Address = 10.13.13.2/32
PrivateKey = sNUzsCOfYmRErEyAnMNW6n4W1z+g7kT6BT2izLHjTkw=
DNS = 10.13.13.1

[Peer]
PublicKey = oLnZj3sH8QthL2iVqwXHJ/n6sxrOnfS6dE/rQuBYRQ4=
Endpoint = 192.0.2.1:51820
AllowedIPs = 10.13.13.0/24
EOF
    export FORWARD_1=5432:10.13.13.1:5432
    gen
    [ "$status" -eq 0 ]
    ! grep -qi '^\s*DNS\s*=' "$WGCONF"
    [[ "$output" == *"stripping 'DNS ='"* ]]
}

@test "missing required variables are reported individually" {
    unset WG_ADDRESS
    export FORWARD_1=5432:192.168.1.20:5432
    gen
    [ "$status" -ne 0 ]
    [[ "$output" == *"WG_ADDRESS is required"* ]]
}
