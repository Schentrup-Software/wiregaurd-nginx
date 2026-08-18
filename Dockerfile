FROM nginx:1.27-alpine

# wireguard-tools  : wg + wg-quick
# wireguard-go     : userspace fallback when the host has no kernel module
# iproute2         : wg-quick needs `ip`
# iptables         : only used by wg-quick when AllowedIPs contains a default route
# bash             : wg-quick is a bash script
RUN apk add --no-cache \
        bash \
        iproute2 \
        iptables \
        wireguard-tools \
        wireguard-go \
    && mkdir -p /etc/nginx/stream.d /etc/nginx/http.d /etc/wireguard \
    && rm -f /etc/nginx/conf.d/default.conf

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
