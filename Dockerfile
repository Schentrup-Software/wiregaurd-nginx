# wireguard-go is no longer packaged by Alpine (dropped after 3.18), so the
# userspace fallback is compiled here. Cross-compiled from the build platform
# rather than emulated, which keeps the arm64 leg of the CI matrix cheap.
FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS wireguard-go
ARG TARGETARCH
# Upstream publishes no release tags, only pseudo-versions; pin one so the build
# is reproducible. The module root is package main and installs as `wireguard`,
# but wg-quick only falls back to a binary named exactly `wireguard-go`.
ARG WIREGUARD_GO_VERSION=v0.0.0-20260522210424-ecfc5a8d5446
ENV CGO_ENABLED=0 GOOS=linux
RUN apk add --no-cache git
RUN GOARCH="$TARGETARCH" \
        go install "golang.zx2c4.com/wireguard@${WIREGUARD_GO_VERSION}" \
    && find /go/bin -type f -name wireguard -exec cp {} /wireguard-go \; \
    && test -x /wireguard-go

FROM nginx:1.27-alpine

# wireguard-tools  : wg + wg-quick
# iproute2         : wg-quick needs `ip`
# iptables         : only used by wg-quick when AllowedIPs contains a default route
# bash             : wg-quick is a bash script
RUN apk add --no-cache \
        bash \
        iproute2 \
        iptables \
        wireguard-tools \
    && mkdir -p /etc/nginx/stream.d /etc/nginx/http.d /etc/wireguard \
    && rm -f /etc/nginx/conf.d/default.conf

# Userspace fallback when the host has no kernel module. wg-quick picks it up
# from PATH on its own; it also needs /dev/net/tun mapped into the container.
COPY --from=wireguard-go /wireguard-go /usr/bin/wireguard-go

COPY nginx.conf    /etc/nginx/nginx.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

LABEL org.opencontainers.image.title="wg-stream-gateway" \
      org.opencontainers.image.description="nginx stream proxy with a built-in WireGuard client, for reaching private networks from Docker" \
      org.opencontainers.image.licenses="MIT"
