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
| `ALLOW_FROM` | unset | Comma-separated CIDRs. Emits `allow`/`deny all` on every listener. Set to your Docker subnet to stop the tunnel's far side dialling back in. |
| `PROXY_TIMEOUT` | `1h` | Idle timeout. nginx's own default is 10 minutes, which silently kills pooled database connections. |
| `PROXY_CONNECT_TIMEOUT` | `10s` | |
| `WG_INTERFACE` | `wg0` | |
| `WG_WATCHDOG` | `true` | Re-up the interface when handshakes go stale. WireGuard does not re-resolve a DNS endpoint on its own, so a home connection on a dynamic IP otherwise stays dead after a WAN change. |
| `WG_HANDSHAKE_MAX_AGE` | `300` | Seconds. Also drives the Docker healthcheck. |

For anything the variables don't cover, mount extra files into
`/etc/nginx/stream.d/` — they're included alongside the generated ones.

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
which destroys Docker's embedded resolver — and since nginx resolves upstream
names at config load, nginx then refuses to start entirely. The entrypoint
strips the line and logs that it did.

**Kernel module.** Uses the host's WireGuard module when present. If it's
missing, `wg-quick` falls back to the bundled `wireguard-go`, which needs
`/dev/net/tun` mapped into the container and is noticeably slower.

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

## License

MIT
