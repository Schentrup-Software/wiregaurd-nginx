#!/bin/bash
# Stands in for the home WireGuard server. Accepts the gateway as a peer and
# forwards its traffic onto HOME_SUBNET, masquerading so the dummy services can
# reply without needing a route back to the tunnel.
set -euo pipefail

log() { printf '[wg-server] %s\n' "$*" >&2; }

: "${SERVER_PRIVATE_KEY:?}" "${CLIENT_PUBLIC_KEY:?}" "${PRESHARED_KEY:?}"
: "${HOME_SUBNET:?}" "${TUNNEL_SUBNET:?}"

ip link add wg0 type wireguard
ip addr add "${TUNNEL_SUBNET%.*}.1/24" dev wg0

umask 077
printf '%s\n' "$SERVER_PRIVATE_KEY" > /run/server.key
printf '%s\n' "$PRESHARED_KEY"      > /run/psk

wg set wg0 \
    listen-port 51820 \
    private-key /run/server.key \
    peer "$CLIENT_PUBLIC_KEY" \
        preshared-key /run/psk \
        allowed-ips "${TUNNEL_SUBNET%.*}.2/32"

ip link set wg0 up

# The interface that faces the private network, found by address rather than by
# assuming a name — Docker's ordering is not stable.
home_if="$(ip -o -4 addr show | awk -v net="${HOME_SUBNET%.*}." '$4 ~ net {print $2; exit}')"
[[ -n "$home_if" ]] || { log "ERROR: no interface on ${HOME_SUBNET}"; exit 1; }
log "routing tunnel traffic onto ${home_if} (${HOME_SUBNET})"

# Set by compose at container creation; /proc/sys is read-only in here, so this
# can only be checked, not written.
[[ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]]     || { log "ERROR: ip_forward is off — the compose file must set it"; exit 1; }
iptables -t nat -A POSTROUTING -s "$TUNNEL_SUBNET" -o "$home_if" -j MASQUERADE
iptables -A FORWARD -i wg0 -o "$home_if" -j ACCEPT
iptables -A FORWARD -i "$home_if" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

log "up — listening on :51820, peer ${CLIENT_PUBLIC_KEY}"
exec sleep infinity
