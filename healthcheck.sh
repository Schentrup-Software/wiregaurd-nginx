#!/bin/sh
# Unhealthy if the tunnel has no recent handshake, or nginx has died.
set -eu

IF="${WG_INTERFACE:-wg0}"
MAX_AGE="${WG_HANDSHAKE_MAX_AGE:-300}"

HS="$(wg show "$IF" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')" || exit 1
[ -n "${HS:-}" ] || exit 1
[ "$HS" -ne 0 ] || exit 1
[ $(( $(date +%s) - HS )) -lt "$MAX_AGE" ] || exit 1

[ -s /var/run/nginx.pid ] || exit 1
kill -0 "$(cat /var/run/nginx.pid)" 2>/dev/null || exit 1

exit 0
