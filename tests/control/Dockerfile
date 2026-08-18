FROM alpine:3.21

# Runs the assertions that need to look at the rig from outside: container
# health, tunnel counters, and the view from containers other than the tester.
# Needs the Docker socket, which is why this is a test-only image.
RUN apk add --no-cache bash bats docker-cli

WORKDIR /control
ENTRYPOINT ["bats"]
CMD ["--print-output-on-failure", "/control/control.bats"]
