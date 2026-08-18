# The "home" side of the tunnel: a WireGuard server that also routes into the
# private network the dummy services sit on. Only used by the test suite.
FROM alpine:3.21

# socat is used by the control suite to probe the gateway from the tunnel side.
RUN apk add --no-cache bash iproute2 iptables socat wireguard-tools

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
