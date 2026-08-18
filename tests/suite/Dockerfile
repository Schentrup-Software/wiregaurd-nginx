FROM alpine:3.21

# bash  : bats needs it
# bats  : test runner
# socat : TCP/UDP probes against the forwards
# curl  : HTTP probe through the proxy
RUN apk add --no-cache bash bats socat curl

WORKDIR /suite
ENTRYPOINT ["bats"]
CMD ["--print-output-on-failure", "/suite/integration.bats"]
