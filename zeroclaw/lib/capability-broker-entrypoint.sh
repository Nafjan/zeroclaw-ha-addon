#!/bin/sh
# Bound one untrusted local capability request so a stalled planner cannot
# monopolize the root-owned listener.
exec timeout 35 /usr/local/bin/ha-broker-handler
