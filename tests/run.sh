#!/usr/bin/env bash
# Test driver.
#
#   ./tests/run.sh            unit + integration
#   ./tests/run.sh unit       config generation only (fast, no tunnel)
#   ./tests/run.sh integration
#   ./tests/run.sh --keep     leave the rig up afterwards for poking at
#
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE=(docker compose -f docker-compose.test.yml)
export MSYS_NO_PATHCONV=1     # keep Git Bash from mangling container paths

WHICH="all"
KEEP=0
for arg in "$@"; do
    case "$arg" in
        unit|integration|all) WHICH="$arg" ;;
        --keep) KEEP=1 ;;
        *) echo "usage: $0 [unit|integration|all] [--keep]" >&2; exit 2 ;;
    esac
done

cleanup() {
    if [[ "$KEEP" -eq 1 ]]; then
        echo "==> leaving the rig up (docker compose -f tests/docker-compose.test.yml down -v to clean)"
    else
        echo "==> tearing down"
        "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

rc=0

# The unit image builds FROM the gateway image, so that tag has to exist first.
echo "==> building the image under test"
"${COMPOSE[@]}" build gateway

if [[ "$WHICH" == "unit" || "$WHICH" == "all" ]]; then
    echo "==> unit: config generation"
    "${COMPOSE[@]}" build unit
    "${COMPOSE[@]}" run --rm --no-deps unit || rc=1
fi

if [[ "$WHICH" == "integration" || "$WHICH" == "all" ]]; then
    echo "==> building the rig"
    "${COMPOSE[@]}" build wg-server tester control

    echo "==> starting the rig (waiting for the gateway to report healthy)"
    "${COMPOSE[@]}" up -d --wait wg-server svc-tcp svc-http svc-udp gateway outsider || {
        echo "!! the rig did not come up healthy; logs follow" >&2
        "${COMPOSE[@]}" logs --no-color gateway wg-server >&2 || true
        exit 1
    }

    echo "==> integration: data plane"
    "${COMPOSE[@]}" run --rm tester || rc=1

    echo "==> integration: tunnel and access control"
    "${COMPOSE[@]}" run --rm --no-deps control || rc=1

    if [[ "$rc" -ne 0 ]]; then
        echo "!! failures — gateway logs follow" >&2
        "${COMPOSE[@]}" logs --no-color --tail 60 gateway >&2 || true
    fi
fi

[[ "$rc" -eq 0 ]] && echo "==> PASS" || echo "==> FAIL"
exit "$rc"
