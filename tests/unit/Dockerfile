# Built FROM the image under test so the real entrypoint and a real `nginx -t`
# are exercised. Only wg-quick and wg are stubbed, since bringing up a tunnel is
# the integration suite's job.
ARG GATEWAY_IMAGE=wg-stream-gateway:test
FROM ${GATEWAY_IMAGE}

RUN apk add --no-cache bats

# /usr/local/sbin precedes /usr/bin and /usr/sbin on Alpine's default PATH.
RUN mkdir -p /usr/local/sbin \
    && printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/wg-quick \
    && printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/wg \
    # Keep real config validation, but make the daemon start a no-op so the
    # entrypoint returns a usable exit code instead of blocking forever.
    && printf '#!/bin/sh\ncase "$1" in -t) exec /usr/sbin/nginx -t ;; esac\nexit 0\n' \
        > /usr/local/sbin/nginx \
    && chmod +x /usr/local/sbin/wg-quick /usr/local/sbin/wg /usr/local/sbin/nginx

WORKDIR /unit
ENTRYPOINT ["bats"]
CMD ["--print-output-on-failure", "/unit/generate.bats"]
