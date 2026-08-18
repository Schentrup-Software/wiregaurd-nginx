#!/usr/bin/env bats
#
# Assertions that need a view the tester container does not have: the gateway's
# health status, the tunnel's own counters, and what other containers can reach.
# Containers are found by compose label rather than by generated name.

PROJECT="${COMPOSE_PROJECT_NAME:-wg-stream-gateway-tests}"

cid() {
    docker ps -q \
        --filter "label=com.docker.compose.project=${PROJECT}" \
        --filter "label=com.docker.compose.service=$1" | head -1
}

setup() {
    GATEWAY="$(cid gateway)"
    WG_SERVER="$(cid wg-server)"
    OUTSIDER="$(cid outsider)"
    [ -n "$GATEWAY" ] || skip "gateway container not running"
}

# --- tunnel is genuinely carrying the traffic --------------------------------

@test "gateway reports healthy" {
    run docker inspect --format '{{.State.Health.Status}}' "$GATEWAY"
    [ "$status" -eq 0 ]
    [ "$output" = "healthy" ]
}

@test "tunnel has a recent handshake" {
    run docker exec "$GATEWAY" wg show wg0 latest-handshakes
    [ "$status" -eq 0 ]
    hs="$(echo "$output" | awk 'NR==1{print $2}')"
    [ -n "$hs" ]
    [ "$hs" -ne 0 ]
    age=$(( $(date +%s) - hs ))
    [ "$age" -lt 180 ]
}

@test "traffic actually traversed the tunnel" {
    # If the forwards were somehow succeeding over a Docker bridge these
    # counters would still be at zero.
    run docker exec "$GATEWAY" wg show wg0 transfer
    [ "$status" -eq 0 ]
    rx="$(echo "$output" | awk 'NR==1{print $2}')"
    tx="$(echo "$output" | awk 'NR==1{print $3}')"
    [ "$rx" -gt 0 ]
    [ "$tx" -gt 0 ]
}

# --- access control -----------------------------------------------------------

@test "the probe used for the deny test actually works" {
    # Positive control, so the deny test below cannot pass just because socat is
    # missing or the payload changed.
    [ -n "$WG_SERVER" ] || skip "wg-server not running"
    run docker exec "$WG_SERVER" socat -T5 -U - TCP:172.31.0.20:5432
    [ "$status" -eq 0 ]
    [[ "$output" == *"HOME-TCP-OK"* ]]
}

@test "the far side of the tunnel cannot dial back in through a forward" {
    # DENY_FROM_TUNNEL derives `deny` rules from AllowedIPs, so a connection
    # sourced from the tunnel must not be proxied into the private network.
    # nginx accepts the TCP connection and then drops it, so the assertion is on
    # the payload rather than on the exit status.
    [ -n "$WG_SERVER" ] || skip "wg-server not running"
    run docker exec "$WG_SERVER" socat -T5 -U - TCP:10.13.13.2:5432
    [[ "$output" != *"HOME-TCP-OK"* ]]

    run docker exec "$WG_SERVER" socat -T5 -U - TCP:10.13.13.2:9000
    [[ "$output" != *"HOME-HTTP-OK"* ]]
}

@test "a container off the gateway's network cannot reach it at all" {
    [ -n "$OUTSIDER" ] || skip "outsider not running"
    run docker exec "$OUTSIDER" getent hosts gateway
    [ "$status" -ne 0 ]
}

# --- generated configuration --------------------------------------------------

@test "UDP forwards get their own short timeout, not the TCP default" {
    run docker exec "$GATEWAY" cat /etc/nginx/stream.d/10-forwards.conf
    [ "$status" -eq 0 ]
    udp_block="$(echo "$output" | awk '/listen 5353 udp;/,/^}/')"
    [[ "$udp_block" == *"proxy_timeout 30s;"* ]]
    [[ "$udp_block" != *"proxy_timeout 1h;"* ]]
}

@test "hostname upstreams go through a variable, literal addresses do not" {
    run docker exec "$GATEWAY" cat /etc/nginx/stream.d/10-forwards.conf
    [ "$status" -eq 0 ]
    [[ "$output" == *'set $upstream_'*'nonexistent.invalid:80;'* ]]
    [[ "$output" == *"proxy_pass 172.31.0.20:5432;"* ]]
}

@test "tunnel-routed ranges are denied on every generated listener" {
    run docker exec "$GATEWAY" cat /etc/nginx/stream.d/10-forwards.conf
    [ "$status" -eq 0 ]
    servers="$(echo "$output" | grep -c '^server {')"
    denies="$(echo "$output" | grep -c 'deny 172.31.0.0/24;')"
    [ "$servers" -eq "$denies" ]
}

@test "PersistentKeepalive is present so handshakes stay fresh" {
    run docker exec "$GATEWAY" cat /run/wg/wg0.conf
    [ "$status" -eq 0 ]
    [[ "$output" == *"PersistentKeepalive"* ]]
}
