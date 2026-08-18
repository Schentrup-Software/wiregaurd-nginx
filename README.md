# wiregaurd-nginx

An nginx TCP/UDP stream proxy with a WireGuard client built in. One container:
apps on a Docker network connect to it by name, and it forwards them over the
tunnel to a private network.

Built for Docker hosts managed through a UI like Yacht, where
`network_mode: "service:..."` isn't expressible and a second sidecar container
is awkward. Everything is set through environment variables.

```
app containers ──► wg-gateway:5432 ──wg0──► 10.13.13.1:5432   (home Postgres)
                   wg-gateway:9000 ──wg0──► 10.13.13.1:9000   (home S3)
```

Containers **not** attached to the gateway's Docker network have no route to it
and therefore no path to the private network at all. That network membership is
the access control — there are no firewall rules to maintain.

---

## Quick start in Yacht

**Image:** `ghcr.io/<you>/wg-stream-gateway:latest`

**Capabilities:** add `NET_ADMIN`.

**Networks:** attach only to the network shared with the services allowed to
reach home (e.g. `vpn-access`). Do not attach it to your general proxy network.

**Ports:** publish none. Consumers reach it by container name over the Docker
network.

**Volumes** (option A — reuse an existing tunnel config):

| Host | Container |
|---|---|
| `/opt/wg-gateway/wg0.conf` | `/etc/wireguard/wg0.conf` (read-only is fine) |

**Environment** (option B — no file, config from variables):

| Variable | Example | Notes |
|---|---|---|
| `WG_PRIVATE_KEY` | `yAnZ...=` | this client's key |
| `WG_ADDRESS` | `10.13.13.2/32` | address on the tunnel |
| `WG_PEER_PUBLIC_KEY` | `HIgo...=` | the home server's public key |
| `WG_ENDPOINT` | `home.example.com:51820` | |
| `WG_ALLOWED_IPS` | `10.13.13.0/24, 192.168.1.0/24` | what's routed into the tunnel |
| `WG_PRESHARED_KEY` | optional | |
| `WG_MTU` | `1380` | default; lower it if handshakes stall |
| `WG_KEEPALIVE` | `25` | default |

**Forwards** — one variable per service:

| Variable | Example |
|---|---|
| `FORWARD_1` | `5432:192.168.1.20:5432` |
| `FORWARD_2` | `9000:192.168.1.20:9000` |
| `UDP_FORWARD_1` | `53:192.168.1.1:53` |

Syntax is `LISTEN:UPSTREAM_HOST:UPSTREAM_PORT`. `FORWARDS=5432:host:5432,9000:host:9000`
works too if you'd rather have one variable.

Apps then use `wg-gateway` as the hostname:

```
DB_HOST=wg-gateway   DB_PORT=5432
S3_ENDPOINT=http://wg-gateway:9000
```

Granting a service access is adding the `vpn-access` network to it. Revoking is
removing it. Both are ordinary container edits.

---

## Other settings

| Variable | Default | Purpose |
|---|---|---|
| `ALLOW_FROM` | unset | Comma-separated CIDRs. Emits `allow`/`deny all` on every generated listener. Takes precedence over `DENY_FROM_TUNNEL`. |
| `DENY_FROM_TUNNEL` | `true` | When `ALLOW_FROM` is unset, deny new connections coming *from* the ranges in `AllowedIPs`. Listeners bind `0.0.0.0`, which includes `wg0`, so without this the far side of the tunnel can dial back in and be proxied into the private network. Skipped with a warning if `AllowedIPs` is a default route, since the deny list would then match everything. |
| `PROXY_TIMEOUT` | `1h` | Idle timeout for TCP listeners. nginx's own default is 10 minutes, which silently kills pooled database connections. |
| `PROXY_CONNECT_TIMEOUT` | `10s` | |
| `UDP_PROXY_TIMEOUT` | `30s` | Idle timeout for UDP listeners, kept separate from `PROXY_TIMEOUT`. A datagram has no close, so this is how long each UDP session is pinned; at the TCP default of `1h` a few thousand DNS queries would exhaust `worker_connections`. |
| `UDP_PROXY_RESPONSES` | unset | Datagrams expected back per datagram sent. Set to `1` for strict request/response protocols like DNS to free the session as soon as the reply arrives. Unset means unlimited, ended by `UDP_PROXY_TIMEOUT`. |
| `WG_INTERFACE` | `wg0` | |
| `WG_WATCHDOG` | `true` | Re-up the interface when handshakes go stale. WireGuard does not re-resolve a DNS endpoint on its own, so a home connection on a dynamic IP otherwise stays dead after a WAN change. |
| `WG_HANDSHAKE_MAX_AGE` | `300` | Seconds. Also drives the Docker healthcheck. |

For anything the variables don't cover, mount extra files into
`/etc/nginx/stream.d/` — they're included alongside the generated ones. Note
that `ALLOW_FROM` and `DENY_FROM_TUNNEL` only apply to listeners this image
generates; write the `allow`/`deny` rules yourself in files you mount.

---

## Notes

**Set `PROXY_TIMEOUT` above your longest idle period**, and your connection
pool's `max_lifetime` below it, so the pool recycles connections before the
proxy closes them. Otherwise you get intermittent resets at arbitrary moments.

**Don't put a default route in `WG_ALLOWED_IPS`.** With `0.0.0.0/0`, `wg-quick`
installs policy routing that suppresses the main table's default route, so
replies to externally-originated connections go down the tunnel. Container-to-
container traffic keeps working, which makes it confusing to diagnose. The
entrypoint warns if it sees one.

**No `DNS =` line.** `wg-quick` honours it by rewriting `/etc/resolv.conf`,
which destroys Docker's embedded resolver, which is what nginx uses to look up
upstream names. The entrypoint strips the line and logs that it did.

**Upstream names are re-resolved at runtime.** A forward whose upstream is a
hostname is emitted through an nginx variable, so the address is re-checked on
the resolver's `valid=` interval (10s) instead of being pinned at config load
for the life of the container. Forwards to a literal address are emitted
directly and still validated by `nginx -t` at startup. Note the resolver is
*Docker's*, not the tunnel's — a name only the remote network's DNS can answer
will not resolve, so use an address for those.

**`PersistentKeepalive` is added if missing.** WireGuard only rehandshakes when
it has traffic to send, so an idle tunnel without it goes longer than
`WG_HANDSHAKE_MAX_AGE` between handshakes — which reads as failure to both the
healthcheck and the watchdog, and gets a perfectly good interface restarted
every 60 seconds. Mounted configs frequently omit it, so the entrypoint adds it
to any `[Peer]` that has none. Set `WG_KEEPALIVE=0` to opt out.

**Kernel module.** Uses the host's WireGuard module when present. If it's
missing, `wg-quick` falls back to the bundled `wireguard-go`, which needs
`/dev/net/tun` mapped into the container and is noticeably slower. Alpine no
longer packages `wireguard-go`, so the Dockerfile cross-compiles it from a
pinned upstream commit in a builder stage.

**Client IPs are not preserved.** Upstream services see the gateway's tunnel
address. Fine for databases and object stores; don't put anything
IP-authenticated behind it.

**Not for mail.** If you proxy SMTP through this, inbound SPF is evaluated
against the gateway's address rather than the sending server's, and most MTAs'
fail2ban equivalents will eventually ban the gateway itself. Map mail ports
straight to the mail container.

---

## Threat model

The gateway holds tunnel credentials and can reach whatever `WG_ALLOWED_IPS`
permits. There is no admin UI and no runtime configuration surface — changing
what it forwards requires changing environment variables and recreating the
container, which is a meaningfully higher bar than a leaked web password.

Listeners bind all interfaces, `wg0` included, so the far side of the tunnel
can reach the forwards too. By default the entrypoint denies new connections
originating from the ranges in `AllowedIPs`, which closes that path without
having to guess your Docker subnets; `ALLOW_FROM` replaces that with an explicit
allowlist, and `DENY_FROM_TUNNEL=false` turns it off.

What it does **not** protect against: an attacker with write access to your
Docker host or container definitions. If `WG_ALLOWED_IPS` covers the whole home
LAN, compromise of this container or the host is equivalent to LAN access.
Narrowing `AllowedIPs` to the specific hosts you need is the cheapest way to
bound that, and it's enforced by WireGuard in-kernel rather than by
configuration this container can rewrite.

---

## Building

```bash
docker build -t wg-stream-gateway .
```

Push to GHCR by putting this repo on GitHub — `.github/workflows/publish.yml`
builds `linux/amd64` and `linux/arm64` on every push to `main` and on `v*` tags,
publishing to `ghcr.io/<owner>/<repo>`. Make the package public in the repo's
Packages settings if you want to pull it without authenticating.

## Tests

```bash
./tests/run.sh              # everything
./tests/run.sh unit         # config generation only, ~10s, no tunnel
./tests/run.sh integration  # full rig
./tests/run.sh --keep       # leave it running to poke at
```

The unit suite runs the real entrypoint with `wg-quick` stubbed out and a real
`nginx -t`, so it covers config generation and proves what it generates parses.

The integration suite stands up an actual tunnel: a WireGuard server container
with dummy TCP, HTTP and UDP services behind it on a private Docker network.
The gateway is deliberately **not** attached to that network, so the tunnel is
the only path — if it is down or the forwards are wrong, the tests fail rather
than quietly succeeding over a Docker bridge, and one test asserts exactly that
by checking the tester cannot reach the services directly.

```
tester ──client── gateway ──transit── wg-server ──home── svc-{tcp,http,udp}
                     └────────── wg0 ──────────────┘
```

It also covers the things that are easy to get wrong and hard to notice: that
the tunnel counters actually moved, that the far side of the tunnel cannot dial
back in through a forward, and that a container on another network has no route
at all. Both suites run in CI, and the image is not published unless they pass.

Requires a host that can create WireGuard interfaces in a container — any recent
Linux kernel, Docker Desktop, or a GitHub runner.

## License

MIT
