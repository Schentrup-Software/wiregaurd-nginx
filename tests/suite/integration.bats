#!/usr/bin/env bats
#
# Data-plane tests. These run from a container on `client` only, exactly like a
# real consumer: it knows the gateway by name and nothing else. Every assertion
# here can only pass if the tunnel is up and nginx is forwarding, because the
# tester has no route to 172.31.0.0/24 by any other means — which is what the
# last test in this file checks.
#
# socat flags worth knowing here:
#   -U   read only from the second address, so the probe does not half-close the
#        connection the instant stdin is empty and miss the reply
#   -T   inactivity timeout, the upper bound on a hung probe

GW=gateway

@test "TCP forward reaches the home service through the tunnel" {
    run socat -T5 -U - "TCP:${GW}:5432"
    [ "$status" -eq 0 ]
    [[ "$output" == *"HOME-TCP-OK"* ]]
}

@test "HTTP forward reaches the home service through the tunnel" {
    run curl -sS --max-time 10 "http://${GW}:9000/"
    [ "$status" -eq 0 ]
    [[ "$output" == *"HOME-HTTP-OK"* ]]
}

@test "UDP forward reaches the home service through the tunnel" {
    run bash -c "printf 'probe' | socat -t2 -T5 - UDP:${GW}:5353"
    [ "$status" -eq 0 ]
    [[ "$output" == *"HOME-UDP-OK"* ]]
}

@test "a forward with an unresolvable upstream does not stop the gateway starting" {
    # Regression test for the resolver fix. A literal `proxy_pass name:port`
    # makes nginx refuse to load the entire config, so the container never comes
    # up and every other forward dies with it. With the variable form nginx
    # listens on this port and only this one forward fails at connect time.
    run socat -T3 /dev/null "TCP:${GW}:9002"
    [ "$status" -eq 0 ]
}

@test "a port with no forward behind it is refused" {
    # Control for the test above: proves accepting on 9002 means something.
    run socat -T3 /dev/null "TCP:${GW}:9999"
    [ "$status" -ne 0 ]
}

@test "the tester has no route to the private network except through the gateway" {
    # Without this, every test above could be quietly succeeding over a Docker
    # bridge instead of the tunnel.
    run socat -T3 -U - TCP:172.31.0.20:5432
    [ "$status" -ne 0 ]
    [[ "$output" != *"HOME-TCP-OK"* ]]
}
