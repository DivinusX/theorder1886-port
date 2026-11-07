#!/usr/bin/env bash
# Fixed scenario timeline — identical every run.
# t+48 hold Space (title -> menu), t+63 hold Space (CONTINUAR -> load checkpoint),
# t+88 shot (loading), t+108 shot (scene in), then 5 look-arounds every 12 s with shots.
# Run alongside: bash harness/run.sh <label> <cold|warm> 180
W=/var/home/Pixel/Documents/order1886-perf-work
sleep 48; $W/harness/nav.sh hold Space; sleep 15; $W/harness/nav.sh hold Space
sleep 25; $W/harness/nav.sh shot
sleep 20; $W/harness/nav.sh shot
for i in 1 2 3 4 5; do sleep 12; $W/harness/nav.sh move 120 0; done
$W/harness/nav.sh shot
